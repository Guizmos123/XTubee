//
//  IPTVLiveChannelGroupingTests.swift
//  YatteeTests
//
//  Tests for conservative Xtream live channel grouping.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Live Channel Grouping Tests")
struct IPTVLiveChannelGroupingTests {
    @Test("TF1 quality variants group while TF1+ remains distinct")
    func TF1Variants() throws {
        let sourceID = UUID()
        let groups = IPTVLiveChannelGrouper.groups(
            sourceID: sourceID,
            streams: try streams([
                ("1", "FR | TF1 HD", "news"),
                ("2", "[FR] TF1 FHD", "news"),
                ("3", "TF1+ HD", "news")
            ])
        )

        #expect(groups.count == 2)
        #expect(groups[0].displayName == "TF1")
        #expect(groups[0].variants.map(\.stream.streamID) == ["1", "2"])
        #expect(groups[0].variants.map(\.attributes.announcedResolution) == [.highDefinition, .fullHD])
        #expect(groups[1].displayName == "TF1+")
    }

    @Test("Numbers, plus-one channels, regional variants, and distinctive names are preserved")
    func distinctiveNamesRemainSeparate() throws {
        let groups = IPTVLiveChannelGrouper.groups(
            sourceID: UUID(),
            streams: try streams([
                ("1", "M6 +1 HD", "general"),
                ("2", "France 3 Alpes HD", "general"),
                ("3", "France 3 Bretagne HD", "general"),
                ("4", "CANAL+ SPORT 360 UHD/4K", "general")
            ])
        )

        #expect(groups.map(\.displayName) == [
            "M6 +1",
            "France 3 Alpes",
            "France 3 Bretagne",
            "CANAL+ SPORT 360"
        ])
    }

    @Test("RMC Sport multi-stream variants retain identifiers, duplicates, and server order")
    func multiStreamOrder() throws {
        let groups = IPTVLiveChannelGrouper.groups(
            sourceID: UUID(),
            streams: try streams([
                ("rmc-a", "RMC Sport 1 HD", "sports"),
                ("rmc-b", "RMC Sport 1 HD", "sports"),
                ("rmc-c", "RMC Sport 1 FHD H265", "sports")
            ])
        )

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.variants.map(\.stream.streamID) == ["rmc-a", "rmc-b", "rmc-c"])
        #expect(group.variants.map(\.attributes.announcedResolution) == [
            .highDefinition,
            .highDefinition,
            .fullHD
        ])
        #expect(group.variants.map(\.attributes.usesHEVC) == [false, false, true])
    }

    @Test("Identical names in distinct categories never group")
    func distinctCategories() throws {
        let sourceID = UUID()
        let groups = IPTVLiveChannelGrouper.groups(
            sourceID: sourceID,
            streams: try streams([
                ("1", "TF1 HD", "national"),
                ("2", "TF1 FHD", "backup")
            ])
        )

        #expect(groups.count == 2)
        #expect(groups.map(\.categoryID) == ["national", "backup"])
        #expect(groups[0].id != groups[1].id)
    }

    @Test("Group identity is deterministic and scoped to its source")
    func deterministicIdentity() throws {
        let firstSource = UUID()
        let secondSource = UUID()
        let input = try streams([("1", "TF1 HD", "national")])

        let first = try #require(IPTVLiveChannelGrouper.groups(sourceID: firstSource, streams: input).first)
        let repeated = try #require(IPTVLiveChannelGrouper.groups(sourceID: firstSource, streams: input).first)
        let otherSource = try #require(IPTVLiveChannelGrouper.groups(sourceID: secondSource, streams: input).first)

        #expect(first.id == repeated.id)
        #expect(first.id != otherSource.id)
    }

    @Test("Unknown resolution stays unknown and codec metadata remains independent")
    func qualityMetadata() throws {
        let groups = IPTVLiveChannelGrouper.groups(
            sourceID: UUID(),
            streams: try streams([
                ("1", "Documentary HEVC", nil),
                ("2", "Classic Channel", nil)
            ])
        )

        #expect(groups[0].variants[0].attributes.announcedResolution == nil)
        #expect(groups[0].variants[0].attributes.usesHEVC)
        #expect(groups[1].variants[0].attributes.announcedResolution == nil)
        #expect(!groups[1].variants[0].attributes.usesHEVC)
    }

    @Test("Decorative separators are flagged but retained")
    func separatorsRemainPresent() throws {
        let input = try streams([
            ("separator", "────────", "sports"),
            ("channel", "RMC Sport 1 HD", "sports")
        ])
        let groups = IPTVLiveChannelGrouper.groups(sourceID: UUID(), streams: input)

        #expect(groups.count == 2)
        #expect(groups[0].isDecorativeSeparator)
        #expect(groups[0].variants.first?.stream.streamID == "separator")
        #expect(!groups[1].isDecorativeSeparator)
    }

    private func streams(
        _ values: [(id: String, name: String, categoryID: String?)]
    ) throws -> [XtreamLiveStream] {
        let objects = values.map { value -> [String: Any] in
            var object: [String: Any] = [
                "stream_id": value.id,
                "name": value.name
            ]
            if let categoryID = value.categoryID {
                object["category_id"] = categoryID
            }
            return object
        }
        return try JSONDecoder().decode(
            [XtreamLiveStream].self,
            from: JSONSerialization.data(withJSONObject: objects)
        )
    }
}
