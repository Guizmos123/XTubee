//
//  XtreamHTTPClientTests.swift
//  YatteeTests
//
//  Tests for Xtream URL normalization and isolated HTTP transport.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Xtream Server URL Tests")
struct XtreamServerURLTests {
    @Test("Accepts HTTP server URL")
    func validHTTP() throws {
        #expect(try XtreamServerURL.normalize("http://server.invalid").absoluteString == "http://server.invalid")
    }

    @Test("Accepts HTTPS server URL with port")
    func validHTTPSPort() throws {
        #expect(try XtreamServerURL.normalize("https://server.invalid:8443").port == 8443)
    }

    @Test("Preserves base path and trailing slash")
    func preservesBasePath() throws {
        let serverURL = try XtreamServerURL.normalize("https://server.invalid/iptv/base/")
        let requestURL = try XtreamServerURL.playerAPIURL(
            serverURL: serverURL,
            username: "demo",
            password: "secret"
        )
        #expect(serverURL.path == "/iptv/base/")
        #expect(requestURL.path == "/iptv/base/player_api.php")
    }

    @Test("Rejects malformed URLs, missing hosts, invalid ports, and fragments", arguments: [
        "server.invalid",
        "https:///missing-host",
        "https://server.invalid:70000",
        "ftp://server.invalid",
        "https://server.invalid/#fragment"
    ])
    func rejectsInvalidServerURLs(value: String) {
        #expect(throws: XtreamClientError.self) {
            try XtreamServerURL.normalize(value)
        }
    }

    @Test("Rejects URL userinfo")
    func rejectsUserInfo() {
        #expect(throws: XtreamClientError.serverURLNotAllowed) {
            try XtreamServerURL.normalize("https://demo:secret@server.invalid")
        }
    }

    @Test("Rejects pre-existing authentication query items", arguments: ["username", "PASSWORD"])
    func rejectsAuthenticationQueryItems(name: String) {
        #expect(throws: XtreamClientError.serverURLNotAllowed) {
            try XtreamServerURL.normalize("https://server.invalid/base?\(name)=secret")
        }
    }

    @Test("Encodes reserved characters in credentials")
    func encodesCredentials() throws {
        let serverURL = try XtreamServerURL.normalize("https://server.invalid")
        let requestURL = try XtreamServerURL.playerAPIURL(
            serverURL: serverURL,
            username: "demo+user@example.invalid",
            password: "p&ss=word?"
        )
        let items = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems

        #expect(items?.first(where: { $0.name == "username" })?.value == "demo+user@example.invalid")
        #expect(items?.first(where: { $0.name == "password" })?.value == "p&ss=word?")
        #expect(requestURL.absoluteString.contains("p%26ss%3Dword?") || requestURL.absoluteString.contains("p%26ss%3Dword%3F"))
    }

    @Test("Builds player_api.php with optional action")
    func buildsPlayerAPIURL() throws {
        let rootServerURL = try XtreamServerURL.normalize("https://server.invalid")
        let rootRequestURL = try XtreamServerURL.playerAPIURL(
            serverURL: rootServerURL,
            username: "user",
            password: "pass"
        )
        let serverURL = try XtreamServerURL.normalize("https://server.invalid/base?tenant=demo")
        let requestURL = try XtreamServerURL.playerAPIURL(
            serverURL: serverURL,
            username: "user",
            password: "pass",
            action: "get_live_streams"
        )
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))

        #expect(rootRequestURL.path == "/player_api.php")
        #expect(components.path == "/base/player_api.php")
        #expect(components.queryItems?.map(\.name) == ["tenant", "username", "password", "action"])
    }

    @Test("Allows only same-origin redirects")
    func redirectPolicy() throws {
        let source = try #require(URL(string: "https://server.invalid/player_api.php?username=user&password=pass"))
        let sameOrigin = try #require(URL(string: "https://server.invalid/base/player_api.php"))
        let otherHost = try #require(URL(string: "https://other.invalid/player_api.php?username=user&password=pass"))
        let downgrade = try #require(URL(string: "http://server.invalid/player_api.php"))

        #expect(XtreamRedirectPolicy.allowsRedirect(from: source, to: sameOrigin))
        #expect(!XtreamRedirectPolicy.allowsRedirect(from: source, to: otherHost))
        #expect(!XtreamRedirectPolicy.allowsRedirect(from: source, to: downgrade))
    }
}

@Suite("Xtream HTTP Client Tests", .serialized)
struct XtreamHTTPClientTests {
    private struct Response: Decodable, Sendable {
        let value: String
    }

    @Test("Decodes a successful JSON response")
    func successfulResponse() async throws {
        let client = makeClient { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(#"{"value":"ok"}"#.utf8))
        }

        let response: Response = try await client.request(
            serverURL: URL(string: "https://server.invalid")!,
            username: "demo-user",
            password: "demo-pass"
        )
        #expect(response.value == "ok")
    }

    @Test("Maps HTTP error status", arguments: [401, 403, 404])
    func HTTPStatus(statusCode: Int) async throws {
        let client = makeClient { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }

        await #expect(throws: XtreamClientError.httpStatus(statusCode)) {
            let _: Response = try await client.request(
                serverURL: URL(string: "https://server.invalid")!,
                username: "demo-user",
                password: "demo-pass"
            )
        }
    }

    @Test("Maps timeout and cancellation", arguments: [URLError.Code.timedOut, .cancelled])
    func transportErrors(code: URLError.Code) async {
        let client = makeClient { _ in throw URLError(code) }
        let expected: XtreamClientError = code == .timedOut ? .timeout : .cancelled

        await #expect(throws: expected) {
            let _: Response = try await client.request(
                serverURL: URL(string: "https://server.invalid")!,
                username: "demo-user",
                password: "demo-pass"
            )
        }
    }

    @Test("Rejects responses above the configured size")
    func responseSizeLimit() async {
        let client = makeClient(maximumResponseSize: 8) { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data(repeating: 0x41, count: 9))
        }

        await #expect(throws: XtreamClientError.responseTooLarge(maximumBytes: 8)) {
            let _: Response = try await client.request(
                serverURL: URL(string: "https://server.invalid")!,
                username: "demo-user",
                password: "demo-pass"
            )
        }
    }

    @Test("Errors never expose credentials")
    func errorsDoNotExposeCredentials() async {
        let client = makeClient { _ in throw URLError(.cannotConnectToHost) }

        do {
            let _: Response = try await client.request(
                serverURL: URL(string: "https://server.invalid")!,
                username: "fictional-user",
                password: "fictional-password"
            )
            Issue.record("Expected request to fail")
        } catch {
            #expect(!error.localizedDescription.contains("fictional-user"))
            #expect(!error.localizedDescription.contains("fictional-password"))
            #expect(!String(reflecting: error).contains("fictional-user"))
            #expect(!String(reflecting: error).contains("fictional-password"))
        }
    }

    private func makeClient(
        maximumResponseSize: Int = 1_024,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> XtreamHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XtreamMockURLProtocol.self]
        XtreamMockURLProtocol.setHandler(handler)
        return XtreamHTTPClient(
            configuration: configuration,
            maximumResponseSize: maximumResponseSize
        )
    }
}

private final class XtreamMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock {
            requestHandler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.requestHandler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
