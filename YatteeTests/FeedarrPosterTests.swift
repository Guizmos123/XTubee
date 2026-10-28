//
//  FeedarrPosterTests.swift
//  Yattee
//
//  Real Nuke loading and caching over a simulated Feedarr transport.
//

import Foundation
import Nuke
import Testing
@testable import XTubee

@Suite("Feedarr Posters")
@MainActor
struct FeedarrPosterTests {
    @Test(arguments: ["/api/posters/release/1?v=7", "api/posters/release/1?v=7", "/base/api/posters/release/1?v=7", "https://feedarr.invalid/base/api/posters/release/1?v=7"])
    func basePathResolution(raw: String) throws {
        let source = try FeedarrSource(name: "Test", serverURL: "https://feedarr.invalid/base")
        #expect(try FeedarrPosterService.resolvePosterURL(raw, source: source).absoluteString == "https://feedarr.invalid/base/api/posters/release/1?v=7")
    }

    @Test(arguments: ["https://other.invalid/api/posters/release/1", "http://feedarr.invalid/api/posters/release/1", "file:///poster.png", "data:image/png;base64,AA", "//other.invalid/a", "https://user:secret@feedarr.invalid/base/a", "/../a", "/%2e%2e/a", "/a?password=secret", "/a?token=secret", "https://feedarr.invalid/other/a", "https://feedarr.invalid:444/base/a"])
    func rejectsUnsafeURLs(raw: String) throws {
        let source = try FeedarrSource(name: "Test", serverURL: "https://feedarr.invalid/base")
        #expect(throws: FeedarrPosterError.invalidURL) { try FeedarrPosterService.resolvePosterURL(raw, source: source) }
    }

    @Test func authenticatedLoadingAndMemoryCache() async throws {
        let fixture = try PosterFixture(auth: true)
        defer { fixture.cleanUp() }
        _ = try await fixture.service.image(for: release())
        _ = try await fixture.service.image(for: release())
        let requests = await fixture.transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://feedarr.invalid/base/api/posters/release/1?v=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:secret".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
        #expect(!(request.url?.absoluteString.contains("secret") ?? true))
    }

    @Test func anonymousHTTP() async throws {
        let fixture = try PosterFixture(url: "http://feedarr.invalid/base")
        defer { fixture.cleanUp() }
        fixture.store.value = try FeedarrCredentials(username: "unrelated", password: "secret")
        _ = try await fixture.service.image(for: release())
        #expect(await fixture.transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func missingCredentialsNeverSendRequest() async throws {
        let fixture = try PosterFixture(auth: true)
        defer { fixture.cleanUp() }
        fixture.store.value = nil
        await #expect(throws: FeedarrPosterError.missingCredentials) { try await fixture.service.image(for: release()) }
        #expect(await fixture.transport.requests.isEmpty)
    }

    @Test func posterVersionIsPartOfCacheIdentity() async throws {
        let fixture = try PosterFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.service.image(for: release())
        _ = try await fixture.service.image(for: release("/api/posters/release/1?v=2"))
        #expect(await fixture.transport.requests.count == 2)
    }

    @Test func sameOriginConfigurationsAreIsolated() async throws {
        let fixture = try PosterFixture(auth: true)
        defer { fixture.cleanUp() }
        _ = try await fixture.service.image(for: release())
        let previous = fixture.service.generation
        try fixture.manager.update(id: fixture.id, name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: true, username: "other", password: "changed")
        _ = try await fixture.service.image(for: release())
        #expect(previous != fixture.service.generation)
        #expect(await fixture.transport.requests.count == 2)
        #expect(await fixture.transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("other:changed".utf8).base64EncodedString())
        try fixture.manager.update(id: fixture.id, name: "Other", serverURL: "https://feedarr.invalid/other", usesBasicAuth: false)
        _ = try await fixture.service.image(for: release())
        #expect(await fixture.transport.requests.last?.url?.path == "/other/api/posters/release/1")
        #expect(await fixture.transport.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(await fixture.transport.requests.count == 3)
    }

    @Test func diskPurgeOnUpdateAndRemoval() async throws {
        let fixture = try PosterFixture(auth: true)
        defer { fixture.cleanUp() }
        let disk = try DataCache(path: fixture.directory)
        _ = try await fixture.service.image(for: release())
        try await waitUntil("initial disk write") { disk.totalCount > 0 }
        let previous = fixture.service.generation
        try fixture.manager.update(id: fixture.id, name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: true, username: "new", password: "new")
        try await waitUntil("invalidation after credentials-only update") { fixture.service.generation != previous }
        #expect(disk.totalCount == 0)
        _ = try await fixture.service.image(for: release())
        try await waitUntil("disk write after credential update") { disk.totalCount > 0 }
        let second = fixture.service.generation
        try fixture.manager.remove(id: fixture.id)
        try await waitUntil("invalidation after source removal") { fixture.service.generation != second }
        #expect(disk.totalCount == 0)
        await #expect(throws: FeedarrPosterError.sourceNotConfigured) { try await fixture.service.image(for: release()) }
    }

    @Test func coldStartDoesNotReuseAnotherCredentialSession() async throws {
        let fixture = try PosterFixture()
        defer { fixture.cleanUp() }
        let disk = try DataCache(path: fixture.directory)
        disk.storeData(Data("old authenticated image".utf8), for: "old")
        disk.flush()
        #expect(disk.totalCount > 0)
        let other = FeedarrPosterService(sources: fixture.manager, credentialsStore: fixture.store,
                                        transport: fixture.transport, cacheDirectory: fixture.directory)
        #expect(disk.totalCount == 0)
        _ = try await other.image(for: release())
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test func identicalRequestsCoalesce() async throws {
        let fixture = try PosterFixture(handler: { request in
            try await Task.sleep(for: .milliseconds(100))
            return PosterTransportStub.response(request)
        })
        defer { fixture.cleanUp() }
        async let first = fixture.service.image(for: release())
        async let second = fixture.service.image(for: release())
        _ = try await (first, second)
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test(arguments: [401, 403, 404, 503])
    func failureDoesNotRetry(status: Int) async throws {
        let fixture = try PosterFixture(handler: { PosterTransportStub.response($0, status: status) })
        defer { fixture.cleanUp() }
        let expected: FeedarrHTTPError = switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        default: .serviceUnavailable
        }
        await #expect(throws: FeedarrPosterError.transport(expected)) { try await fixture.service.image(for: release()) }
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test func rejectsExternalRedirect() async throws {
        let fixture = try PosterFixture(auth: true, handler: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                     headerFields: ["Location": "https://external.invalid/poster"])!)
        })
        defer { fixture.cleanUp() }
        await #expect(throws: FeedarrPosterError.transport(.redirectForbidden)) { try await fixture.service.image(for: release()) }
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test func externalPosterNeverReachesTransport() async throws {
        let fixture = try PosterFixture(auth: true)
        defer { fixture.cleanUp() }
        await #expect(throws: FeedarrPosterError.invalidURL) {
            try await fixture.service.image(for: release("https://external.invalid/api/posters/release/1"))
        }
        #expect(await fixture.transport.requests.isEmpty)
    }

    @Test func invalidImageAndOversizedResponse() async throws {
        let fixture = try PosterFixture(handler: { PosterTransportStub.response($0, data: Data("not an image".utf8)) })
        defer { fixture.cleanUp() }
        await #expect(throws: FeedarrPosterError.invalidImage) { try await fixture.service.image(for: release()) }
        await fixture.transport.setHandler { PosterTransportStub.response($0, data: Data(repeating: 0, count: FeedarrPosterService.maximumResponseSize + 1)) }
        await #expect(throws: FeedarrPosterError.transport(.responseTooLarge(maximumBytes: FeedarrPosterService.maximumResponseSize))) {
            try await fixture.service.image(for: release("/api/posters/release/2"))
        }
    }

    @Test func cancellationReachesTransport() async throws {
        let signal = CancellationSignal()
        let fixture = try PosterFixture(handler: { _ in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await signal.mark(); throw error }
            throw URLError(.cancelled)
        })
        defer { fixture.cleanUp() }
        let task = Task { try await fixture.service.image(for: release()) }
        try await waitUntil { await !fixture.transport.requests.isEmpty }
        task.cancel()
        await #expect(throws: FeedarrPosterError.cancelled) { try await task.value }
        try await waitUntil { await signal.cancelled }
    }

    @Test func staleCompletionCannotRestorePurgedCache() async throws {
        let gate = PosterGate()
        let fixture = try PosterFixture(handler: { request in
            await gate.wait() // Deliberately ignores cancellation to simulate a late transport.
            return PosterTransportStub.response(request)
        })
        defer { fixture.cleanUp() }
        let task = Task { try await fixture.service.image(for: release()) }
        try await waitUntil { await !fixture.transport.requests.isEmpty }
        let old = fixture.service.generation
        try fixture.manager.remove(id: fixture.id)
        try await waitUntil { fixture.service.generation != old }
        await gate.open()
        await #expect(throws: FeedarrPosterError.obsoleteResponse) { try await task.value }
        #expect(try DataCache(path: fixture.directory).totalCount == 0)
    }

    private func release(_ url: String = "/api/posters/release/1?v=1") throws -> FeedarrRelease {
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "sourceId": 2, "posterUrl": url])
        return try JSONDecoder().decode(FeedarrRelease.self, from: data)
    }

    private func waitUntil(_ operation: String = "poster operation", _ condition: () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for \(operation)")
        throw URLError(.timedOut)
    }
}

@MainActor
private struct PosterFixture {
    let store = PosterCredentials()
    let manager: FeedarrSourcesManager
    let transport: PosterTransportStub
    let service: FeedarrPosterService
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedarrPosterTests-" + UUID().uuidString)
    let id: UUID
    init(url: String = "https://feedarr.invalid/base", auth: Bool = false,
         handler: @escaping PosterTransportStub.Handler = { PosterTransportStub.response($0) }) throws {
        manager = FeedarrSourcesManager(persistence: PosterPersistence(), credentialsStore: store)
        id = try manager.add(name: "Test", serverURL: url, usesBasicAuth: auth, username: auth ? "user" : nil, password: auth ? "secret" : nil).id
        transport = PosterTransportStub(handler: handler)
        service = FeedarrPosterService(sources: manager, credentialsStore: store, transport: transport, cacheDirectory: directory)
    }
    func cleanUp() {
        try? manager.remove(id: id)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class PosterPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor
private final class PosterCredentials: FeedarrCredentialsStoring {
    var value: FeedarrCredentials?
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { value }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { value = credentials }
    func deleteCredentials(for sourceID: UUID) throws { value = nil }
}

private actor PosterTransportStub: FeedarrHTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var handler: Handler
    private(set) var requests: [URLRequest] = []
    init(handler: @escaping Handler) { self.handler = handler }
    func setHandler(_ handler: @escaping Handler) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await handler(request)
    }
    // Synthetic 1x1 PNG, decoded by Nuke rather than an image mock.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1X8AAAAASUVORK5CYII=")!
    static func response(_ request: URLRequest, status: Int = 200, data: Data = png) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
    }
}

private actor CancellationSignal {
    private(set) var cancelled = false
    func mark() { cancelled = true }
}

private actor PosterGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}
