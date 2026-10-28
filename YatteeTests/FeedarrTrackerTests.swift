//
//  FeedarrTrackerTests.swift
//  Yattee
//
//  Real API decoding plus shared directory caching with entirely simulated transports.
//

import Foundation
import Observation
import Testing
@testable import XTubee

@Suite("Feedarr Trackers")
@MainActor
struct FeedarrTrackerTests {
    @Test func sourcesArrayDecodesWithExistingHTTPSAuthentication() async throws {
        let fixture = try TrackerFixture(auth: true)
        let transport = TrackerTransport(body: Self.sourcesJSON)
        let api = FeedarrAPIClient(sources: fixture.manager, credentialsStore: fixture.credentials, transport: transport)
        let rows = try await api.trackerSources()
        #expect(rows.count == 2 && rows[0].id == 4_294_967_310)
        #expect(rows[0].name == "Real Tracker" && rows[0].color == "#12aBeF")
        #expect(rows[1].color == nil)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let url = try #require(requests[0].url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.scheme == "https" && url.host == "feedarr.invalid" && url.path == "/base/api/sources")
        #expect(components.queryItems?.isEmpty ?? true)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("login:secret".utf8).base64EncodedString())
        let cachedProjection = try String(decoding: JSONEncoder().encode(rows), as: UTF8.self)
        #expect(!cachedProjection.contains("torznabUrl") && !cachedProjection.contains("discard-me"))
    }

    @Test func objectEnvelopeIsNotMistakenForTheRealArrayContract() async throws {
        let fixture = try TrackerFixture()
        let api = FeedarrAPIClient(sources: fixture.manager, credentialsStore: fixture.credentials,
                                  transport: TrackerTransport(body: "{\"items\":\(Self.sourcesJSON)}"))
        await #expect(throws: FeedarrAPIError.invalidJSON) { try await api.trackerSources() }
    }

    @Test func sourceIDMappingUpdatesObserversWithoutInventingNames() async throws {
        let fixture = try TrackerFixture()
        fixture.loader.rows = [FeedarrTracker(id: 9, name: " Actual Name ", color: "#123456"),
                               FeedarrTracker(id: 10, name: "No color", color: nil),
                               FeedarrTracker(id: 11, name: "Bad color", color: "red"),
                               FeedarrTracker(id: 12, name: "  ", color: "#ffffff")]
        let changed = TrackerChangeFlag()
        withObservationTracking { _ = fixture.directory.tracker(for: 9) } onChange: { changed.mark() }
        await fixture.directory.loadIfNeeded()
        #expect(changed.value) // A sheet waiting for the initial request will actually redraw.
        #expect(fixture.directory.tracker(for: 9)?.name == "Actual Name")
        #expect(fixture.directory.tracker(for: 9)?.badgeColor == FeedarrTrackerColor(hex: "#123456"))
        #expect(fixture.directory.tracker(for: 10)?.badgeColor == nil)
        #expect(fixture.directory.tracker(for: 11)?.badgeColor == nil)
        #expect(fixture.directory.tracker(for: 12) == nil && fixture.directory.tracker(for: 999) == nil)
    }

    @Test func customColorsNormalizeAndProvideReadableContrast() {
        #expect(FeedarrTrackerColor(hex: " 12aBEf ") == FeedarrTrackerColor(hex: "#12abef"))
        for invalid in ["", "red", "#abc", "#aabbccdd", "#zzzzzz", "#12345g"] {
            #expect(FeedarrTrackerColor(hex: invalid) == nil)
        }
        #expect(FeedarrTrackerColor(hex: nil) == nil)
        for hex in ["#ffffff", "#000000", "#8b5cf6", "#f59e0b", "#187d3d", "#ef4444", "#12abef"] {
            guard let rgb = FeedarrTrackerColor(hex: hex) else { Issue.record("Invalid test color"); return }
            let contrast = rgb.usesDarkText ? (rgb.luminance + 0.05) / 0.05 : 1.05 / (rgb.luminance + 0.05)
            #expect(contrast >= 4.5)
        }
    }

    @Test func concurrentAndRepeatedSheetLoadsShareOneFetch() async throws {
        let fixture = try TrackerFixture()
        fixture.loader.manual = true
        let first = Task { await fixture.directory.loadIfNeeded() }
        try await wait { fixture.loader.calls == 1 }
        let second = Task { await fixture.directory.loadIfNeeded() }
        await Task.yield()
        #expect(fixture.loader.calls == 1)
        fixture.loader.finish(0, rows: [Self.tracker])
        await first.value
        await second.value
        await fixture.directory.loadIfNeeded()
        await fixture.directory.loadIfNeeded()
        #expect(fixture.loader.calls == 1 && fixture.directory.tracker(for: 9) == Self.tracker)
    }

    @Test func cacheExpiresAndExplicitRefreshBypassesValidity() async throws {
        let fixture = try TrackerFixture()
        await fixture.directory.loadIfNeeded()
        await fixture.directory.loadIfNeeded()
        #expect(fixture.loader.calls == 1)
        fixture.clock.date.addTimeInterval(301)
        #expect(fixture.directory.tracker(for: 9) == nil)
        await fixture.directory.loadIfNeeded()
        #expect(fixture.loader.calls == 2)
        fixture.loader.rows = [FeedarrTracker(id: 9, name: "Changed in Feedarr", color: "#ffffff")]
        await fixture.directory.refresh()
        #expect(fixture.loader.calls == 3)
        #expect(fixture.directory.tracker(for: 9)?.name == "Changed in Feedarr")
    }

    @Test func apiFailureIsSoftAndDoesNotRetryOnEverySheet() async throws {
        let fixture = try TrackerFixture()
        fixture.loader.error = .http(.forbidden, problem: nil)
        await fixture.directory.loadIfNeeded()
        #expect(fixture.directory.loadFailed && !fixture.directory.isLoading)
        #expect(fixture.directory.tracker(for: 9) == nil)
        await fixture.directory.loadIfNeeded()
        #expect(fixture.loader.calls == 1)
        fixture.loader.error = nil
        await fixture.directory.refresh()
        #expect(fixture.loader.calls == 2 && !fixture.directory.loadFailed)
        #expect(fixture.directory.tracker(for: 9) == Self.tracker)
    }

    @Test func urlCredentialsAndRemovalInvalidateTheDirectory() async throws {
        let fixture = try TrackerFixture(auth: true)
        await fixture.directory.loadIfNeeded()
        try fixture.manager.update(id: fixture.id, name: "Test", serverURL: "https://new.invalid/base", usesBasicAuth: true, username: "login", password: "secret")
        #expect(fixture.directory.tracker(for: 9) == nil)
        await fixture.directory.loadIfNeeded()
        #expect(fixture.loader.calls == 2)
        try fixture.manager.update(id: fixture.id, name: "Test", serverURL: "https://new.invalid/base", usesBasicAuth: true, username: "changed", password: "changed")
        #expect(fixture.directory.tracker(for: 9) == nil)
        await fixture.directory.loadIfNeeded()
        #expect(fixture.loader.calls == 3)
        try fixture.manager.remove(id: fixture.id)
        #expect(fixture.directory.tracker(for: 9) == nil)
        await fixture.directory.loadIfNeeded()
        #expect(fixture.loader.calls == 3 && fixture.directory.trackers.isEmpty)
    }

    @Test func previousConfigurationResponseCannotOverwriteNewDirectory() async throws {
        let fixture = try TrackerFixture()
        fixture.loader.manual = true
        let old = Task { await fixture.directory.loadIfNeeded() }
        try await wait { fixture.loader.calls == 1 }
        try fixture.manager.update(id: fixture.id, name: "Test", serverURL: "https://new.invalid", usesBasicAuth: false)
        let fresh = Task { await fixture.directory.loadIfNeeded() }
        try await wait { fixture.loader.calls == 2 }
        let updated = FeedarrTracker(id: 9, name: "New Server", color: "#ffffff")
        fixture.loader.finish(1, rows: [updated])
        await fresh.value
        fixture.loader.finish(0, rows: [Self.tracker])
        await old.value
        #expect(fixture.directory.tracker(for: 9) == updated)
        #expect(!fixture.directory.loadFailed)
    }

    static let tracker = FeedarrTracker(id: 9, name: "Tracker", color: "#123456")
    static let sourcesJSON = ##"[{"id":4294967310,"name":"Real Tracker","color":"#12aBeF","enabled":true,"torznabUrl":"https://tracker.invalid/api?key=discard-me","authMode":"query"},{"id":2,"name":"Second","color":null,"enabled":false}]"##

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for tracker directory", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
}

@MainActor
private struct TrackerFixture {
    let credentials = TrackerCredentials()
    let manager: FeedarrSourcesManager
    let loader = TrackerLoader()
    let clock = TrackerClock()
    let directory: FeedarrTrackerService
    let id: UUID
    init(auth: Bool = false) throws {
        manager = FeedarrSourcesManager(persistence: TrackerPersistence(), credentialsStore: credentials)
        id = try manager.add(name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: auth, username: auth ? "login" : nil, password: auth ? "secret" : nil).id
        let fetch = loader, time = clock
        directory = FeedarrTrackerService(sources: manager, now: { time.date }) { try await fetch.load() }
    }
}

@MainActor
private final class TrackerClock { var date = Date(timeIntervalSince1970: 1_000) }

@MainActor
private final class TrackerLoader {
    var rows = [FeedarrTrackerTests.tracker]
    var error: FeedarrAPIError?
    var manual = false
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<[FeedarrTracker], Never>] = [:]
    func load() async throws -> [FeedarrTracker] {
        let index = calls
        calls += 1
        if let error { throw error }
        if manual { return await withCheckedContinuation { pending[index] = $0 } }
        return rows
    }
    func finish(_ index: Int, rows: [FeedarrTracker]) { pending.removeValue(forKey: index)?.resume(returning: rows) }
}

@MainActor
private final class TrackerPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor
private final class TrackerCredentials: FeedarrCredentialsStoring {
    var value: FeedarrCredentials?
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { value }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { value = credentials }
    func deleteCredentials(for sourceID: UUID) throws { value = nil }
}

private actor TrackerTransport: FeedarrHTTPTransport {
    let body: String
    private(set) var requests: [URLRequest] = []
    init(body: String) { self.body = body }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class TrackerChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func mark() { lock.withLock { stored = true } }
}
