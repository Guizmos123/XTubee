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
    func save(_ snapshot: IPTVEPGSnapshot) async throws
    func remove(sourceID: UUID) async throws
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
        try Task.checkCancellation()
        let fileURL = cacheURL(for: sourceID)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            try Task.checkCancellation()
            let snapshot = try decoder.decode(
                IPTVEPGSnapshot.self,
                from: data
            )
            guard snapshot.sourceID == sourceID else {
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
                to: cacheURL(for: snapshot.sourceID),
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
            let fileURL = cacheURL(for: sourceID)
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw IPTVEPGSyncError.cacheWriteFailed
        }
    }

    private func cacheURL(for sourceID: UUID) -> URL {
        directoryURL
            .appendingPathComponent(sourceID.uuidString)
            .appendingPathExtension("epgcache")
    }
}

private enum XtreamXMLTVDownloadError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus
    case responseTooLarge
    case transport
}

actor XtreamXMLTVClient {
    static let defaultTimeout: TimeInterval = 120
    static let defaultMaximumDownloadSize: Int64 = 128 * 1_024 * 1_024

    private let session: URLSession
    private let timeout: TimeInterval
    private let maximumDownloadSize: Int64

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        timeout: TimeInterval = defaultTimeout,
        maximumDownloadSize: Int64 = defaultMaximumDownloadSize
    ) {
        precondition(timeout > 0, "XMLTV timeout must be positive")
        precondition(maximumDownloadSize > 0, "XMLTV size limit must be positive")

        session = URLSession(
            configuration: configuration,
            delegate: XtreamRedirectDelegate(),
            delegateQueue: nil
        )
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
            let (fileURL, response) = try await session.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: fileURL)
                throw XtreamXMLTVDownloadError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                try? FileManager.default.removeItem(at: fileURL)
                throw XtreamXMLTVDownloadError.httpStatus
            }

            let expectedLength = httpResponse.expectedContentLength
            let downloadedSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard expectedLength <= 0 || expectedLength <= maximumDownloadSize,
                  Int64(downloadedSize) <= maximumDownloadSize else {
                try? FileManager.default.removeItem(at: fileURL)
                throw XtreamXMLTVDownloadError.responseTooLarge
            }
            let ownedFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("XMLTVDownload-\(UUID().uuidString)")
                .appendingPathExtension("xml")
            try FileManager.default.moveItem(at: fileURL, to: ownedFileURL)
            return ownedFileURL
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
    }

    func state(for sourceID: UUID) -> IPTVEPGState {
        states[sourceID] ?? .empty
    }

    @discardableResult
    func loadCachedCatalog(sourceID: UUID) async -> EPGCatalog? {
        if let existing = states[sourceID]?.snapshot {
            return existing.catalog
        }

        do {
            let snapshot = try await persistence.load(sourceID: sourceID)
            try Task.checkCancellation()
            states[sourceID] = IPTVEPGState(
                snapshot: snapshot,
                loadingState: .idle,
                lastError: nil
            )
            return snapshot?.catalog
        } catch is CancellationError {
            return states[sourceID]?.catalog
        } catch {
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
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard synchronizationTokens[sourceID] == synchronizationToken,
                  sourcesManager.sources.contains(where: { $0.id == sourceID }) else {
                return
            }
            try await persistence.save(snapshot)
            try Task.checkCancellation()
            guard synchronizationTokens[sourceID] == synchronizationToken,
                  sourcesManager.sources.contains(where: { $0.id == sourceID }) else {
                return
            }
            states[sourceID] = IPTVEPGState(
                snapshot: snapshot,
                loadingState: .idle,
                lastError: nil
            )
        } catch is CancellationError {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            var retainedState = state(for: sourceID)
            retainedState.loadingState = .idle
            states[sourceID] = retainedState
        } catch let error as IPTVEPGSyncError where error == .cacheWriteFailed {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            setError(.cacheWriteFailed, sourceID: sourceID)
        } catch is XMLTVParserError {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            setError(.invalidXML, sourceID: sourceID)
        } catch let error as XtreamXMLTVDownloadError where error == .responseTooLarge {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            setError(.responseTooLarge, sourceID: sourceID)
        } catch {
            guard synchronizationTokens[sourceID] == synchronizationToken else { return }
            setError(.downloadFailed, sourceID: sourceID)
        }

    }

    private func setError(_ error: IPTVEPGSyncError, sourceID: UUID) {
        var retainedState = state(for: sourceID)
        retainedState.loadingState = .idle
        retainedState.lastError = error
        states[sourceID] = retainedState
    }
}
