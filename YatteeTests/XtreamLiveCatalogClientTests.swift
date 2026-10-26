//
//  XtreamLiveCatalogClientTests.swift
//  YatteeTests
//
//  Tests for fetching Xtream live categories and streams.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Xtream Live Catalog Client Tests", .serialized)
struct XtreamLiveCatalogClientTests {
    @Test("Fetches categories in server order with flexible identifiers")
    func fetchCategories() async throws {
        let (catalog, actions) = makeCatalog { request in
            try response(for: request, json: #"""
            [
              {"category_id": 20, "category_name": "Second", "parent_id": "0"},
              {"category_id": "first", "category_name": "First", "unknown": true}
            ]
            """#)
        }

        let categories = try await fetchCategories(with: catalog)

        #expect(categories.map(\.categoryID) == ["20", "first"])
        #expect(categories.map(\.name) == ["Second", "First"])
        #expect(actions.values == ["get_live_categories"])
    }

    @Test("Fetches streams in server order including streams without categories")
    func fetchStreams() async throws {
        let (catalog, actions) = makeCatalog { request in
            try response(for: request, json: #"""
            [
              {"stream_id": "channel-b", "name": "Channel B", "category_id": null},
              {"stream_id": 101, "name": "Channel A", "category_id": 20, "extra": "ignored"}
            ]
            """#)
        }

        let streams = try await fetchStreams(with: catalog)

        #expect(streams.map(\.streamID) == ["channel-b", "101"])
        #expect(streams[0].categoryID == nil)
        #expect(streams[1].categoryID == "20")
        #expect(actions.values == ["get_live_streams"])
    }

    @Test("Accepts empty category and stream arrays independently")
    func emptyArrays() async throws {
        let (catalog, actions) = makeCatalog { request in
            try response(for: request, json: "[]")
        }

        let categories = try await fetchCategories(with: catalog)
        let streams = try await fetchStreams(with: catalog)

        #expect(categories.isEmpty)
        #expect(streams.isEmpty)
        #expect(actions.values == ["get_live_categories", "get_live_streams"])
    }

    @Test("Rejects malformed JSON")
    func invalidJSON() async {
        let (catalog, _) = makeCatalog { request in
            try response(for: request, json: "not-json")
        }

        await #expect(throws: XtreamClientError.invalidJSON) {
            _ = try await fetchCategories(with: catalog)
        }
    }

    @Test("Rejects objects in place of arrays")
    func objectInsteadOfArray() async {
        let (catalog, _) = makeCatalog { request in
            try response(for: request, json: #"{"category_id":"1","category_name":"Wrong root"}"#)
        }

        await #expect(throws: XtreamClientError.decodingFailed) {
            _ = try await fetchCategories(with: catalog)
        }
    }

    @Test("Rejects the complete response when one required element is invalid")
    func invalidRequiredElement() async {
        let (catalog, _) = makeCatalog { request in
            try response(for: request, json: #"""
            [
              {"stream_id":"1","name":"Valid"},
              {"stream_id":"2"}
            ]
            """#)
        }

        await #expect(throws: XtreamClientError.decodingFailed) {
            _ = try await fetchStreams(with: catalog)
        }
    }

    @Test("Propagates HTTP and transport errors")
    func HTTPAndTransportErrors() async {
        let (httpCatalog, _) = makeCatalog { request in
            try response(for: request, statusCode: 503, json: "{}")
        }
        await #expect(throws: XtreamClientError.httpStatus(503)) {
            _ = try await fetchCategories(with: httpCatalog)
        }

        let (transportCatalog, _) = makeCatalog { _ in
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: XtreamClientError.transportFailure) {
            _ = try await fetchStreams(with: transportCatalog)
        }
    }

    @Test("Propagates cancellation")
    func cancellation() async {
        let (catalog, _) = makeCatalog { _ in throw URLError(.cancelled) }

        await #expect(throws: XtreamClientError.cancelled) {
            _ = try await fetchStreams(with: catalog)
        }
    }

    @Test("Credentials are absent from results, errors, and application logs")
    @MainActor
    func credentialsDoNotLeak() async throws {
        let logging = LoggingService.shared
        let wasEnabled = logging.isEnabled
        defer {
            logging.clearLogs()
            logging.isEnabled = wasEnabled
        }
        logging.isEnabled = true
        logging.clearLogs()

        let (successfulCatalog, _) = makeCatalog { request in
            try response(for: request, json: #"[{"category_id":"1","category_name":"Demo"}]"#)
        }
        let categories = try await fetchCategories(with: successfulCatalog)
        #expect(!String(reflecting: categories).contains("fictional-user"))
        #expect(!String(reflecting: categories).contains("fictional-password"))

        let (failingCatalog, _) = makeCatalog { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await fetchStreams(with: failingCatalog)
            Issue.record("Expected request to fail")
        } catch {
            #expect(!error.localizedDescription.contains("fictional-user"))
            #expect(!error.localizedDescription.contains("fictional-password"))
            #expect(!String(reflecting: error).contains("fictional-user"))
            #expect(!String(reflecting: error).contains("fictional-password"))
        }

        #expect(logging.entries.allSatisfy {
            !$0.message.contains("fictional-user")
                && !$0.message.contains("fictional-password")
                && !($0.details?.contains("fictional-user") ?? false)
                && !($0.details?.contains("fictional-password") ?? false)
        })
    }

    private func fetchCategories(
        with catalog: XtreamLiveCatalogClient
    ) async throws -> [XtreamLiveCategory] {
        try await catalog.fetchCategories(
            serverURL: URL(string: "https://server.invalid")!,
            username: "fictional-user",
            password: "fictional-password"
        )
    }

    private func fetchStreams(
        with catalog: XtreamLiveCatalogClient
    ) async throws -> [XtreamLiveStream] {
        try await catalog.fetchStreams(
            serverURL: URL(string: "https://server.invalid")!,
            username: "fictional-user",
            password: "fictional-password"
        )
    }

    private func makeCatalog(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (XtreamLiveCatalogClient, ActionRecorder) {
        let actions = ActionRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XtreamCatalogMockURLProtocol.self]
        XtreamCatalogMockURLProtocol.setHandler { request in
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value
            actions.append(action)
            return try handler(request)
        }
        return (XtreamLiveCatalogClient(client: XtreamHTTPClient(configuration: configuration)), actions)
    }

    private func response(
        for request: URLRequest,
        statusCode: Int = 200,
        json: String
    ) throws -> (HTTPURLResponse, Data) {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, Data(json.utf8))
    }
}

private final class ActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    var values: [String?] {
        lock.withLock { storage }
    }

    func append(_ value: String?) {
        lock.withLock { storage.append(value) }
    }
}

private final class XtreamCatalogMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock { requestHandler = handler }
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
