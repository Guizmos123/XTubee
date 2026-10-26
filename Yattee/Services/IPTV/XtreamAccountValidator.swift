//
//  XtreamAccountValidator.swift
//  Yattee
//
//  Validates Xtream account state without retaining credentials.
//

import Foundation

struct XtreamValidatedAccount: Hashable, Sendable {
    let status: String
    let expirationDate: Date?
    let activeConnections: Int?
    let maxConnections: Int?
    let allowedOutputFormats: [String]?
}

enum XtreamAccountValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidServerURL
    case serverURLNotAllowed
    case authenticationRefused
    case accountDisabled
    case accountSuspended
    case accountExpired
    case accountInactive
    case invalidJSONResponse
    case incompleteResponse
    case serverUnavailable
    case timeout
    case httpError(Int)
    case cancelled
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The IPTV server URL is invalid."
        case .serverURLNotAllowed:
            return "The IPTV server URL is not allowed."
        case .authenticationRefused:
            return "The IPTV server rejected the credentials."
        case .accountDisabled:
            return "The IPTV account is disabled."
        case .accountSuspended:
            return "The IPTV account is suspended."
        case .accountExpired:
            return "The IPTV account has expired."
        case .accountInactive:
            return "The IPTV account is not active."
        case .invalidJSONResponse:
            return "The IPTV server returned invalid JSON."
        case .incompleteResponse:
            return "The IPTV server returned an incomplete account response."
        case .serverUnavailable:
            return "The IPTV server is unavailable."
        case .timeout:
            return "The IPTV server request timed out."
        case .httpError(let statusCode):
            return "The IPTV server returned HTTP status \(statusCode)."
        case .cancelled:
            return "The IPTV account validation was cancelled."
        case .responseTooLarge:
            return "The IPTV server response is too large."
        }
    }
}

struct XtreamAccountValidator: Sendable {
    private let client: XtreamHTTPClient
    private let currentDate: @Sendable () -> Date

    init(
        client: XtreamHTTPClient = XtreamHTTPClient(),
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.currentDate = currentDate
    }

    /// Validates credentials in memory and returns non-sensitive account metadata.
    func validate(
        serverURL: URL,
        username: String,
        password: String
    ) async throws -> XtreamValidatedAccount {
        let response: XtreamAccountResponse
        do {
            response = try await client.request(
                serverURL: serverURL,
                username: username,
                password: password,
                action: nil
            )
        } catch let error as XtreamClientError {
            throw mapClientError(error)
        } catch is CancellationError {
            throw XtreamAccountValidationError.cancelled
        } catch {
            throw XtreamAccountValidationError.serverUnavailable
        }

        guard let isAuthenticated = response.userInfo.isAuthenticated,
              let rawStatus = response.userInfo.status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawStatus.isEmpty else {
            throw XtreamAccountValidationError.incompleteResponse
        }
        guard isAuthenticated else {
            throw XtreamAccountValidationError.authenticationRefused
        }

        switch rawStatus.lowercased() {
        case "disabled":
            throw XtreamAccountValidationError.accountDisabled
        case "suspended", "banned":
            throw XtreamAccountValidationError.accountSuspended
        case "expired":
            throw XtreamAccountValidationError.accountExpired
        case "active":
            break
        default:
            throw XtreamAccountValidationError.accountInactive
        }

        if let expirationDate = response.userInfo.expirationDate,
           expirationDate <= currentDate() {
            throw XtreamAccountValidationError.accountExpired
        }

        return XtreamValidatedAccount(
            status: rawStatus,
            expirationDate: response.userInfo.expirationDate,
            activeConnections: response.userInfo.activeConnections,
            maxConnections: response.userInfo.maxConnections,
            allowedOutputFormats: response.userInfo.allowedOutputFormats
        )
    }

    private func mapClientError(_ error: XtreamClientError) -> XtreamAccountValidationError {
        switch error {
        case .invalidServerURL:
            return .invalidServerURL
        case .serverURLNotAllowed:
            return .serverURLNotAllowed
        case .transportFailure, .invalidHTTPResponse:
            return .serverUnavailable
        case .timeout:
            return .timeout
        case .cancelled:
            return .cancelled
        case .httpStatus(let statusCode):
            return .httpError(statusCode)
        case .responseTooLarge:
            return .responseTooLarge
        case .invalidJSON:
            return .invalidJSONResponse
        case .decodingFailed:
            return .incompleteResponse
        }
    }
}
