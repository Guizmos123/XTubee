//
//  IPTVSourceDataCleanupTests.swift
//  YatteeTests
//
//  Tests source-scoped removal of local IPTV data.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Source Data Cleanup Tests")
@MainActor
struct IPTVSourceDataCleanupTests {
    @Test("Cleanup removes only the deleted source from every local store")
    func sourceIsolation() async throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let favoritePersistence = CleanupFavoritesPersistence(ids: [
            favoriteID(sourceID: deletedID),
            favoriteID(sourceID: retainedID)
        ])
        let favorites = IPTVLiveFavoritesManager(persistence: favoritePersistence)
        let live = CleanupLivePersistence(sourceIDs: [deletedID, retainedID])
        let epg = CleanupEPGPersistence(sourceIDs: [deletedID, retainedID])
        let hidden = CleanupHiddenCategoriesPersistence(sourceIDs: [deletedID, retainedID])
        let cleanup = IPTVSourceDataCleanupCoordinator(
            livePersistence: live,
            epgPersistence: epg,
            favoritesManager: favorites,
            hiddenCategoriesPersistence: hidden
        )

        try await cleanup.removeData(for: deletedID)

        #expect(!favorites.favoriteIDs.contains { $0.sourceID == deletedID })
        #expect(favorites.favoriteIDs.contains { $0.sourceID == retainedID })
        #expect(await live.contains(deletedID) == false)
        #expect(await live.contains(retainedID))
        #expect(await epg.contains(deletedID) == false)
        #expect(await epg.contains(retainedID))
        #expect(hidden.sourceIDs == [retainedID])
    }

    @Test("Hidden categories are removed only for the deleted source")
    func hiddenCategoryIsolation() throws {
        let suiteName = "IPTVSourceDataCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deletedID = UUID()
        let retainedID = UUID()
        var preferences = IPTVHiddenCategoriesPreferences()
        preferences.setHidden(true, categoryID: "deleted-category", sourceID: deletedID)
        preferences.setHidden(true, categoryID: "retained-category", sourceID: retainedID)
        defaults.set(
            preferences.encoded,
            forKey: UserDefaultsIPTVHiddenCategoriesPersistence.key
        )
        let persistence = UserDefaultsIPTVHiddenCategoriesPersistence(defaults: defaults)

        try persistence.removeCategories(for: deletedID)

        let saved = IPTVHiddenCategoriesPreferences.decode(
            defaults.string(forKey: UserDefaultsIPTVHiddenCategoriesPersistence.key) ?? ""
        )
        #expect(saved.hiddenCount(sourceID: deletedID) == 0)
        #expect(saved.isHidden("retained-category", sourceID: retainedID))
    }

    private func favoriteID(sourceID: UUID) -> IPTVLiveChannelGroup.ID {
        IPTVLiveChannelGroup.ID(
            sourceID: sourceID,
            categoryID: "general",
            normalizedName: "channel"
        )
    }
}

@MainActor
private final class CleanupFavoritesPersistence: IPTVLiveFavoritesPersisting {
    var ids: [IPTVLiveChannelGroup.ID]

    init(ids: [IPTVLiveChannelGroup.ID]) {
        self.ids = ids
    }

    func load() throws -> [IPTVLiveChannelGroup.ID] { ids }
    func save(_ favoriteIDs: [IPTVLiveChannelGroup.ID]) throws { ids = favoriteIDs }
}

private actor CleanupLivePersistence: IPTVLiveCatalogPersisting {
    private var sourceIDs: Set<UUID>

    init(sourceIDs: Set<UUID>) { self.sourceIDs = sourceIDs }

    func load(sourceID: UUID) async throws -> IPTVLiveCatalog? { nil }
    func save(_ catalog: IPTVLiveCatalog) async throws { sourceIDs.insert(catalog.sourceID) }
    func remove(sourceID: UUID) async throws { sourceIDs.remove(sourceID) }
    func contains(_ sourceID: UUID) -> Bool { sourceIDs.contains(sourceID) }
}

private actor CleanupEPGPersistence: IPTVEPGPersisting {
    private var sourceIDs: Set<UUID>

    init(sourceIDs: Set<UUID>) { self.sourceIDs = sourceIDs }

    func load(sourceID: UUID) async throws -> IPTVEPGSnapshot? { nil }
    func save(_ snapshot: IPTVEPGSnapshot) async throws { sourceIDs.insert(snapshot.sourceID) }
    func remove(sourceID: UUID) async throws { sourceIDs.remove(sourceID) }
    func contains(_ sourceID: UUID) -> Bool { sourceIDs.contains(sourceID) }
}

@MainActor
private final class CleanupHiddenCategoriesPersistence: IPTVHiddenCategoriesPersisting {
    var sourceIDs: Set<UUID>

    init(sourceIDs: Set<UUID>) { self.sourceIDs = sourceIDs }

    func removeCategories(for sourceID: UUID) throws {
        sourceIDs.remove(sourceID)
    }
}
