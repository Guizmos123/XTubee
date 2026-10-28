//
//  IPTVLiveCatalogSyncServiceTests.swift
//  YatteeTests
//
//  Tests for local Xtream live catalog caching and synchronization.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Live Catalog Sync Service Tests")
@MainActor
struct IPTVLiveCatalogSyncServiceTests {
    @Test("Fresh cache is available immediately without a network request")
    func freshCacheAvoidsNetwork() async throws {
        let fixture = try makeFixture()
        let cached = try makeCatalog(sourceID: fixture.source.id, updatedAt: fixture.now.addingTimeInterval(-60))
        await fixture.catalogPersistence.seed(cached)
        let calls = CatalogRequestCounter()
        let service = makeService(fixture: fixture, calls: calls)

        #expect(await service.loadCachedCatalog(sourceID: fixture.source.id) == cached)
        await service.synchronizeIfNeeded(sourceID: fixture.source.id)
        let categoryCount = await calls.categoryCount
        let streamCount = await calls.streamCount

        #expect(service.state(for: fixture.source.id).catalog == cached)
        #expect(categoryCount == 0)
        #expect(streamCount == 0)
    }

    @Test("A stale cache is atomically replaced after both requests succeed")
    func staleCacheRefreshesAtomically() async throws {
        let fixture = try makeFixture()
        let oldCatalog = try makeCatalog(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-(25 * 60 * 60)),
            suffix: "old"
        )
        await fixture.catalogPersistence.seed(oldCatalog)
        let calls = CatalogRequestCounter()
        let service = makeService(fixture: fixture, calls: calls)

        await service.synchronizeIfNeeded(sourceID: fixture.source.id)
        let categoryCount = await calls.categoryCount
        let streamCount = await calls.streamCount

        let result = try #require(service.state(for: fixture.source.id).catalog)
        #expect(result.categories.map(\.categoryID) == ["new-category"])
        #expect(result.streams.map(\.streamID) == ["new-stream"])
        #expect(result.lastUpdated == fixture.now)
        #expect(await fixture.catalogPersistence.catalog(for: fixture.source.id) == result)
        #expect(categoryCount == 1)
        #expect(streamCount == 1)
    }

    @Test("Manual refresh bypasses a fresh cache")
    func manualRefreshIsForced() async throws {
        let fixture = try makeFixture()
        await fixture.catalogPersistence.seed(try makeCatalog(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-60),
            suffix: "cached"
        ))
        let calls = CatalogRequestCounter()
        let service = makeService(fixture: fixture, calls: calls)

        await service.refresh(sourceID: fixture.source.id)
        let categoryCount = await calls.categoryCount
        let streamCount = await calls.streamCount

        #expect(categoryCount == 1)
        #expect(streamCount == 1)
        #expect(service.state(for: fixture.source.id).catalog?.categories.first?.categoryID == "new-category")
    }

    @Test("A failed endpoint preserves the complete previous catalog")
    func partialNetworkFailurePreservesCache() async throws {
        let fixture = try makeFixture()
        let cached = try makeCatalog(sourceID: fixture.source.id, updatedAt: fixture.now.addingTimeInterval(-100_000))
        await fixture.catalogPersistence.seed(cached)
        let currentDate = fixture.now
        let service = IPTVLiveCatalogSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.catalogPersistence,
            now: { currentDate },
            fetchCategories: { _, _, _ in try Self.categories(suffix: "new") },
            fetchStreams: { _, _, _ in throw XtreamClientError.transportFailure }
        )

        await service.refresh(sourceID: fixture.source.id)

        let state = service.state(for: fixture.source.id)
        #expect(state.catalog == cached)
        #expect(state.lastError == .refreshFailed)
        #expect(await fixture.catalogPersistence.currentSaveCount() == 0)
    }

    @Test("A cache write failure does not publish a partially replaced catalog")
    func cacheWriteFailurePreservesPreviousCatalog() async throws {
        let fixture = try makeFixture()
        let cached = try makeCatalog(sourceID: fixture.source.id, updatedAt: fixture.now.addingTimeInterval(-100_000))
        await fixture.catalogPersistence.seed(cached)
        await fixture.catalogPersistence.setFailSave(true)
        let service = makeService(fixture: fixture, calls: CatalogRequestCounter())

        await service.refresh(sourceID: fixture.source.id)

        let state = service.state(for: fixture.source.id)
        #expect(state.catalog == cached)
        #expect(state.lastError == .cacheWriteFailed)
        #expect(await fixture.catalogPersistence.catalog(for: fixture.source.id) == cached)
    }

    @Test("A cache read failure is published without starting the network")
    func cacheReadFailureIsPublished() async throws {
        let fixture = try makeFixture()
        await fixture.catalogPersistence.setFailLoad(true)
        let service = makeService(fixture: fixture, calls: CatalogRequestCounter())

        #expect(await service.loadCachedCatalog(sourceID: fixture.source.id) == nil)
        #expect(service.state(for: fixture.source.id).lastError == .cacheReadFailed)
    }

    @Test("A refreshed catalog is published only after persistence completes")
    func persistenceCompletesBeforePublication() async throws {
        let fixture = try makeFixture()
        let cached = try makeCatalog(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000)
        )
        await fixture.catalogPersistence.seed(cached)
        let saveStarted = AsyncSignal()
        let allowSave = AsyncSignal()
        await fixture.catalogPersistence.setSaveGate(started: saveStarted, release: allowSave)
        let service = makeService(fixture: fixture, calls: CatalogRequestCounter())

        let refreshTask = Task { await service.refresh(sourceID: fixture.source.id) }
        await saveStarted.wait()

        #expect(service.state(for: fixture.source.id).catalog == cached)
        #expect(service.state(for: fixture.source.id).loadingState == .refreshing)

        await allowSave.signal()
        await refreshTask.value

        #expect(service.state(for: fixture.source.id).catalog?.categories.first?.categoryID == "new-category")
        #expect(service.state(for: fixture.source.id).loadingState == .idle)
    }

    @Test("Cancellation during persistence never publishes an obsolete catalog")
    func cancellationDuringPersistenceDoesNotPublish() async throws {
        let fixture = try makeFixture()
        let cached = try makeCatalog(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000)
        )
        await fixture.catalogPersistence.seed(cached)
        let saveStarted = AsyncSignal()
        let allowSave = AsyncSignal()
        await fixture.catalogPersistence.setSaveGate(started: saveStarted, release: allowSave)
        let service = makeService(fixture: fixture, calls: CatalogRequestCounter())
        service.selectSource(fixture.source.id)

        let refreshTask = Task { await service.refresh(sourceID: fixture.source.id) }
        await saveStarted.wait()
        service.selectSource(UUID())
        await allowSave.signal()
        await refreshTask.value

        #expect(service.state(for: fixture.source.id).catalog == cached)
        #expect(service.state(for: fixture.source.id).loadingState == .idle)
        #expect(await fixture.catalogPersistence.currentSaveCount() == 1)
    }

    @Test("Concurrent refreshes share one synchronization per source")
    func concurrentRefreshesAreCoalesced() async throws {
        let fixture = try makeFixture()
        let calls = CatalogRequestCounter()
        let service = makeService(fixture: fixture, calls: calls, delay: .milliseconds(20))

        async let first: Void = service.refresh(sourceID: fixture.source.id)
        async let second: Void = service.refresh(sourceID: fixture.source.id)
        _ = await (first, second)
        let categoryCount = await calls.categoryCount
        let streamCount = await calls.streamCount

        #expect(categoryCount == 1)
        #expect(streamCount == 1)
        #expect(await fixture.catalogPersistence.currentSaveCount() == 1)
    }

    @Test("Changing the selected source cancels obsolete work and retains its cache")
    func sourceChangeCancelsPreviousSynchronization() async throws {
        let fixture = try makeFixture()
        let cached = try makeCatalog(sourceID: fixture.source.id, updatedAt: fixture.now.addingTimeInterval(-100_000))
        await fixture.catalogPersistence.seed(cached)
        let started = AsyncSignal()
        let currentDate = fixture.now
        let sourceID = fixture.source.id
        let service = IPTVLiveCatalogSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.catalogPersistence,
            now: { currentDate },
            fetchCategories: { _, _, _ in
                await started.signal()
                try await Task.sleep(for: .seconds(30))
                return try Self.categories(suffix: "late")
            },
            fetchStreams: { _, _, _ in
                try await Task.sleep(for: .seconds(30))
                return try Self.streams(suffix: "late")
            }
        )

        service.selectSource(sourceID)
        let refreshTask = Task { await service.refresh(sourceID: sourceID) }
        await started.wait()
        service.selectSource(UUID())
        await refreshTask.value

        #expect(service.state(for: sourceID).catalog == cached)
        #expect(service.state(for: sourceID).loadingState == .idle)
        #expect(await fixture.catalogPersistence.currentSaveCount() == 0)
    }

    @Test("Deleting a source during synchronization cannot recreate its cache")
    func sourceDeletionPreventsLateCacheWrite() async throws {
        let fixture = try makeFixture()
        await fixture.catalogPersistence.seed(
            try makeCatalog(sourceID: fixture.source.id, updatedAt: fixture.now)
        )
        let started = AsyncSignal()
        let release = AsyncSignal()
        let currentDate = fixture.now
        let service = IPTVLiveCatalogSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.catalogPersistence,
            now: { currentDate },
            fetchCategories: { _, _, _ in
                await started.signal()
                await release.wait()
                return try Self.categories(suffix: "late")
            },
            fetchStreams: { _, _, _ in
                return try Self.streams(suffix: "late")
            }
        )
        fixture.sourcesManager.setDataCleaner(
            CatalogPersistenceCleaner(persistence: fixture.catalogPersistence)
        )

        let refreshTask = Task { await service.refresh(sourceID: fixture.source.id) }
        await started.wait()
        try await fixture.sourcesManager.remove(id: fixture.source.id)
        await release.signal()
        await refreshTask.value

        #expect(await fixture.catalogPersistence.catalog(for: fixture.source.id) == nil)
        #expect(await fixture.catalogPersistence.currentSaveCount() == 0)
    }

    @Test("Cached payload contains neither credentials nor a server URL")
    func cachedPayloadContainsNoSecrets() throws {
        let sourceID = UUID()
        let catalog = try makeCatalog(sourceID: sourceID, updatedAt: Date())
        let encoded = try JSONEncoder().encode(catalog)
        let payload = String(decoding: encoded, as: UTF8.self)

        #expect(!payload.contains("fictional-user"))
        #expect(!payload.contains("fictional-password"))
        #expect(!payload.contains("server.invalid"))
        #expect(try JSONDecoder().decode(IPTVLiveCatalog.self, from: encoded) == catalog)
    }

    private func makeService(
        fixture: Fixture,
        calls: CatalogRequestCounter,
        delay: Duration? = nil
    ) -> IPTVLiveCatalogSyncService {
        let currentDate = fixture.now
        return IPTVLiveCatalogSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.catalogPersistence,
            now: { currentDate },
            fetchCategories: { _, _, _ in
                await calls.recordCategories()
                if let delay { try await Task.sleep(for: delay) }
                return try Self.categories(suffix: "new")
            },
            fetchStreams: { _, _, _ in
                await calls.recordStreams()
                if let delay { try await Task.sleep(for: delay) }
                return try Self.streams(suffix: "new")
            }
        )
    }

    private func makeFixture() throws -> Fixture {
        let sourcePersistence = SyncMockSourcesPersistence()
        let credentialsStore = SyncMockCredentialsStore()
        let sourcesManager = IPTVSourcesManager(
            persistence: sourcePersistence,
            credentialsStore: credentialsStore
        )
        let source = try sourcesManager.add(
            name: "Test",
            serverURL: "https://server.invalid",
            username: "fictional-user",
            password: "fictional-password"
        )
        return Fixture(
            now: Date(timeIntervalSince1970: 1_800_000_000),
            source: source,
            sourcesManager: sourcesManager,
            credentialsStore: credentialsStore,
            catalogPersistence: SyncMockCatalogPersistence()
        )
    }

    private func makeCatalog(
        sourceID: UUID,
        updatedAt: Date,
        suffix: String = "cached"
    ) throws -> IPTVLiveCatalog {
        IPTVLiveCatalog(
            sourceID: sourceID,
            categories: try Self.categories(suffix: suffix),
            streams: try Self.streams(suffix: suffix),
            lastUpdated: updatedAt
        )
    }

    nonisolated private static func categories(suffix: String) throws -> [XtreamLiveCategory] {
        try JSONDecoder().decode(
            [XtreamLiveCategory].self,
            from: Data(#"[{"category_id":"\#(suffix)-category","category_name":"Category"}]"#.utf8)
        )
    }

    nonisolated private static func streams(suffix: String) throws -> [XtreamLiveStream] {
        try JSONDecoder().decode(
            [XtreamLiveStream].self,
            from: Data(#"[{"stream_id":"\#(suffix)-stream","name":"Channel","added":"1700000000"}]"#.utf8)
        )
    }
}

private struct Fixture {
    let now: Date
    let source: IPTVSource
    let sourcesManager: IPTVSourcesManager
    let credentialsStore: SyncMockCredentialsStore
    let catalogPersistence: SyncMockCatalogPersistence
}

private actor SyncMockCatalogPersistence: IPTVLiveCatalogPersisting {
    var catalogs: [UUID: IPTVLiveCatalog] = [:]
    var saveCount = 0
    var failLoad = false
    var failSave = false
    var saveGate: (started: AsyncSignal, release: AsyncSignal)?

    func load(sourceID: UUID) async throws -> IPTVLiveCatalog? {
        if failLoad { throw IPTVLiveCatalogSyncError.cacheReadFailed }
        return catalogs[sourceID]
    }

    func save(_ catalog: IPTVLiveCatalog) async throws {
        if failSave { throw IPTVLiveCatalogSyncError.cacheWriteFailed }
        if let saveGate {
            await saveGate.started.signal()
            await saveGate.release.wait()
            try Task.checkCancellation()
        }
        saveCount += 1
        catalogs[catalog.sourceID] = catalog
    }

    func remove(sourceID: UUID) async throws {
        catalogs[sourceID] = nil
    }

    func seed(_ catalog: IPTVLiveCatalog) {
        catalogs[catalog.sourceID] = catalog
    }

    func catalog(for sourceID: UUID) -> IPTVLiveCatalog? {
        catalogs[sourceID]
    }

    func currentSaveCount() -> Int { saveCount }
    func setFailLoad(_ value: Bool) { failLoad = value }
    func setFailSave(_ value: Bool) { failSave = value }
    func setSaveGate(started: AsyncSignal, release: AsyncSignal) {
        saveGate = (started, release)
    }
}

@MainActor
private final class CatalogPersistenceCleaner: IPTVSourceDataCleaning {
    private let persistence: SyncMockCatalogPersistence

    init(persistence: SyncMockCatalogPersistence) {
        self.persistence = persistence
    }

    func removeData(for sourceID: UUID) async throws {
        try await persistence.remove(sourceID: sourceID)
    }
}

@MainActor
private final class SyncMockSourcesPersistence: IPTVSourcesPersisting {
    var sources: [IPTVSource] = []
    var activeSourceID: UUID?

    func loadSources() throws -> [IPTVSource] { sources }
    func loadActiveSourceID() throws -> UUID? { activeSourceID }
    func saveSources(_ sources: [IPTVSource]) throws { self.sources = sources }
    func saveActiveSourceID(_ sourceID: UUID?) throws { activeSourceID = sourceID }
}

@MainActor
private final class SyncMockCredentialsStore: XtreamCredentialsStoring {
    var credentialsBySourceID: [UUID: XtreamCredentials] = [:]

    func credentials(for sourceID: UUID) throws -> XtreamCredentials? {
        credentialsBySourceID[sourceID]
    }

    func setCredentials(_ credentials: XtreamCredentials, for sourceID: UUID) throws {
        credentialsBySourceID[sourceID] = credentials
    }

    func deleteCredentials(for sourceID: UUID) throws {
        credentialsBySourceID[sourceID] = nil
    }
}

private actor CatalogRequestCounter {
    private(set) var categoryCount = 0
    private(set) var streamCount = 0

    func recordCategories() { categoryCount += 1 }
    func recordStreams() { streamCount += 1 }
}

private actor AsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var wasSignalled = false

    func wait() async {
        if wasSignalled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        wasSignalled = true
        continuation?.resume()
        continuation = nil
    }
}
