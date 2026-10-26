//
//  IPTVLiveChannelGrouping.swift
//  Yattee
//
//  Groups raw Xtream live streams without losing server-provided variants or order.
//

import Foundation

enum IPTVAnnouncedResolution: String, Codable, Hashable, Sendable {
    case ultraHD4K
    case fullHD
    case highDefinition
    case standardDefinition
}

struct IPTVLiveStreamAttributes: Codable, Hashable, Sendable {
    let announcedResolution: IPTVAnnouncedResolution?
    let usesHEVC: Bool
}

struct IPTVLiveChannelVariant: Hashable, Sendable {
    let stream: XtreamLiveStream
    let attributes: IPTVLiveStreamAttributes
}

struct IPTVLiveChannelGroup: Identifiable, Hashable, Sendable {
    struct ID: Codable, Hashable, Sendable {
        let sourceID: UUID
        let categoryID: String?
        let normalizedName: String
    }

    let id: ID
    let sourceID: UUID
    let categoryID: String?
    let displayName: String
    let isDecorativeSeparator: Bool
    let variants: [IPTVLiveChannelVariant]
}

enum IPTVLiveChannelGrouper {
    static func groups(
        sourceID: UUID,
        streams: [XtreamLiveStream]
    ) -> [IPTVLiveChannelGroup] {
        var groups: [IPTVLiveChannelGroup] = []
        var groupIndexes: [IPTVLiveChannelGroup.ID: Int] = [:]

        for stream in streams {
            let normalizedName = normalizeName(stream.name)
            let identityName = groupingKey(for: normalizedName)
            let id = IPTVLiveChannelGroup.ID(
                sourceID: sourceID,
                categoryID: stream.categoryID,
                normalizedName: identityName
            )
            let variant = IPTVLiveChannelVariant(
                stream: stream,
                attributes: attributes(for: stream.name)
            )

            if let index = groupIndexes[id] {
                let existing = groups[index]
                groups[index] = IPTVLiveChannelGroup(
                    id: existing.id,
                    sourceID: existing.sourceID,
                    categoryID: existing.categoryID,
                    displayName: existing.displayName,
                    isDecorativeSeparator: existing.isDecorativeSeparator,
                    variants: existing.variants + [variant]
                )
            } else {
                groupIndexes[id] = groups.count
                groups.append(
                    IPTVLiveChannelGroup(
                        id: id,
                        sourceID: sourceID,
                        categoryID: stream.categoryID,
                        displayName: normalizedName,
                        isDecorativeSeparator: isDecorativeSeparator(stream.name),
                        variants: [variant]
                    )
                )
            }
        }

        return groups
    }

    static func normalizeName(_ rawName: String) -> String {
        var name = collapseWhitespace(rawName)
        name = removingDecorativeCountryPrefix(from: name)

        while let range = name.range(
            of: #"(?i)(?:^|[\s|/_\-])(?:[\[(]\s*)?(?:UHD|4K|FHD|HD|SD|H[ .-]?265|HEVC)(?:\s*[\])])?\s*$"#,
            options: .regularExpression
        ) {
            let shortened = String(name[..<range.lowerBound])
            let trimmed = trimDecorativeEdge(shortened)
            guard !trimmed.isEmpty else { break }
            name = trimmed
        }

        let normalized = collapseWhitespace(name)
        return normalized.isEmpty ? collapseWhitespace(rawName) : normalized
    }

    static func attributes(for rawName: String) -> IPTVLiveStreamAttributes {
        let uppercasedName = rawName.uppercased()
        let resolution: IPTVAnnouncedResolution?
        if containsMarker("UHD", in: uppercasedName) || containsMarker("4K", in: uppercasedName) {
            resolution = .ultraHD4K
        } else if containsMarker("FHD", in: uppercasedName) {
            resolution = .fullHD
        } else if containsMarker("HD", in: uppercasedName) {
            resolution = .highDefinition
        } else if containsMarker("SD", in: uppercasedName) {
            resolution = .standardDefinition
        } else {
            resolution = nil
        }

        return IPTVLiveStreamAttributes(
            announcedResolution: resolution,
            usesHEVC: containsMarker("HEVC", in: uppercasedName)
                || uppercasedName.range(
                    of: #"(?:^|[\s|/_\-\[(])H[ .-]?265(?:$|[\s|/_\-\])])"#,
                    options: .regularExpression
                ) != nil
        )
    }

    static func isDecorativeSeparator(_ rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.unicodeScalars.allSatisfy {
            !CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func removingDecorativeCountryPrefix(from name: String) -> String {
        var result = removingLeadingFlags(from: name)
        let codes = "FR|BE|CH|UK|GB|US|CA|DE|ES|IT|PT"
        let pattern = #"(?i)^\s*(?:\[(?:"# + codes + #")\]|\((?:"# + codes + #")\)|(?:"# + codes + #")\s*[:|\-])\s*"#

        while let range = result.range(of: pattern, options: .regularExpression) {
            let stripped = String(result[range.upperBound...])
            guard !stripped.isEmpty else { break }
            result = removingLeadingFlags(from: stripped)
        }
        return collapseWhitespace(result)
    }

    private static func removingLeadingFlags(from name: String) -> String {
        var scalars = Array(name.unicodeScalars)
        var removedFlag = false

        while true {
            while let first = scalars.first,
                  CharacterSet.whitespacesAndNewlines.contains(first) {
                scalars.removeFirst()
            }
            guard scalars.count >= 2,
                  isRegionalIndicator(scalars[0]),
                  isRegionalIndicator(scalars[1]) else {
                break
            }
            scalars.removeFirst(2)
            removedFlag = true
        }

        guard removedFlag else { return name }
        var result = ""
        for scalar in scalars {
            result.append(contentsOf: String(scalar))
        }
        result = trimDecorativeEdge(result)
        return result
    }

    private static func isRegionalIndicator(_ scalar: UnicodeScalar) -> Bool {
        (0x1F1E6 ... 0x1F1FF).contains(scalar.value)
    }

    private static func containsMarker(_ marker: String, in name: String) -> Bool {
        let escapedMarker = NSRegularExpression.escapedPattern(for: marker)
        return name.range(
            of: "(?:^|[\\s|/_\\-\\[(])\(escapedMarker)(?:$|[\\s|/_\\-\\])])",
            options: .regularExpression
        ) != nil
    }

    private static func groupingKey(for name: String) -> String {
        collapseWhitespace(name).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func trimDecorativeEdge(_ value: String) -> String {
        value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|/-_"))
        )
    }
}
