//
//  FeedarrConnectionValidator.swift
//  Yattee
//
//  Validates Feedarr identity and paginated feed compatibility.
//

import Foundation

enum FeedarrConnectionValidationError: Error, LocalizedError, Equatable, Sendable {
    case transport(FeedarrHTTPError)
    case nonJSON
    case incompatibleHealthContract
    case incompatibleReleasesContract

    var errorDescription: String? {
        switch self {
        case .transport(let error): return error.errorDescription
        case .nonJSON: return "The server did not return JSON."
        case .incompatibleHealthContract: return "The server is not a compatible Feedarr instance."
        case .incompatibleReleasesContract: return "The Feedarr releases API is incompatible."
        }
    }
}

struct FeedarrConnectionValidationResult: Equatable, Sendable {
    let serverURL: URL
}

struct FeedarrConnectionValidator: Sendable {
    private let transport: any FeedarrHTTPTransport
    private let timeout: TimeInterval
    private let maximumResponseSize: Int

    init(
        transport: any FeedarrHTTPTransport = URLSessionFeedarrTransport(),
        timeout: TimeInterval = FeedarrHTTPClient.defaultTimeout,
        maximumResponseSize: Int = FeedarrHTTPClient.defaultMaximumResponseSize
    ) {
        self.transport = transport
        self.timeout = timeout
        self.maximumResponseSize = maximumResponseSize
    }

    func validate(
        serverURL: String,
        username: String? = nil,
        password: String? = nil
    ) async throws -> FeedarrConnectionValidationResult {
        let client: FeedarrHTTPClient
        do {
            client = try FeedarrHTTPClient(
                serverURL: serverURL,
                username: username,
                password: password,
                transport: transport,
                timeout: timeout,
                maximumResponseSize: maximumResponseSize
            )
        } catch let error as FeedarrHTTPError {
            throw FeedarrConnectionValidationError.transport(error)
        }

        let health = try await request(client, path: ["health"])
        let healthJSON = try object(from: health)
        guard healthJSON["status"] as? String == "up" else {
            throw FeedarrConnectionValidationError.incompatibleHealthContract
        }

        let releases = try await request(
            client,
            path: ["api", "feed", "releases"],
            queryItems: [URLQueryItem(name: "limit", value: "1")]
        )
        let releasesJSON = try object(from: releases)
        guard releasesJSON["items"] is [Any],
              let pagination = releasesJSON["pagination"] as? [String: Any],
              pagination["limit"] is NSNumber,
              pagination["hasMore"] is Bool,
              pagination.keys.contains("nextCursor"),
              pagination["snapshotMaxId"] is NSNumber,
              isInteger(pagination["limit"]),
              isInteger(pagination["snapshotMaxId"]),
              pagination["nextCursor"] is NSNull || pagination["nextCursor"] is String else {
            throw FeedarrConnectionValidationError.incompatibleReleasesContract
        }
        return FeedarrConnectionValidationResult(serverURL: client.baseURL)
    }

    private func request(
        _ client: FeedarrHTTPClient,
        path: [String],
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        do {
            return try await client.get(pathComponents: path, queryItems: queryItems)
        } catch let error as FeedarrHTTPError {
            throw FeedarrConnectionValidationError.transport(error)
        }
    }

    private func object(from data: Data) throws -> [String: Any] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FeedarrConnectionValidationError.nonJSON
        }
        guard let object = json as? [String: Any] else {
            throw FeedarrConnectionValidationError.incompatibleReleasesContract
        }
        return object
    }

    private func isInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.rounded() == number.doubleValue
    }
}
