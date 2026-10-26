//
//  IPTVLiveChannelPresentationTests.swift
//  YatteeTests
//
//  Tests for ordered Xtream live variant presentation.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Live Channel Presentation Tests")
struct IPTVLiveChannelPresentationTests {
    @Test("Variants are ordered by quality with stable server order")
    func qualityOrder() throws {
        let presentation = try makePresentation([
            ("sd-1", "Channel SD"),
            ("unknown-1", "Channel"),
            ("hd-1", "Channel HD"),
            ("uhd-1", "Channel 4K"),
            ("fhd-1", "Channel FHD"),
            ("hd-2", "Channel HD")
        ])

        #expect(presentation.variants.map(\.streamID) == [
            "uhd-1", "fhd-1", "hd-1", "hd-2", "sd-1", "unknown-1"
        ])
        #expect(presentation.variants.map(\.quality) == [
            .ultraHD, .fullHD, .highDefinition, .highDefinition, .standardDefinition, .unknown
        ])
    }

    @Test("Duplicate qualities keep every stream and receive numbered labels")
    func duplicateQualityLabels() throws {
        let presentation = try makePresentation([
            ("fhd-a", "Channel FHD"),
            ("fhd-b", "Channel FHD"),
            ("fhd-c", "Channel FHD")
        ])

        #expect(presentation.variants.map(\.streamID) == ["fhd-a", "fhd-b", "fhd-c"])
        #expect(presentation.variants.map(\.label) == [
            "FHD · Flux 1",
            "FHD · Flux 2",
            "FHD · Flux 3"
        ])
    }

    @Test("Unknown quality and HEVC codec remain independent")
    func unknownQualityAndCodec() throws {
        let presentation = try makePresentation([
            ("hevc", "Channel HEVC"),
            ("plain", "Channel")
        ])

        #expect(presentation.variants.map(\.quality) == [.unknown, .unknown])
        #expect(presentation.variants.map(\.label) == [
            "Qualité inconnue · Flux 1",
            "Qualité inconnue · Flux 2"
        ])
        #expect(presentation.variants.map(\.usesHEVC) == [true, false])
    }

    @Test("Only the first three choices are exposed without losing the complete list")
    func firstThreeChoices() throws {
        let presentation = try makePresentation([
            ("uhd", "Channel UHD"),
            ("fhd", "Channel FHD"),
            ("hd", "Channel HD"),
            ("sd", "Channel SD"),
            ("unknown", "Channel")
        ])

        #expect(presentation.firstChoices.map(\.streamID) == ["uhd", "fhd", "hd"])
        #expect(presentation.additionalChoiceCount == 2)
        #expect(presentation.variants.count == 5)
    }

    @Test("Single and multiple variants expose distinct selection behavior")
    func selectionMode() throws {
        let single = try makePresentation([("only", "Channel HD")])
        let multiple = try makePresentation([
            ("first", "Channel HD"),
            ("second", "Channel SD")
        ])

        #expect(single.selectionMode == .direct(single.variants[0].id))
        #expect(multiple.selectionMode == .requiresExplicitChoice)
    }

    @Test("Variant identifiers are stable and resolve the exact stream identifier")
    func stableIdentityAndLookup() throws {
        let sourceID = UUID()
        let first = try makePresentation(
            [("stream-a", "Channel HD"), ("stream-b", "Channel FHD")],
            sourceID: sourceID
        )
        let repeated = try makePresentation(
            [("stream-a", "Channel HD"), ("stream-b", "Channel FHD")],
            sourceID: sourceID
        )

        #expect(first.variants.map(\.id) == repeated.variants.map(\.id))
        #expect(first.variant(streamID: "stream-a")?.streamID == "stream-a")
        #expect(first.variant(streamID: "missing") == nil)
    }

    private func makePresentation(
        _ values: [(id: String, name: String)],
        sourceID: UUID = UUID()
    ) throws -> IPTVLiveChannelPresentation {
        let objects = values.map {
            [
                "stream_id": $0.id,
                "name": $0.name,
                "category_id": "category"
            ]
        }
        let streams = try JSONDecoder().decode(
            [XtreamLiveStream].self,
            from: JSONSerialization.data(withJSONObject: objects)
        )
        let groups = IPTVLiveChannelGrouper.groups(sourceID: sourceID, streams: streams)
        return IPTVLiveChannelPresentation(group: try #require(groups.first))
    }
}
