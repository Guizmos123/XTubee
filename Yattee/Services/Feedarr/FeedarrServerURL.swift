//
//  FeedarrServerURL.swift
//  Yattee
//
//  Validates and normalizes Feedarr server base URLs.
//

import Foundation

enum FeedarrServerURLError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case embeddedCredentials
    case fragmentNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Feedarr server URL is invalid."
        case .unsupportedScheme:
            return "The Feedarr server URL must use HTTP or HTTPS."
        case .embeddedCredentials:
            return "Credentials must not be embedded in the Feedarr server URL."
        case .fragmentNotAllowed:
            return "The Feedarr server URL must not contain a fragment."
        }
    }
}

enum FeedarrServerURL {
    static func normalize(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: trimmed),
              let rawScheme = components.scheme,
              let host = components.host,
              !host.isEmpty else {
            throw FeedarrServerURLError.invalidURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw FeedarrServerURLError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw FeedarrServerURLError.embeddedCredentials
        }
        guard !(components.queryItems ?? []).contains(where: {
            $0.name.caseInsensitiveCompare("username") == .orderedSame
                || $0.name.caseInsensitiveCompare("password") == .orderedSame
        }) else {
            throw FeedarrServerURLError.embeddedCredentials
        }
        guard components.fragment == nil else {
            throw FeedarrServerURLError.fragmentNotAllowed
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw FeedarrServerURLError.invalidURL
        }

        components.scheme = scheme
        while components.percentEncodedPath.count > 1,
              components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }

        guard let normalizedURL = components.url,
              normalizedURL.host != nil else {
            throw FeedarrServerURLError.invalidURL
        }
        return normalizedURL
    }
}
