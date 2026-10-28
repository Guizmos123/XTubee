//
//  FeedarrAPIClient.swift
//  Yattee
//
//  Authenticated, bounded catalogue requests using the active Feedarr source.
//

import Foundation

/// Feedarr normalizes controller errors to ProblemDetails (title is the error code).
/// Raw server diagnostics are deliberately excluded from descriptions and debug output.
struct FeedarrAPIProblem: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let status: Int?
    let title: String?
    let detail: String?
    var description: String { "FeedarrAPIProblem(redacted)" }
    var debugDescription: String { description }
}

enum FeedarrAPIError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotConfigured
    case credentialsMissing
    case configurationUnavailable
    case credentialsUnavailable
    case transport(FeedarrHTTPError)
    case http(FeedarrHTTPError, problem: FeedarrAPIProblem?)
    case invalidJSON
    case cancelled
    case obsoleteResponse

    var errorDescription: String? {
        switch self {
        case .sourceNotConfigured: return "No Feedarr source is configured."
        case .credentialsMissing: return "The Feedarr credentials are missing."
        case .configurationUnavailable: return "The Feedarr configuration is unavailable."
        case .credentialsUnavailable: return "The Feedarr credential store is unavailable."
        case .transport(let error), .http(let error, _): return error.errorDescription
        case .invalidJSON: return "The Feedarr JSON response is invalid or incompatible."
        case .cancelled: return "The Feedarr request was cancelled."
        case .obsoleteResponse: return "The Feedarr configuration changed during the request."
        }
    }
}

@MainActor
final class FeedarrAPIClient {
    nonisolated static let maximumAPIResponseSize = 8 * 1_024 * 1_024

    private let sources: FeedarrSourcesManager
    private let credentialsStore: any FeedarrCredentialsStoring
    private let transport: any FeedarrHTTPTransport
    private let timeout: TimeInterval
    private let maximumResponseSize: Int

    init(
        sources: FeedarrSourcesManager,
        credentialsStore: (any FeedarrCredentialsStoring)? = nil,
        transport: any FeedarrHTTPTransport = URLSessionFeedarrTransport(),
        timeout: TimeInterval = FeedarrHTTPClient.defaultTimeout,
        maximumResponseSize: Int = maximumAPIResponseSize
    ) {
        precondition(timeout > 0 && timeout.isFinite && maximumResponseSize > 0)
        self.sources = sources
        self.credentialsStore = credentialsStore ?? FeedarrCredentialsStore()
        self.transport = transport
        self.timeout = timeout
        self.maximumResponseSize = maximumResponseSize
    }

    func top(
        hours: Int = 24, take: Int = 5, perCategoryTake: Int = 5,
        sort: FeedarrTopSort = .defaultSort
    ) async throws -> FeedarrTopResponse {
        try await request("top", queryItems: [
            URLQueryItem(name: "hours", value: String(hours)),
            URLQueryItem(name: "take", value: String(take)),
            URLQueryItem(name: "perCategoryTake", value: String(perCategoryTake)),
            URLQueryItem(name: "sort", value: sort.rawValue)
        ])
    }

    func releases(
        limit: Int = 50, sort: FeedarrReleasesSort = .defaultSort,
        q: String? = nil, unifiedCategory: String? = nil, cursor: String? = nil
    ) async throws -> FeedarrReleasesResponse {
        var items = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "sort", value: sort.rawValue)]
        if let q { items.append(URLQueryItem(name: "q", value: q)) }
        if let unifiedCategory { items.append(URLQueryItem(name: "unifiedCategory", value: unifiedCategory)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("releases", queryItems: items)
    }

    func trackerSources() async throws -> [FeedarrTracker] {
        try await request("sources", queryItems: [], pathPrefix: ["api"])
    }

    private func credentials(for source: FeedarrSource) throws -> FeedarrCredentials? {
        guard source.usesBasicAuth else { return nil }
        do {
            guard let credentials = try credentialsStore.credentials(for: source.id) else {
                throw FeedarrAPIError.credentialsMissing
            }
            return credentials
        } catch let error as FeedarrAPIError { throw error }
        catch { throw FeedarrAPIError.credentialsUnavailable }
    }

    private func request<Response: Decodable & Sendable>(
        _ endpoint: String, queryItems: [URLQueryItem], pathPrefix: [String] = ["api", "feed"]
    ) async throws -> Response {
        if Task.isCancelled { throw FeedarrAPIError.cancelled }
        guard let source = sources.source else { throw FeedarrAPIError.sourceNotConfigured }
        if let error = sources.loadError, error != .missingCredentials {
            throw FeedarrAPIError.configurationUnavailable
        }
        let credentials = try credentials(for: source)
        do {
            let http = try FeedarrHTTPClient(
                serverURL: source.serverURL.absoluteString,
                username: credentials?.username, password: credentials?.password,
                transport: transport, timeout: timeout, maximumResponseSize: maximumResponseSize
            )
            let (data, response) = try await http.getResponse(
                pathComponents: pathPrefix + [endpoint], queryItems: queryItems
            )
            if Task.isCancelled { throw FeedarrAPIError.cancelled }
            try validateActive(source: source, credentials: credentials)
            do { try http.validateStatus(response) }
            catch let error as FeedarrHTTPError {
                let problem = try? JSONDecoder().decode(FeedarrAPIProblem.self, from: data)
                throw FeedarrAPIError.http(error, problem: problem)
            }
            let result: Response = try await Self.decode(data)
            if Task.isCancelled { throw FeedarrAPIError.cancelled }
            try validateActive(source: source, credentials: credentials)
            return result
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? FeedarrHTTPError) == .cancelled {
                throw FeedarrAPIError.cancelled
            }
            try validateActive(source: source, credentials: credentials)
            if let error = error as? FeedarrAPIError { throw error }
            if let error = error as? FeedarrHTTPError { throw FeedarrAPIError.transport(error) }
            throw FeedarrAPIError.invalidJSON
        }
    }

    private func validateActive(source: FeedarrSource, credentials: FeedarrCredentials?) throws {
        guard let active = sources.source,
              active.id == source.id, active.serverURL == source.serverURL,
              active.usesBasicAuth == source.usesBasicAuth, sources.loadError == nil else {
            throw FeedarrAPIError.obsoleteResponse
        }
        guard (try? self.credentials(for: active)) == credentials else {
            throw FeedarrAPIError.obsoleteResponse
        }
    }

    private nonisolated static func decode<Response: Decodable & Sendable>(_ data: Data) async throws -> Response {
        try Task.checkCancellation()
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
