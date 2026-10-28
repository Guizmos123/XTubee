//
//  FeedarrAPIClientTests.swift
//  Yattee
//
//  Catalogue contract and security tests with an entirely simulated transport.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr API Client Tests")
@MainActor
struct FeedarrAPIClientTests {
    @Test func topDefaultsAndDTO() async throws {
        let fixture = try Fixture()
        let response = try await fixture.client.top()
        #expect(response.sortUsed == .score)
        #expect(response.globalTop.first?.id == 4_294_967_310)
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.url?.absoluteString == "https://feedarr.invalid/base/api/feed/top?hours=24&take=5&perCategoryTake=5&sort=score")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
    }

    @Test func releasesDefaultsAndDTO() async throws {
        let fixture = try Fixture()
        let response = try await fixture.client.releases()
        #expect(response.pagination.snapshotMaxId == 9_000_000_000)
        #expect(response.pagination.nextCursor == FeedarrDTOFixtures.nextCursor)
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.url?.absoluteString == "https://feedarr.invalid/base/api/feed/releases?limit=50&sort=date")
    }

    @Test(arguments: FeedarrTopSort.allCases)
    func topSort(sort: FeedarrTopSort) async throws {
        let fixture = try Fixture()
        _ = try await fixture.client.top(hours: 48, take: 7, perCategoryTake: 3, sort: sort)
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.url?.query == "hours=48&take=7&perCategoryTake=3&sort=\(sort.rawValue)")
    }

    @Test(arguments: FeedarrReleasesSort.allCases)
    func filtersAndOpaqueCursor(sort: FeedarrReleasesSort) async throws {
        let fixture = try Fixture()
        let cursor = " opaque+/=&?#%é "
        _ = try await fixture.client.releases(limit: 123, sort: sort, q: "été & 4K + ?", unifiedCategory: "films", cursor: cursor)
        let request = try #require(await fixture.transport.requests.first)
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "limit", value: "123"), URLQueryItem(name: "sort", value: sort.rawValue),
                          URLQueryItem(name: "q", value: "été & 4K + ?"), URLQueryItem(name: "unifiedCategory", value: "films"),
                          URLQueryItem(name: "cursor", value: cursor)])
    }

    @Test func basicAuthFromStore() async throws {
        let fixture = try Fixture(auth: true)
        _ = try await fixture.client.releases()
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:secret".utf8).base64EncodedString())
        #expect(!(request.url?.absoluteString.contains("secret") ?? true))
    }

    @Test func anonymousHTTPNeverAuthenticates() async throws {
        let fixture = try Fixture(url: "http://feedarr.invalid/base", auth: false)
        _ = try await fixture.client.releases()
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func basicAuthHTTPRejected() async throws {
        let transport = APITransport()
        #expect(throws: FeedarrHTTPError.insecureBasicAuth) {
            try FeedarrHTTPClient(serverURL: "http://feedarr.invalid", username: "user", password: "secret", transport: transport)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func missingSourceAndCredentials() async throws {
        let fixture = try Fixture(auth: true)
        fixture.store.value = nil
        await #expect(throws: FeedarrAPIError.credentialsMissing) { try await fixture.client.top() }
        #expect(await fixture.transport.requests.isEmpty)
        try fixture.manager.remove(id: try #require(fixture.manager.source?.id))
        await #expect(throws: FeedarrAPIError.sourceNotConfigured) { try await fixture.client.releases() }
    }

    @Test(arguments: [401, 403, 500])
    func httpProblems(status: Int) async throws {
        let fixture = try Fixture(handler: { request in
            APITransport.response(request, status: status, json: "{\"status\":\(status),\"title\":\"invalid_cursor\",\"detail\":\"Example diagnostic\"}")
        })
        do {
            _ = try await fixture.client.releases()
            Issue.record("Expected HTTP failure")
        } catch let FeedarrAPIError.http(error, problem) {
            let expected: FeedarrHTTPError = status == 401 ? .unauthorized : status == 403 ? .forbidden : .httpStatus(500)
            #expect(error == expected)
            #expect(problem?.title == "invalid_cursor")
            #expect(problem?.detail == "Example diagnostic")
            #expect(problem?.status == status)
            #expect(!String(reflecting: problem).contains("Example diagnostic"))
        }
    }

    @Test func emptyUnauthorizedBody() async throws {
        let fixture = try Fixture(handler: { APITransport.response($0, status: 401, json: "") })
        await #expect(throws: FeedarrAPIError.http(.unauthorized, problem: nil)) { try await fixture.client.top() }
    }

    @Test(arguments: ["not JSON", "{}", "{\"items\":false}"])
    func invalidJSON(json: String) async throws {
        let fixture = try Fixture(handler: { APITransport.response($0, json: json) })
        await #expect(throws: FeedarrAPIError.invalidJSON) { try await fixture.client.releases() }
    }

    @Test func redirectDoesNotFollowOrExposeCredentials() async throws {
        let fixture = try Fixture(auth: true, handler: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                     headerFields: ["Location": "https://other.invalid/"])!)
        })
        await #expect(throws: FeedarrAPIError.transport(.redirectForbidden)) { try await fixture.client.top() }
        #expect(await fixture.transport.requests.count == 1)
        #expect(!FeedarrRedirectPolicy.allowsRedirect(from: URL(string: "https://feedarr.invalid")!, to: URL(string: "https://other.invalid")!))
    }

    @Test func cancellationIsNotAuthenticationFailure() async throws {
        let fixture = try Fixture(handler: { _ in
            try await Task.sleep(for: .seconds(30))
            throw URLError(.userAuthenticationRequired)
        })
        let task = Task { try await fixture.client.releases() }
        while await fixture.transport.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: FeedarrAPIError.cancelled) { try await task.value }
    }

    @Test func obsoleteConfiguration() async throws {
        let fixture = try Fixture()
        await fixture.transport.setHandler { request in
            await MainActor.run { fixture.store.value = try! FeedarrCredentials(username: "changed", password: "changed") }
            return APITransport.response(request, json: FeedarrDTOFixtures.pagedReleases)
        }
        // The request captures credentials before the simulated response changes the store.
        fixture.store.value = try FeedarrCredentials(username: "user", password: "secret")
        try fixture.manager.update(id: try #require(fixture.manager.source?.id), name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: true, username: "user", password: "secret")
        await #expect(throws: FeedarrAPIError.obsoleteResponse) { try await fixture.client.releases() }
    }

    @Test func largeCatalogueAndBound() async throws {
        let json = String(repeating: " ", count: 1_100_000) + FeedarrDTOFixtures.emptyReleases
        let fixture = try Fixture(handler: { APITransport.response($0, json: json) })
        #expect(try await fixture.client.releases().items.isEmpty)
        let small = FeedarrAPIClient(sources: fixture.manager, credentialsStore: fixture.store, transport: fixture.transport, maximumResponseSize: 100)
        await #expect(throws: FeedarrAPIError.transport(.responseTooLarge(maximumBytes: 100))) { try await small.releases() }
        #expect(FeedarrHTTPClient.defaultMaximumResponseSize == 1_024 * 1_024)
    }

    @Test(arguments: ["declared", "streamed"])
    func productionTransportBoundsBody(mode: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedFeedarrProtocol.self]
        let transport = URLSessionFeedarrTransport(configuration: configuration)
        let http = try FeedarrHTTPClient(serverURL: "https://feedarr.invalid", transport: transport, maximumResponseSize: 16)
        await #expect(throws: FeedarrHTTPError.responseTooLarge(maximumBytes: 16)) {
            try await http.get(pathComponents: [mode])
        }
    }

    @Test func concurrentSessionRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedFeedarrProtocol.self]
        let transport = URLSessionFeedarrTransport(configuration: configuration)
        let http = try FeedarrHTTPClient(serverURL: "https://feedarr.invalid", transport: transport, maximumResponseSize: 64)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await http.get(pathComponents: ["streamed"]) } }
            var count = 0
            for try await data in group { #expect(data.count == 32); count += 1 }
            #expect(count == 8)
        }
    }
}

private final class BoundedFeedarrProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = request.url!.lastPathComponent == "declared" ? ["Content-Length": "32"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 32))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private struct Fixture {
    let manager: FeedarrSourcesManager
    let store: APICredentials
    let transport: APITransport
    let client: FeedarrAPIClient

    init(url: String = "https://feedarr.invalid/base", auth: Bool = false,
         handler: @escaping APITransport.Handler = APITransport.success) throws {
        store = APICredentials()
        manager = FeedarrSourcesManager(persistence: APIPersistence(), credentialsStore: store)
        try manager.add(name: "Test", serverURL: url, usesBasicAuth: auth, username: auth ? "user" : nil, password: auth ? "secret" : nil)
        transport = APITransport(handler: handler)
        client = FeedarrAPIClient(sources: manager, credentialsStore: store, transport: transport)
    }
}

@MainActor
private final class APIPersistence: FeedarrSourcePersisting {
    var value: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { value }
    func saveSource(_ source: FeedarrSource?) throws { value = source }
}

@MainActor
private final class APICredentials: FeedarrCredentialsStoring {
    var value: FeedarrCredentials?
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { value }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { value = credentials }
    func deleteCredentials(for sourceID: UUID) throws { value = nil }
}

private actor APITransport: FeedarrHTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var handler: Handler
    private(set) var requests: [URLRequest] = []
    init(handler: @escaping Handler = APITransport.success) { self.handler = handler }
    func setHandler(_ handler: @escaping Handler) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await handler(request)
    }
    static func response(_ request: URLRequest, status: Int = 200, json: String) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    static func success(_ request: URLRequest) async throws -> (Data, URLResponse) {
        response(request, json: request.url!.path.hasSuffix("top") ? FeedarrDTOFixtures.completeTop : FeedarrDTOFixtures.pagedReleases)
    }
}
