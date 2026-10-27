//
//  IPTVLiveFavoritesManager.swift
//  Yattee
//
//  Persists ordered IPTV channel-group favorites independently from YouTube favorites.
//

import Foundation
import SwiftUI

enum IPTVLiveFavoritesError: Error, LocalizedError, Equatable, Sendable {
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .readFailed:
            return "The IPTV favorites could not be read."
        case .writeFailed:
            return "The IPTV favorites could not be saved."
        }
    }
}

@MainActor
protocol IPTVLiveFavoritesPersisting: AnyObject {
    func load() throws -> [IPTVLiveChannelGroup.ID]
    func save(_ favoriteIDs: [IPTVLiveChannelGroup.ID]) throws
}

@MainActor
final class FileIPTVLiveFavoritesPersistence: IPTVLiveFavoritesPersisting {
    private struct Payload: Codable {
        let favoriteIDs: [IPTVLiveChannelGroup.ID]
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let resolvedDirectory = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("XTubee", isDirectory: true)
            .appendingPathComponent("IPTVFavorites", isDirectory: true)
        self.directoryURL = resolvedDirectory
        fileURL = resolvedDirectory.appendingPathComponent("favorites.json")
    }

    func load() throws -> [IPTVLiveChannelGroup.ID] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try decoder.decode(Payload.self, from: Data(contentsOf: fileURL)).favoriteIDs
        } catch {
            throw IPTVLiveFavoritesError.readFailed
        }
    }

    func save(_ favoriteIDs: [IPTVLiveChannelGroup.ID]) throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var localDirectoryURL = directoryURL
            try localDirectoryURL.setResourceValues(resourceValues)
            try encoder.encode(Payload(favoriteIDs: favoriteIDs)).write(
                to: fileURL,
                options: .atomic
            )
        } catch {
            throw IPTVLiveFavoritesError.writeFailed
        }
    }
}

@MainActor
@Observable
final class IPTVLiveFavoritesManager {
    private(set) var favoriteIDs: [IPTVLiveChannelGroup.ID] = []
    private(set) var loadError: IPTVLiveFavoritesError?

    private let persistence: IPTVLiveFavoritesPersisting

    init(persistence: IPTVLiveFavoritesPersisting? = nil) {
        self.persistence = persistence ?? FileIPTVLiveFavoritesPersistence()
        loadFavorites()
    }

    func isFavorite(_ group: IPTVLiveChannelGroup) -> Bool {
        favoriteIDs.contains(group.id)
    }

    /// Toggles a group favorite and returns its resulting favorite state.
    @discardableResult
    func toggleFavorite(_ group: IPTVLiveChannelGroup) throws -> Bool {
        let previousIDs = favoriteIDs
        let isNowFavorite: Bool

        if let index = favoriteIDs.firstIndex(of: group.id) {
            favoriteIDs.remove(at: index)
            isNowFavorite = false
        } else {
            favoriteIDs.append(group.id)
            isNowFavorite = true
        }

        do {
            try persistence.save(favoriteIDs)
        } catch {
            favoriteIDs = previousIDs
            throw IPTVLiveFavoritesError.writeFailed
        }
        return isNowFavorite
    }

    /// Resolves available groups without deleting persisted references to absent groups.
    func favorites(
        for sourceID: UUID,
        in groups: [IPTVLiveChannelGroup]
    ) -> [IPTVLiveChannelGroup] {
        var availableGroups: [IPTVLiveChannelGroup.ID: IPTVLiveChannelGroup] = [:]
        for group in groups where group.sourceID == sourceID {
            availableGroups[group.id] = group
        }
        return favoriteIDs
            .filter { $0.sourceID == sourceID }
            .compactMap { availableGroups[$0] }
    }

    func removeFavorites(for sourceID: UUID) throws {
        let previousIDs = favoriteIDs
        favoriteIDs.removeAll { $0.sourceID == sourceID }
        guard favoriteIDs != previousIDs else { return }

        do {
            try persistence.save(favoriteIDs)
        } catch {
            favoriteIDs = previousIDs
            throw IPTVLiveFavoritesError.writeFailed
        }
    }

    func moveFavorites(
        for sourceID: UUID,
        in groups: [IPTVLiveChannelGroup],
        fromOffsets: IndexSet,
        toOffset: Int
    ) throws {
        let availableFavorites = favorites(for: sourceID, in: groups)
        var reorderedIDs = availableFavorites.map(\.id)
        reorderedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)

        let reorderedIDSet = Set(reorderedIDs)
        let unavailableIDs = favoriteIDs.filter {
            $0.sourceID == sourceID && !reorderedIDSet.contains($0)
        }
        let previousIDs = favoriteIDs
        favoriteIDs.removeAll { $0.sourceID == sourceID }
        favoriteIDs.append(contentsOf: reorderedIDs + unavailableIDs)

        do {
            try persistence.save(favoriteIDs)
        } catch {
            favoriteIDs = previousIDs
            throw IPTVLiveFavoritesError.writeFailed
        }
    }

    private func loadFavorites() {
        do {
            let loadedIDs = try persistence.load()
            var seenIDs: Set<IPTVLiveChannelGroup.ID> = []
            favoriteIDs = loadedIDs.filter { seenIDs.insert($0).inserted }
            loadError = nil
        } catch {
            favoriteIDs = []
            loadError = .readFailed
        }
    }
}
