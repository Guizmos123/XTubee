//
//  XtreamHTTPClient.swift
//  Yattee
//
//  Security-scoped HTTP transport for ephemeral Xtream API requests.
//

import Foundation

enum XtreamClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidServerURL
    case serverURLNotAllowed
    case transportFailure
    case timeout
    case cancelled
    case invalidHTTPResponse
    case httpStatus(Int)
    case responseTooLarge(maximumBytes: Int)
    case invalidJSON
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The IPTV server URL is invalid."
        case .serverURLNotAllowed:
            return "The IPTV server URL is not allowed."
        case .transportFailure:
            return "The IPTV server could not be reached."
        case .timeout:
            return "The IPTV server request timed out."
        case .cancelled:
            return "The IPTV server request was cancelled."
        case .invalidHTTPResponse:
            return "The IPTV server returned an invalid response."
        case .httpStatus(let statusCode):
            return "The IPTV server returned HTTP status \(statusCode)."
        case .responseTooLarge(let maximumBytes):
            return "The IPTV server response exceeded the \(maximumBytes)-byte limit."
        case .invalidJSON:
            return "The IPTV server returned invalid JSON."
        case .decodingFailed:
            return "The IPTV server response could not be decoded."
        }
    }
}

actor XtreamHTTPClient {
    static let defaultTimeout: TimeInterval = 30
    static let defaultMaximumResponseSize = 32 * 1_024 * 1_024

    private let session: URLSession
    private let decoder: JSONDecoder
    private let timeout: TimeInterval
    private let maximumResponseSize: Int

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        decoder: JSONDecoder = JSONDecoder(),
        timeout: TimeInterval = defaultTimeout,
        maximumResponseSize: Int = defaultMaximumResponseSize
    ) {
        precondition(timeout > 0, "Xtream timeout must be positive")
        precondition(maximumResponseSize > 0, "Xtream response size limit must be positive")

        let redirectDelegate = XtreamRedirectDelegate()
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        self.decoder = decoder
        self.timeout = timeout
        self.maximumResponseSize = maximumResponseSize
    }

    /// Performs a generic Xtream request without retaining its credential-bearing URL.
    func request<Response: Decodable & Sendable>(
        serverURL: URL,
        username: String,
        password: String,
        action: String? = nil,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        try Task.checkCancellation()

        let requestURL = try XtreamServerURL.playerAPIURL(
            serverURL: serverURL,
            username: username,
            password: password,
            action: action
        )
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw XtreamClientError.invalidHTTPResponse
            }
            if httpResponse.expectedContentLength > Int64(maximumResponseSize) {
                throw XtreamClientError.responseTooLarge(maximumBytes: maximumResponseSize)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw XtreamClientError.httpStatus(httpResponse.statusCode)
            }

            var receivedData = Data()
            if httpResponse.expectedContentLength > 0 {
                receivedData.reserveCapacity(
                    min(Int(httpResponse.expectedContentLength), maximumResponseSize)
                )
            }
            for try await byte in bytes {
                guard receivedData.count < maximumResponseSize else {
                    throw XtreamClientError.responseTooLarge(maximumBytes: maximumResponseSize)
                }
                receivedData.append(byte)
            }
            data = receivedData
        } catch let error as XtreamClientError {
            throw error
        } catch is CancellationError {
            throw XtreamClientError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw XtreamClientError.timeout
            case .cancelled:
                throw XtreamClientError.cancelled
            default:
                throw XtreamClientError.transportFailure
            }
        } catch {
            throw XtreamClientError.transportFailure
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw XtreamClientError.invalidJSON
        }

        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw XtreamClientError.decodingFailed
        }
    }
}

final class XtreamRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sourceURL = response.url,
              let destinationURL = request.url,
              XtreamRedirectPolicy.allowsRedirect(from: sourceURL, to: destinationURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
