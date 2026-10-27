//
//  IPTVEPGSyncServiceTests.swift
//  YatteeTests
//
//  Tests for local XMLTV caching and synchronization.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV EPG Sync Service Tests")
@MainActor
struct IPTVEPGSyncServiceTests {
    @Test("Fresh cache is returned immediately without downloading")
    func freshCacheAvoidsDownload() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-60),
            title: "Cached"
        )
        await fixture.persistence.seed(cached)
        let calls = EPGRequestCounter()
        let service = makeService(fixture: fixture, calls: calls)

        #expect(await service.loadCachedCatalog(sourceID: fixture.source.id) == cached.catalog)
        await service.synchronizeIfNeeded(sourceID: fixture.source.id)
        let downloadCount = await calls.downloadCount

        #expect(downloadCount == 0)
        #expect(service.state(for: fixture.source.id).snapshot == cached)
    }

    @Test("Stale cache is replaced only after download, parsing, and persistence succeed")
    func staleCacheRefreshesAtomically() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-(25 * 60 * 60)),
            title: "Old"
        )
        await fixture.persistence.seed(cached)
        let calls = EPGRequestCounter()
        let service = makeService(fixture: fixture, calls: calls, title: "New")

        await service.synchronizeIfNeeded(sourceID: fixture.source.id)

        let result = try #require(service.state(for: fixture.source.id).snapshot)
        let downloadCount = await calls.downloadCount
        let parseCount = await calls.parseCount
        #expect(result.catalog.programsByChannelID.values.flatMap { $0 }.map(\.title) == ["New"])
        #expect(result.lastUpdated == fixture.now)
        #expect(await fixture.persistence.snapshot(for: fixture.source.id) == result)
        #expect(await fixture.persistence.currentSaveCount() == 1)
        #expect(downloadCount == 1)
        #expect(parseCount == 1)
    }

    @Test("Manual refresh bypasses a fresh cache")
    func manualRefreshIsForced() async throws {
        let fixture = try makeFixture()
        await fixture.persistence.seed(makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-60),
            title: "Cached"
        ))
        let calls = EPGRequestCounter()
        let service = makeService(fixture: fixture, calls: calls, title: "Forced")

        await service.refresh(sourceID: fixture.source.id)
        let downloadCount = await calls.downloadCount
        let titles = service.state(for: fixture.source.id).catalog?
            .programsByChannelID.values.flatMap { $0 }.map(\.title) ?? []

        #expect(downloadCount == 1)
        #expect(titles == ["Forced"])
    }

    @Test("Download failure preserves the last valid guide")
    func downloadFailurePreservesCache() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000),
            title: "Cached"
        )
        await fixture.persistence.seed(cached)
        let currentDate = fixture.now
        let service = IPTVEPGSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.persistence,
            now: { currentDate },
            downloadXMLTV: { _, _, _ in throw URLError(.notConnectedToInternet) },
            parseXMLTV: { _ in Self.makeCatalog(title: "Unexpected") }
        )

        await service.refresh(sourceID: fixture.source.id)

        #expect(service.state(for: fixture.source.id).snapshot == cached)
        #expect(service.state(for: fixture.source.id).lastError == .downloadFailed)
        #expect(await fixture.persistence.currentSaveCount() == 0)
    }

    @Test("Invalid XML preserves the last valid guide")
    func invalidXMLPreservesCache() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000),
            title: "Cached"
        )
        await fixture.persistence.seed(cached)
        let currentDate = fixture.now
        let service = IPTVEPGSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.persistence,
            now: { currentDate },
            downloadXMLTV: { _, _, _ in URL(fileURLWithPath: "/tmp/epg-invalid.xml") },
            parseXMLTV: { _ in throw XMLTVParserError.invalidDocument }
        )

        await service.refresh(sourceID: fixture.source.id)

        #expect(service.state(for: fixture.source.id).snapshot == cached)
        #expect(service.state(for: fixture.source.id).lastError == .invalidXML)
        #expect(await fixture.persistence.currentSaveCount() == 0)
    }

    @Test("Cache write failure does not publish the downloaded guide")
    func cacheWriteFailurePreservesCache() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000),
            title: "Cached"
        )
        await fixture.persistence.seed(cached)
        await fixture.persistence.setFailSave(true)
        let service = makeService(fixture: fixture, calls: EPGRequestCounter(), title: "New")

        await service.refresh(sourceID: fixture.source.id)

        #expect(service.state(for: fixture.source.id).snapshot == cached)
        #expect(service.state(for: fixture.source.id).lastError == .cacheWriteFailed)
        #expect(await fixture.persistence.snapshot(for: fixture.source.id) == cached)
    }

    @Test("A cache read failure is published without replacing state")
    func cacheReadFailureIsPublished() async throws {
        let fixture = try makeFixture()
        await fixture.persistence.setFailLoad(true)
        let service = makeService(fixture: fixture, calls: EPGRequestCounter())

        #expect(await service.loadCachedCatalog(sourceID: fixture.source.id) == nil)
        #expect(service.state(for: fixture.source.id).lastError == .cacheReadFailed)
    }

    @Test("A refreshed guide is published only after persistence completes")
    func persistenceCompletesBeforePublication() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000),
            title: "Cached"
        )
        await fixture.persistence.seed(cached)
        let saveStarted = EPGAsyncSignal()
        let allowSave = EPGAsyncSignal()
        await fixture.persistence.setSaveGate(started: saveStarted, release: allowSave)
        let service = makeService(
            fixture: fixture,
            calls: EPGRequestCounter(),
            title: "New"
        )

        let refreshTask = Task { await service.refresh(sourceID: fixture.source.id) }
        await saveStarted.wait()

        #expect(service.state(for: fixture.source.id).snapshot == cached)
        #expect(service.state(for: fixture.source.id).loadingState == .refreshing)

        await allowSave.signal()
        await refreshTask.value

        let titles = service.state(for: fixture.source.id).catalog?
            .programsByChannelID.values.flatMap { $0 }.map(\.title)
        #expect(titles == ["New"])
        #expect(service.state(for: fixture.source.id).loadingState == .idle)
    }

    @Test("Cancellation during persistence never publishes an obsolete guide")
    func cancellationDuringPersistenceDoesNotPublish() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000),
            title: "Cached"
        )
        await fixture.persistence.seed(cached)
        let saveStarted = EPGAsyncSignal()
        let allowSave = EPGAsyncSignal()
        await fixture.persistence.setSaveGate(started: saveStarted, release: allowSave)
        let service = makeService(fixture: fixture, calls: EPGRequestCounter(), title: "New")
        service.selectSource(fixture.source.id)

        let refreshTask = Task { await service.refresh(sourceID: fixture.source.id) }
        await saveStarted.wait()
        service.selectSource(UUID())
        await allowSave.signal()
        await refreshTask.value

        #expect(service.state(for: fixture.source.id).snapshot == cached)
        #expect(service.state(for: fixture.source.id).loadingState == .idle)
        #expect(await fixture.persistence.currentSaveCount() == 1)
    }

    @Test("Concurrent refreshes share one synchronization")
    func concurrentRefreshesAreCoalesced() async throws {
        let fixture = try makeFixture()
        let calls = EPGRequestCounter()
        let service = makeService(
            fixture: fixture,
            calls: calls,
            delay: .milliseconds(20)
        )

        async let first: Void = service.refresh(sourceID: fixture.source.id)
        async let second: Void = service.refresh(sourceID: fixture.source.id)
        _ = await (first, second)
        let downloadCount = await calls.downloadCount
        let parseCount = await calls.parseCount

        #expect(downloadCount == 1)
        #expect(parseCount == 1)
        #expect(await fixture.persistence.currentSaveCount() == 1)
    }

    @Test("Changing source cancels obsolete work and retains its cache")
    func sourceChangeCancelsSynchronization() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(
            sourceID: fixture.source.id,
            updatedAt: fixture.now.addingTimeInterval(-100_000),
            title: "Cached"
        )
        await fixture.persistence.seed(cached)
        let started = EPGAsyncSignal()
        let currentDate = fixture.now
        let service = IPTVEPGSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.persistence,
            now: { currentDate },
            downloadXMLTV: { _, _, _ in
                await started.signal()
                try await Task.sleep(for: .seconds(30))
                return URL(fileURLWithPath: "/tmp/epg-late.xml")
            },
            parseXMLTV: { _ in Self.makeCatalog(title: "Late") }
        )

        service.selectSource(fixture.source.id)
        let refreshTask = Task { await service.refresh(sourceID: fixture.source.id) }
        await started.wait()
        service.selectSource(UUID())
        await refreshTask.value

        #expect(service.state(for: fixture.source.id).snapshot == cached)
        #expect(service.state(for: fixture.source.id).loadingState == .idle)
        #expect(await fixture.persistence.currentSaveCount() == 0)
    }

    @Test("Cached models and errors expose no credentials or server URL")
    func cacheAndErrorsContainNoSecrets() throws {
        let sourceID = UUID()
        let snapshot = makeSnapshot(sourceID: sourceID, updatedAt: Date(), title: "Guide")
        let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        let errors = [
            IPTVEPGSyncError.credentialsUnavailable,
            .downloadFailed,
            .invalidXML
        ].compactMap(\.errorDescription).joined(separator: " ")

        for secret in ["fictional-user", "fictional-password", "server.invalid"] {
            #expect(!payload.contains(secret))
            #expect(!errors.contains(secret))
        }
    }

    @Test("XMLTV endpoint uses the canonical path and ephemeral query credentials")
    func buildsCanonicalXMLTVEndpoint() throws {
        let serverURL = try #require(URL(string: "https://server.invalid/base"))
        let url = try XtreamServerURL.xmlTVURL(
            serverURL: serverURL,
            username: "user/name",
            password: "secret value"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.path == "/base/xmltv.php")
        #expect(components.queryItems?.first(where: { $0.name == "username" })?.value == "user/name")
        #expect(components.queryItems?.first(where: { $0.name == "password" })?.value == "secret value")
    }

    private func makeService(
        fixture: EPGFixture,
        calls: EPGRequestCounter,
        title: String = "Downloaded",
        delay: Duration? = nil
    ) -> IPTVEPGSyncService {
        let currentDate = fixture.now
        return IPTVEPGSyncService(
            sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore,
            persistence: fixture.persistence,
            now: { currentDate },
            downloadXMLTV: { _, _, _ in
                await calls.recordDownload()
                if let delay { try await Task.sleep(for: delay) }
                return URL(fileURLWithPath: "/tmp/epg-fixture.xml")
            },
            parseXMLTV: { _ in
                await calls.recordParse()
                return Self.makeCatalog(title: title)
            }
        )
    }

    private func makeFixture() throws -> EPGFixture {
        let sourcePersistence = EPGMockSourcesPersistence()
        let credentialsStore = EPGMockCredentialsStore()
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
        return EPGFixture(
            now: Date(timeIntervalSince1970: 1_800_000_000),
            source: source,
            sourcesManager: sourcesManager,
            credentialsStore: credentialsStore,
            persistence: EPGMockPersistence()
        )
    }

    private func makeSnapshot(sourceID: UUID, updatedAt: Date, title: String) -> IPTVEPGSnapshot {
        IPTVEPGSnapshot(
            sourceID: sourceID,
            catalog: Self.makeCatalog(title: title),
            lastUpdated: updatedAt
        )
    }

    nonisolated private static func makeCatalog(title: String) -> EPGCatalog {
        let channelID = EPGChannelID(rawValue: "epg.channel")
        let program = EPGProgram(
            epgChannelID: channelID,
            title: title,
            description: "Description",
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_003_600)
        )
        return EPGCatalog(
            channelsByID: [channelID: EPGChannel(id: channelID, displayName: "Channel")],
            programsByChannelID: [channelID: [program]]
        )
    }
}

private struct EPGFixture {
    let now: Date
    let source: IPTVSource
    let sourcesManager: IPTVSourcesManager
    let credentialsStore: EPGMockCredentialsStore
    let persistence: EPGMockPersistence
}

private actor EPGMockPersistence: IPTVEPGPersisting {
    var snapshots: [UUID: IPTVEPGSnapshot] = [:]
    var saveCount = 0
    var failLoad = false
    var failSave = false
    var saveGate: (started: EPGAsyncSignal, release: EPGAsyncSignal)?

    func load(sourceID: UUID) async throws -> IPTVEPGSnapshot? {
        if failLoad { throw IPTVEPGSyncError.cacheReadFailed }
        snapshots[sourceID]
    }

    func save(_ snapshot: IPTVEPGSnapshot) async throws {
        if failSave { throw IPTVEPGSyncError.cacheWriteFailed }
        if let saveGate {
            await saveGate.started.signal()
            await saveGate.release.wait()
            try Task.checkCancellation()
        }
        snapshots[snapshot.sourceID] = snapshot
        saveCount += 1
    }

    func remove(sourceID: UUID) async throws {
        snapshots[sourceID] = nil
    }

    func seed(_ snapshot: IPTVEPGSnapshot) {
        snapshots[snapshot.sourceID] = snapshot
    }

    func snapshot(for sourceID: UUID) -> IPTVEPGSnapshot? {
        snapshots[sourceID]
    }

    func currentSaveCount() -> Int { saveCount }
    func setFailLoad(_ value: Bool) { failLoad = value }
    func setFailSave(_ value: Bool) { failSave = value }
    func setSaveGate(started: EPGAsyncSignal, release: EPGAsyncSignal) {
        saveGate = (started, release)
    }
}

@MainActor
private final class EPGMockCredentialsStore: XtreamCredentialsStoring {
    var values: [UUID: XtreamCredentials] = [:]

    func credentials(for sourceID: UUID) throws -> XtreamCredentials? { values[sourceID] }
    func setCredentials(_ credentials: XtreamCredentials, for sourceID: UUID) throws {
        values[sourceID] = credentials
    }
    func deleteCredentials(for sourceID: UUID) throws { values[sourceID] = nil }
}

@MainActor
private final class EPGMockSourcesPersistence: IPTVSourcesPersisting {
    private var sources: [IPTVSource] = []
    private var activeID: UUID?

    func loadSources() throws -> [IPTVSource] { sources }
    func loadActiveSourceID() throws -> UUID? { activeID }
    func saveSources(_ sources: [IPTVSource]) throws { self.sources = sources }
    func saveActiveSourceID(_ sourceID: UUID?) throws { activeID = sourceID }
}

private actor EPGRequestCounter {
    private(set) var downloadCount = 0
    private(set) var parseCount = 0

    func recordDownload() { downloadCount += 1 }
    func recordParse() { parseCount += 1 }
}

private actor EPGAsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
