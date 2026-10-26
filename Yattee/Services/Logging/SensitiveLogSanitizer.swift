//
//  SensitiveLogSanitizer.swift
//  Yattee
//
//  Redacts credentials from diagnostic text without changing network requests.
//

import Foundation

/// Sanitizes text before it reaches console, in-memory, or exported logs.
enum SensitiveLogSanitizer {
    private static let redacted = "[REDACTED]"

    /// Returns a deterministic, idempotent representation safe for diagnostics.
    static func sanitize(_ text: String) -> String {
        var result = text

        // Xtream live URLs embed credentials in the two path components after `/live/`.
        // Keep the host, stream identifier, extension, query, and fragment for diagnosis.
        result = result.replacingOccurrences(
            of: #"(?i)(/live/)[^/?#\s]+/[^/?#\s]+/([^/?#\s]+)"#,
            with: "$1\(redacted)/\(redacted)/$2",
            options: .regularExpression
        )

        // Xtream API requests carry credentials as query parameters. Match them in any
        // order and preserve all unrelated parameters.
        result = result.replacingOccurrences(
            of: #"(?i)([?&](?:username|password)=)[^&#\s]*"#,
            with: "$1\(redacted)",
            options: .regularExpression
        )

        // Preserve the export server's existing generic protections at the common
        // logging entry point so secrets are never retained in memory first.
        let genericRedactions = [
            (#"(?i)(\b(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key)\s*:\s*)[^\r\n]+"#, "$1\(redacted)"),
            (#"(?i)(\"(?:password|passwd|access_token|refresh_token|api_key|apikey|client_secret|token)\"\s*:\s*\")[^\"]*(\")"#, "$1\(redacted)$2"),
            (#"(?i)(\b(?:password|passwd|access_token|refresh_token|api_key|apikey|client_secret|token)\s*=\s*)[^&\s,;]+"#, "$1\(redacted)"),
            (#"(?i)(://[^:/\s]+:)[^@/\s]+(@)"#, "$1\(redacted)$2")
        ]

        for (pattern, replacement) in genericRedactions {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        return result
    }
}
