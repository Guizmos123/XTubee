//
//  FeedarrSourcesManager.swift
//  Yattee
//
//  Coordinates persistent Feedarr metadata and optional Basic Auth credentials.
//

import Foundation
import SwiftUI

enum FeedarrSourcesManagerError: Error, LocalizedError, Equatable, Sendable {
    case sourceAlreadyExists
    case sourceNotFound
    case insecureBasicAuth
    case incompleteCredentials
    case missingCredentials
    case persistenceFailure
    case credentialFailure
    case rollbackFailure

    var errorDescription: String? {
        switch self {
        case .sourceAlreadyExists:
            return "A Feedarr source is already configured."
        case .sourceNotFound:
            return "The Feedarr source was not found."
        case .insecureBasicAuth:
            return "Feedarr Basic Auth requires HTTPS."
        case .incompleteCredentials:
            return "Feedarr Basic Auth requires both a username and a password."
        case .missingCredentials:
            return "The Feedarr source credentials are missing."
        case .persistenceFailure:
            return "The Feedarr source could not be saved locally."
        case .credentialFailure:
            return "The local Feedarr credential store is unavailable."
        case .rollbackFailure:
            return "The Feedarr source update could not be rolled back safely."
        }
    }
}

@MainActor
protocol FeedarrSourcePersisting: AnyObject {
    func loadSource() throws -> FeedarrSource?
    func saveSource(_ source: FeedarrSource?) throws
}

@MainActor
final class UserDefaultsFeedarrSourcePersistence: FeedarrSourcePersisting {
    static let sourceKey = "configuredFeedarrSource"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSource() throws -> FeedarrSource? {
        guard let data = defaults.data(forKey: Self.sourceKey) else { return nil }
        do {
            return try JSONDecoder().decode(FeedarrSource.self, from: data)
        } catch {
            throw FeedarrSourcesManagerError.persistenceFailure
        }
    }

    func saveSource(_ source: FeedarrSource?) throws {
        guard let source else {
            defaults.removeObject(forKey: Self.sourceKey)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(source), forKey: Self.sourceKey)
        } catch {
            throw FeedarrSourcesManagerError.persistenceFailure
        }
    }
}

@MainActor
@Observable
final class FeedarrSourcesManager {
    private(set) var source: FeedarrSource?
    private(set) var loadError: FeedarrSourcesManagerError?
    /// Cache consumers must also observe credentials-only changes (source metadata can remain equal).
    private(set) var configurationRevision = UUID()

    private let persistence: FeedarrSourcePersisting
    private let credentialsStore: FeedarrCredentialsStoring

    init() {
        persistence = UserDefaultsFeedarrSourcePersistence()
        credentialsStore = FeedarrCredentialsStore()
        loadInitialState()
    }

    init(
        persistence: FeedarrSourcePersisting,
        credentialsStore: FeedarrCredentialsStoring
    ) {
        self.persistence = persistence
        self.credentialsStore = credentialsStore
        loadInitialState()
    }

    @discardableResult
    func add(
        name: String,
        serverURL: String,
        usesBasicAuth: Bool,
        username: String? = nil,
        password: String? = nil,
        dateAdded: Date = Date()
    ) throws -> FeedarrSource {
        defer { configurationRevision = UUID() }
        guard source == nil else { throw FeedarrSourcesManagerError.sourceAlreadyExists }
        let newSource = try FeedarrSource(
            name: name,
            serverURL: serverURL,
            dateAdded: dateAdded,
            usesBasicAuth: usesBasicAuth
        )
        let credentials = try validatedCredentials(
            for: newSource,
            username: username,
            password: password,
            existing: nil,
            mayReuseExisting: false
        )

        if let credentials {
            do {
                try credentialsStore.setCredentials(credentials, for: newSource.id)
            } catch {
                throw FeedarrSourcesManagerError.credentialFailure
            }
        }

        do {
            try persistence.saveSource(newSource)
        } catch {
            do {
                if credentials != nil {
                    try credentialsStore.deleteCredentials(for: newSource.id)
                }
            } catch {
                throw FeedarrSourcesManagerError.rollbackFailure
            }
            throw FeedarrSourcesManagerError.persistenceFailure
        }

        source = newSource
        loadError = nil
        return newSource
    }

    @discardableResult
    func update(
        id: UUID,
        name: String,
        serverURL: String,
        usesBasicAuth: Bool,
        username: String? = nil,
        password: String? = nil
    ) throws -> FeedarrSource {
        defer { configurationRevision = UUID() }
        guard let previous = source, previous.id == id else {
            throw FeedarrSourcesManagerError.sourceNotFound
        }
        let updated = try FeedarrSource(
            id: previous.id,
            name: name,
            serverURL: serverURL,
            dateAdded: previous.dateAdded,
            usesBasicAuth: usesBasicAuth
        )

        let oldCredentials: FeedarrCredentials?
        do {
            oldCredentials = try credentialsStore.credentials(for: id)
        } catch {
            throw FeedarrSourcesManagerError.credentialFailure
        }
        let mayReuse = previous.serverURL == updated.serverURL && previous.usesBasicAuth
        let newCredentials = try validatedCredentials(
            for: updated,
            username: username,
            password: password,
            existing: oldCredentials,
            mayReuseExisting: mayReuse
        )
        let credentialsChanged = newCredentials != oldCredentials

        if credentialsChanged {
            do {
                try replaceCredentials(newCredentials, for: id)
            } catch let error as FeedarrSourcesManagerError {
                throw error
            } catch {
                throw FeedarrSourcesManagerError.credentialFailure
            }
        }

        do {
            try persistence.saveSource(updated)
        } catch {
            if credentialsChanged {
                do {
                    try replaceCredentials(oldCredentials, for: id)
                } catch {
                    throw FeedarrSourcesManagerError.rollbackFailure
                }
            }
            throw FeedarrSourcesManagerError.persistenceFailure
        }

        source = updated
        loadError = nil
        return updated
    }

    func remove(id: UUID) throws {
        defer { configurationRevision = UUID() }
        guard let previous = source, previous.id == id else {
            throw FeedarrSourcesManagerError.sourceNotFound
        }
        let oldCredentials: FeedarrCredentials?
        do {
            oldCredentials = try credentialsStore.credentials(for: id)
            try credentialsStore.deleteCredentials(for: id)
        } catch {
            throw FeedarrSourcesManagerError.credentialFailure
        }

        do {
            try persistence.saveSource(nil)
        } catch {
            do {
                if let oldCredentials {
                    try credentialsStore.setCredentials(oldCredentials, for: id)
                }
            } catch {
                throw FeedarrSourcesManagerError.rollbackFailure
            }
            throw FeedarrSourcesManagerError.persistenceFailure
        }

        source = nil
        loadError = nil
    }

    func reload() throws {
        defer { configurationRevision = UUID() }
        let loaded: FeedarrSource?
        do {
            loaded = try persistence.loadSource()
        } catch {
            loadError = .persistenceFailure
            throw FeedarrSourcesManagerError.persistenceFailure
        }

        guard let loaded else {
            source = nil
            loadError = nil
            return
        }
        source = loaded
        guard loaded.usesBasicAuth else {
            loadError = nil
            return
        }
        guard loaded.serverURL.scheme == "https" else {
            loadError = .insecureBasicAuth
            return
        }
        do {
            if try credentialsStore.credentials(for: loaded.id) == nil {
                loadError = .missingCredentials
            } else {
                loadError = nil
            }
        } catch {
            loadError = .credentialFailure
        }
    }

    private func loadInitialState() {
        do {
            try reload()
        } catch {
            // reload records a non-sensitive error while preserving the prior in-memory state.
        }
    }

    private func validatedCredentials(
        for source: FeedarrSource,
        username: String?,
        password: String?,
        existing: FeedarrCredentials?,
        mayReuseExisting: Bool
    ) throws -> FeedarrCredentials? {
        if source.usesBasicAuth, source.serverURL.scheme != "https" {
            throw FeedarrSourcesManagerError.insecureBasicAuth
        }

        let supplied: FeedarrCredentials?
        switch (username, password) {
        case (nil, nil):
            supplied = nil
        case let (username?, password?):
            do {
                supplied = try FeedarrCredentials(username: username, password: password)
            } catch {
                throw FeedarrSourcesManagerError.incompleteCredentials
            }
        default:
            throw FeedarrSourcesManagerError.incompleteCredentials
        }

        guard source.usesBasicAuth else { return nil }
        if let supplied { return supplied }
        if mayReuseExisting, let existing { return existing }
        throw FeedarrSourcesManagerError.missingCredentials
    }

    private func replaceCredentials(
        _ credentials: FeedarrCredentials?,
        for sourceID: UUID
    ) throws {
        do {
            if let credentials {
                try credentialsStore.setCredentials(credentials, for: sourceID)
            } else {
                try credentialsStore.deleteCredentials(for: sourceID)
            }
        } catch {
            throw FeedarrSourcesManagerError.credentialFailure
        }
    }
}
