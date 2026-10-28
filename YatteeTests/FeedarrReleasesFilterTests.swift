//
//  FeedarrReleasesFilterTests.swift
//  Yattee
//
//  Focused filter contracts, cursor resets and stale-response protection.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Releases Filters")
@MainActor
struct FeedarrReleasesFilterTests {
    @Test func apiParametersAndPaginationPreserveQuery() async throws {
        let fixture = try FilterFixture()
        let transport = FilterTransport()
        let client = FeedarrAPIClient(sources: fixture.manager, credentialsStore: fixture.credentials, transport: transport)
        let model = FeedarrReleasesModel(sources: fixture.manager, debounce: {}) { query, cursor, sort, category in
            try await client.releases(limit: 50, sort: sort, q: query, unifiedCategory: category?.rawValue, cursor: cursor)
        }
        model.selectSort(.seeders)
        model.selectCategory(.films)
        model.updateSearchText("  été + 4K  ")
        model.setVisible(true)
        try await wait { model.hasLoadedInitial }
        model.loadNextPage()
        try await wait { model.isAtEnd }
        let requests = await transport.requests
        #expect(requests.count == 2)
        for (index, request) in requests.enumerated() {
            let url = try #require(request.url)
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.first { $0.name == "limit" }?.value == "50")
            #expect(items.first { $0.name == "sort" }?.value == "seeders")
            #expect(items.first { $0.name == "q" }?.value == "été + 4K")
            #expect(items.first { $0.name == "unifiedCategory" }?.value == "films")
            #expect(items.first { $0.name == "cursor" }?.value == (index == 0 ? nil : "opaque+/="))
        }
    }

    @Test func defaultsSameSelectionAndSegmentsDoNotReload() async throws {
        let fixture = try FilterFixture()
        let transport = FilterTransport()
        let client = FeedarrAPIClient(sources: fixture.manager, credentialsStore: fixture.credentials, transport: transport)
        let model = FeedarrReleasesModel(sources: fixture.manager) { query, cursor, sort, category in
            try await client.releases(limit: 50, sort: sort, q: query, unifiedCategory: category?.rawValue, cursor: cursor)
        }
        #expect(model.selectedSort == .date && model.selectedCategory == nil && !model.hasActiveFilters)
        model.setVisible(true)
        try await wait { model.hasLoadedInitial }
        let initial = model.catalogGeneration
        model.selectSort(.date)
        model.selectCategory(nil)
        #expect(model.catalogGeneration == initial)
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.first?.url?.query == "limit=50&sort=date")
        model.setVisible(false)
        model.selectSort(.grabs)
        model.selectCategory(.series)
        #expect(await transport.requests.count == 1)
        model.setVisible(true)
        try await wait { model.hasLoadedInitial }
        let filtered = model.catalogGeneration
        model.setVisible(false)
        model.setVisible(true)
        #expect(model.selectedSort == .grabs && model.selectedCategory == .series && model.hasActiveFilters)
        #expect(model.catalogGeneration == filtered)
        #expect(await transport.requests.count == 2)
    }

    @Test func rapidChangesResetCursorAndRejectLatePages() async throws {
        let fixture = try FilterFixture()
        let stub = FilterStub()
        let model = FeedarrReleasesModel(sources: fixture.manager, debounce: {}) { query, cursor, sort, category in
            try await stub.load(FilterCall(query: query, cursor: cursor, sort: sort, category: category))
        }
        model.updateSearchText("term")
        model.setVisible(true)
        try await wait { stub.calls.count == 1 }
        stub.finish(0, page: try filterPage([1], next: "old"))
        try await wait { model.hasLoadedInitial }
        model.loadNextPage()
        try await wait { stub.calls.count == 2 }
        model.selectSort(.score)
        #expect(model.items.isEmpty && model.nextCursor == nil && model.query == "term")
        try await wait { stub.calls.count == 3 }
        model.selectCategory(.games)
        try await wait { stub.calls.count == 4 }
        #expect(stub.calls[2] == FilterCall(query: "term", cursor: nil, sort: .score, category: nil))
        #expect(stub.calls[3] == FilterCall(query: "term", cursor: nil, sort: .score, category: .games))
        stub.finish(3, page: try filterPage([9]))
        try await wait { model.hasLoadedInitial }
        stub.finish(1, page: try filterPage([2]))
        stub.finish(2, page: try filterPage([3]))
        try await wait { stub.cancelled.isSuperset(of: [1, 2]) }
        #expect(model.items.map(\.id) == [9])
        #expect(model.failure == nil && model.isAtEnd)
    }

    @Test func filterFlushesPendingSearchDebounceOnce() async throws {
        let fixture = try FilterFixture()
        let pause = FilterPause()
        var calls: [FilterCall] = []
        let model = FeedarrReleasesModel(sources: fixture.manager, debounce: { await pause.wait() }) { query, cursor, sort, category in
            calls.append(FilterCall(query: query, cursor: cursor, sort: sort, category: category))
            return try filterPage([1])
        }
        model.updateSearchText(" pending ")
        model.setVisible(true)
        try await wait { await pause.started }
        #expect(calls.isEmpty)
        model.selectSort(.grabs)
        try await wait { model.hasLoadedInitial }
        await pause.release()
        await Task.yield()
        #expect(calls == [FilterCall(query: "pending", cursor: nil, sort: .grabs, category: nil)])
        #expect(!model.isDebouncing)
    }

    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Releases filters", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
}

private struct FilterCall: Equatable, Sendable {
    let query: String?
    let cursor: String?
    let sort: FeedarrReleasesSort
    let category: FeedarrTopCategory?
}

private func filterPage(_ ids: [Int64], next: String? = nil) throws -> FeedarrReleasesResponse {
    let items = try ids.map { try JSONDecoder().decode(FeedarrRelease.self, from: Data("{\"id\":\($0),\"sourceId\":1}".utf8)) }
    return FeedarrReleasesResponse(items: items, pagination: FeedarrPagination(limit: 50, hasMore: next != nil, nextCursor: next, snapshotMaxId: 100), query: nil)
}

@MainActor
private struct FilterFixture {
    let credentials = FilterCredentials()
    let manager: FeedarrSourcesManager
    init() throws {
        manager = FeedarrSourcesManager(persistence: FilterPersistence(), credentialsStore: credentials)
        try manager.add(name: "Test", serverURL: "https://feedarr.invalid", usesBasicAuth: false)
    }
}

@MainActor
private final class FilterStub {
    private(set) var calls: [FilterCall] = []
    private(set) var cancelled: Set<Int> = []
    private var pending: [Int: CheckedContinuation<FeedarrReleasesResponse, Never>] = [:]
    func load(_ call: FilterCall) async throws -> FeedarrReleasesResponse {
        let index = calls.count
        calls.append(call)
        defer { if Task.isCancelled { cancelled.insert(index) } }
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, page: FeedarrReleasesResponse) { pending.removeValue(forKey: index)?.resume(returning: page) }
}

private actor FilterPause {
    private(set) var started = false
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
}

@MainActor
private final class FilterPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor
private final class FilterCredentials: FeedarrCredentialsStoring {
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { nil }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws {}
    func deleteCredentials(for sourceID: UUID) throws {}
}

private actor FilterTransport: FeedarrHTTPTransport {
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let page = try filterPage([Int64(requests.count)], next: requests.count == 1 ? "opaque+/=" : nil)
        return (try JSONEncoder().encode(page), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
