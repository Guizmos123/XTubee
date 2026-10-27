//
//  IPTVSourceDataCleanup.swift
//  Yattee
//
//  Removes local data that belongs to a deleted IPTV source.
//

import Foundation

enum IPTVSourceDataCleanupError: Error, LocalizedError, Equatable, Sendable {
    case cleanupFailed

    var errorDescription: String? {
        "Some local IPTV data could not be removed."
    }
}

@MainActor
protocol IPTVSourceDataCleaning: AnyObject {
    func removeData(for sourceID: UUID) async throws
}

struct IPTVHiddenCategoriesPreferences: Codable, Sendable {
    private var categoryIDsBySource: [String: Set<String>] = [:]

    static func decode(_ value: String) -> IPTVHiddenCategoriesPreferences {
        guard let data = value.data(using: .utf8), !data.isEmpty,
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return preferences
    }

    static func decodeStrict(_ value: String) throws -> IPTVHiddenCategoriesPreferences {
        guard let data = value.data(using: .utf8), !data.isEmpty else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func isHidden(_ categoryID: String, sourceID: UUID) -> Bool {
        categoryIDsBySource[sourceID.uuidString]?.contains(categoryID) == true
    }

    func hiddenCount(sourceID: UUID) -> Int {
        categoryIDsBySource[sourceID.uuidString]?.count ?? 0
    }

    mutating func setHidden(_ isHidden: Bool, categoryID: String, sourceID: UUID) {
        let key = sourceID.uuidString
        if isHidden {
            categoryIDsBySource[key, default: []].insert(categoryID)
        } else {
            categoryIDsBySource[key]?.remove(categoryID)
            if categoryIDsBySource[key]?.isEmpty == true {
                categoryIDsBySource[key] = nil
            }
        }
    }

    mutating func showAll(sourceID: UUID) {
        categoryIDsBySource[sourceID.uuidString] = nil
    }
}

@MainActor
protocol IPTVHiddenCategoriesPersisting: AnyObject {
    func removeCategories(for sourceID: UUID) throws
}

@MainActor
final class UserDefaultsIPTVHiddenCategoriesPersistence: IPTVHiddenCategoriesPersisting {
    static let key = "iptv.hiddenCategories"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func removeCategories(for sourceID: UUID) throws {
        let value = defaults.string(forKey: Self.key) ?? ""
        var preferences = try IPTVHiddenCategoriesPreferences.decodeStrict(value)
        preferences.showAll(sourceID: sourceID)
        defaults.set(preferences.encoded, forKey: Self.key)
    }
}

@MainActor
final class IPTVSourceDataCleanupCoordinator: IPTVSourceDataCleaning {
    private let livePersistence: IPTVLiveCatalogPersisting
    private let epgPersistence: IPTVEPGPersisting
    private let favoritesManager: IPTVLiveFavoritesManager
    private let hiddenCategoriesPersistence: IPTVHiddenCategoriesPersisting

    init(
        livePersistence: IPTVLiveCatalogPersisting,
        epgPersistence: IPTVEPGPersisting,
        favoritesManager: IPTVLiveFavoritesManager,
        hiddenCategoriesPersistence: IPTVHiddenCategoriesPersisting? = nil
    ) {
        self.livePersistence = livePersistence
        self.epgPersistence = epgPersistence
        self.favoritesManager = favoritesManager
        self.hiddenCategoriesPersistence = hiddenCategoriesPersistence
            ?? UserDefaultsIPTVHiddenCategoriesPersistence()
    }

    func removeData(for sourceID: UUID) async throws {
        var failed = false

        do {
            try favoritesManager.removeFavorites(for: sourceID)
        } catch {
            failed = true
        }
        do {
            try hiddenCategoriesPersistence.removeCategories(for: sourceID)
        } catch {
            failed = true
        }
        do {
            try await livePersistence.remove(sourceID: sourceID)
        } catch {
            failed = true
        }
        do {
            try await epgPersistence.remove(sourceID: sourceID)
        } catch {
            failed = true
        }

        if failed {
            throw IPTVSourceDataCleanupError.cleanupFailed
        }
    }
}
