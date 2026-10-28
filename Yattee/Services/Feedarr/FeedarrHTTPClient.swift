//
//  FeedarrHTTPClient.swift
//  Yattee
//
//  Security-scoped HTTP transport for Feedarr connection validation.
//

import Foundation

enum FeedarrHTTPError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case incompleteCredentials
    case insecureBasicAuth
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfterSeconds: Int?)
    case serviceUnavailable
    case httpStatus(Int)
    case timeout
    case cancelled
    case networkUnavailable
    case invalidTLS
    case invalidHTTPResponse
    case responseTooLarge(maximumBytes: Int)
    case redirectForbidden

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The Feedarr server URL is invalid."
        case .incompleteCredentials: return "Feedarr Basic Auth requires both a username and a password."
        case .insecureBasicAuth: return "Feedarr Basic Auth requires HTTPS."
        case .unauthorized: return "The Feedarr credentials were rejected."
        case .forbidden: return "The Feedarr server refused access."
        case .notFound: return "The Feedarr endpoint was not found."
        case .rateLimited(let seconds):
            return seconds.map { "Too many requests. Try again in \($0) seconds." } ?? "Too many requests."
        case .serviceUnavailable: return "The Feedarr service is unavailable."
        case .httpStatus(let code): return "The Feedarr server returned HTTP status \(code)."
        case .timeout: return "The Feedarr request timed out."
        case .cancelled: return "The Feedarr request was cancelled."
        case .networkUnavailable: return "The Feedarr server could not be reached."
        case .invalidTLS: return "The Feedarr server certificate is invalid."
        case .invalidHTTPResponse: return "The Feedarr server returned an invalid response."
        case .responseTooLarge(let maximumBytes): return "The Feedarr response exceeded the \(maximumBytes)-byte limit."
        case .redirectForbidden: return "The Feedarr server attempted an unsafe redirect."
        }
    }
}

protocol FeedarrHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest, maximumResponseSize: Int) async throws -> (Data, URLResponse)
}

extension FeedarrHTTPTransport {
    func data(for request: URLRequest, maximumResponseSize: Int) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        guard result.0.count <= maximumResponseSize else {
            throw FeedarrHTTPError.responseTooLarge(maximumBytes: maximumResponseSize)
        }
        return result
    }
}

final class URLSessionFeedarrTransport: FeedarrHTTPTransport, Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.urlCredentialStorage = nil
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCache = nil
        session = URLSession(configuration: isolated, delegate: FeedarrSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, maximumResponseSize: FeedarrHTTPClient.defaultMaximumResponseSize)
    }

    func data(for request: URLRequest, maximumResponseSize: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(maximumResponseSize) else {
            throw FeedarrHTTPError.responseTooLarge(maximumBytes: maximumResponseSize)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseSize else {
                throw FeedarrHTTPError.responseTooLarge(maximumBytes: maximumResponseSize)
            }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class FeedarrSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = response.url,
              let destination = request.url,
              FeedarrRedirectPolicy.allowsRedirect(from: source, to: destination) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if source.origin != destination.origin {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}

enum FeedarrRedirectPolicy {
    static func allowsRedirect(from source: URL, to destination: URL) -> Bool {
        guard source.origin == destination.origin else { return false }
        return !(source.scheme?.lowercased() == "https" && destination.scheme?.lowercased() == "http")
    }
}

struct FeedarrHTTPClient: Sendable {
    static let defaultTimeout: TimeInterval = 15
    static let defaultMaximumResponseSize = 1_024 * 1_024

    let baseURL: URL
    private let credentials: FeedarrCredentials?
    private let transport: any FeedarrHTTPTransport
    private let timeout: TimeInterval
    private let maximumResponseSize: Int

    init(
        serverURL: String,
        username: String? = nil,
        password: String? = nil,
        transport: any FeedarrHTTPTransport = URLSessionFeedarrTransport(),
        timeout: TimeInterval = defaultTimeout,
        maximumResponseSize: Int = defaultMaximumResponseSize
    ) throws {
        do {
            baseURL = try FeedarrServerURL.normalize(serverURL)
        } catch {
            throw FeedarrHTTPError.invalidURL
        }
        switch (username, password) {
        case (nil, nil): credentials = nil
        case let (username?, password?):
            do {
                credentials = try FeedarrCredentials(username: username, password: password)
            } catch {
                throw FeedarrHTTPError.incompleteCredentials
            }
        default: throw FeedarrHTTPError.incompleteCredentials
        }
        if credentials != nil, baseURL.scheme != "https" {
            throw FeedarrHTTPError.insecureBasicAuth
        }
        precondition(timeout > 0)
        precondition(maximumResponseSize > 0)
        self.transport = transport
        self.timeout = timeout
        self.maximumResponseSize = maximumResponseSize
    }

    func get(pathComponents: [String], queryItems: [URLQueryItem] = []) async throws -> Data {
        let (data, response) = try await getResponse(pathComponents: pathComponents, queryItems: queryItems)
        try validateStatus(response)
        return data
    }

    /// Bounded response access for catalogue ProblemDetails; authentication stays centralized here.
    func getResponse(pathComponents: [String], queryItems: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        try await response(pathComponents: pathComponents, queryItems: queryItems, downloading: false)
    }

    func downloadResponse(pathComponents: [String]) async throws -> (Data, HTTPURLResponse) {
        try await response(pathComponents: pathComponents, queryItems: [], downloading: true)
    }

    private func response(pathComponents: [String], queryItems: [URLQueryItem], downloading: Bool) async throws -> (Data, HTTPURLResponse) {
        if Task.isCancelled { throw FeedarrHTTPError.cancelled }
        let url = try endpointURL(pathComponents: pathComponents, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(downloading ? "application/x-bittorrent, application/octet-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let credentials {
            let value = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await transport.data(for: request, maximumResponseSize: maximumResponseSize)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw FeedarrHTTPError.invalidHTTPResponse
            }
            // The session refuses non-HTTP redirects. Only expose a magnet to the download caller.
            let magnet = downloading && response.statusCode == 302 &&
                response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))?.scheme?.lowercased() == "magnet"
            if ((300...399).contains(response.statusCode) && !magnet) || response.url?.origin != url.origin {
                throw FeedarrHTTPError.redirectForbidden
            }
            guard data.count <= maximumResponseSize else {
                throw FeedarrHTTPError.responseTooLarge(maximumBytes: maximumResponseSize)
            }
            return (data, response)
        } catch let error as FeedarrHTTPError {
            throw error
        } catch is CancellationError {
            throw FeedarrHTTPError.cancelled
        } catch let error as URLError {
            throw map(error)
        } catch {
            throw FeedarrHTTPError.networkUnavailable
        }
    }

    func endpointURL(pathComponents: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FeedarrHTTPError.invalidURL
        }
        let basePath = components.percentEncodedPath.split(separator: "/").map(String.init)
        let encoded = pathComponents.map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0
        }
        components.percentEncodedPath = "/" + (basePath + encoded).joined(separator: "/")
        components.queryItems = (components.queryItems ?? []) + queryItems
        guard let url = components.url else { throw FeedarrHTTPError.invalidURL }
        return url
    }

    func validateStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200: return
        case 401: throw FeedarrHTTPError.unauthorized
        case 403: throw FeedarrHTTPError.forbidden
        case 404: throw FeedarrHTTPError.notFound
        case 429:
            throw FeedarrHTTPError.rateLimited(
                retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            )
        case 503: throw FeedarrHTTPError.serviceUnavailable
        default: throw FeedarrHTTPError.httpStatus(response.statusCode)
        }
    }

    private func map(_ error: URLError) -> FeedarrHTTPError {
        switch error.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        case .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired,
             .secureConnectionFailed: return .invalidTLS
        default: return .networkUnavailable
        }
    }
}

private extension URL {
    var origin: String? {
        guard let scheme = scheme?.lowercased(), let host = host?.lowercased() else { return nil }
        let effectivePort = port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(effectivePort)"
    }
}
