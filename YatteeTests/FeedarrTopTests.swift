//
//  FeedarrTopTests.swift
//  Yattee
//
//  Top page lifecycle and ranking tests with controlled API responses.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Top")
@MainActor
struct FeedarrTopTests {
    @Test func oneRequestAndFixedRails() async throws {
        let fixture = try TopFixture()
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        #expect(fixture.api.calls == [.score])
        #expect(fixture.model.rails.map(\.id) == [.global, .category(.films), .category(.series), .category(.emissions), .category(.games), .category(.animation), .category(.spectacle)])
        #expect(fixture.model.rails.map(\.count) == [nil, 100, 30, 4, 8, 6, 2])
        #expect(fixture.model.rails[0].items.count == 5)
        #expect(fixture.model.rails[1].items.count == 1) // Count 100 is not take or grabs.
    }

    @Test func realAPIClientUsesSingleTopEndpoint() async throws {
        let fixture = try TopFixture()
        let transport = TopHTTPTransport()
        let api = FeedarrAPIClient(sources: fixture.manager, credentialsStore: fixture.credentials, transport: transport)
        let model = FeedarrTopModel(sources: fixture.manager) { sort in
            try await api.top(hours: 24, take: 5, perCategoryTake: 5, sort: sort)
        }
        model.setVisible(true)
        try await waitUntil { model.response != nil }
        #expect(model.rails.count == 7)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://feedarr.invalid/base/api/feed/top?hours=24&take=5&perCategoryTake=5&sort=score")
    }

    @Test func absentAndEmptyCategoriesHaveNoInventedCountsOrItems() async throws {
        let base = try decode(FeedarrDTOFixtures.sparseTop)
        let response = FeedarrTopResponse(window: base.window, takeUsed: base.takeUsed, perCategoryTakeUsed: base.perCategoryTakeUsed,
                                         sortUsed: base.sortUsed, dedupeUsed: base.dedupeUsed, supportsEntityDedupe: true,
                                         globalTop: [], categories: base.categories + [FeedarrTopCategoryResponse(key: "emissions", label: "Shows", count: 0, top: [])])
        let fixture = try TopFixture(response: response)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        #expect(fixture.model.rails.count == 7)
        #expect(fixture.model.rails[0].count == nil)
        #expect(fixture.model.rails[2].count == nil) // Missing category.
        #expect(fixture.model.rails[3].count == 0) // Explicit server count.
        #expect(fixture.model.rails.dropFirst(2).allSatisfy { $0.items.isEmpty })
        #expect(!fixture.model.isEmpty)
    }

    @Test func entirelyEmptyResponse() async throws {
        let fixture = try TopFixture(response: decode(FeedarrDTOFixtures.emptyTop))
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        #expect(fixture.model.isEmpty)
        #expect(fixture.model.rails.allSatisfy { $0.items.isEmpty && $0.count == nil })
    }

    @Test(arguments: FeedarrTopSort.allCases)
    func sortChangesAreTopSortValues(sort: FeedarrTopSort) async throws {
        let fixture = try TopFixture()
        #expect(fixture.model.selectedSort == .score)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        fixture.model.selectSort(sort)
        try await waitUntil { !fixture.model.isLoading }
        #expect(fixture.model.selectedSort == sort)
        #expect(fixture.api.calls == (sort == .score ? [.score] : [.score, sort]))
    }

    @Test func noLoadUntilVisibleAndNoRepeatedLoadOnReconstruction() async throws {
        let fixture = try TopFixture()
        fixture.model.setVisible(false)
        await fixture.model.refresh()
        fixture.model.selectSort(.grabs)
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setVisible(true)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        fixture.model.setVisible(true)
        #expect(fixture.api.calls == [.grabs])
    }

    @Test func dataSurvivesSegmentSwitches() async throws {
        let fixture = try TopFixture()
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        let data = fixture.model.response
        fixture.model.setVisible(false)
        #expect(fixture.model.response == data)
        fixture.model.setVisible(true)
        #expect(fixture.model.response == data)
        #expect(fixture.api.calls == [.score])
    }

    @Test func pullToRefreshKeepsDataAndReloadsOnce() async throws {
        let fixture = try TopFixture()
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        let old = fixture.model.response
        fixture.api.automatic = nil
        let refresh = Task { await fixture.model.refresh() }
        try await waitUntil { fixture.api.calls.count == 2 }
        #expect(fixture.model.response == old)
        #expect(fixture.model.isLoading)
        fixture.api.finish(1, with: try decode(FeedarrDTOFixtures.sparseTop))
        await refresh.value
        #expect(fixture.api.calls.count == 2)
        #expect(fixture.model.response?.globalTop.isEmpty == true)
        #expect(!fixture.model.isLoading)
    }

    @Test func cancelledSortResponseCannotOverwriteLatest() async throws {
        let fixture = try TopFixture(manual: true)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.api.calls.count == 1 }
        fixture.model.selectSort(.recent)
        try await waitUntil { fixture.api.calls.count == 2 }
        let latest = try decode(FeedarrDTOFixtures.sparseTop)
        fixture.api.finish(1, with: latest)
        try await waitUntil { fixture.model.response != nil }
        fixture.api.finish(0, with: try decode(FeedarrDTOFixtures.completeTop))
        try await waitUntil { fixture.api.cancelled.contains(0) }
        #expect(fixture.model.response == latest)
        #expect(fixture.model.failure == nil)
    }

    @Test func leavingTopCancelsAndDiscardsInFlightResponse() async throws {
        let fixture = try TopFixture(manual: true)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.api.calls.count == 1 }
        fixture.model.setVisible(false)
        fixture.api.finish(0, with: try decode(FeedarrDTOFixtures.completeTop))
        try await waitUntil { fixture.api.cancelled.contains(0) }
        #expect(fixture.model.response == nil)
        #expect(!fixture.model.isLoading)
        #expect(fixture.model.failure == nil)
        fixture.api.automatic = try decode(FeedarrDTOFixtures.sparseTop)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        #expect(fixture.api.calls.count == 2)
    }

    @Test func configurationChangeRejectsLateResponseAndReloads() async throws {
        let fixture = try TopFixture(manual: true)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.api.calls.count == 1 }
        try fixture.manager.update(id: fixture.id, name: "New", serverURL: "https://new.invalid/feedarr", usesBasicAuth: false)
        try await waitUntil { fixture.api.calls.count == 2 }
        let latest = try decode(FeedarrDTOFixtures.sparseTop)
        fixture.api.finish(1, with: latest)
        try await waitUntil { fixture.model.response != nil }
        fixture.api.finish(0, with: try decode(FeedarrDTOFixtures.completeTop))
        try await waitUntil { fixture.api.cancelled.contains(0) }
        #expect(fixture.model.response == latest)
    }

    @Test func credentialsOnlyChangeInvalidatesWhileHidden() async throws {
        let fixture = try TopFixture()
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        fixture.model.setVisible(false)
        try fixture.manager.update(id: fixture.id, name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: true, username: "user", password: "new")
        try await waitUntil { fixture.model.response == nil }
        #expect(fixture.api.calls.count == 1)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        #expect(fixture.api.calls.count == 2)
    }

    @Test func removalClearsDataAndPreventsRefresh() async throws {
        let fixture = try TopFixture()
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        try fixture.manager.remove(id: fixture.id)
        try await waitUntil { fixture.model.response == nil }
        await fixture.model.refresh()
        fixture.model.retry()
        #expect(fixture.api.calls.count == 1)
        #expect(!fixture.model.isLoading)
    }

    @Test func noServerMeansNoNetworkAndAdditionWaitsForTopVisibility() async throws {
        let fixture = try TopFixture(configured: false)
        fixture.model.setVisible(true)
        await fixture.model.refresh()
        fixture.model.retry()
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setVisible(false)
        try fixture.manager.add(name: "Test", serverURL: "https://feedarr.invalid", usesBasicAuth: false)
        await Task.yield()
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        #expect(fixture.api.calls.count == 1)
    }

    @Test(arguments: [FeedarrAPIError.transport(.networkUnavailable), .transport(.timeout), .invalidJSON, .http(.unauthorized, problem: nil), .http(.httpStatus(500), problem: nil)])
    func safeFailureAndExplicitRetry(error: FeedarrAPIError) async throws {
        let fixture = try TopFixture()
        fixture.api.error = error
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.failure != nil }
        #expect(fixture.model.failure == FeedarrTopFailure(error))
        fixture.model.setVisible(false)
        fixture.model.setVisible(true)
        #expect(fixture.api.calls.count == 1) // No automatic retry loop on reappearance.
        fixture.api.error = nil
        fixture.model.retry()
        try await waitUntil { fixture.model.response != nil }
        #expect(fixture.model.failure == nil)
        #expect(fixture.api.calls.count == 2)
    }

    @Test func failedRefreshPreservesLastSuccessfulData() async throws {
        let fixture = try TopFixture()
        fixture.model.setVisible(true)
        try await waitUntil { fixture.model.response != nil }
        let old = fixture.model.response
        fixture.api.error = .transport(.networkUnavailable)
        await fixture.model.refresh()
        #expect(fixture.model.failure == .offline)
        #expect(fixture.model.response == old)
    }

    @Test func homeAndHubShareOneRequestAndRetainCache() async throws {
        let fixture = try TopFixture(manual: true)
        let home = UUID(), hub = UUID()
        fixture.model.setConsumer(home, active: true)
        fixture.model.setConsumer(hub, active: true)
        try await waitUntil { fixture.api.calls.count == 1 }
        fixture.model.setConsumer(home, active: false)
        fixture.model.setConsumer(hub, active: false)
        #expect(fixture.model.isLoading)
        fixture.model.setConsumer(hub, active: true)
        let response = try decode(FeedarrDTOFixtures.completeTop)
        fixture.api.finish(0, with: response)
        try await waitUntil { fixture.model.currentResponse != nil }
        fixture.model.setConsumer(hub, active: false)
        fixture.model.setConsumer(home, active: true)
        #expect(fixture.model.currentResponse == response)
        #expect(fixture.api.calls.count == 1)
        fixture.model.setConsumer(home, active: false)
    }

    @Test func sharedConsumersRejectPreviousSourceAndLateResponse() async throws {
        let fixture = try TopFixture(manual: true)
        let home = UUID(), hub = UUID()
        fixture.model.setConsumer(home, active: true)
        fixture.model.setConsumer(hub, active: true)
        try await waitUntil { fixture.api.calls.count == 1 }
        let oldRevision = fixture.model.configurationRevision
        try fixture.manager.update(id: fixture.id, name: "B", serverURL: "https://new.invalid", usesBasicAuth: false)
        #expect(fixture.model.currentResponse == nil)
        try await waitUntil { fixture.api.calls.count == 2 }
        #expect(fixture.model.configurationRevision != oldRevision)
        let current = try decode(FeedarrDTOFixtures.sparseTop)
        fixture.api.finish(1, with: current)
        try await waitUntil { fixture.model.currentResponse != nil }
        fixture.api.finish(0, with: try decode(FeedarrDTOFixtures.completeTop))
        try await waitUntil { fixture.api.cancelled.contains(0) }
        #expect(fixture.model.currentResponse == current)
        fixture.model.setConsumer(home, active: false)
        fixture.model.setConsumer(hub, active: false)
    }

    @Test func sharedHomeDataLoadsOnlyOnDemandWithoutSource() async throws {
        let fixture = try TopFixture(configured: false)
        let consumer = UUID()
        fixture.model.setConsumer(consumer, active: true)
        await Task.yield()
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setConsumer(consumer, active: false)
        try fixture.manager.add(name: "A", serverURL: "https://feedarr.invalid", usesBasicAuth: false)
        await Task.yield()
        #expect(fixture.api.calls.isEmpty)
        fixture.model.setConsumer(consumer, active: true)
        try await waitUntil { fixture.model.currentResponse != nil }
        let response = try #require(fixture.model.currentResponse)
        #expect(FeedarrHomeSection.global.releases(in: response) == response.globalTop)
        #expect(FeedarrHomeSection.films.releases(in: response) == response.category(for: .films)?.top)
        #expect(FeedarrHomeSection.series.releases(in: response) == response.category(for: .series)?.top)
        fixture.model.setConsumer(consumer, active: false)
    }

    private func decode(_ json: String) throws -> FeedarrTopResponse {
        try JSONDecoder().decode(FeedarrTopResponse.self, from: Data(json.utf8))
    }

    private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Top state", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
}

@MainActor
private struct TopFixture {
    let credentials = TopCredentials()
    let manager: FeedarrSourcesManager
    let api: TopStub
    let model: FeedarrTopModel
    let id: UUID
    init(configured: Bool = true, manual: Bool = false, response: FeedarrTopResponse? = nil) throws {
        manager = FeedarrSourcesManager(persistence: TopPersistence(), credentialsStore: credentials)
        id = configured ? try manager.add(name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: false).id : UUID()
        let initial = try response ?? JSONDecoder().decode(FeedarrTopResponse.self, from: Data(FeedarrDTOFixtures.completeTop.utf8))
        api = TopStub(automatic: manual ? nil : initial)
        let stub = api
        model = FeedarrTopModel(sources: manager) { try await stub.load($0) }
    }
}

@MainActor
private final class TopStub {
    var automatic: FeedarrTopResponse?
    var error: FeedarrAPIError?
    private(set) var calls: [FeedarrTopSort] = []
    private(set) var cancelled: Set<Int> = []
    private var pending: [Int: CheckedContinuation<FeedarrTopResponse, Error>] = [:]
    init(automatic: FeedarrTopResponse?) { self.automatic = automatic }
    func load(_ sort: FeedarrTopSort) async throws -> FeedarrTopResponse {
        let index = calls.count
        calls.append(sort)
        if let error { throw error }
        if let automatic { return automatic }
        let response: FeedarrTopResponse = try await withCheckedThrowingContinuation { pending[index] = $0 }
        if Task.isCancelled { cancelled.insert(index) }
        return response
    }
    func finish(_ index: Int, with response: FeedarrTopResponse) { pending.removeValue(forKey: index)?.resume(returning: response) }
}

@MainActor
private final class TopPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor
private final class TopCredentials: FeedarrCredentialsStoring {
    var value: FeedarrCredentials?
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { value }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { value = credentials }
    func deleteCredentials(for sourceID: UUID) throws { value = nil }
}

private actor TopHTTPTransport: FeedarrHTTPTransport {
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(FeedarrDTOFixtures.completeTop.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
