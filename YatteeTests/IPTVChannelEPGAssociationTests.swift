//
//  IPTVChannelEPGAssociationTests.swift
//  YatteeTests
//
//  Tests exact XMLTV association and efficient now/next programme lookup.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Channel EPG Association Tests")
struct IPTVChannelEPGAssociationTests {
    @Test("TF1 quality and H265 variants share their exact EPG identifier")
    func sharedIdentifierAcrossVariants() throws {
        let group = try makeGroup([
            ("1", "TF1 HD", "tf1.fr"),
            ("2", "TF1 FHD", "tf1.fr"),
            ("3", "TF1 FHD H265", "tf1.fr")
        ])
        let association = makeAssociator().association(for: group)

        #expect(association.primaryChannelID == EPGChannelID(rawValue: "tf1.fr"))
        #expect(association.alternativeChannelIDs.isEmpty)
    }

    @Test("Distinct identifiers retain first server occurrence as primary")
    func distinctIdentifiersAreNotMerged() throws {
        let group = try makeGroup([
            ("1", "TF1 HD", "tf1.primary"),
            ("2", "TF1 FHD", "tf1.backup"),
            ("3", "TF1 SD", "tf1.primary")
        ])
        let associator = makeAssociator()
        let association = associator.association(for: group)

        #expect(association.primaryChannelID == EPGChannelID(rawValue: "tf1.primary"))
        #expect(association.alternativeChannelIDs == [EPGChannelID(rawValue: "tf1.backup")])
        #expect(
            associator.nowAndNext(
                for: association,
                channelID: EPGChannelID(rawValue: "tf1.backup"),
                at: date(150)
            )?.currentProgram?.title == "Alternative"
        )
    }

    @Test("A valid primary identifier retains server priority")
    func validPrimaryRetainsPriority() throws {
        let group = try makeGroup([
            ("1", "TF1 HD", "tf1.primary"),
            ("2", "TF1 FHD", "tf1.backup")
        ])

        let result = try #require(makeAssociator().nowAndNext(for: group, at: date(150)))

        #expect(result.channelID == EPGChannelID(rawValue: "tf1.primary"))
        #expect(result.currentProgram?.title == "Morning")
    }

    @Test("An absent primary identifier falls back to the first valid alternative")
    func absentPrimaryFallsBack() throws {
        let group = try makeGroup([
            ("1", "TF1 HD", "missing"),
            ("2", "TF1 FHD", "tf1.backup")
        ])

        let result = try #require(makeAssociator().nowAndNext(for: group, at: date(150)))

        #expect(result.channelID == EPGChannelID(rawValue: "tf1.backup"))
        #expect(result.currentProgram?.title == "Alternative")
    }

    @Test("A primary identifier without programmes falls back to an alternative")
    func emptyPrimaryFallsBack() throws {
        let group = try makeGroup([
            ("1", "TF1 HD", "empty"),
            ("2", "TF1 FHD", "tf1.backup")
        ])

        let result = try #require(makeAssociator().nowAndNext(for: group, at: date(150)))

        #expect(result.channelID == EPGChannelID(rawValue: "tf1.backup"))
        #expect(result.currentProgram?.title == "Alternative")
    }

    @Test("Multiple alternatives preserve server priority")
    func multipleAlternativesPreservePriority() throws {
        let group = try makeGroup([
            ("1", "TF1 HD", "missing"),
            ("2", "TF1 FHD", "tf1.backup"),
            ("3", "TF1 SD", "overlap")
        ])

        let result = try #require(makeAssociator().nowAndNext(for: group, at: date(175)))

        #expect(result.channelID == EPGChannelID(rawValue: "tf1.backup"))
        #expect(result.currentProgram?.title == "Alternative")
    }

    @Test("No valid alternative preserves the primary empty result")
    func noValidAlternativePreservesPrimary() throws {
        let group = try makeGroup([
            ("1", "TF1 HD", "missing.primary"),
            ("2", "TF1 FHD", "missing.backup")
        ])

        let result = try #require(makeAssociator().nowAndNext(for: group, at: date(150)))

        #expect(result.channelID == EPGChannelID(rawValue: "missing.primary"))
        #expect(result.currentProgram == nil)
        #expect(result.nextProgram == nil)
    }

    @Test("Missing and unknown EPG identifiers produce no invented programmes")
    func absentEPG() throws {
        let groupWithoutID = try makeGroup([("1", "TF1 HD", nil)])
        let unknownGroup = try makeGroup([("2", "TF1 HD", "unknown")])
        let associator = makeAssociator()

        #expect(associator.nowAndNext(for: groupWithoutID, at: date(150)) == nil)
        let unknown = try #require(associator.nowAndNext(for: unknownGroup, at: date(150)))
        #expect(unknown.currentProgram == nil)
        #expect(unknown.nextProgram == nil)
    }

    @Test("Programme boundaries use start-inclusive and end-exclusive intervals")
    func programmeBoundaries() throws {
        let group = try makeGroup([("1", "TF1 HD", "tf1.primary")])
        let associator = makeAssociator()

        let first = try #require(associator.nowAndNext(for: group, at: date(100)))
        #expect(first.currentProgram?.title == "Morning")
        #expect(first.nextProgram?.title == "Midday")

        let transition = try #require(associator.nowAndNext(for: group, at: date(200)))
        #expect(transition.currentProgram?.title == "Midday")
        #expect(transition.nextProgram == nil)
    }

    @Test("Gaps and overlaps resolve deterministically without mixing channel IDs")
    func gapsAndOverlaps() throws {
        let group = try makeGroup([("1", "TF1 HD", "overlap")])
        let associator = makeAssociator()

        let overlap = try #require(associator.nowAndNext(for: group, at: date(175)))
        #expect(overlap.currentProgram?.title == "Later overlap")
        #expect(overlap.nextProgram?.title == "After overlap")

        let gap = try #require(associator.nowAndNext(for: group, at: date(275)))
        #expect(gap.currentProgram == nil)
        #expect(gap.nextProgram?.title == "After overlap")
    }

    private func makeAssociator() -> IPTVChannelEPGAssociator {
        let primary = EPGChannelID(rawValue: "tf1.primary")
        let alternative = EPGChannelID(rawValue: "tf1.backup")
        let overlap = EPGChannelID(rawValue: "overlap")
        return IPTVChannelEPGAssociator(
            catalog: EPGCatalog(
                channelsByID: [:],
                programsByChannelID: [
                    primary: [
                        program(primary, "Morning", 100, 200),
                        program(primary, "Midday", 200, 300)
                    ],
                    alternative: [program(alternative, "Alternative", 100, 200)],
                    overlap: [
                        program(overlap, "Long programme", 100, 250),
                        program(overlap, "Later overlap", 150, 225),
                        program(overlap, "After overlap", 300, 400)
                    ]
                ]
            )
        )
    }

    private func makeGroup(
        _ variants: [(id: String, name: String, epgChannelID: String?)]
    ) throws -> IPTVLiveChannelGroup {
        let objects = variants.map { variant -> [String: Any] in
            var object: [String: Any] = [
                "stream_id": variant.id,
                "name": variant.name,
                "category_id": "national"
            ]
            if let epgChannelID = variant.epgChannelID {
                object["epg_channel_id"] = epgChannelID
            }
            return object
        }
        let streams = try JSONDecoder().decode(
            [XtreamLiveStream].self,
            from: JSONSerialization.data(withJSONObject: objects)
        )
        return try #require(
            IPTVLiveChannelGrouper.groups(sourceID: UUID(), streams: streams).first
        )
    }

    private func program(
        _ channelID: EPGChannelID,
        _ title: String,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> EPGProgram {
        EPGProgram(
            epgChannelID: channelID,
            title: title,
            description: nil,
            start: date(start),
            end: date(end)
        )
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}
