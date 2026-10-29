//
//  XtreamLivePlaybackService.swift
//  Yattee
//
//  Prepares non-persistent Xtream Live playback objects without starting playback.
//

import Foundation

enum XtreamLiveOutputFormat: String, Codable, Hashable, Sendable {
    case m3u8
    case ts

    var mimeType: String {
        switch self {
        case .m3u8: return "application/vnd.apple.mpegurl"
        case .ts: return "video/mp2t"
        }
    }
}

enum XtreamLivePlaybackPolicy: Hashable, Sendable {
    /// Loads the canonical Xtream URL directly and lets MPV handle HTTP and HLS
    /// redirects. No authorization, cookie, or other sensitive header is added.
    /// Redirect targets remain controlled by the provider, and plain HTTP does
    /// not protect the credential-bearing URL in transit.
    case directMPV
}

struct XtreamLivePlaybackPreparation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let video: Video
    let stream: Stream
    let outputFormat: XtreamLiveOutputFormat
    let playbackPolicy: XtreamLivePlaybackPolicy

    var isPlaybackAllowed: Bool { playbackPolicy == .directMPV }
    var description: String { "XtreamLivePlaybackPreparation(redacted)" }
    var debugDescription: String { description }
}

enum XtreamLivePlaybackPreparationError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotFound
    case credentialsMissing
    case credentialStoreUnavailable
    case noSupportedOutputFormat
    case invalidStreamIdentifier
    case invalidPlaybackURL

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "The IPTV source was not found."
        case .credentialsMissing:
            return "The IPTV source credentials are unavailable."
        case .credentialStoreUnavailable:
            return "The local IPTV credential store is unavailable."
        case .noSupportedOutputFormat:
            return "The IPTV account does not advertise a supported Live output format."
        case .invalidStreamIdentifier:
            return "The IPTV stream identifier is invalid."
        case .invalidPlaybackURL:
            return "The IPTV playback address could not be prepared."
        }
    }
}

@MainActor
final class XtreamLivePlaybackService {
    private static let provider = "iptv"

    private let sourcesManager: IPTVSourcesManager
    private let credentialsStore: XtreamCredentialsStoring

    init(
        sourcesManager: IPTVSourcesManager,
        credentialsStore: XtreamCredentialsStoring
    ) {
        self.sourcesManager = sourcesManager
        self.credentialsStore = credentialsStore
    }

    /// Builds ephemeral `Video` and `Stream` values for the selected Xtream variant.
    ///
    /// The returned stream uses direct MPV playback. MPV may follow provider and
    /// HLS redirects, but this service never attaches sensitive HTTP headers.
    func prepare(
        sourceID: UUID,
        group: IPTVLiveChannelGroup,
        variant: IPTVLiveVariantPresentation,
        allowedOutputFormats: [String]?
    ) throws -> XtreamLivePlaybackPreparation {
        guard let source = sourcesManager.sources.first(where: { $0.id == sourceID }) else {
            throw XtreamLivePlaybackPreparationError.sourceNotFound
        }
        guard group.sourceID == sourceID,
              variant.id.groupID == group.id,
              group.variants.contains(variant.variant),
              !variant.streamID.isEmpty else {
            throw XtreamLivePlaybackPreparationError.invalidStreamIdentifier
        }

        let credentials: XtreamCredentials
        do {
            guard let storedCredentials = try credentialsStore.credentials(for: sourceID),
                  !storedCredentials.username.isEmpty,
                  !storedCredentials.password.isEmpty else {
                throw XtreamLivePlaybackPreparationError.credentialsMissing
            }
            credentials = storedCredentials
        } catch let error as XtreamLivePlaybackPreparationError {
            throw error
        } catch {
            throw XtreamLivePlaybackPreparationError.credentialStoreUnavailable
        }

        let outputFormat = try Self.preferredOutputFormat(from: allowedOutputFormats)
        let playbackURL = try Self.playbackURL(
            serverURL: source.serverURL,
            username: credentials.username,
            password: credentials.password,
            streamID: variant.streamID,
            outputFormat: outputFormat
        )

        let video = Video(
            id: VideoID(
                source: .extracted(extractor: Self.provider, originalURL: source.serverURL),
                videoID: "iptv:\(source.id.uuidString.lowercased()):\(variant.streamID)"
            ),
            title: group.displayName,
            description: nil,
            author: Author(
                id: "iptv:\(source.id.uuidString.lowercased())",
                name: source.name,
                hasRealChannelInfo: false
            ),
            duration: 0,
            publishedAt: nil,
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: variant.variant.stream.streamIconURL.map { [Thumbnail(url: $0)] } ?? [],
            isLive: true,
            isUpcoming: false,
            scheduledStartTime: nil
        )
        let stream = Stream(
            url: playbackURL,
            resolution: nil,
            format: outputFormat.rawValue,
            videoCodec: variant.usesHEVC ? "hevc" : nil,
            audioCodec: nil,
            isAudioOnly: false,
            isLive: true,
            mimeType: outputFormat.mimeType,
            httpHeaders: nil
        )

        return XtreamLivePlaybackPreparation(
            video: video,
            stream: stream,
            outputFormat: outputFormat,
            playbackPolicy: .directMPV
        )
    }

    static func preferredOutputFormat(
        from allowedOutputFormats: [String]?
    ) throws -> XtreamLiveOutputFormat {
        let advertised = Set(
            (allowedOutputFormats ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        if advertised.contains(XtreamLiveOutputFormat.m3u8.rawValue) { return .m3u8 }
        if advertised.contains(XtreamLiveOutputFormat.ts.rawValue) { return .ts }
        throw XtreamLivePlaybackPreparationError.noSupportedOutputFormat
    }

    private static func playbackURL(
        serverURL: URL,
        username: String,
        password: String,
        streamID: String,
        outputFormat: XtreamLiveOutputFormat
    ) throws -> URL {
        guard var components = URLComponents(
            url: try XtreamServerURL.normalize(serverURL.absoluteString),
            resolvingAgainstBaseURL: false
        ) else {
            throw XtreamLivePlaybackPreparationError.invalidPlaybackURL
        }

        let encodedSegments = try [username, password, streamID].map(percentEncodedPathSegment)
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = "\(basePath)/live/\(encodedSegments[0])/\(encodedSegments[1])/\(encodedSegments[2]).\(outputFormat.rawValue)"

        guard let url = components.url else {
            throw XtreamLivePlaybackPreparationError.invalidPlaybackURL
        }
        return url
    }

    private static func percentEncodedPathSegment(_ value: String) throws -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard !value.isEmpty,
              let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw XtreamLivePlaybackPreparationError.invalidPlaybackURL
        }
        return encoded
    }
}

// MARK: - Temporary Live Diagnostics

/// Opt-in, bounded diagnostic history. No caller-supplied text reaches the log.
@MainActor
final class IPTVPlaybackDiagnostics {
    enum Event: String, Hashable, Sendable {
        case sessionStart, sessionEnd, playRequest, loadStart, loadCommand, startFile, firstFrame
        case endFile, endHandled, pausedForCache, bufferEmpty, bufferRecovered
        case watchdogStart, watchdogFired, recoveryBegin, recoveryEnd, failed, stateChanged
        case appPause, appStop, backendStop, backendDestroy
        case nativeHTTP, nativeTimeout, nativeNetwork, nativeTLS, nativeDecode, nativeError
    }
    enum Origin: String, Sendable { case none, mpv, watchdog, application }
    enum Reason: String, Sendable { case none, eof, stop, quit, error, redirect, unknown }
    enum Outcome: String, Sendable { case none, success, failure, cancelled, limit }
    enum Failure: String, Sendable { case none, cancelled, network, noInstance, noStreams, load, other }
    enum State: String, Sendable { case idle, loading, ready, playing, paused, buffering, ended, failed }
    enum Format: String, Sendable { case hls, ts, unknown }
    enum Backend: String, Sendable { case mpv, avplayer, unknown }
    struct NativeSignal: Hashable, Sendable {
        let event: Event
        let code: Int?
        let isError: Bool
    }

    let sessionID = UUID()
    private let launched = ContinuousClock.now
    private var firstFrame: ContinuousClock.Instant?
    private var attemptHasFrame = false
    private var attempt = 0
    private var sequence = 0
    private var currentEntry: Int64?
    private var firstSignal: (sequence: Int, time: ContinuousClock.Instant)?
    private var history: [String] = []
    private var startLine: String?
    private var firstFrameLine: String?
    private var firstSignalLine: String?
    private var lastTransitionTimes: [Event: ContinuousClock.Instant] = [:]
    private var nativeSignals: Set<NativeSignal> = []
    private var closed = false
    private var hasFailed = false
    private var format: Format = .unknown
    private var backend: Backend = .unknown
    private var state: State = .idle
    private var position: Double = 0
    private var buffer: Double = 0
    private var percent = 0
    private var paused = false
    private var wasEmpty: Bool?
    private let enabled: @MainActor () -> Bool
    private let sink: @MainActor (String) -> Void

    init(format: String? = nil, backend: Backend = .unknown, enabled: @escaping @MainActor () -> Bool = {
        UserDefaults.standard.bool(forKey: "loggingEnabled") && UserDefaults.standard.bool(forKey: "verboseMPVLogging")
    }, sink: @escaping @MainActor (String) -> Void = { LoggingService.shared.info($0, category: .mpv) }) {
        self.enabled = enabled
        self.sink = sink
        configure(format: format, backend: backend)
        record(.sessionStart)
    }

    func configure(format rawFormat: String?, backend: Backend) {
        switch rawFormat?.lowercased() {
        case "m3u8", "hls": format = .hls
        case "ts": format = .ts
        default: format = .unknown
        }
        self.backend = backend
    }

    func beginLoad() {
        attempt += 1
        attemptHasFrame = false
        position = 0
        buffer = 0
        percent = 0
        paused = false
        wasEmpty = nil
        nativeSignals.removeAll(keepingCapacity: true)
        record(.loadStart, origin: .application)
    }

    func renderedFirstFrame() {
        guard !attemptHasFrame else { return }
        attemptHasFrame = true
        if firstFrame == nil { firstFrame = .now }
        record(.firstFrame)
    }

    func updateState(_ state: State) {
        guard self.state != state else { return }
        self.state = state
        record(.stateChanged)
    }

    func updatePosition(_ position: Double) { self.position = position.isFinite ? max(0, position) : 0 }

    func sample(position: Double, buffer: Double, percent: Int, paused: Bool) {
        self.position = position.isFinite ? max(0, position) : 0
        self.buffer = buffer.isFinite ? max(0, buffer) : 0
        self.percent = min(100, max(0, percent))
        self.paused = paused
        // Property updates can be frequent; only log the empty/nonempty boundary.
        let empty = percent == 0
        if empty != wasEmpty {
            wasEmpty = empty
            record(empty ? .bufferEmpty : .bufferRecovered)
        }
    }

    func native(_ signal: NativeSignal, at time: ContinuousClock.Instant) {
        guard enabled() else { return }
        guard nativeSignals.insert(signal).inserted else { return }
        record(signal.event, origin: .mpv, code: signal.code, incident: signal.isError, at: time)
    }

    func record(_ event: Event, origin: Origin = .none, code: Int? = nil, reason: Reason = .none,
                outcome: Outcome = .none, failure: Failure = .none, recovery: Int? = nil, recoveryID: UUID? = nil, entry: Int64? = nil,
                incident: Bool = false, at time: ContinuousClock.Instant = .now) {
        guard enabled() else { return }
        if [.bufferEmpty, .bufferRecovered, .pausedForCache, .stateChanged].contains(event) {
            if let last = lastTransitionTimes[event], last.duration(to: time) < .seconds(1) { return }
            lastTransitionTimes[event] = time
        }
        sequence += 1
        if event == .startFile { currentEntry = entry }
        let earlierSignal = incident && (firstSignal.map({ time < $0.time }) ?? true)
        if earlierSignal { firstSignal = (sequence, time) }
        let role = incident ? (firstSignal?.sequence == sequence ? "initial" : "secondary") : "none"
        let elapsed = Self.seconds(launched.duration(to: time))
        let sinceFrame = firstFrame.flatMap { time >= $0 ? Self.seconds($0.duration(to: time)) : nil } ?? -1
        let line = "IPTV-DIAG session=\(sessionID.uuidString) seq=\(sequence) event=\(event.rawValue) elapsed=\(elapsed) since_first_frame=\(sinceFrame) load=\(attempt) format=\(format.rawValue) backend=\(backend.rawValue) state=\(state.rawValue) position=\(position) buffer=\(buffer) percent=\(percent) paused_for_cache=\(paused) origin=\(origin.rawValue) reason=\(reason.rawValue) code=\(code.map(String.init) ?? "none") recovery=\(recovery.map(String.init) ?? "none") recovery_id=\(recoveryID?.uuidString ?? "none") outcome=\(outcome.rawValue) failure=\(failure.rawValue) entry=\(entry.map(String.init) ?? "none") current_entry=\(currentEntry.map(String.init) ?? "none") first_signal=\(firstSignal?.sequence ?? 0) role=\(role) closed=\(closed)"
        if event == .sessionStart { startLine = line }
        if event == .firstFrame, firstFrameLine == nil { firstFrameLine = line }
        if firstSignal?.sequence == sequence { firstSignalLine = line }
        history.append(line)
        if history.count > 128 { history.removeFirst(history.count - 128) }
        sink(line)
        if event == .failed { hasFailed = true }
        if event == .failed || (earlierSignal && hasFailed) { snapshot() }
    }

    func end() {
        guard !closed else { return }
        closed = true
        record(.sessionEnd, origin: .application)
        snapshot()
    }

    /// Re-emit retained safe records after failure; new MPV attempts never clear this history.
    private func snapshot() {
        guard enabled() else { return }
        sink("IPTV-DIAG snapshot session=\(sessionID.uuidString) first_signal=\(firstSignal?.sequence ?? 0) records=\(history.count)")
        for line in [startLine, firstFrameLine, firstSignalLine].compactMap({ $0 }) {
            sink("IPTV-DIAG anchor " + line)
        }
        for line in history { sink("IPTV-DIAG retained " + line) }
    }

    nonisolated static func failure(_ error: Error) -> Failure {
        if error is CancellationError { return .cancelled }
        if error is URLError { return .network }
        if let error = error as? APIError {
            switch error {
            case .noInstance: return .noInstance
            case .noStreams: return .noStreams
            default: return .other
            }
        }
        if error is BackendError { return .load }
        return .other
    }

    /// Inspect only known patterns. Never retain the prefix, raw line, URL, or error description.
    nonisolated static func classifyNative(prefix: String, level: String, text: String) -> NativeSignal? {
        guard ["fatal", "error", "warn"].contains(level) else { return nil }
        let lower = text.lowercased()
        if let range = lower.range(of: #"http error [1-5][0-9]{2}\b"#, options: .regularExpression),
           let code = Int(lower[range].suffix(3)) {
            return NativeSignal(event: .nativeHTTP, code: code, isError: code >= 400)
        }
        if lower.contains("timed out") || lower.contains("timeout") { return NativeSignal(event: .nativeTimeout, code: nil, isError: true) }
        if lower.contains("tls") || lower.contains("certificate") { return NativeSignal(event: .nativeTLS, code: nil, isError: level != "warn") }
        if lower.contains("connection reset") || lower.contains("connection refused") || lower.contains("network is unreachable") {
            return NativeSignal(event: .nativeNetwork, code: nil, isError: true)
        }
        let component = prefix.lowercased()
        if component.hasPrefix("vd") || component.contains("videotoolbox") || component.contains("decoder") {
            return NativeSignal(event: .nativeDecode, code: nil, isError: level != "warn")
        }
        return level == "error" || level == "fatal" ? NativeSignal(event: .nativeError, code: nil, isError: level != "warn") : nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
