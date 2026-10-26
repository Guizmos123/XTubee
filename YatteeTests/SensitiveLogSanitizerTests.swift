//
//  SensitiveLogSanitizerTests.swift
//  YatteeTests
//
//  Tests for redacting credentials before diagnostic logging.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Sensitive Log Sanitizer Tests")
struct SensitiveLogSanitizerTests {
    @Test("Redacts Xtream live URL credentials", arguments: ["ts", "m3u8"])
    func liveURL(extension streamExtension: String) {
        let input = "https://iptv.invalid/live/demo-user/demo-pass/123.\(streamExtension)"
        let output = SensitiveLogSanitizer.sanitize(input)

        #expect(output == "https://iptv.invalid/live/[REDACTED]/[REDACTED]/123.\(streamExtension)")
        #expect(!output.contains("demo-user"))
        #expect(!output.contains("demo-pass"))
    }

    @Test("Redacts Xtream API query credentials")
    func playerAPIQuery() {
        let input = "https://iptv.invalid/player_api.php?username=demo-user&password=demo-pass&action=get_live_streams"
        let output = SensitiveLogSanitizer.sanitize(input)

        #expect(output == "https://iptv.invalid/player_api.php?username=[REDACTED]&password=[REDACTED]&action=get_live_streams")
    }

    @Test("Preserves port, stream identity, and additional parameters")
    func portAndAdditionalParameters() {
        let input = "https://iptv.invalid:8443/live/demo-user/demo-pass/456.ts?token=fake-token&quality=hd"
        let output = SensitiveLogSanitizer.sanitize(input)

        #expect(output.contains("iptv.invalid:8443"))
        #expect(output.contains("/live/[REDACTED]/[REDACTED]/456.ts"))
        #expect(output.contains("quality=hd"))
        #expect(!output.contains("demo-user"))
        #expect(!output.contains("demo-pass"))
        #expect(!output.contains("fake-token"))
    }

    @Test("Redacts percent-encoded credentials")
    func encodedCredentials() {
        let input = "https://iptv.invalid/live/demo%40user/p%2Fass%3Fword/789.m3u8"
        let output = SensitiveLogSanitizer.sanitize(input)

        #expect(output == "https://iptv.invalid/live/[REDACTED]/[REDACTED]/789.m3u8")
        #expect(!output.contains("demo%40user"))
        #expect(!output.contains("p%2Fass%3Fword"))
    }

    @Test("Redacts a sensitive URL inside an MPV error")
    func mpvErrorMessage() {
        let input = "[ffmpeg/error] Failed to open https://iptv.invalid/live/demo-user/demo-pass/123.ts: HTTP 401"
        let output = SensitiveLogSanitizer.sanitize(input)

        #expect(output.contains("[ffmpeg/error] Failed to open https://iptv.invalid/live/[REDACTED]/[REDACTED]/123.ts: HTTP 401"))
    }

    @Test("Redacts a loadfile command")
    func loadfileCommand() {
        let input = "loadfile https://iptv.invalid/live/demo-user/demo-pass/123.ts replace"
        let output = SensitiveLogSanitizer.sanitize(input)

        #expect(output == "loadfile https://iptv.invalid/live/[REDACTED]/[REDACTED]/123.ts replace")
    }

    @Test("Leaves non-sensitive messages unchanged")
    func nonSensitiveMessage() {
        let input = "MPV stream loaded successfully"
        #expect(SensitiveLogSanitizer.sanitize(input) == input)
    }

    @Test("Sanitization is idempotent")
    func idempotence() {
        let input = "GET https://iptv.invalid:8443/player_api.php?password=demo-pass&username=demo-user&action=get_live_streams"
        let once = SensitiveLogSanitizer.sanitize(input)
        #expect(SensitiveLogSanitizer.sanitize(once) == once)
    }

    @Test("LoggingService stores only sanitized values")
    @MainActor
    func loggingServiceStorage() async throws {
        let service = LoggingService.shared
        let wasEnabled = service.isEnabled
        defer {
            service.clearLogs()
            service.isEnabled = wasEnabled
        }

        service.isEnabled = true
        service.clearLogs()
        service.info(
            "Opening https://iptv.invalid/live/demo-user/demo-pass/123.ts",
            details: "player_api.php?username=demo-user&password=demo-pass"
        )

        for _ in 0..<20 where service.entries.isEmpty {
            await Task.yield()
        }

        let entry = try #require(service.entries.first)
        #expect(!entry.message.contains("demo-user"))
        #expect(!entry.message.contains("demo-pass"))
        #expect(entry.details?.contains("demo-user") == false)
        #expect(entry.details?.contains("demo-pass") == false)
    }
}
