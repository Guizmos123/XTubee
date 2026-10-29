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
    let configurationRevision: UUID?

    init(sourceID: UUID, categories: [XtreamLiveCategory], streams: [XtreamLiveStream],
         lastUpdated: Date, configurationRevision: UUID? = nil) {
        self.sourceID = sourceID
        self.categories = categories
        self.streams = streams
        self.lastUpdated = lastUpdated
        self.configurationRevision = configurationRevision
    }
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
    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVLiveCatalog?
    func save(_ catalog: IPTVLiveCatalog) async throws
    func remove(sourceID: UUID) async throws
}

extension IPTVLiveCatalogPersisting {
    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVLiveCatalog? {
        let catalog = try await load(sourceID: sourceID)
        return catalog?.configurationRevision == configurationRevision ? catalog : nil
    }
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
        try await load(sourceID: sourceID, configurationRevision: nil)
    }

    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVLiveCatalog? {
        try Task.checkCancellation()
        let fileURL = catalogURL(for: sourceID, configurationRevision: configurationRevision)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            try Task.checkCancellation()
            let catalog = try decoder.decode(IPTVLiveCatalog.self, from: data)
            guard catalog.sourceID == sourceID, catalog.configurationRevision == configurationRevision else { return nil }
            return catalog
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
                to: catalogURL(for: catalog.sourceID, configurationRevision: catalog.configurationRevision),
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
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            for fileURL in try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                where fileURL.lastPathComponent.hasPrefix(sourceID.uuidString + ".") && fileURL.pathExtension == "json" {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            throw IPTVLiveCatalogSyncError.cacheWriteFailed
        }
    }

    private func catalogURL(for sourceID: UUID, configurationRevision: UUID?) -> URL {
        let name = sourceID.uuidString + (configurationRevision.map { "." + $0.uuidString } ?? "")
        return directoryURL.appendingPathComponent(name).appendingPathExtension("json")
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
    @ObservationIgnored private var sourceCacheIdentities: [UUID: UUID] = [:]

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
        observeSources()
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
        observeSources()
    }

    func state(for sourceID: UUID) -> IPTVLiveCatalogState {
        guard let source = sourcesManager.sources.first(where: { $0.id == sourceID }),
              sourceCacheIdentities[sourceID] == source.cacheIdentity else { return .empty }
        return states[sourceID] ?? .empty
    }

    /// Loads the last valid catalog before synchronization so callers can render it immediately.
    @discardableResult
    func loadCachedCatalog(sourceID: UUID) async -> IPTVLiveCatalog? {
        synchronizeConfiguration(sourceID: sourceID)
        guard let source = sourcesManager.sources.first(where: { $0.id == sourceID }) else { return nil }
        if let loadedState = states[sourceID], loadedState.catalog != nil {
            return loadedState.catalog
        }

        do {
            let catalog = try await persistence.load(sourceID: sourceID, configurationRevision: source.configurationRevision)
            try Task.checkCancellation()
            guard isCurrent(source) else { return nil }
            states[sourceID] = IPTVLiveCatalogState(
                catalog: catalog,
                loadingState: .idle,
                lastError: nil
            )
            return catalog
        } catch is CancellationError {
            return state(for: sourceID).catalog
        } catch {
            guard isCurrent(source) else { return nil }
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
        guard !Task.isCancelled else { return }
        synchronizeConfiguration(sourceID: sourceID)
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
                lastUpdated: synchronizationDate,
                configurationRevision: source.configurationRevision
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
                  !Task.isCancelled, isCurrent(source) else {
                return
            }
            try await persistence.save(catalog)
            try Task.checkCancellation()
            guard synchronizationTokens[sourceID] == synchronizationToken,
                  isCurrent(source) else {
                return
            }
            states[sourceID] = IPTVLiveCatalogState(
                catalog: catalog,
                loadingState: .idle,
                lastError: nil
            )
        } catch is CancellationError {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            var retainedState = state(for: sourceID)
            retainedState.loadingState = .idle
            states[sourceID] = retainedState
        } catch let error as IPTVLiveCatalogSyncError where error == .cacheWriteFailed {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            setError(.cacheWriteFailed, sourceID: sourceID)
        } catch {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            setError(.refreshFailed, sourceID: sourceID)
        }
    }

    private func isCurrent(_ source: IPTVSource) -> Bool {
        sourcesManager.sources.contains { $0.id == source.id && $0.cacheIdentity == source.cacheIdentity }
    }

    private func synchronizeConfiguration(sourceID: UUID) {
        let identity = sourcesManager.sources.first { $0.id == sourceID }?.cacheIdentity
        guard sourceCacheIdentities[sourceID] != identity else { return }
        cancel(sourceID: sourceID)
        states[sourceID] = nil
        sourceCacheIdentities[sourceID] = identity
    }

    private func observeSources() {
        withObservationTracking { _ = sourcesManager.sources } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for sourceID in Array(self.sourceCacheIdentities.keys) {
                    self.synchronizeConfiguration(sourceID: sourceID)
                }
                self.observeSources()
            }
        }
    }

    private func setError(_ error: IPTVLiveCatalogSyncError, sourceID: UUID) {
        var currentState = state(for: sourceID)
        currentState.loadingState = .idle
        currentState.lastError = error
        states[sourceID] = currentState
    }
}
