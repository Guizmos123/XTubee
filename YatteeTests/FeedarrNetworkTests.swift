//
//  FeedarrNetworkTests.swift
//  YatteeTests
//
//  Simulated-network tests for Feedarr connection validation.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Network Tests", .serialized)
struct FeedarrNetworkTests {
    @Test("Validates HTTP and HTTPS open instances", arguments: ["http", "https"])
    func validatesOpenInstance(scheme: String) async throws {
        let transport = MockFeedarrTransport(handler: Self.success)
        let result = try await validator(transport).validate(serverURL: "\(scheme)://feedarr.invalid")
        #expect(result.serverURL.scheme == scheme)
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test("HTTPS Basic Auth is sent on both validated requests")
    func basicAuth() async throws {
        let transport = MockFeedarrTransport(handler: Self.success)
        _ = try await validator(transport).validate(
            serverURL: "https://feedarr.invalid",
            username: "alice",
            password: "secret"
        )
        let expected = "Basic " + Data("alice:secret".utf8).base64EncodedString()
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == expected })
    }

    @Test("HTTP Basic Auth is rejected before transport")
    func rejectsHTTPBasicAuth() async {
        let transport = MockFeedarrTransport(handler: Self.success)
        await #expect(throws: FeedarrConnectionValidationError.transport(.insecureBasicAuth)) {
            try await validator(transport).validate(
                serverURL: "http://feedarr.invalid",
                username: "alice",
                password: "secret"
            )
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Incomplete credentials are rejected before transport")
    func incompleteCredentials() async {
        let transport = MockFeedarrTransport(handler: Self.success)
        await #expect(throws: FeedarrConnectionValidationError.transport(.incompleteCredentials)) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid", username: "alice")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Health HTTP failures stop validation", arguments: [401, 403, 404, 503])
    func healthHTTPFailure(status: Int) async {
        let transport = MockFeedarrTransport { request in
            Self.response(request, status: status, body: Data())
        }
        let expected: FeedarrHTTPError = switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        default: .serviceUnavailable
        }
        await #expect(throws: FeedarrConnectionValidationError.transport(expected)) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
        #expect(transport.requests.count == 1)
    }

    @Test("Rate limiting preserves Retry-After")
    func rateLimited() async {
        let transport = MockFeedarrTransport { request in
            Self.response(request, status: 429, body: Data(), headers: ["Retry-After": "17"])
        }
        await #expect(throws: FeedarrConnectionValidationError.transport(.rateLimited(retryAfterSeconds: 17))) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
    }

    @Test("Health identity contract rejects down status")
    func healthDown() async {
        let transport = MockFeedarrTransport { request in
            Self.response(request, body: Data(#"{"status":"down"}"#.utf8))
        }
        await #expect(throws: FeedarrConnectionValidationError.incompatibleHealthContract) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
        #expect(transport.requests.count == 1)
    }

    @Test("Health rejects HTML and malformed JSON", arguments: ["<html></html>", "{"])
    func healthNonJSON(body: String) async {
        let transport = MockFeedarrTransport { request in
            Self.response(request, body: Data(body.utf8))
        }
        await #expect(throws: FeedarrConnectionValidationError.nonJSON) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
    }

    @Test("An empty release catalogue is valid")
    func emptyCatalogue() async throws {
        let transport = MockFeedarrTransport(handler: Self.success)
        _ = try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        #expect(transport.requests.last?.url?.query == "limit=1")
    }

    @Test("Invalid release contracts are rejected", arguments: [
        #"{"items":{},"pagination":{"limit":1,"hasMore":false,"nextCursor":null,"snapshotMaxId":0}}"#,
        #"{"items":[],"pagination":{"limit":"1","hasMore":false,"nextCursor":null,"snapshotMaxId":0}}"#,
        #"{"items":[],"pagination":{"limit":1,"hasMore":"false","nextCursor":null,"snapshotMaxId":0}}"#,
        #"{"items":[],"pagination":{"limit":1,"hasMore":false,"snapshotMaxId":0}}"#
    ])
    func invalidReleases(body: String) async {
        let transport = MockFeedarrTransport { request in
            if request.url?.path.hasSuffix("/health") == true { return try Self.health(request) }
            return Self.response(request, body: Data(body.utf8))
        }
        await #expect(throws: FeedarrConnectionValidationError.incompatibleReleasesContract) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
    }

    @Test("Transport errors retain their category", arguments: [
        (URLError.Code.timedOut, FeedarrHTTPError.timeout),
        (.cancelled, .cancelled),
        (.cannotConnectToHost, .networkUnavailable),
        (.serverCertificateUntrusted, .invalidTLS)
    ])
    func transportErrors(code: URLError.Code, expected: FeedarrHTTPError) async {
        let transport = MockFeedarrTransport { _ in throw URLError(code) }
        await #expect(throws: FeedarrConnectionValidationError.transport(expected)) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
    }

    @Test("A cancelled task stops before transport")
    func taskCancellation() async {
        let transport = MockFeedarrTransport(handler: Self.success)
        let task = Task {
            await Task.yield()
            return try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
        task.cancel()
        await #expect(throws: FeedarrConnectionValidationError.transport(.cancelled)) {
            try await task.value
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Oversized responses are rejected")
    func oversized() async {
        let transport = MockFeedarrTransport { request in
            Self.response(request, body: Data(repeating: 0x41, count: 9))
        }
        await #expect(throws: FeedarrConnectionValidationError.transport(.responseTooLarge(maximumBytes: 8))) {
            try await validator(transport, maximumBytes: 8).validate(serverURL: "https://feedarr.invalid")
        }
    }

    @Test("HTTP redirects are surfaced as forbidden")
    func redirectResponse() async {
        let transport = MockFeedarrTransport { request in
            Self.response(request, status: 302, body: Data(), headers: ["Location": "https://other.invalid"])
        }
        await #expect(throws: FeedarrConnectionValidationError.transport(.redirectForbidden)) {
            try await validator(transport).validate(serverURL: "https://feedarr.invalid")
        }
    }

    @Test("Redirect policy rejects other origins and HTTPS downgrade")
    func redirectPolicy() throws {
        let source = try #require(URL(string: "https://feedarr.invalid/health"))
        #expect(FeedarrRedirectPolicy.allowsRedirect(from: source, to: URL(string: "https://feedarr.invalid/base/health")!))
        #expect(!FeedarrRedirectPolicy.allowsRedirect(from: source, to: URL(string: "https://other.invalid/health")!))
        #expect(!FeedarrRedirectPolicy.allowsRedirect(from: source, to: URL(string: "http://feedarr.invalid/health")!))
    }

    @Test("Installation subpaths and existing query items are preserved")
    func preservesSubpath() async throws {
        let transport = MockFeedarrTransport(handler: Self.success)
        _ = try await validator(transport).validate(serverURL: "https://feedarr.invalid/apps/feedarr?tenant=home")
        #expect(transport.requests[0].url?.path == "/apps/feedarr/health")
        #expect(transport.requests[0].url?.query == "tenant=home")
        #expect(transport.requests[1].url?.path == "/apps/feedarr/api/feed/releases")
        #expect(transport.requests[1].url?.query?.contains("tenant=home") == true)
        #expect(transport.requests[1].url?.query?.contains("limit=1") == true)
    }

    @Test("Errors never expose credentials")
    func secretsAreRedacted() async {
        let transport = MockFeedarrTransport { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await validator(transport).validate(
                serverURL: "https://feedarr.invalid",
                username: "private-user",
                password: "private-password"
            )
            Issue.record("Expected failure")
        } catch {
            #expect(!error.localizedDescription.contains("private-user"))
            #expect(!error.localizedDescription.contains("private-password"))
            #expect(!String(reflecting: error).contains("private-password"))
        }
    }

    private func validator(
        _ transport: MockFeedarrTransport,
        maximumBytes: Int = 1_024
    ) -> FeedarrConnectionValidator {
        FeedarrConnectionValidator(transport: transport, maximumResponseSize: maximumBytes)
    }

    private static func success(_ request: URLRequest) throws -> (Data, URLResponse) {
        if request.url?.path.hasSuffix("/health") == true { return try health(request) }
        return response(
            request,
            body: Data(#"{"items":[],"pagination":{"limit":1,"hasMore":false,"nextCursor":null,"snapshotMaxId":0}}"#.utf8)
        )
    }

    private static func health(_ request: URLRequest) throws -> (Data, URLResponse) {
        response(request, body: Data(#"{"status":"up"}"#.utf8))
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: Data,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (body, response)
    }
}

private final class MockFeedarrTransport: FeedarrHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)
    private var storedRequests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { storedRequests.append(request) }
        return try handler(request)
    }
}
