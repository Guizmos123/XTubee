//
//  IPTVSourcesManager.swift
//  Yattee
//
//  Manages local Xtream source metadata and its active selection.
//

import Foundation
import SwiftUI

enum IPTVSourcesManagerError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotFound
    case duplicateSource
    case persistenceFailure
    case credentialFailure
    case rollbackFailure

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "The IPTV source was not found."
        case .duplicateSource:
            return "An IPTV source already exists for this server and account."
        case .persistenceFailure:
            return "The IPTV sources could not be saved locally."
        case .credentialFailure:
            return "The local IPTV credentials could not be updated."
        case .rollbackFailure:
            return "The IPTV source update could not be rolled back safely."
        }
    }
}

@MainActor
protocol IPTVSourcesPersisting: AnyObject {
    func loadSources() throws -> [IPTVSource]
    func loadActiveSourceID() throws -> UUID?
    func saveSources(_ sources: [IPTVSource]) throws
    func saveActiveSourceID(_ sourceID: UUID?) throws
}

@MainActor
final class UserDefaultsIPTVSourcesPersistence: IPTVSourcesPersisting {
    static let sourcesKey = "configuredIPTVSources"
    static let activeSourceKey = "activeIPTVSourceID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSources() throws -> [IPTVSource] {
        guard let data = defaults.data(forKey: Self.sourcesKey) else { return [] }
        do {
            return try JSONDecoder().decode([IPTVSource].self, from: data)
        } catch {
            throw IPTVSourcesManagerError.persistenceFailure
        }
    }

    func loadActiveSourceID() throws -> UUID? {
        guard let value = defaults.string(forKey: Self.activeSourceKey) else { return nil }
        return UUID(uuidString: value)
    }

    func saveSources(_ sources: [IPTVSource]) throws {
        do {
            defaults.set(try JSONEncoder().encode(sources), forKey: Self.sourcesKey)
        } catch {
            throw IPTVSourcesManagerError.persistenceFailure
        }
    }

    func saveActiveSourceID(_ sourceID: UUID?) throws {
        if let sourceID {
            defaults.set(sourceID.uuidString, forKey: Self.activeSourceKey)
        } else {
            defaults.removeObject(forKey: Self.activeSourceKey)
        }
    }
}

@MainActor
@Observable
final class IPTVSourcesManager {
    private(set) var sources: [IPTVSource] = []
    private(set) var activeSourceID: UUID?
    private(set) var loadError: IPTVSourcesManagerError?
    private(set) var lastCleanupError: IPTVSourceDataCleanupError?

    private let persistence: IPTVSourcesPersisting
    private let credentialsStore: XtreamCredentialsStoring
    private var dataCleaner: IPTVSourceDataCleaning?

    var activeSource: IPTVSource? {
        guard let activeSourceID else { return nil }
        return sources.first { $0.id == activeSourceID }
    }

    init() {
        persistence = UserDefaultsIPTVSourcesPersistence()
        credentialsStore = XtreamCredentialsStore()
        loadInitialState()
    }

    init(
        persistence: IPTVSourcesPersisting,
        credentialsStore: XtreamCredentialsStoring
    ) {
        self.persistence = persistence
        self.credentialsStore = credentialsStore
        loadInitialState()
    }

    private func loadInitialState() {
        do {
            try reload()
        } catch let error as IPTVSourcesManagerError {
            loadError = error
        } catch {
            loadError = .persistenceFailure
        }
    }

    @discardableResult
    func add(
        name: String,
        serverURL: String,
        username: String,
        password: String,
        dateAdded: Date = Date()
    ) throws -> IPTVSource {
        let source = try IPTVSource(name: name, serverURL: serverURL, dateAdded: dateAdded)
        try ensureUnique(serverURL: source.serverURL, username: username, excluding: nil)

        do {
            try credentialsStore.setCredentials(
                XtreamCredentials(username: username, password: password),
                for: source.id
            )
        } catch {
            throw IPTVSourcesManagerError.credentialFailure
        }

        let previousSources = sources
        let previousActiveID = activeSourceID
        sources.append(source)
        if activeSourceID == nil { activeSourceID = source.id }

        do {
            try persistState(
                previousSources: previousSources,
                previousActiveSourceID: previousActiveID
            )
        } catch let persistenceError {
            sources = previousSources
            activeSourceID = previousActiveID
            do {
                try credentialsStore.deleteCredentials(for: source.id)
            } catch {
                throw IPTVSourcesManagerError.rollbackFailure
            }
            if persistenceError as? IPTVSourcesManagerError == .rollbackFailure {
                throw IPTVSourcesManagerError.rollbackFailure
            }
            throw IPTVSourcesManagerError.persistenceFailure
        }
        return source
    }

    @discardableResult
    func update(
        id: UUID,
        name: String,
        serverURL: String,
        username: String,
        password: String
    ) throws -> IPTVSource {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            throw IPTVSourcesManagerError.sourceNotFound
        }

        let updated = try IPTVSource(
            id: id,
            name: name,
            serverURL: serverURL,
            dateAdded: sources[index].dateAdded
        )
        try ensureUnique(serverURL: updated.serverURL, username: username, excluding: id)

        let oldCredentials: XtreamCredentials?
        do {
            oldCredentials = try credentialsStore.credentials(for: id)
            try credentialsStore.setCredentials(
                XtreamCredentials(username: username, password: password),
                for: id
            )
        } catch {
            throw IPTVSourcesManagerError.credentialFailure
        }

        let previous = sources[index]
        sources[index] = updated
        do {
            try persistence.saveSources(sources)
        } catch {
            sources[index] = previous
            do {
                if let oldCredentials {
                    try credentialsStore.setCredentials(oldCredentials, for: id)
                } else {
                    try credentialsStore.deleteCredentials(for: id)
                }
            } catch {
                throw IPTVSourcesManagerError.rollbackFailure
            }
            throw IPTVSourcesManagerError.persistenceFailure
        }
        return updated
    }

    func remove(id: UUID) async throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            throw IPTVSourcesManagerError.sourceNotFound
        }

        let oldCredentials: XtreamCredentials?
        do {
            oldCredentials = try credentialsStore.credentials(for: id)
            try credentialsStore.deleteCredentials(for: id)
        } catch {
            throw IPTVSourcesManagerError.credentialFailure
        }

        let previousSources = sources
        let previousActiveID = activeSourceID
        sources.remove(at: index)
        if activeSourceID == id {
            activeSourceID = sources.first?.id
        }

        do {
            try persistState(
                previousSources: previousSources,
                previousActiveSourceID: previousActiveID
            )
        } catch let persistenceError {
            sources = previousSources
            activeSourceID = previousActiveID
            do {
                if let oldCredentials {
                    try credentialsStore.setCredentials(oldCredentials, for: id)
                }
            } catch {
                throw IPTVSourcesManagerError.rollbackFailure
            }
            if persistenceError as? IPTVSourcesManagerError == .rollbackFailure {
                throw IPTVSourcesManagerError.rollbackFailure
            }
            throw IPTVSourcesManagerError.persistenceFailure
        }

        lastCleanupError = nil
        do {
            try await dataCleaner?.removeData(for: id)
        } catch {
            lastCleanupError = .cleanupFailed
            LoggingService.shared.error(
                "IPTV source data cleanup failed",
                category: .general
            )
        }
    }

    func setDataCleaner(_ dataCleaner: IPTVSourceDataCleaning) {
        self.dataCleaner = dataCleaner
    }

    func setActive(id: UUID) throws {
        guard sources.contains(where: { $0.id == id }) else {
            throw IPTVSourcesManagerError.sourceNotFound
        }
        let previous = activeSourceID
        activeSourceID = id
        do {
            try persistence.saveActiveSourceID(id)
        } catch {
            activeSourceID = previous
            throw IPTVSourcesManagerError.persistenceFailure
        }
    }

    func reload() throws {
        let loadedSources: [IPTVSource]
        let loadedActiveID: UUID?
        do {
            loadedSources = try persistence.loadSources()
            loadedActiveID = try persistence.loadActiveSourceID()
        } catch {
            throw IPTVSourcesManagerError.persistenceFailure
        }

        sources = loadedSources
        if let loadedActiveID, loadedSources.contains(where: { $0.id == loadedActiveID }) {
            activeSourceID = loadedActiveID
        } else {
            activeSourceID = loadedSources.first?.id
            do {
                try persistence.saveActiveSourceID(activeSourceID)
            } catch {
                throw IPTVSourcesManagerError.persistenceFailure
            }
        }
        loadError = nil
    }

    private func ensureUnique(serverURL: URL, username: String, excluding sourceID: UUID?) throws {
        for source in sources where source.id != sourceID && source.serverURL == serverURL {
            do {
                if try credentialsStore.credentials(for: source.id)?.username == username {
                    throw IPTVSourcesManagerError.duplicateSource
                }
            } catch let error as IPTVSourcesManagerError {
                throw error
            } catch {
                throw IPTVSourcesManagerError.credentialFailure
            }
        }
    }

    private func persistState(
        previousSources: [IPTVSource],
        previousActiveSourceID: UUID?
    ) throws {
        do {
            try persistence.saveSources(sources)
        } catch {
            throw IPTVSourcesManagerError.persistenceFailure
        }

        do {
            try persistence.saveActiveSourceID(activeSourceID)
        } catch {
            do {
                try persistence.saveSources(previousSources)
                try persistence.saveActiveSourceID(previousActiveSourceID)
            } catch {
                throw IPTVSourcesManagerError.rollbackFailure
            }
            throw IPTVSourcesManagerError.persistenceFailure
        }
    }
}
