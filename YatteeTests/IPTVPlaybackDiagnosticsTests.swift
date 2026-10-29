//
//  IPTVPlaybackDiagnosticsTests.swift
//  Yattee
//
//  Opt-in event retention and allowlist-only Live diagnostics.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Playback Diagnostics")
@MainActor
struct IPTVPlaybackDiagnosticsTests {
    @Test func disabledModeEmitsNothing() {
        var lines: [String] = []
        let diagnostic = IPTVPlaybackDiagnostics(enabled: { false }, sink: { lines.append($0) })
        diagnostic.beginLoad()
        diagnostic.record(.endFile, reason: .error, incident: true)
        diagnostic.record(.failed, incident: true)
        diagnostic.end()
        #expect(lines.isEmpty)
    }

    @Test func rawNetworkAndErrorTextNeverReachesLogs() throws {
        var lines: [String] = []
        let secret = "https://provider.invalid/live/private-user/private-password/42.m3u8?token=private-token"
        let diagnostic = IPTVPlaybackDiagnostics(format: secret, backend: .mpv, enabled: { true }, sink: { lines.append($0) })
        let signal = try #require(IPTVPlaybackDiagnostics.classifyNative(prefix: "ffmpeg/" + secret, level: "error",
            text: "HTTP error 403 " + secret + " Authorization: private-header Cookie: private-cookie"))
        diagnostic.native(signal, at: .now)
        for error in [SecretDiagnosticError(text: secret) as Error, BackendError.loadFailed(secret),
                      URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLStringErrorKey: secret])] {
            diagnostic.record(.failed, failure: IPTVPlaybackDiagnostics.failure(error), incident: true)
        }
        let exported = lines.joined(separator: "\n")
        #expect(exported.contains("event=nativeHTTP"))
        #expect(exported.contains("code=403"))
        #expect(exported.contains("format=unknown"))
        for forbidden in ["https://", "provider.invalid", "private-user", "private-password", "private-token", "private-header", "private-cookie", "Authorization", "Cookie"] {
            #expect(!exported.contains(forbidden))
        }
    }

    @Test func initialSignalSurvivesNewLoadsAndHistoryEviction() throws {
        var lines: [String] = []
        let diagnostic = IPTVPlaybackDiagnostics(format: "m3u8", backend: .mpv, enabled: { true }, sink: { lines.append($0) })
        diagnostic.beginLoad()
        diagnostic.renderedFirstFrame()
        diagnostic.record(.endFile, origin: .mpv, code: -13, reason: .error, entry: 1, incident: true)
        let initial = try #require(lines.last)
        let sequence = try #require(initial.components(separatedBy: " seq=").last?.split(separator: " ").first)
        diagnostic.beginLoad()
        for _ in 0..<150 { diagnostic.record(.loadCommand) }
        diagnostic.record(.recoveryEnd, origin: .mpv, outcome: .failure, failure: .noInstance, recovery: 1, incident: true)
        diagnostic.record(.failed, failure: .noInstance, incident: true)
        #expect(lines.contains { $0.hasPrefix("IPTV-DIAG anchor ") && $0.contains("event=endFile") && $0.contains("seq=\(sequence) ") })
        #expect(lines.contains { $0.hasPrefix("IPTV-DIAG snapshot ") && $0.contains("first_signal=\(sequence) ") && $0.contains("records=128") })
        #expect(lines.contains { $0.contains("event=failed") && $0.contains("role=secondary") })
        #expect(lines.contains { $0.contains("event=firstFrame") && $0.contains("since_first_frame=") })
    }

    @Test func nativeSignalsAreDeduplicatedPerAttempt() throws {
        var lines: [String] = []
        let diagnostic = IPTVPlaybackDiagnostics(enabled: { true }, sink: { lines.append($0) })
        let signal = try #require(IPTVPlaybackDiagnostics.classifyNative(prefix: "ffmpeg", level: "error", text: "HTTP error 503"))
        diagnostic.beginLoad()
        for _ in 0..<20 { diagnostic.native(signal, at: .now) }
        diagnostic.beginLoad()
        diagnostic.native(signal, at: .now)
        #expect(lines.filter { $0.contains("event=nativeHTTP ") }.count == 2)
    }

    @Test func frequentTransitionsAreThrottledWithoutThrottlingFailure() {
        var lines: [String] = []
        let diagnostic = IPTVPlaybackDiagnostics(enabled: { true }, sink: { lines.append($0) })
        let time = ContinuousClock.now
        for _ in 0..<100 { diagnostic.record(.bufferEmpty, at: time) }
        diagnostic.record(.bufferEmpty, at: time.advanced(by: .seconds(2)))
        #expect(lines.filter { $0.contains("event=bufferEmpty ") }.count == 2)
        diagnostic.record(.failed, incident: true)
        #expect(lines.contains { $0.hasPrefix("IPTV-DIAG snapshot ") })
    }

    @Test func firstSignalUsesCaptureTimeRatherThanActorDeliveryOrder() throws {
        var lines: [String] = []
        let diagnostic = IPTVPlaybackDiagnostics(enabled: { true }, sink: { lines.append($0) })
        let time = ContinuousClock.now
        diagnostic.record(.endFile, reason: .error, incident: true, at: time.advanced(by: .milliseconds(10)))
        diagnostic.record(.failed, incident: true, at: time.advanced(by: .milliseconds(20)))
        let timeout = try #require(IPTVPlaybackDiagnostics.classifyNative(prefix: "ffmpeg", level: "error", text: "Connection timed out"))
        diagnostic.native(timeout, at: time)
        #expect(lines.contains { $0.hasPrefix("IPTV-DIAG anchor ") && $0.contains("event=nativeTimeout") && $0.contains("role=initial") })
    }
}

private struct SecretDiagnosticError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
