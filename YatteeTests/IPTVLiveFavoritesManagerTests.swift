//
//  IPTVLiveFavoritesManagerTests.swift
//  YatteeTests
//
//  Tests for ordered, source-isolated IPTV live favorites.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Live Favorites Manager Tests")
@MainActor
struct IPTVLiveFavoritesManagerTests {
    @Test("Favorites are isolated by IPTV source UUID")
    func sourceIsolation() throws {
        let manager = IPTVLiveFavoritesManager(persistence: MockIPTVFavoritesPersistence())
        let firstSource = UUID()
        let secondSource = UUID()
        let firstGroup = try group(sourceID: firstSource, names: ["TF1 HD"])
        let secondGroup = try group(sourceID: secondSource, names: ["TF1 HD"])

        try manager.toggleFavorite(firstGroup)

        #expect(manager.isFavorite(firstGroup))
        #expect(!manager.isFavorite(secondGroup))
        #expect(manager.favorites(for: firstSource, in: [firstGroup, secondGroup]) == [firstGroup])
        #expect(manager.favorites(for: secondSource, in: [firstGroup, secondGroup]).isEmpty)
    }

    @Test("Quality changes preserve a favorite because identity does not use stream IDs")
    func qualityChangesPreserveFavorite() throws {
        let manager = IPTVLiveFavoritesManager(persistence: MockIPTVFavoritesPersistence())
        let sourceID = UUID()
        let initial = try group(
            sourceID: sourceID,
            streams: [("old-hd", "RMC Sport 1 HD")]
        )
        try manager.toggleFavorite(initial)
        let refreshed = try group(
            sourceID: sourceID,
            streams: [
                ("new-fhd", "RMC Sport 1 FHD"),
                ("new-uhd", "RMC Sport 1 UHD")
            ]
        )

        #expect(manager.isFavorite(refreshed))
        #expect(manager.favorites(for: sourceID, in: [refreshed]) == [refreshed])
        #expect(refreshed.variants.count == 2)
    }

    @Test("Favorites persist with their addition order")
    func persistenceAndOrder() throws {
        let persistence = MockIPTVFavoritesPersistence()
        let sourceID = UUID()
        let first = try group(sourceID: sourceID, names: ["TF1 HD"])
        let second = try group(sourceID: sourceID, names: ["M6 HD"])
        let initialManager = IPTVLiveFavoritesManager(persistence: persistence)
        try initialManager.toggleFavorite(second)
        try initialManager.toggleFavorite(first)

        let reloadedManager = IPTVLiveFavoritesManager(persistence: persistence)

        #expect(reloadedManager.favorites(for: sourceID, in: [first, second]) == [second, first])
    }

    @Test("Favorites can be reordered per source and persist immediately")
    func reorderPersistenceAndIsolation() throws {
        let persistence = MockIPTVFavoritesPersistence()
        let firstSource = UUID()
        let secondSource = UUID()
        let first = try group(sourceID: firstSource, names: ["TF1 HD"])
        let second = try group(sourceID: firstSource, names: ["M6 HD"])
        let otherSource = try group(sourceID: secondSource, names: ["Arte HD"])
        let manager = IPTVLiveFavoritesManager(persistence: persistence)
        try manager.toggleFavorite(first)
        try manager.toggleFavorite(second)
        try manager.toggleFavorite(otherSource)

        try manager.moveFavorites(
            for: firstSource,
            in: [first, second, otherSource],
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )
        let reloaded = IPTVLiveFavoritesManager(persistence: persistence)

        #expect(reloaded.favorites(for: firstSource, in: [first, second]) == [second, first])
        #expect(reloaded.favorites(for: secondSource, in: [otherSource]) == [otherSource])
    }

    @Test("A failed reorder restores the previous favorite order")
    func reorderFailureRollsBack() throws {
        let persistence = MockIPTVFavoritesPersistence()
        let sourceID = UUID()
        let first = try group(sourceID: sourceID, names: ["TF1 HD"])
        let second = try group(sourceID: sourceID, names: ["M6 HD"])
        let manager = IPTVLiveFavoritesManager(persistence: persistence)
        try manager.toggleFavorite(first)
        try manager.toggleFavorite(second)
        persistence.failSave = true

        #expect(throws: IPTVLiveFavoritesError.writeFailed) {
            try manager.moveFavorites(
                for: sourceID,
                in: [first, second],
                fromOffsets: IndexSet(integer: 1),
                toOffset: 0
            )
        }
        #expect(manager.favorites(for: sourceID, in: [first, second]) == [first, second])
    }

    @Test("Removing and adding again moves a favorite to the end")
    func removeAndReadd() throws {
        let manager = IPTVLiveFavoritesManager(persistence: MockIPTVFavoritesPersistence())
        let sourceID = UUID()
        let first = try group(sourceID: sourceID, names: ["TF1 HD"])
        let second = try group(sourceID: sourceID, names: ["M6 HD"])
        try manager.toggleFavorite(first)
        try manager.toggleFavorite(second)
        try manager.toggleFavorite(first)
        try manager.toggleFavorite(first)

        #expect(manager.favorites(for: sourceID, in: [first, second]) == [second, first])
    }

    @Test("Orphaned favorites remain persisted and resolve when the group returns")
    func orphanedFavorites() throws {
        let persistence = MockIPTVFavoritesPersistence()
        let sourceID = UUID()
        let favorite = try group(sourceID: sourceID, names: ["CANAL+ SPORT 360 HD"])
        let manager = IPTVLiveFavoritesManager(persistence: persistence)
        try manager.toggleFavorite(favorite)

        #expect(manager.favorites(for: sourceID, in: []).isEmpty)
        #expect(persistence.favoriteIDs == [favorite.id])

        let returned = try group(
            sourceID: sourceID,
            streams: [("replacement", "CANAL+ SPORT 360 FHD")]
        )
        #expect(manager.favorites(for: sourceID, in: [returned]) == [returned])
    }

    @Test("Removing one source leaves favorites from other sources intact")
    func removeSourceFavorites() throws {
        let persistence = MockIPTVFavoritesPersistence()
        let firstSource = UUID()
        let secondSource = UUID()
        let first = try group(sourceID: firstSource, names: ["TF1 HD"])
        let second = try group(sourceID: secondSource, names: ["M6 HD"])
        let manager = IPTVLiveFavoritesManager(persistence: persistence)
        try manager.toggleFavorite(first)
        try manager.toggleFavorite(second)

        try manager.removeFavorites(for: firstSource)

        #expect(!manager.isFavorite(first))
        #expect(manager.isFavorite(second))
        #expect(persistence.favoriteIDs == [second.id])
    }

    @Test("A persistence failure rolls the in-memory toggle back")
    func writeFailureRollsBack() throws {
        let persistence = MockIPTVFavoritesPersistence()
        let favorite = try group(sourceID: UUID(), names: ["TF1 HD"])
        let manager = IPTVLiveFavoritesManager(persistence: persistence)
        persistence.failSave = true

        #expect(throws: IPTVLiveFavoritesError.writeFailed) {
            try manager.toggleFavorite(favorite)
        }
        #expect(!manager.isFavorite(favorite))
    }

    private func group(
        sourceID: UUID,
        names: [String],
        categoryID: String = "category"
    ) throws -> IPTVLiveChannelGroup {
        try group(
            sourceID: sourceID,
            streams: names.enumerated().map { ("stream-\($0.offset)", $0.element) },
            categoryID: categoryID
        )
    }

    private func group(
        sourceID: UUID,
        streams: [(id: String, name: String)],
        categoryID: String = "category"
    ) throws -> IPTVLiveChannelGroup {
        let objects = streams.map {
            [
                "stream_id": $0.id,
                "name": $0.name,
                "category_id": categoryID
            ]
        }
        let decodedStreams = try JSONDecoder().decode(
            [XtreamLiveStream].self,
            from: JSONSerialization.data(withJSONObject: objects)
        )
        return try #require(
            IPTVLiveChannelGrouper.groups(sourceID: sourceID, streams: decodedStreams).first
        )
    }
}

@MainActor
private final class MockIPTVFavoritesPersistence: IPTVLiveFavoritesPersisting {
    var favoriteIDs: [IPTVLiveChannelGroup.ID] = []
    var failLoad = false
    var failSave = false

    func load() throws -> [IPTVLiveChannelGroup.ID] {
        if failLoad { throw IPTVLiveFavoritesError.readFailed }
        return favoriteIDs
    }

    func save(_ favoriteIDs: [IPTVLiveChannelGroup.ID]) throws {
        if failSave { throw IPTVLiveFavoritesError.writeFailed }
        self.favoriteIDs = favoriteIDs
    }
}
