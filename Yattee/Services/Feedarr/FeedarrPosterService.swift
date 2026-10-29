//
//  FeedarrPosterService.swift
//  Yattee
//
//  Private Nuke pipeline for the active Feedarr installation's posters.
//

import Foundation
import Observation
import Nuke

enum FeedarrPosterError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotConfigured, credentialsUnavailable, missingCredentials
    case invalidURL, cacheUnavailable, invalidImage, cancelled, obsoleteResponse
    case transport(FeedarrHTTPError)

    var errorDescription: String? { "The Feedarr poster is unavailable." }
}

@MainActor
@Observable
final class FeedarrPosterService {
    nonisolated static let maximumResponseSize = 8 * 1_024 * 1_024
    nonisolated static let memoryCacheLimit = 32 * 1_024 * 1_024
    nonisolated static let diskCacheLimit = 100 * 1_024 * 1_024

    private(set) var generation = UUID()
    @ObservationIgnored private let sources: FeedarrSourcesManager
    @ObservationIgnored private let credentialsStore: any FeedarrCredentialsStoring
    @ObservationIgnored private let transport: any FeedarrHTTPTransport
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private var snapshot: Snapshot?
    @ObservationIgnored private var snapshotRevision: UUID?
    @ObservationIgnored private var pipeline: ImagePipeline?
    @ObservationIgnored private var diskCache: FeedarrPosterDataCache?

    /// Own one service per sources manager and inject it into poster views.
    /// No credential fingerprint is persisted: a cold start purges the dedicated
    /// disk cache, which remains useful across memory evictions within the session.
    init(
        sources: FeedarrSourcesManager,
        credentialsStore: (any FeedarrCredentialsStoring)? = nil,
        transport: any FeedarrHTTPTransport = URLSessionFeedarrTransport(),
        cacheDirectory: URL? = nil
    ) {
        self.sources = sources
        self.credentialsStore = credentialsStore ?? FeedarrCredentialsStore()
        self.transport = transport
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.xtubee.feedarr.posters", isDirectory: true)
        // Also remove a previous session's cache when the current source is absent.
        if let cache = try? DataCache(path: self.cacheDirectory) { cache.removeAll(); cache.flush() }
        try? refreshConfiguration()
        observeSource()
    }

    func image(for release: FeedarrRelease) async throws -> PlatformImage {
        if Task.isCancelled { throw FeedarrPosterError.cancelled }
        try refreshConfiguration()
        guard let snapshot, let pipeline else { throw FeedarrPosterError.sourceNotConfigured }
        let url = try Self.resolvePosterURL(release.posterUrl, source: snapshot.source)
        let token = generation
        do {
            let image = try await pipeline.image(for: url)
            if Task.isCancelled { throw FeedarrPosterError.cancelled }
            try refreshConfiguration()
            guard token == generation else { throw FeedarrPosterError.obsoleteResponse }
            return image
        } catch {
            if Task.isCancelled { throw FeedarrPosterError.cancelled }
            try refreshConfiguration()
            guard token == generation else { throw FeedarrPosterError.obsoleteResponse }
            if error is CancellationError { throw FeedarrPosterError.cancelled }
            if let error = error as? FeedarrPosterError { throw error }
            if case let ImagePipeline.Error.dataLoadingFailed(underlying) = error {
                if let error = underlying as? FeedarrHTTPError {
                    if error == .cancelled { throw FeedarrPosterError.cancelled }
                    throw FeedarrPosterError.transport(error)
                }
                if let error = underlying as? FeedarrPosterError { throw error }
            }
            throw FeedarrPosterError.invalidImage
        }
    }

    /// Handles both backend-root paths and paths already including the proxy base.
    /// Absolute URLs are preserved, but must stay inside the configured installation.
    nonisolated static func resolvePosterURL(_ raw: String?, source: FeedarrSource) throws -> URL {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("//"), !raw.contains("\\"),
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              var poster = URLComponents(string: raw), poster.fragment == nil,
              poster.user == nil, poster.password == nil else { throw FeedarrPosterError.invalidURL }
        let decodedPath = poster.percentEncodedPath.removingPercentEncoding ?? poster.path
        guard !decodedPath.contains("\\"),
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw FeedarrPosterError.invalidURL
        }
        let forbidden = Set(["username", "password", "user", "pass", "token", "access_token", "api_key", "apikey", "authorization"])
        guard !(poster.queryItems ?? []).contains(where: { forbidden.contains($0.name.lowercased()) }) else {
            throw FeedarrPosterError.invalidURL
        }
        guard let base = URLComponents(url: source.serverURL, resolvingAgainstBaseURL: false) else {
            throw FeedarrPosterError.invalidURL
        }
        let prefix = base.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = prefix.isEmpty ? "" : "/" + prefix
        if poster.scheme == nil && poster.host == nil {
            let path = "/" + poster.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            poster.scheme = base.scheme
            poster.host = base.host
            poster.port = base.port
            poster.percentEncodedPath = basePath.isEmpty || path.hasPrefix(basePath + "/") ? path : basePath + path
        }
        guard let url = poster.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              FeedarrRedirectPolicy.allowsRedirect(from: source.serverURL, to: url),
              basePath.isEmpty || url.path.hasPrefix(source.serverURL.path + "/") else {
            throw FeedarrPosterError.invalidURL
        }
        return url
    }

    private func currentSnapshot() throws -> Snapshot? {
        guard let source = sources.source else { return nil }
        guard sources.loadError == nil else { throw FeedarrPosterError.credentialsUnavailable }
        var credentials: FeedarrCredentials?
        if source.usesBasicAuth {
            do { credentials = try credentialsStore.credentials(for: source.id) }
            catch { throw FeedarrPosterError.credentialsUnavailable }
            guard credentials != nil else { throw FeedarrPosterError.missingCredentials }
            guard source.serverURL.scheme == "https" else { throw FeedarrPosterError.transport(.insecureBasicAuth) }
        }
        return Snapshot(source: source, credentials: credentials)
    }

    private func refreshConfiguration() throws {
        let revision = sources.configurationRevision
        // All application credential writes and reloads advance this revision.
        // Check it before and after loading without rereading Keychain per image.
        guard snapshotRevision != revision else { return }
        let next: Snapshot?
        do { next = try currentSnapshot() }
        catch { invalidate(); throw error }
        guard next != snapshot else {
            snapshotRevision = revision
            return
        }
        invalidate()
        guard let next else {
            snapshotRevision = revision
            return
        }
        do {
            let disk = try FeedarrPosterDataCache(path: cacheDirectory)
            let memory = ImageCache()
            memory.costLimit = Self.memoryCacheLimit
            memory.countLimit = 150
            var configuration = ImagePipeline.Configuration(dataLoader: FeedarrPosterLoader(snapshot: next, transport: transport))
            configuration.imageCache = memory
            configuration.dataCache = disk
            configuration.isTaskCoalescingEnabled = true
            configuration.isProgressiveDecodingEnabled = false
            pipeline = ImagePipeline(configuration: configuration, delegate: PosterCacheKey(generation: generation))
            diskCache = disk
            snapshot = next
            snapshotRevision = revision
        } catch { throw FeedarrPosterError.cacheUnavailable }
    }

    private func invalidate() {
        snapshotRevision = nil
        guard snapshot != nil || pipeline != nil else { return }
        // Close writes before cancellation: late completions cannot repopulate disk.
        diskCache?.closeAndPurge()
        pipeline?.invalidate()
        pipeline?.configuration.imageCache?.removeAll()
        pipeline = nil
        diskCache = nil
        snapshot = nil
        generation = UUID()
    }

    private func observeSource() {
        withObservationTracking {
            _ = sources.source
            _ = sources.loadError
            _ = sources.configurationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? self.refreshConfiguration()
                self.observeSource()
            }
        }
    }

    private struct Snapshot: Equatable, Sendable {
        let source: FeedarrSource
        let credentials: FeedarrCredentials?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.source.id == rhs.source.id && lhs.source.serverURL == rhs.source.serverURL &&
                lhs.source.usesBasicAuth == rhs.source.usesBasicAuth && lhs.credentials == rhs.credentials
        }
    }

    private struct FeedarrPosterLoader: DataLoading {
        let snapshot: Snapshot
        let transport: any FeedarrHTTPTransport

        func loadData(with request: URLRequest,
                      didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                      completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
            let task = Task {
                do {
                    let url = try FeedarrPosterService.resolvePosterURL(request.url?.absoluteString, source: snapshot.source)
                    let http = try FeedarrHTTPClient(
                        serverURL: url.absoluteString, username: snapshot.credentials?.username, password: snapshot.credentials?.password,
                        transport: PosterTransport(underlying: transport), maximumResponseSize: FeedarrPosterService.maximumResponseSize
                    )
                    let (data, response) = try await http.getResponse(pathComponents: [])
                    try http.validateStatus(response)
                    try Task.checkCancellation()
                    didReceiveData(data, response)
                    completion(nil)
                } catch { completion(error) }
            }
            return PosterCancellation(task: task)
        }
    }
}

private struct PosterTransport: FeedarrHTTPTransport {
    let underlying: any FeedarrHTTPTransport
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, maximumResponseSize: FeedarrPosterService.maximumResponseSize)
    }
    func data(for request: URLRequest, maximumResponseSize: Int) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await underlying.data(for: request, maximumResponseSize: maximumResponseSize)
    }
}

private final class PosterCancellation: Cancellable, Sendable {
    let task: Task<Void, Never>
    init(task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
}

private final class PosterCacheKey: ImagePipelineDelegate {
    let generation: UUID
    init(generation: UUID) { self.generation = generation }
    func cacheKey(for request: ImageRequest, pipeline: ImagePipeline) -> String? {
        request.url.map { generation.uuidString + ":" + $0.absoluteString }
    }
}

/// A Feedarr-only write gate around Nuke's disk cache, preventing post-purge writes.
private final class FeedarrPosterDataCache: DataCaching, @unchecked Sendable {
    private let lock = NSLock()
    private let cache: DataCache
    private var active = true
    init(path: URL) throws {
        cache = try DataCache(path: path)
        cache.sizeLimit = FeedarrPosterService.diskCacheLimit
    }
    func cachedData(for key: String) -> Data? { lock.withLock { active ? cache.cachedData(for: key) : nil } }
    func containsData(for key: String) -> Bool { cachedData(for: key) != nil }
    func storeData(_ data: Data, for key: String) { lock.withLock { if active { cache.storeData(data, for: key) } } }
    func removeData(for key: String) { lock.withLock { cache.removeData(for: key) } }
    func removeAll() { lock.withLock { cache.removeAll() } }
    func closeAndPurge() {
        lock.withLock { active = false; cache.removeAll() }
        cache.flush()
    }
}
