//
//  FeedarrReleasesTests.swift
//  Yattee
//
//  Cursor pagination and segment lifecycle with controlled, entirely local responses.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Releases")
@MainActor
struct FeedarrReleasesTests {
    @Test func firstPageAndOpaqueCursorThroughRealAPIClient() async throws {
        let fixture = try ReleasesFixture()
        let transport = ReleasesHTTPTransport()
        let client = FeedarrAPIClient(sources: fixture.manager, credentialsStore: fixture.credentials, transport: transport)
        let model = FeedarrReleasesModel(sources: fixture.manager) { query, cursor, sort, category in
            try await client.releases(limit: 50, sort: sort, q: query, unifiedCategory: category?.rawValue, cursor: cursor)
        }
        model.setVisible(true)
        try await wait { model.hasLoadedInitial }
        model.loadNextPage()
        try await wait { model.isAtEnd }
        #expect(model.items.map(\.id) == [1, 2])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://feedarr.invalid/base/api/feed/releases?limit=50&sort=date")
        let components = try #require(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "sort", value: "date"),
                                        URLQueryItem(name: "cursor", value: ReleasesHTTPTransport.opaque)])
    }

    @Test func deduplicatesWithinAndBetweenPagesPreservingOrder() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        fixture.api.succeed(0, page: try releasesPage([3, 1, 3, 2], next: "A"))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.succeed(1, page: try releasesPage([2, 4, 1, 5, 4]))
        try await wait { fixture.model.isAtEnd }
        #expect(fixture.model.items.map(\.id) == [3, 1, 2, 4, 5])
    }

    @Test func onlyOneActiveRequestDespiteRepeatedAppearance() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        fixture.model.setVisible(true)
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 1 }
        #expect(fixture.model.isLoadingInitial && !fixture.model.isLoadingNextPage)
        fixture.api.succeed(0, page: try releasesPage(Array(1...50), next: "A"))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.itemAppeared(1)
        #expect(fixture.api.calls.count == 1)
        for _ in 0..<20 { fixture.model.itemAppeared(48); fixture.model.loadNextPage(); fixture.model.setVisible(true) }
        try await wait { fixture.api.calls.count == 2 }
        #expect(fixture.model.isLoadingNextPage && !fixture.model.isLoadingInitial)
        fixture.api.succeed(1, page: try releasesPage([51]))
        try await wait { fixture.model.isAtEnd }
        for _ in 0..<20 { fixture.model.loadNextPage(); fixture.model.itemAppeared(51) }
        #expect(fixture.api.calls.count == 2)
    }

    @Test func emptyCatalogueStops() async throws {
        let fixture = try ReleasesFixture(automatic: releasesPage([]))
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.model.isEmpty && fixture.model.isAtEnd)
        fixture.model.loadNextPage()
        #expect(fixture.api.calls.count == 1)
    }

    @Test func hasMoreFalseWinsOverStrayCursor() async throws {
        let fixture = try ReleasesFixture(automatic: releasesPage([1], next: "ignored", hasMore: false))
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.loadNextPage()
        #expect(fixture.model.nextCursor == nil)
        #expect(fixture.api.calls.count == 1)
    }

    @Test func nextPageFailureKeepsItemsAndRetriesSameCursor() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        fixture.api.succeed(0, page: try releasesPage([1, 2], next: "opaque-A"))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.fail(1, error: .transport(.networkUnavailable))
        try await wait { fixture.model.failure != nil }
        #expect(fixture.model.items.map(\.id) == [1, 2])
        #expect(fixture.model.nextCursor == "opaque-A")
        #expect(fixture.model.failure == .offline)
        fixture.model.loadNextPage()
        fixture.model.itemAppeared(2)
        fixture.model.setVisible(false)
        fixture.model.setVisible(true)
        #expect(fixture.api.calls.count == 2)
        fixture.model.retry()
        try await wait { fixture.api.calls.count == 3 }
        #expect(fixture.api.calls == [nil, "opaque-A", "opaque-A"])
        fixture.api.succeed(2, page: try releasesPage([3]))
        try await wait { fixture.model.isAtEnd }
        #expect(fixture.model.items.map(\.id) == [1, 2, 3])
    }

    @Test func refreshReplacesWithoutCursorAndResetsScrollIdentity() async throws {
        let fixture = try ReleasesFixture(automatic: releasesPage([1, 2], next: "old"))
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        let generation = fixture.model.catalogGeneration
        fixture.api.automatic = try releasesPage([9], next: "fresh")
        await fixture.model.refresh()
        #expect(fixture.api.calls == [nil, nil])
        #expect(fixture.model.items.map(\.id) == [9])
        #expect(fixture.model.nextCursor == "fresh")
        #expect(fixture.model.catalogGeneration != generation)
    }

    @Test func failedRefreshPreservesDataAndRetryRestartsFirstPage() async throws {
        let fixture = try ReleasesFixture(automatic: releasesPage([1], next: "A"))
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        let generation = fixture.model.catalogGeneration
        fixture.api.automatic = nil
        let refresh = Task { await fixture.model.refresh() }
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.fail(1, error: .http(.httpStatus(500), problem: nil))
        await refresh.value
        #expect(fixture.model.items.map(\.id) == [1])
        #expect(fixture.model.catalogGeneration == generation)
        fixture.model.retry()
        try await wait { fixture.api.calls.count == 3 }
        #expect(fixture.api.calls == [nil, nil, nil])
        fixture.api.succeed(2, page: try releasesPage([7]))
        try await wait { fixture.model.isAtEnd }
        #expect(fixture.model.items.map(\.id) == [7])
    }

    @Test func refreshRejectsLatePageResponse() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        fixture.api.succeed(0, page: try releasesPage([1], next: "A"))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 2 }
        let refresh = Task { await fixture.model.refresh() }
        try await wait { fixture.api.calls.count == 3 }
        fixture.api.succeed(2, page: try releasesPage([9]))
        await refresh.value
        fixture.api.succeed(1, page: try releasesPage([2, 3]))
        try await wait { fixture.api.cancelled.contains(1) }
        #expect(fixture.model.items.map(\.id) == [9])
        #expect(fixture.model.isAtEnd)
    }

    @Test func segmentsRetainDataCursorAndScrollIdentity() async throws {
        let fixture = try ReleasesFixture(automatic: releasesPage([1, 2], next: "A"))
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        let generation = fixture.model.catalogGeneration
        fixture.model.setVisible(false)
        fixture.model.loadNextPage()
        fixture.model.setVisible(true)
        #expect(fixture.model.items.map(\.id) == [1, 2])
        #expect(fixture.model.catalogGeneration == generation)
        #expect(fixture.model.nextCursor == "A")
        #expect(fixture.api.calls.count == 1)
    }

    @Test func hiddenNextPageIsCancelledAndCanResume() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        fixture.api.succeed(0, page: try releasesPage([1], next: "A"))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 2 }
        fixture.model.setVisible(false)
        fixture.api.succeed(1, page: try releasesPage([2]))
        try await wait { fixture.api.cancelled.contains(1) }
        #expect(fixture.model.items.map(\.id) == [1])
        #expect(fixture.model.failure == nil)
        fixture.model.setVisible(true)
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 3 }
        #expect(fixture.api.calls[2] == "A")
        fixture.api.succeed(2, page: try releasesPage([2]))
        try await wait { fixture.model.isAtEnd }
    }

    @Test func configurationChangeRejectsOldResponseAndStartsFresh() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        try fixture.manager.update(id: fixture.id, name: "New", serverURL: "https://new.invalid/base", usesBasicAuth: false)
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.succeed(1, page: try releasesPage([7]))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.api.succeed(0, page: try releasesPage([1], next: "stale"))
        try await wait { fixture.api.cancelled.contains(0) }
        #expect(fixture.model.items.map(\.id) == [7])
        #expect(fixture.api.calls == [nil, nil])
    }

    @Test func credentialsOnlyChangeInvalidatesEvenWhileHidden() async throws {
        let fixture = try ReleasesFixture(automatic: releasesPage([1], next: "A"), auth: true)
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.setVisible(false)
        try fixture.manager.update(id: fixture.id, name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: true, username: "other", password: "changed")
        try await wait { !fixture.model.hasLoadedInitial }
        #expect(fixture.model.items.isEmpty && fixture.model.nextCursor == nil)
        #expect(fixture.api.calls.count == 1)
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls == [nil, nil])
    }

    @Test func removalCancelsAndClearsCatalogue() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        try fixture.manager.remove(id: fixture.id)
        try await wait { !fixture.model.isLoading }
        fixture.api.succeed(0, page: try releasesPage([1]))
        try await wait { fixture.api.cancelled.contains(0) }
        await fixture.model.refresh()
        fixture.model.retry()
        #expect(fixture.model.items.isEmpty && !fixture.model.hasLoadedInitial)
        #expect(fixture.api.calls.count == 1)
    }

    @Test func neverLoadsWithoutSourceOrBeforeReleasesIsVisible() async throws {
        let fixture = try ReleasesFixture(configured: false, automatic: releasesPage([1]))
        fixture.model.setVisible(true)
        await fixture.model.refresh()
        fixture.model.loadNextPage()
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setVisible(false)
        try fixture.manager.add(name: "Test", serverURL: "https://feedarr.invalid", usesBasicAuth: false)
        await Task.yield()
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls.count == 1)
    }

    @Test(arguments: [FeedarrAPIError.transport(.networkUnavailable), .invalidJSON, .http(.unauthorized, problem: nil)])
    func initialFailureCanBeRetried(error: FeedarrAPIError) async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        fixture.api.fail(0, error: error)
        try await wait { fixture.model.failure != nil }
        #expect(fixture.model.failure == FeedarrReleasesFailure(error))
        #expect(!fixture.model.hasLoadedInitial && !fixture.model.isLoading)
        fixture.model.retry()
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.succeed(1, page: try releasesPage([1]))
        try await wait { fixture.model.hasLoadedInitial }
    }

    @Test(arguments: [false, true])
    func invalidPaginationDoesNotLoop(missingCursor: Bool) async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        fixture.api.succeed(0, page: try releasesPage([1], next: "A"))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.succeed(1, page: try releasesPage([2], next: missingCursor ? nil : "A", hasMore: true))
        try await wait { fixture.model.failure != nil }
        #expect(fixture.model.failure == .invalidResponse)
        #expect(fixture.model.items.map(\.id) == [1])
        fixture.model.loadNextPage()
        #expect(fixture.api.calls.count == 2)
    }

    @Test func duplicateOnlyPageAdvancesToNewCursor() async throws {
        let fixture = try ReleasesFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.api.calls.count == 1 }
        fixture.api.succeed(0, page: try releasesPage([1], next: "A"))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.succeed(1, page: try releasesPage([1, 1], next: "B"))
        try await wait { fixture.model.nextCursor == "B" }
        #expect(fixture.model.items.map(\.id) == [1])
        fixture.model.loadNextPage()
        try await wait { fixture.api.calls.count == 3 }
        #expect(fixture.api.calls == [nil, "A", "B"])
        fixture.api.succeed(2, page: try releasesPage([2]))
        try await wait { fixture.model.isAtEnd }
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Releases state", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
}

private func releasesPage(_ ids: [Int64], next: String? = nil, hasMore: Bool? = nil) throws -> FeedarrReleasesResponse {
    let items = try ids.map { id in
        try JSONDecoder().decode(FeedarrRelease.self, from: Data("{\"id\":\(id),\"sourceId\":1}".utf8))
    }
    return FeedarrReleasesResponse(items: items, pagination: FeedarrPagination(limit: 50, hasMore: hasMore ?? (next != nil), nextCursor: next, snapshotMaxId: 9_000_000_000), query: nil)
}

@MainActor
private struct ReleasesFixture {
    let credentials = ReleasesCredentials()
    let manager: FeedarrSourcesManager
    let api: ReleasesStub
    let model: FeedarrReleasesModel
    let id: UUID
    init(configured: Bool = true, automatic: FeedarrReleasesResponse? = nil, auth: Bool = false) throws {
        manager = FeedarrSourcesManager(persistence: ReleasesPersistence(), credentialsStore: credentials)
        id = configured ? try manager.add(name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: auth, username: auth ? "user" : nil, password: auth ? "old" : nil).id : UUID()
        api = ReleasesStub()
        api.automatic = automatic
        let stub = api
        model = FeedarrReleasesModel(sources: manager) { _, cursor, _, _ in try await stub.load(cursor) }
    }
}

@MainActor
private final class ReleasesStub {
    var automatic: FeedarrReleasesResponse?
    private(set) var calls: [String?] = []
    private(set) var cancelled: Set<Int> = []
    private var pending: [Int: CheckedContinuation<FeedarrReleasesResponse, Error>] = [:]
    func load(_ cursor: String?) async throws -> FeedarrReleasesResponse {
        let index = calls.count
        calls.append(cursor)
        defer { if Task.isCancelled { cancelled.insert(index) } }
        if let automatic { return automatic }
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func succeed(_ index: Int, page: FeedarrReleasesResponse) { pending.removeValue(forKey: index)?.resume(returning: page) }
    func fail(_ index: Int, error: FeedarrAPIError) { pending.removeValue(forKey: index)?.resume(throwing: error) }
}

@MainActor
private final class ReleasesPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor
private final class ReleasesCredentials: FeedarrCredentialsStoring {
    var value: FeedarrCredentials?
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { value }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { value = credentials }
    func deleteCredentials(for sourceID: UUID) throws { value = nil }
}

private actor ReleasesHTTPTransport: FeedarrHTTPTransport {
    static let opaque = " opaque+/=%é? "
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let page = try requests.count == 1 ? releasesPage([1], next: Self.opaque) : releasesPage([2])
        return (try JSONEncoder().encode(page), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
