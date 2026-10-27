//
//  XtreamServerURL.swift
//  Yattee
//
//  Validates Xtream server addresses and builds ephemeral API request URLs.
//

import Foundation

enum XtreamServerURL {
    /// Normalizes an HTTP(S) server URL while preserving its base path and query.
    ///
    /// Rejected inputs include unsupported schemes, missing hosts, invalid ports,
    /// URL userinfo, pre-existing username/password query items, and fragments.
    static func normalize(_ value: String) throws -> URL {
        guard !value.isEmpty,
              let parsed = URLComponents(string: value),
              let rawScheme = parsed.scheme,
              let host = parsed.host,
              !host.isEmpty else {
            throw XtreamClientError.invalidServerURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw XtreamClientError.serverURLNotAllowed
        }
        guard parsed.user == nil, parsed.password == nil else {
            throw XtreamClientError.serverURLNotAllowed
        }
        if let port = parsed.port, !(1...65_535).contains(port) {
            throw XtreamClientError.invalidServerURL
        }
        guard parsed.fragment == nil else {
            throw XtreamClientError.serverURLNotAllowed
        }
        guard !(parsed.queryItems ?? []).contains(where: {
            $0.name.caseInsensitiveCompare("username") == .orderedSame
                || $0.name.caseInsensitiveCompare("password") == .orderedSame
        }) else {
            throw XtreamClientError.serverURLNotAllowed
        }

        var normalized = parsed
        normalized.scheme = scheme
        guard let url = normalized.url, url.host != nil else {
            throw XtreamClientError.invalidServerURL
        }
        return url
    }

    /// Builds an ephemeral `player_api.php` URL. Callers must not persist the result.
    static func playerAPIURL(
        serverURL: URL,
        username: String,
        password: String,
        action: String? = nil
    ) throws -> URL {
        let validatedServerURL = try normalize(serverURL.absoluteString)
        guard var components = URLComponents(url: validatedServerURL, resolvingAgainstBaseURL: false) else {
            throw XtreamClientError.invalidServerURL
        }

        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/player_api.php"
        } else if components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "player_api.php"
        } else {
            components.percentEncodedPath += "/player_api.php"
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "username", value: username))
        queryItems.append(URLQueryItem(name: "password", value: password))
        if let action {
            queryItems.append(URLQueryItem(name: "action", value: action))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw XtreamClientError.invalidServerURL
        }
        return url
    }

    /// Builds an ephemeral XMLTV URL. Callers must not persist or log the result.
    static func xmlTVURL(
        serverURL: URL,
        username: String,
        password: String
    ) throws -> URL {
        let validatedServerURL = try normalize(serverURL.absoluteString)
        guard var components = URLComponents(
            url: validatedServerURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw XtreamClientError.invalidServerURL
        }

        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/xmltv.php"
        } else if components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "xmltv.php"
        } else {
            components.percentEncodedPath += "/xmltv.php"
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "username", value: username))
        queryItems.append(URLQueryItem(name: "password", value: password))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw XtreamClientError.invalidServerURL
        }
        return url
    }
}

enum XtreamRedirectPolicy {
    /// Credentials may only follow redirects that remain on the exact same origin.
    static func allowsRedirect(from sourceURL: URL, to destinationURL: URL) -> Bool {
        guard sourceURL.user == nil, sourceURL.password == nil,
              destinationURL.user == nil, destinationURL.password == nil,
              let sourceScheme = sourceURL.scheme?.lowercased(),
              let destinationScheme = destinationURL.scheme?.lowercased(),
              let sourceHost = sourceURL.host?.lowercased(),
              let destinationHost = destinationURL.host?.lowercased() else {
            return false
        }

        return sourceScheme == destinationScheme
            && sourceHost == destinationHost
            && effectivePort(for: sourceURL) == effectivePort(for: destinationURL)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
