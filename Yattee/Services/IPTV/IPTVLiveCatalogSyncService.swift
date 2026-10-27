//
//  IPTVLiveCatalogSyncService.swift
//  Yattee
//
//  Provides local caching and atomic synchronization for Xtream live catalogs.
//

import Foundation
import SwiftUI

struct IPTVLiveCatalog: Codable, Hashable, Sendable {
    let sourceID: UUID
    let categories: [XtreamLiveCategory]
    let streams: [XtreamLiveStream]
    let lastUpdated: Date
}

enum IPTVLiveCatalogLoadingState: Equatable, Sendable {
    case idle
    case loading
    case refreshing
}

enum IPTVLiveCatalogSyncError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotFound
    case credentialsUnavailable
    case cacheReadFailed
    case cacheWriteFailed
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "The IPTV source was not found."
        case .credentialsUnavailable:
            return "The local IPTV credentials are unavailable."
        case .cacheReadFailed:
            return "The local IPTV catalog could not be read."
        case .cacheWriteFailed:
            return "The IPTV catalog could not be saved locally."
        case .refreshFailed:
            return "The IPTV catalog could not be refreshed."
        }
    }
}

struct IPTVLiveCatalogState: Equatable, Sendable {
    var catalog: IPTVLiveCatalog?
    var loadingState: IPTVLiveCatalogLoadingState
    var lastError: IPTVLiveCatalogSyncError?

    var lastUpdated: Date? { catalog?.lastUpdated }

    static let empty = IPTVLiveCatalogState(
        catalog: nil,
        loadingState: .idle,
        lastError: nil
    )
}

protocol IPTVLiveCatalogPersisting: Actor {
    func load(sourceID: UUID) async throws -> IPTVLiveCatalog?
    func save(_ catalog: IPTVLiveCatalog) async throws
    func remove(sourceID: UUID) async throws
}

actor FileIPTVLiveCatalogPersistence: IPTVLiveCatalogPersisting {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("IPTVLiveCatalog", isDirectory: true)
    }

    func load(sourceID: UUID) async throws -> IPTVLiveCatalog? {
        try Task.checkCancellation()
        let fileURL = catalogURL(for: sourceID)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            try Task.checkCancellation()
            return try decoder.decode(IPTVLiveCatalog.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IPTVLiveCatalogSyncError.cacheReadFailed
        }
    }

    func save(_ catalog: IPTVLiveCatalog) async throws {
        do {
            try Task.checkCancellation()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var localDirectoryURL = directoryURL
            try localDirectoryURL.setResourceValues(resourceValues)
            let data = try encoder.encode(catalog)
            try Task.checkCancellation()
            try data.write(
                to: catalogURL(for: catalog.sourceID),
                options: .atomic
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IPTVLiveCatalogSyncError.cacheWriteFailed
        }
    }

    func remove(sourceID: UUID) async throws {
        do {
            let fileURL = catalogURL(for: sourceID)
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw IPTVLiveCatalogSyncError.cacheWriteFailed
        }
    }

    private func catalogURL(for sourceID: UUID) -> URL {
        directoryURL.appendingPathComponent(sourceID.uuidString).appendingPathExtension("json")
    }
}

@MainActor
@Observable
final class IPTVLiveCatalogSyncService {
    typealias FetchCategories = @Sendable (URL, String, String) async throws -> [XtreamLiveCategory]
    typealias FetchStreams = @Sendable (URL, String, String) async throws -> [XtreamLiveStream]

    private(set) var states: [UUID: IPTVLiveCatalogState] = [:]

    private let sourcesManager: IPTVSourcesManager
    private let credentialsStore: XtreamCredentialsStoring
    private let persistence: IPTVLiveCatalogPersisting
    private let fetchCategories: FetchCategories
    private let fetchStreams: FetchStreams
    private let now: @Sendable () -> Date
    private let cacheLifetime: TimeInterval

    @ObservationIgnored private var synchronizationTasks: [UUID: Task<IPTVLiveCatalog, Error>] = [:]
    @ObservationIgnored private var synchronizationTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var selectedSourceID: UUID?

    init(
        sourcesManager: IPTVSourcesManager,
        credentialsStore: XtreamCredentialsStoring,
        catalogClient: XtreamLiveCatalogClient = XtreamLiveCatalogClient(),
        persistence: IPTVLiveCatalogPersisting? = nil,
        cacheLifetime: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sourcesManager = sourcesManager
        self.credentialsStore = credentialsStore
        self.persistence = persistence ?? FileIPTVLiveCatalogPersistence()
        fetchCategories = { serverURL, username, password in
            try await catalogClient.fetchCategories(
                serverURL: serverURL,
                username: username,
                password: password
            )
        }
        fetchStreams = { serverURL, username, password in
            try await catalogClient.fetchStreams(
                serverURL: serverURL,
                username: username,
                password: password
            )
        }
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    init(
        sourcesManager: IPTVSourcesManager,
        credentialsStore: XtreamCredentialsStoring,
        persistence: IPTVLiveCatalogPersisting,
        cacheLifetime: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        fetchCategories: @escaping FetchCategories,
        fetchStreams: @escaping FetchStreams
    ) {
        self.sourcesManager = sourcesManager
        self.credentialsStore = credentialsStore
        self.persistence = persistence
        self.cacheLifetime = cacheLifetime
        self.now = now
        self.fetchCategories = fetchCategories
        self.fetchStreams = fetchStreams
    }

    func state(for sourceID: UUID) -> IPTVLiveCatalogState {
        states[sourceID] ?? .empty
    }

    /// Loads the last valid catalog before synchronization so callers can render it immediately.
    @discardableResult
    func loadCachedCatalog(sourceID: UUID) async -> IPTVLiveCatalog? {
        if let loadedState = states[sourceID], loadedState.catalog != nil {
            return loadedState.catalog
        }

        do {
            let catalog = try await persistence.load(sourceID: sourceID)
            try Task.checkCancellation()
            states[sourceID] = IPTVLiveCatalogState(
                catalog: catalog,
                loadingState: .idle,
                lastError: nil
            )
            return catalog
        } catch is CancellationError {
            return states[sourceID]?.catalog
        } catch {
            states[sourceID] = IPTVLiveCatalogState(
                catalog: nil,
                loadingState: .idle,
                lastError: .cacheReadFailed
            )
            return nil
        }
    }

    func synchronizeIfNeeded(
        sourceID: UUID,
        onSynchronizationStarted: (@MainActor @Sendable () -> Void)? = nil
    ) async {
        let cachedCatalog = await loadCachedCatalog(sourceID: sourceID)
        if let cachedCatalog,
           now().timeIntervalSince(cachedCatalog.lastUpdated) <= cacheLifetime {
            return
        }
        onSynchronizationStarted?()
        await synchronize(sourceID: sourceID)
    }

    func refresh(sourceID: UUID) async {
        _ = await loadCachedCatalog(sourceID: sourceID)
        await synchronize(sourceID: sourceID)
    }

    func synchronizeActiveSourceIfNeeded() async {
        guard let activeSourceID = sourcesManager.activeSourceID else { return }
        selectSource(activeSourceID)
        await synchronizeIfNeeded(sourceID: activeSourceID)
    }

    func refreshActiveSource() async {
        guard let activeSourceID = sourcesManager.activeSourceID else { return }
        selectSource(activeSourceID)
        await refresh(sourceID: activeSourceID)
    }

    func selectSource(_ sourceID: UUID) {
        if let selectedSourceID, selectedSourceID != sourceID {
            cancel(sourceID: selectedSourceID)
        }
        selectedSourceID = sourceID
    }

    func cancel(sourceID: UUID) {
        synchronizationTasks[sourceID]?.cancel()
        synchronizationTasks[sourceID] = nil
        synchronizationTokens[sourceID] = nil
        var currentState = state(for: sourceID)
        currentState.loadingState = .idle
        states[sourceID] = currentState
    }

    private func synchronize(sourceID: UUID) async {
        if let existingTask = synchronizationTasks[sourceID] {
            _ = try? await existingTask.value
            return
        }

        guard let source = sourcesManager.sources.first(where: { $0.id == sourceID }) else {
            setError(.sourceNotFound, sourceID: sourceID)
            return
        }

        let credentials: XtreamCredentials
        do {
            guard let storedCredentials = try credentialsStore.credentials(for: sourceID) else {
                setError(.credentialsUnavailable, sourceID: sourceID)
                return
            }
            credentials = storedCredentials
        } catch {
            setError(.credentialsUnavailable, sourceID: sourceID)
            return
        }

        var currentState = state(for: sourceID)
        currentState.loadingState = currentState.catalog == nil ? .loading : .refreshing
        currentState.lastError = nil
        states[sourceID] = currentState

        let fetchCategories = fetchCategories
        let fetchStreams = fetchStreams
        let synchronizationDate = now()
        let synchronizationToken = UUID()
        let task = Task<IPTVLiveCatalog, Error> {
            async let categories = fetchCategories(
                source.serverURL,
                credentials.username,
                credentials.password
            )
            async let streams = fetchStreams(
                source.serverURL,
                credentials.username,
                credentials.password
            )
            let (fetchedCategories, fetchedStreams) = try await (categories, streams)
            return IPTVLiveCatalog(
                sourceID: sourceID,
                categories: fetchedCategories,
                streams: fetchedStreams,
                lastUpdated: synchronizationDate
            )
        }
        synchronizationTasks[sourceID] = task
        synchronizationTokens[sourceID] = synchronizationToken
        defer {
            if synchronizationTokens[sourceID] == synchronizationToken {
                synchronizationTasks[sourceID] = nil
                synchronizationTokens[sourceID] = nil
            }
        }

        do {
            let catalog = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard synchronizationTokens[sourceID] == synchronizationToken,
                  sourcesManager.sources.contains(where: { $0.id == sourceID }) else {
                return
            }
            try await persistence.save(catalog)
            try Task.checkCancellation()
            guard synchronizationTokens[sourceID] == synchronizationToken,
                  sourcesManager.sources.contains(where: { $0.id == sourceID }) else {
                return
            }
            states[sourceID] = IPTVLiveCatalogState(
                catalog: catalog,
                loadingState: .idle,
                lastError: nil
            )
        } catch is CancellationError {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            var retainedState = state(for: sourceID)
            retainedState.loadingState = .idle
            states[sourceID] = retainedState
        } catch let error as IPTVLiveCatalogSyncError where error == .cacheWriteFailed {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            setError(.cacheWriteFailed, sourceID: sourceID)
        } catch {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            setError(.refreshFailed, sourceID: sourceID)
        }
    }

    private func setError(_ error: IPTVLiveCatalogSyncError, sourceID: UUID) {
        var currentState = state(for: sourceID)
        currentState.loadingState = .idle
        currentState.lastError = error
        states[sourceID] = currentState
    }
}
