//
//  IPTVChannelEPGAssociation.swift
//  Yattee
//
//  Associates grouped Xtream channels with exact XMLTV identifiers and schedules.
//

import Foundation

struct IPTVChannelEPGAssociation: Hashable, Sendable {
    let groupID: IPTVLiveChannelGroup.ID
    let primaryChannelID: EPGChannelID?
    let alternativeChannelIDs: [EPGChannelID]

    var channelIDs: [EPGChannelID] {
        primaryChannelID.map { [$0] + alternativeChannelIDs } ?? []
    }
}

struct IPTVChannelEPGNowNext: Hashable, Sendable {
    let channelID: EPGChannelID
    let currentProgram: EPGProgram?
    let nextProgram: EPGProgram?
}

struct IPTVChannelEPGAssociator: Sendable {
    private let catalog: EPGCatalog

    init(catalog: EPGCatalog) {
        self.catalog = catalog
    }

    func association(for group: IPTVLiveChannelGroup) -> IPTVChannelEPGAssociation {
        var channelIDs: [EPGChannelID] = []
        var seenIDs: Set<EPGChannelID> = []

        for variant in group.variants {
            guard let rawChannelID = variant.stream.epgChannelID else { continue }
            let channelID = EPGChannelID(rawValue: rawChannelID)
            if seenIDs.insert(channelID).inserted {
                channelIDs.append(channelID)
            }
        }

        return IPTVChannelEPGAssociation(
            groupID: group.id,
            primaryChannelID: channelIDs.first,
            alternativeChannelIDs: Array(channelIDs.dropFirst())
        )
    }

    func nowAndNext(
        for group: IPTVLiveChannelGroup,
        at date: Date
    ) -> IPTVChannelEPGNowNext? {
        let association = association(for: group)
        guard let channelID = association.channelIDs.first(where: {
            !catalog.programs(for: $0).isEmpty
        }) ?? association.primaryChannelID else { return nil }
        return nowAndNext(for: association, channelID: channelID, at: date)
    }

    func nowAndNext(
        for association: IPTVChannelEPGAssociation,
        channelID: EPGChannelID,
        at date: Date
    ) -> IPTVChannelEPGNowNext? {
        guard association.channelIDs.contains(channelID) else { return nil }

        let programs = catalog.programs(for: channelID)
        let insertionIndex = firstProgramStarting(after: date, in: programs)
        let currentProgram = currentProgram(
            at: date,
            in: programs,
            before: insertionIndex
        )
        let nextStart = currentProgram?.end ?? date
        let nextIndex = firstProgramStarting(atOrAfter: nextStart, in: programs)
        let nextProgram = programs.indices.contains(nextIndex) ? programs[nextIndex] : nil

        return IPTVChannelEPGNowNext(
            channelID: channelID,
            currentProgram: currentProgram,
            nextProgram: nextProgram
        )
    }

    func upcomingPrograms(
        for association: IPTVChannelEPGAssociation,
        channelID: EPGChannelID,
        startingAt date: Date,
        limit: Int
    ) -> [EPGProgram] {
        guard limit > 0, association.channelIDs.contains(channelID) else { return [] }
        let programs = catalog.programs(for: channelID)
        let startIndex = firstProgramStarting(atOrAfter: date, in: programs)
        guard programs.indices.contains(startIndex) else { return [] }
        return Array(programs[startIndex...].prefix(limit))
    }

    private func firstProgramStarting(after date: Date, in programs: [EPGProgram]) -> Int {
        var lowerBound = 0
        var upperBound = programs.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if programs[middle].start <= date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func firstProgramStarting(atOrAfter date: Date, in programs: [EPGProgram]) -> Int {
        var lowerBound = 0
        var upperBound = programs.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if programs[middle].start < date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func currentProgram(
        at date: Date,
        in programs: [EPGProgram],
        before insertionIndex: Int
    ) -> EPGProgram? {
        guard insertionIndex > 0 else { return nil }
        return programs[..<insertionIndex].reversed().first { program in
            program.start <= date && date < program.end
        }
    }
}
