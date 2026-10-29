//
//  XMLTVParser.swift
//  Yattee
//
//  Progressively decodes XMLTV channels and programmes without building a DOM.
//

import Foundation

enum XMLTVParserError: Error, LocalizedError, Equatable, Sendable {
    case invalidDocument

    var errorDescription: String? {
        "The XMLTV document is not well formed."
    }
}

struct XMLTVParser: Sendable {
    func parse(data: Data) throws -> EPGCatalog {
        try parse(stream: InputStream(data: data))
    }

    /// Parses incrementally from the supplied stream without building an XML tree.
    func parse(
        stream: InputStream,
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
    ) throws -> EPGCatalog {
        let delegate = XMLTVParserDelegate(cancellationCheck: cancellationCheck)
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            if delegate.wasCancelled {
                throw CancellationError()
            }
            throw XMLTVParserError.invalidDocument
        }
        return delegate.catalog()
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private struct ChannelDraft {
        let id: EPGChannelID
        var displayName: String?
    }

    private struct ProgramDraft {
        let channelID: EPGChannelID?
        let start: Date?
        let end: Date?
        var title: String?
        var description: String?
    }

    private struct ProgramKey: Hashable {
        let channelID: EPGChannelID
        let start: Date
        let end: Date
        let title: String
    }

    private struct ProgramLocation {
        let channelID: EPGChannelID
        let index: Int
    }

    private enum TextField {
        case channelDisplayName
        case programTitle
        case programDescription
    }

    private var channelsByID: [EPGChannelID: EPGChannel] = [:]
    private var programsByChannelID: [EPGChannelID: [EPGProgram]] = [:]
    private var programLocations: [ProgramKey: ProgramLocation] = [:]

    private var channelDraft: ChannelDraft?
    private var programDraft: ProgramDraft?
    private var textField: TextField?
    private var textBuffer = ""
    private let dateParser = XMLTVDateParser()
    private let cancellationCheck: @Sendable () -> Bool
    private(set) var wasCancelled = false

    init(cancellationCheck: @escaping @Sendable () -> Bool) {
        self.cancellationCheck = cancellationCheck
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard continueParsing(parser) else { return }
        switch elementName.lowercased() {
        case "channel":
            let identifier = normalizedText(attributeDict["id"])
            channelDraft = identifier.map {
                ChannelDraft(id: EPGChannelID(rawValue: $0), displayName: nil)
            }

        case "programme":
            let identifier = normalizedText(attributeDict["channel"]).map {
                EPGChannelID(rawValue: $0)
            }
            programDraft = ProgramDraft(
                channelID: identifier,
                start: dateParser.date(from: attributeDict["start"]),
                end: dateParser.date(from: attributeDict["stop"]),
                title: nil,
                description: nil
            )

        case "display-name" where channelDraft != nil:
            beginText(.channelDisplayName)
        case "title" where programDraft != nil:
            beginText(.programTitle)
        case "desc" where programDraft != nil:
            beginText(.programDescription)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard continueParsing(parser) else { return }
        guard textField != nil else { return }
        textBuffer.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName.lowercased() {
        case "display-name":
            if textField == .channelDisplayName,
               let value = normalizedText(textBuffer),
               channelDraft?.displayName == nil {
                channelDraft?.displayName = value
            }
            endText()

        case "title":
            if textField == .programTitle,
               let value = normalizedText(textBuffer),
               programDraft?.title == nil {
                programDraft?.title = value
            }
            endText()

        case "desc":
            if textField == .programDescription,
               let value = normalizedText(textBuffer),
               programDraft?.description == nil {
                programDraft?.description = value
            }
            endText()

        case "channel":
            finishChannel()
        case "programme":
            finishProgram()
        default:
            break
        }
    }

    func catalog() -> EPGCatalog {
        for channelID in Array(programsByChannelID.keys) {
            programsByChannelID[channelID]?.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        programLocations.removeAll(keepingCapacity: false)
        return EPGCatalog(
            channelsByID: channelsByID,
            programsByChannelID: programsByChannelID
        )
    }

    private func beginText(_ field: TextField) {
        textField = field
        textBuffer.removeAll(keepingCapacity: true)
    }

    private func endText() {
        textField = nil
        textBuffer.removeAll(keepingCapacity: true)
    }

    private func finishChannel() {
        defer {
            channelDraft = nil
            endText()
        }
        guard let draft = channelDraft else { return }

        if let existing = channelsByID[draft.id] {
            channelsByID[draft.id] = EPGChannel(
                id: draft.id,
                displayName: existing.displayName ?? draft.displayName
            )
        } else {
            channelsByID[draft.id] = EPGChannel(
                id: draft.id,
                displayName: draft.displayName
            )
        }
    }

    private func finishProgram() {
        defer {
            programDraft = nil
            endText()
        }
        guard let draft = programDraft,
              let channelID = draft.channelID,
              let start = draft.start,
              let end = draft.end,
              end > start,
              let title = normalizedText(draft.title) else {
            return
        }

        let key = ProgramKey(
            channelID: channelID,
            start: start,
            end: end,
            title: title
        )
        let description = normalizedText(draft.description)

        if let location = programLocations[key] {
            guard programsByChannelID[location.channelID]?.indices.contains(location.index) == true,
                  let existing = programsByChannelID[location.channelID]?[location.index],
                  existing.description == nil,
                  let description else {
                return
            }
            programsByChannelID[location.channelID]?[location.index] = EPGProgram(
                epgChannelID: existing.epgChannelID,
                title: existing.title,
                description: description,
                start: existing.start,
                end: existing.end
            )
            return
        }

        let program = EPGProgram(
            epgChannelID: channelID,
            title: title,
            description: description,
            start: start,
            end: end
        )
        let index = programsByChannelID[channelID, default: []].count
        programsByChannelID[channelID, default: []].append(program)
        programLocations[key] = ProgramLocation(channelID: channelID, index: index)
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private func continueParsing(_ parser: XMLParser) -> Bool {
        guard !cancellationCheck() else {
            wasCancelled = true
            parser.abortParsing()
            return false
        }
        return true
    }
}

private final class XMLTVDateParser {
    private var formatters: [String: DateFormatter] = [:]

    func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let components = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let dateComponent = components.first,
              [8, 10, 12, 14].contains(dateComponent.count),
              dateComponent.allSatisfy(\.isNumber),
              components.count <= 2 else {
            return nil
        }

        let timeZoneComponent = components.count == 2 ? components[1] : nil
        if let timeZoneComponent,
           !timeZoneComponent.matchesXMLTVTimeZone {
            return nil
        }

        let format = Self.format(
            dateLength: dateComponent.count,
            hasTimeZone: timeZoneComponent != nil
        )
        let formatter = formatter(for: format)
        return formatter.date(from: components.joined(separator: " "))
    }

    private func formatter(for format: String) -> DateFormatter {
        if let formatter = formatters[format] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = format
        formatters[format] = formatter
        return formatter
    }

    private static func format(dateLength: Int, hasTimeZone: Bool) -> String {
        let dateFormat = switch dateLength {
        case 8: "yyyyMMdd"
        case 10: "yyyyMMddHH"
        case 12: "yyyyMMddHHmm"
        default: "yyyyMMddHHmmss"
        }
        return hasTimeZone ? "\(dateFormat) Z" : dateFormat
    }
}

private extension String {
    var matchesXMLTVTimeZone: Bool {
        count == 5
            && (first == "+" || first == "-")
            && dropFirst().allSatisfy(\.isNumber)
    }
}
