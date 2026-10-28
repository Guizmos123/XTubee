//
//  FeedarrReleasesSearchTests.swift
//  Yattee
//
//  Controlled debounce and search pagination; no live services.
//

import Foundation
import SwiftUI
import Testing
#if os(iOS)
import UIKit
#endif
@testable import XTubee

@Suite("Feedarr Releases Search")
@MainActor
struct FeedarrReleasesSearchTests {
    @Test func debounceCoalescesAndNormalizes() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText(" first ")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        #expect(fixture.api.calls.isEmpty)
        fixture.model.updateSearchText(" \nfinal query  ")
        try await wait { await fixture.pause.count == 2 }
        #expect(fixture.model.items.isEmpty && fixture.model.isDebouncing)
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls == [SearchCall(query: "final query", cursor: nil)])
        #expect(!fixture.model.isDebouncing)
    }

    @Test func equivalentTextNeitherRestartsDebounceNorReloads() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText("query")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        fixture.model.updateSearchText(" query\n")
        #expect(await fixture.pause.count == 1)
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        let identity = fixture.model.catalogGeneration
        fixture.model.updateSearchText("  query  ")
        #expect(fixture.api.calls.count == 1)
        #expect(fixture.model.catalogGeneration == identity)
        #expect(!fixture.model.isDebouncing)
    }

    @Test func whitespaceOnlyLoadsGlobalCatalogueWithoutDebounce() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText(" \n\t ")
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls == [SearchCall(query: nil, cursor: nil)])
        #expect(await fixture.pause.count == 0)
    }

    @Test func changingQueryClearsOldResultsAndCursorImmediately() async throws {
        let fixture = try SearchFixture()
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.model.nextCursor == "opaque-next")
        fixture.model.updateSearchText("new")
        #expect(fixture.model.items.isEmpty)
        #expect(fixture.model.nextCursor == nil && !fixture.model.hasLoadedInitial)
        #expect(fixture.model.isDebouncing)
        fixture.model.loadNextPage()
        try await wait { await fixture.pause.count == 1 }
        #expect(fixture.api.calls.count == 1)
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls.last == SearchCall(query: "new", cursor: nil))
    }

    @Test func paginationAndRefreshKeepExactQuery() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText("  été + 4K  ")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        fixture.api.response = try searchPage([1, 2])
        fixture.model.loadNextPage()
        try await wait { fixture.model.isAtEnd }
        #expect(fixture.api.calls == [SearchCall(query: "été + 4K", cursor: nil), SearchCall(query: "été + 4K", cursor: "opaque-next")])
        #expect(fixture.model.items.map(\.id) == [1, 2])
        await fixture.model.refresh()
        #expect(fixture.api.calls.last == SearchCall(query: "été + 4K", cursor: nil))
    }

    @Test func clearingSearchRestoresGlobalCatalogue() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText("film")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        fixture.model.updateSearchText("")
        #expect(fixture.model.query == nil && fixture.model.items.isEmpty)
        try await wait { await fixture.pause.count == 2 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls.last == SearchCall(query: nil, cursor: nil))
    }

    @Test func lateSearchResponseCannotOverwriteNewSearch() async throws {
        let fixture = try SearchFixture()
        fixture.api.manual = true
        fixture.model.updateSearchText("old")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        await fixture.pause.releaseAll()
        try await wait { fixture.api.calls.count == 1 }
        fixture.model.updateSearchText("new")
        try await wait { await fixture.pause.count == 2 }
        await fixture.pause.releaseAll()
        try await wait { fixture.api.calls.count == 2 }
        fixture.api.finish(1, with: try searchPage([9]))
        try await wait { fixture.model.hasLoadedInitial }
        fixture.api.finish(0, with: try searchPage([1], next: "old-cursor"))
        try await wait { fixture.api.cancelled.contains(0) }
        #expect(fixture.model.items.map(\.id) == [9])
        #expect(fixture.model.query == "new" && fixture.model.isAtEnd)
    }

    @Test func segmentsPreserveTextResultsAndScrollIdentity() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText(" film ")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        let identity = fixture.model.catalogGeneration
        fixture.model.setVisible(false)
        fixture.model.setVisible(true)
        #expect(fixture.model.searchText == " film ")
        #expect(fixture.model.query == "film")
        #expect(fixture.model.items.map(\.id) == [1])
        #expect(fixture.model.catalogGeneration == identity)
        #expect(fixture.api.calls.count == 1)
    }

    @Test func debounceCompletingWhileHiddenDoesNotLoadUntilReturn() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText("hidden")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        fixture.model.setVisible(false)
        await fixture.pause.releaseAll()
        try await wait { !fixture.model.isDebouncing }
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setVisible(true)
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls == [SearchCall(query: "hidden", cursor: nil)])
    }

    @Test func noSearchNetworkWithoutSource() async throws {
        let fixture = try SearchFixture(configured: false)
        fixture.model.updateSearchText("no server")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        await fixture.pause.releaseAll()
        try await wait { !fixture.model.isDebouncing }
        await fixture.model.refresh()
        #expect(fixture.api.calls.isEmpty)
    }

    @Test func refreshFlushesDebounceWithoutDuplicateRequest() async throws {
        let fixture = try SearchFixture()
        fixture.model.updateSearchText("refresh now")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        await fixture.model.refresh()
        #expect(fixture.model.hasLoadedInitial)
        await fixture.pause.releaseAll()
        await Task.yield()
        #expect(fixture.api.calls == [SearchCall(query: "refresh now", cursor: nil)])
        #expect(!fixture.model.isDebouncing)
    }

    @Test func emptySearchAndRetryRetainCurrentQuery() async throws {
        let fixture = try SearchFixture()
        fixture.api.error = .transport(.networkUnavailable)
        fixture.model.updateSearchText("absent")
        fixture.model.setVisible(true)
        try await wait { await fixture.pause.count == 1 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.failure != nil }
        #expect(fixture.model.failure == .offline)
        fixture.api.error = nil
        fixture.api.response = try searchPage([])
        fixture.model.retry()
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.model.isEmpty && fixture.model.query == "absent")
        #expect(fixture.api.calls == [SearchCall(query: "absent", cursor: nil), SearchCall(query: "absent", cursor: nil)])
    }

    #if os(iOS)
    @Test func nativeSearchOpensFocusesCancelsAndPreservesQueryAcrossSegments() async throws {
        let fixture = try SearchFixture()
        fixture.api.response = try searchPage([1])
        let visibility = SearchVisibility()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedarrSearchUI-" + UUID().uuidString)
        let posters = FeedarrPosterService(sources: fixture.manager, credentialsStore: fixture.credentials,
                                          transport: NoSearchPosterTransport(), cacheDirectory: directory)
        let host = UIHostingController(rootView: SearchTestHost(model: fixture.model, posters: posters, visibility: visibility))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKey()
            try? FileManager.default.removeItem(at: directory)
        }
        host.view.layoutIfNeeded()
        try await wait { fixture.model.hasLoadedInitial }
        #expect(textField(in: window) == nil)
        fixture.model.updateSearchText("kept")
        try await wait { await fixture.pause.count == 1 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.query == "kept" && fixture.model.hasLoadedInitial }
        let identity = fixture.model.catalogGeneration
        let calls = fixture.api.calls.count
        visibility.searchPresented = true
        try await wait { textField(in: window)?.isFirstResponder == true }
        let originalField = try #require(textField(in: window))
        #expect(originalField.text == "kept")
        // Cancel changes only presentation; it never changes the model's search binding.
        visibility.searchPresented = false
        try await wait { textField(in: window) == nil && !originalField.isFirstResponder }
        #expect(fixture.model.searchText == "kept" && fixture.model.query == "kept")
        #expect(fixture.model.catalogGeneration == identity && fixture.api.calls.count == calls)

        visibility.searchPresented = true
        try await wait { textField(in: window)?.isFirstResponder == true }
        let field = try #require(textField(in: window))
        fixture.model.updateSearchText("") // Same action as the explicit clear button.
        try await wait { fixture.model.query == nil && fixture.model.isDebouncing }
        try await wait { await fixture.pause.count == 2 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.hasLoadedInitial }
        #expect(fixture.api.calls.last?.query == nil)
        try await wait { field.text == "" }
        #expect(field.isFirstResponder)

        fixture.model.updateSearchText("again")
        try await wait { await fixture.pause.count == 3 }
        await fixture.pause.releaseAll()
        try await wait { fixture.model.query == "again" && fixture.model.hasLoadedInitial }
        let segmentIdentity = fixture.model.catalogGeneration
        visibility.visible = false
        try await wait { textField(in: window) == nil }
        #expect(!visibility.searchPresented && !field.isFirstResponder)
        #expect(fixture.model.searchText == "again")
        visibility.visible = true
        await Task.yield()
        #expect(textField(in: window) == nil)
        #expect(fixture.model.searchText == "again" && fixture.model.catalogGeneration == segmentIdentity)
        visibility.searchPresented = true
        try await wait { textField(in: window)?.isFirstResponder == true }
        #expect(textField(in: window)?.text == "again")
    }

    private func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        return view.subviews.compactMap { textField(in: $0) }.first
    }

    #endif

    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<250 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Releases search state", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
}

private struct SearchCall: Equatable, Sendable { let query: String?; let cursor: String? }

@MainActor
private struct SearchFixture {
    let credentials = SearchCredentials()
    let manager: FeedarrSourcesManager
    let api: SearchStub
    let model: FeedarrReleasesModel
    let pause = SearchDebounce()
    init(configured: Bool = true) throws {
        manager = FeedarrSourcesManager(persistence: SearchPersistence(), credentialsStore: credentials)
        if configured { try manager.add(name: "Test", serverURL: "https://feedarr.invalid", usesBasicAuth: false) }
        api = SearchStub(response: try searchPage([1], next: "opaque-next"))
        let gate = pause, stub = api
        model = FeedarrReleasesModel(sources: manager, debounce: { await gate.wait() }) { query, cursor, _, _ in
            try await stub.load(query: query, cursor: cursor)
        }
    }
}

private func searchPage(_ ids: [Int64], next: String? = nil) throws -> FeedarrReleasesResponse {
    let items = try ids.map { try JSONDecoder().decode(FeedarrRelease.self, from: Data("{\"id\":\($0),\"sourceId\":1}".utf8)) }
    return FeedarrReleasesResponse(items: items, pagination: FeedarrPagination(limit: 50, hasMore: next != nil, nextCursor: next, snapshotMaxId: 100), query: nil)
}

private actor SearchDebounce {
    private(set) var count = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { count += 1; await withCheckedContinuation { waiting.append($0) } }
    func releaseAll() { let current = waiting; waiting = []; current.forEach { $0.resume() } }
}

@MainActor
private final class SearchStub {
    var response: FeedarrReleasesResponse
    var manual = false
    var error: FeedarrAPIError?
    private(set) var calls: [SearchCall] = []
    private(set) var cancelled: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<FeedarrReleasesResponse, Error>] = [:]
    init(response: FeedarrReleasesResponse) { self.response = response }
    func load(query: String?, cursor: String?) async throws -> FeedarrReleasesResponse {
        let index = calls.count
        calls.append(SearchCall(query: query, cursor: cursor))
        defer { if Task.isCancelled { cancelled.insert(index) } }
        if let error { throw error }
        if !manual { return response }
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }
    func finish(_ index: Int, with response: FeedarrReleasesResponse) { waiting.removeValue(forKey: index)?.resume(returning: response) }
}

@MainActor
private final class SearchPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor
private final class SearchCredentials: FeedarrCredentialsStoring {
    var value: FeedarrCredentials?
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { value }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { value = credentials }
    func deleteCredentials(for sourceID: UUID) throws { value = nil }
}

#if os(iOS)
@MainActor @Observable
private final class SearchVisibility { var visible = true; var searchPresented = false }

private struct SearchTestHost: View {
    let model: FeedarrReleasesModel
    let posters: FeedarrPosterService
    let visibility: SearchVisibility
    var body: some View {
        NavigationStack {
            FeedarrReleasesView(model: model, posterService: posters, isVisible: visibility.visible,
                                isSearchPresented: Binding(get: { visibility.searchPresented }, set: { visibility.searchPresented = $0 }))
                .navigationTitle("Feedarr")
        }
    }
}

private struct NoSearchPosterTransport: FeedarrHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.unsupportedURL) }
}
#endif
