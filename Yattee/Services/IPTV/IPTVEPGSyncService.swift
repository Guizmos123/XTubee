//
//  IPTVEPGSyncService.swift
//  Yattee
//
//  Downloads, parses, caches, and synchronizes XMLTV guides per IPTV source.
//

import Foundation
import SwiftUI

struct IPTVEPGSnapshot: Codable, Equatable, Sendable {
    let sourceID: UUID
    let catalog: EPGCatalog
    let lastUpdated: Date
    let configurationRevision: UUID?

    init(sourceID: UUID, catalog: EPGCatalog, lastUpdated: Date, configurationRevision: UUID? = nil) {
        self.sourceID = sourceID
        self.catalog = catalog
        self.lastUpdated = lastUpdated
        self.configurationRevision = configurationRevision
    }
}

enum IPTVEPGLoadingState: Equatable, Sendable {
    case idle
    case loading
    case refreshing
}

enum IPTVEPGSyncError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotFound
    case credentialsUnavailable
    case cacheReadFailed
    case cacheWriteFailed
    case downloadFailed
    case responseTooLarge
    case invalidXML

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "The IPTV source was not found."
        case .credentialsUnavailable:
            return "The local IPTV credentials are unavailable."
        case .cacheReadFailed:
            return "The cached programme guide could not be read."
        case .cacheWriteFailed:
            return "The programme guide could not be cached."
        case .downloadFailed:
            return "The programme guide could not be downloaded."
        case .responseTooLarge:
            return "The programme guide exceeded the download size limit."
        case .invalidXML:
            return "The programme guide contains invalid XMLTV data."
        }
    }
}

struct IPTVEPGState: Equatable, Sendable {
    var snapshot: IPTVEPGSnapshot?
    var loadingState: IPTVEPGLoadingState
    var lastError: IPTVEPGSyncError?

    var catalog: EPGCatalog? { snapshot?.catalog }
    var lastUpdated: Date? { snapshot?.lastUpdated }

    static let empty = IPTVEPGState(
        snapshot: nil,
        loadingState: .idle,
        lastError: nil
    )
}

protocol IPTVEPGPersisting: Actor {
    func load(sourceID: UUID) async throws -> IPTVEPGSnapshot?
    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVEPGSnapshot?
    func save(_ snapshot: IPTVEPGSnapshot) async throws
    func remove(sourceID: UUID) async throws
}

extension IPTVEPGPersisting {
    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVEPGSnapshot? {
        let snapshot = try await load(sourceID: sourceID)
        return snapshot?.configurationRevision == configurationRevision ? snapshot : nil
    }
}

actor FileIPTVEPGPersistence: IPTVEPGPersisting {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("IPTVEPG", isDirectory: true)
        encoder.outputFormat = .binary
    }

    func load(sourceID: UUID) async throws -> IPTVEPGSnapshot? {
        try await load(sourceID: sourceID, configurationRevision: nil)
    }

    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVEPGSnapshot? {
        try Task.checkCancellation()
        let fileURL = cacheURL(for: sourceID, configurationRevision: configurationRevision)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            try Task.checkCancellation()
            let snapshot = try decoder.decode(
                IPTVEPGSnapshot.self,
                from: data
            )
            guard snapshot.sourceID == sourceID, snapshot.configurationRevision == configurationRevision else {
                throw IPTVEPGSyncError.cacheReadFailed
            }
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IPTVEPGSyncError.cacheReadFailed
        }
    }

    func save(_ snapshot: IPTVEPGSnapshot) async throws {
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

            let data = try encoder.encode(snapshot)
            try Task.checkCancellation()
            try data.write(
                to: cacheURL(for: snapshot.sourceID, configurationRevision: snapshot.configurationRevision),
                options: .atomic
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IPTVEPGSyncError.cacheWriteFailed
        }
    }

    func remove(sourceID: UUID) async throws {
        do {
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            for fileURL in try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                where fileURL.lastPathComponent.hasPrefix(sourceID.uuidString + ".") && fileURL.pathExtension == "epgcache" {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            throw IPTVEPGSyncError.cacheWriteFailed
        }
    }

    private func cacheURL(for sourceID: UUID, configurationRevision: UUID?) -> URL {
        let name = sourceID.uuidString + (configurationRevision.map { "." + $0.uuidString } ?? "")
        return directoryURL
            .appendingPathComponent(name)
            .appendingPathExtension("epgcache")
    }
}

enum XtreamXMLTVDownloadError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus
    case responseTooLarge
    case transport
}

/// One XMLTV transfer. Delegate callbacks write bounded chunks directly to disk.
/// The lock also serializes cancellation with writes and continuation completion.
private final class XtreamXMLTVDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("XMLTVDownload-\(UUID().uuidString)").appendingPathExtension("xml")
    private let redirects = XtreamRedirectDelegate()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var output: FileHandle?
    private var receivedBytes: Int64 = 0
    private var completed = false

    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

    func download(request: URLRequest, configuration: URLSessionConfiguration) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    guard !completed else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    let task = session.dataTask(with: request)
                    self.session = session
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let failure: Error? = lock.withLock {
            guard !completed else { return CancellationError() }
            guard let response = response as? HTTPURLResponse else { return XtreamXMLTVDownloadError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { return XtreamXMLTVDownloadError.httpStatus }
            guard response.expectedContentLength <= maximumBytes else { return XtreamXMLTVDownloadError.responseTooLarge }
            do {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    return XtreamXMLTVDownloadError.transport
                }
                output = try FileHandle(forWritingTo: fileURL)
                return nil
            } catch { return XtreamXMLTVDownloadError.transport }
        }
        if let failure {
            finish(.failure(failure))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failure: Error? = lock.withLock {
            guard !completed else { return nil }
            guard let output else { return XtreamXMLTVDownloadError.invalidResponse }
            // Check before writing, independently of any advertised length. Subtraction
            // avoids overflow and the partial file never exceeds the configured bound.
            guard Int64(data.count) <= maximumBytes - receivedBytes else {
                return XtreamXMLTVDownloadError.responseTooLarge
            }
            do {
                try output.write(contentsOf: data)
                receivedBytes += Int64(data.count)
                return nil
            } catch { return XtreamXMLTVDownloadError.transport }
        }
        if let failure { finish(.failure(failure)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        let result: Result<URL, Error>? = lock.withLock {
            guard !completed else { return nil }
            guard let output else { return .failure(XtreamXMLTVDownloadError.invalidResponse) }
            do {
                try output.close()
                self.output = nil
                return .success(fileURL)
            } catch { return .failure(XtreamXMLTVDownloadError.transport) }
        }
        if let result { finish(result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: request, completionHandler: completionHandler)
    }

    private func finish(_ result: Result<URL, Error>) {
        let resources: (CheckedContinuation<URL, Error>?, URLSessionDataTask?, URLSession?)? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            try? output?.close()
            output = nil
            if case .failure = result { try? FileManager.default.removeItem(at: fileURL) }
            let resources = (continuation, task, session)
            continuation = nil
            task = nil
            session = nil
            return resources
        }
        guard let (continuation, task, session) = resources else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

actor XtreamXMLTVClient {
    static let defaultTimeout: TimeInterval = 120
    static let defaultMaximumDownloadSize: Int64 = 128 * 1_024 * 1_024

    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private let maximumDownloadSize: Int64

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        timeout: TimeInterval = defaultTimeout,
        maximumDownloadSize: Int64 = defaultMaximumDownloadSize
    ) {
        precondition(timeout > 0, "XMLTV timeout must be positive")
        precondition(maximumDownloadSize > 0, "XMLTV size limit must be positive")

        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.timeout = timeout
        self.maximumDownloadSize = maximumDownloadSize
    }

    func download(
        serverURL: URL,
        username: String,
        password: String
    ) async throws -> URL {
        try Task.checkCancellation()
        let requestURL = try XtreamServerURL.xmlTVURL(
            serverURL: serverURL,
            username: username,
            password: password
        )
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let fileURL = try await XtreamXMLTVDownload(maximumBytes: maximumDownloadSize)
                .download(request: request, configuration: configuration)
            do {
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
            return fileURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as XtreamXMLTVDownloadError {
            throw error
        } catch {
            throw XtreamXMLTVDownloadError.transport
        }
    }
}

@MainActor
@Observable
final class IPTVEPGSyncService {
    typealias DownloadXMLTV = @Sendable (URL, String, String) async throws -> URL
    typealias ParseXMLTV = @Sendable (URL) async throws -> EPGCatalog

    private(set) var states: [UUID: IPTVEPGState] = [:]

    private let sourcesManager: IPTVSourcesManager
    private let credentialsStore: XtreamCredentialsStoring
    private let persistence: IPTVEPGPersisting
    private let downloadXMLTV: DownloadXMLTV
    private let parseXMLTV: ParseXMLTV
    private let now: @Sendable () -> Date
    private let cacheLifetime: TimeInterval

    @ObservationIgnored private var synchronizationTasks: [UUID: Task<IPTVEPGSnapshot, Error>] = [:]
    @ObservationIgnored private var synchronizationTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var selectedSourceID: UUID?
    @ObservationIgnored private var sourceCacheIdentities: [UUID: UUID] = [:]

    init(
        sourcesManager: IPTVSourcesManager,
        credentialsStore: XtreamCredentialsStoring,
        client: XtreamXMLTVClient = XtreamXMLTVClient(),
        parser: XMLTVParser = XMLTVParser(),
        persistence: IPTVEPGPersisting? = nil,
        cacheLifetime: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sourcesManager = sourcesManager
        self.credentialsStore = credentialsStore
        self.persistence = persistence ?? FileIPTVEPGPersistence()
        downloadXMLTV = { serverURL, username, password in
            try await client.download(
                serverURL: serverURL,
                username: username,
                password: password
            )
        }
        parseXMLTV = { fileURL in
            let parseTask = Task.detached(priority: .utility) {
                guard let stream = InputStream(url: fileURL) else {
                    throw XMLTVParserError.invalidDocument
                }
                return try parser.parse(
                    stream: stream,
                    cancellationCheck: { Task.isCancelled }
                )
            }
            return try await withTaskCancellationHandler {
                try await parseTask.value
            } onCancel: {
                parseTask.cancel()
            }
        }
        self.cacheLifetime = cacheLifetime
        self.now = now
        observeSources()
    }

    init(
        sourcesManager: IPTVSourcesManager,
        credentialsStore: XtreamCredentialsStoring,
        persistence: IPTVEPGPersisting,
        cacheLifetime: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        downloadXMLTV: @escaping DownloadXMLTV,
        parseXMLTV: @escaping ParseXMLTV
    ) {
        self.sourcesManager = sourcesManager
        self.credentialsStore = credentialsStore
        self.persistence = persistence
        self.cacheLifetime = cacheLifetime
        self.now = now
        self.downloadXMLTV = downloadXMLTV
        self.parseXMLTV = parseXMLTV
        observeSources()
    }

    func state(for sourceID: UUID) -> IPTVEPGState {
        guard let source = sourcesManager.sources.first(where: { $0.id == sourceID }),
              sourceCacheIdentities[sourceID] == source.cacheIdentity else { return .empty }
        return states[sourceID] ?? .empty
    }

    @discardableResult
    func loadCachedCatalog(sourceID: UUID) async -> EPGCatalog? {
        synchronizeConfiguration(sourceID: sourceID)
        guard let source = sourcesManager.sources.first(where: { $0.id == sourceID }) else { return nil }
        if let existing = states[sourceID]?.snapshot {
            return existing.catalog
        }

        do {
            let snapshot = try await persistence.load(sourceID: sourceID, configurationRevision: source.configurationRevision)
            try Task.checkCancellation()
            guard isCurrent(source) else { return nil }
            states[sourceID] = IPTVEPGState(
                snapshot: snapshot,
                loadingState: .idle,
                lastError: nil
            )
            return snapshot?.catalog
        } catch is CancellationError {
            return state(for: sourceID).catalog
        } catch {
            guard isCurrent(source) else { return nil }
            states[sourceID] = IPTVEPGState(
                snapshot: nil,
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
        _ = await loadCachedCatalog(sourceID: sourceID)
        if let lastUpdated = state(for: sourceID).lastUpdated,
           now().timeIntervalSince(lastUpdated) <= cacheLifetime {
            return
        }
        onSynchronizationStarted?()
        await synchronize(sourceID: sourceID)
    }

    func refresh(sourceID: UUID) async {
        _ = await loadCachedCatalog(sourceID: sourceID)
        await synchronize(sourceID: sourceID)
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
        var retainedState = state(for: sourceID)
        retainedState.loadingState = .idle
        states[sourceID] = retainedState
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

        var loadingState = state(for: sourceID)
        loadingState.loadingState = loadingState.snapshot == nil ? .loading : .refreshing
        loadingState.lastError = nil
        states[sourceID] = loadingState

        let downloadXMLTV = downloadXMLTV
        let parseXMLTV = parseXMLTV
        let synchronizationDate = now()
        let synchronizationToken = UUID()
        let task = Task<IPTVEPGSnapshot, Error> {
            let fileURL = try await downloadXMLTV(
                source.serverURL,
                credentials.username,
                credentials.password
            )
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let catalog = try await parseXMLTV(fileURL)
            return IPTVEPGSnapshot(
                sourceID: sourceID,
                catalog: catalog,
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
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard synchronizationTokens[sourceID] == synchronizationToken,
                  !Task.isCancelled, isCurrent(source) else {
                return
            }
            try await persistence.save(snapshot)
            try Task.checkCancellation()
            guard synchronizationTokens[sourceID] == synchronizationToken,
                  isCurrent(source) else {
                return
            }
            states[sourceID] = IPTVEPGState(
                snapshot: snapshot,
                loadingState: .idle,
                lastError: nil
            )
        } catch is CancellationError {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            var retainedState = state(for: sourceID)
            retainedState.loadingState = .idle
            states[sourceID] = retainedState
        } catch let error as IPTVEPGSyncError where error == .cacheWriteFailed {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            setError(.cacheWriteFailed, sourceID: sourceID)
        } catch is XMLTVParserError {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            setError(.invalidXML, sourceID: sourceID)
        } catch let error as XtreamXMLTVDownloadError where error == .responseTooLarge {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            setError(.responseTooLarge, sourceID: sourceID)
        } catch {
            guard synchronizationTokens[sourceID] == synchronizationToken, isCurrent(source) else { return }
            setError(.downloadFailed, sourceID: sourceID)
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

    private func setError(_ error: IPTVEPGSyncError, sourceID: UUID) {
        var retainedState = state(for: sourceID)
        retainedState.loadingState = .idle
        retainedState.lastError = error
        states[sourceID] = retainedState
    }
}
