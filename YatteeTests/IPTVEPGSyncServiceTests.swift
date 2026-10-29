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

    @Test("Connection changes reject fresh EPG caches with unchanged source UUID", arguments: ["host", "username", "password"])
    func connectionChangeInvalidatesCache(kind: String) async throws {
        let fixture = try makeFixture()
        let id = fixture.source.id
        let old = makeSnapshot(sourceID: id, updatedAt: fixture.now, title: "Old")
        await fixture.persistence.seed(old)
        let calls = EPGRequestCounter()
        let service = makeService(fixture: fixture, calls: calls)
        await service.synchronizeIfNeeded(sourceID: id)
        #expect(service.state(for: id).snapshot == old)
        let updated = try fixture.sourcesManager.update(id: id, name: "Changed",
            serverURL: kind == "host" ? "https://new.invalid" : fixture.source.serverURL.absoluteString,
            username: kind == "username" ? "new-user" : "fictional-user",
            password: kind == "password" ? "new-pass" : "fictional-password")
        #expect(service.state(for: id).snapshot == nil)
        #expect(await service.loadCachedCatalog(sourceID: id) == nil)
        await service.synchronizeIfNeeded(sourceID: id)
        #expect(service.state(for: id).snapshot?.configurationRevision == updated.configurationRevision)
        service.selectSource(UUID())
        service.selectSource(id)
        await service.synchronizeIfNeeded(sourceID: id)
        let returned = makeService(fixture: fixture, calls: calls)
        await returned.synchronizeIfNeeded(sourceID: id)
        #expect(await calls.downloadCount == 1)
    }

    @Test("Renaming a source and revisiting EPG retain its cache")
    func cosmeticChangeRetainsCache() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(sourceID: fixture.source.id, updatedAt: fixture.now, title: "Current")
        await fixture.persistence.seed(cached)
        let calls = EPGRequestCounter()
        let service = makeService(fixture: fixture, calls: calls)
        await service.synchronizeIfNeeded(sourceID: fixture.source.id)
        _ = try fixture.sourcesManager.update(id: fixture.source.id, name: "Renamed",
            serverURL: fixture.source.serverURL.absoluteString, username: "fictional-user", password: "fictional-password")
        await service.synchronizeIfNeeded(sourceID: fixture.source.id)
        let returned = makeService(fixture: fixture, calls: calls)
        await returned.synchronizeIfNeeded(sourceID: fixture.source.id)
        #expect(returned.state(for: fixture.source.id).snapshot == cached)
        #expect(await calls.downloadCount == 0)
    }

    @Test("An old EPG response cannot publish or save after a connection change")
    func connectionChangeRejectsLateResponse() async throws {
        let fixture = try makeFixture()
        let started = EPGAsyncSignal()
        let release = EPGAsyncSignal()
        let service = IPTVEPGSyncService(sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore, persistence: fixture.persistence,
            downloadXMLTV: { url, _, _ in
                if url.host == "server.invalid" { await started.signal(); await release.wait() }
                return URL(fileURLWithPath: "/tmp/epg-\(url.host!).xml")
            }, parseXMLTV: { url in Self.makeCatalog(title: url.lastPathComponent) })
        let oldRefresh = Task { await service.refresh(sourceID: fixture.source.id) }
        await started.wait()
        _ = try fixture.sourcesManager.update(id: fixture.source.id, name: "New", serverURL: "https://new.invalid",
                                              username: "new-user", password: "new-pass")
        await service.refresh(sourceID: fixture.source.id)
        await release.signal()
        await oldRefresh.value
        let programs = service.state(for: fixture.source.id).catalog?.programs(for: EPGChannelID(rawValue: "epg.channel"))
        #expect(programs?.first?.title == "epg-new.invalid.xml")
        #expect(await fixture.persistence.currentSaveCount() == 1)
    }

    @Test("EPG disk generations isolate late writes, survive reload and remove only their source")
    func diskRevisionIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileIPTVEPGPersistence(directoryURL: directory)
        let id = UUID()
        let old = makeSnapshot(sourceID: id, updatedAt: Date(), title: "Old")
        let current = IPTVEPGSnapshot(sourceID: id, catalog: Self.makeCatalog(title: "New"),
                                      lastUpdated: Date(), configurationRevision: UUID())
        let other = makeSnapshot(sourceID: UUID(), updatedAt: Date(), title: "Other")
        try await persistence.save(current)
        try await persistence.save(old)
        try await persistence.save(other)
        let restarted = FileIPTVEPGPersistence(directoryURL: directory)
        #expect(try await restarted.load(sourceID: id, configurationRevision: current.configurationRevision) == current)
        #expect(try await restarted.load(sourceID: id, configurationRevision: UUID()) == nil)
        try await restarted.remove(sourceID: id)
        #expect(try await restarted.load(sourceID: id) == nil)
        #expect(try await restarted.load(sourceID: id, configurationRevision: current.configurationRevision) == nil)
        #expect(try await restarted.load(sourceID: other.sourceID) == other)
    }

    @Test("An oversized XMLTV transfer preserves the last valid guide and never starts parsing")
    func oversizedTransferPreservesCache() async throws {
        let fixture = try makeFixture()
        let cached = makeSnapshot(sourceID: fixture.source.id, updatedAt: fixture.now, title: "Cached")
        await fixture.persistence.seed(cached)
        let transfer = XMLTVTransferFixture(declaredLength: XtreamXMLTVClient.defaultMaximumDownloadSize + 1,
                                             finishes: false,
                                             maximumBytes: XtreamXMLTVClient.defaultMaximumDownloadSize)
        defer { transfer.cleanUp() }
        let calls = EPGRequestCounter()
        let service = IPTVEPGSyncService(sourcesManager: fixture.sourcesManager,
            credentialsStore: fixture.credentialsStore, persistence: fixture.persistence,
            downloadXMLTV: { _, _, _ in try await transfer.download() },
            parseXMLTV: { _ in
                await calls.recordParse()
                return Self.makeCatalog(title: "Unexpected")
            })
        await service.refresh(sourceID: fixture.source.id)
        #expect(service.state(for: fixture.source.id).snapshot == cached)
        #expect(service.state(for: fixture.source.id).lastError == .responseTooLarge)
        #expect(await fixture.persistence.currentSaveCount() == 0)
        #expect(await calls.parseCount == 0)
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
        return snapshots[sourceID]
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

@Suite("XMLTV bounded file transfers", .serialized)
struct XMLTVBoundedTransferTests {
    @Test("Oversized Content-Length is rejected at the response without creating a file")
    func oversizedContentLength() async throws {
        #expect(XtreamXMLTVClient.defaultMaximumDownloadSize == 128 * 1_024 * 1_024)
        let before = try temporaryDownloads()
        let fixture = XMLTVTransferFixture(declaredLength: XtreamXMLTVClient.defaultMaximumDownloadSize + 1,
                                           finishes: false,
                                           maximumBytes: XtreamXMLTVClient.defaultMaximumDownloadSize)
        defer { fixture.cleanUp() }
        await #expect(throws: XtreamXMLTVDownloadError.responseTooLarge) { try await fixture.download() }
        try await waitUntil { fixture.probe.stopped }
        #expect(fixture.probe.deliveredChunks < fixture.probe.chunkCount)
        #expect(try temporaryDownloads() == before)
    }

    @Test("Actual bytes stop an unbounded or dishonest response", arguments: [false, true])
    func oversizedStream(dishonestLength: Bool) async throws {
        let before = try temporaryDownloads()
        // Inject a small limit to exercise the same streaming boundary without allocating 128 MiB.
        let fixture = XMLTVTransferFixture(declaredLength: dishonestLength ? 1 : nil)
        defer { fixture.cleanUp() }
        await #expect(throws: XtreamXMLTVDownloadError.responseTooLarge) { try await fixture.download() }
        try await waitUntil { fixture.probe.stopped }
        #expect(fixture.probe.deliveredChunks < fixture.probe.chunkCount)
        #expect(try temporaryDownloads() == before)
    }

    @Test("A valid XMLTV file at or below the limit is written intact", arguments: [64, 128])
    func validFile(size: Int) async throws {
        let payload = Data(("<tv/>" + String(repeating: " ", count: size - 5)).utf8)
        let fixture = XMLTVTransferFixture(declaredLength: Int64(payload.count), chunk: payload, chunkCount: 1)
        defer { fixture.cleanUp() }
        let file = try await fixture.download()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.lastPathComponent.hasPrefix("XMLTVDownload-"))
        #expect(file.pathExtension == "xml")
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test("Cancellation stops a stalled request and removes its partial file")
    func cancellationCleansUp() async throws {
        let before = try temporaryDownloads()
        let fixture = XMLTVTransferFixture(chunkCount: 1, finishes: false)
        defer { fixture.cleanUp() }
        let download = Task { try await fixture.download() }
        try await waitUntil { fixture.probe.deliveredChunks == 1 }
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
        try await waitUntil { fixture.probe.stopped }
        #expect(try temporaryDownloads() == before)
    }

    private func temporaryDownloads() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                       includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix("XMLTVDownload-") && $0.pathExtension == "xml"
        })
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate(), "The transfer did not reach the expected state")
    }
}

private struct XMLTVTransferFixture: Sendable {
    let serverURL: URL
    let client: XtreamXMLTVClient
    let probe: XMLTVTransferProbe

    init(declaredLength: Int64? = nil, chunk: Data = Data(repeating: 32, count: 32),
         chunkCount: Int = 100, finishes: Bool = true, maximumBytes: Int64 = 128) {
        probe = XMLTVTransferProbe(declaredLength: declaredLength, chunk: chunk, chunkCount: chunkCount, finishes: finishes)
        serverURL = XMLTVTransferRegistry.shared.register(probe)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XMLTVTransferProtocol.self]
        client = XtreamXMLTVClient(configuration: configuration, timeout: 2, maximumDownloadSize: maximumBytes)
    }

    func download() async throws -> URL {
        try await client.download(serverURL: serverURL, username: "test-user", password: "test-password")
    }

    func cleanUp() { XMLTVTransferRegistry.shared.remove(serverURL) }
}

private final class XMLTVTransferProbe: @unchecked Sendable {
    let declaredLength: Int64?
    let chunk: Data
    let chunkCount: Int
    let finishes: Bool
    private let lock = NSLock()
    private var count = 0
    private var wasStopped = false

    init(declaredLength: Int64?, chunk: Data, chunkCount: Int, finishes: Bool) {
        self.declaredLength = declaredLength
        self.chunk = chunk
        self.chunkCount = chunkCount
        self.finishes = finishes
    }

    var deliveredChunks: Int { lock.withLock { count } }
    var stopped: Bool { lock.withLock { wasStopped } }
    func delivered() { lock.withLock { count += 1 } }
    func stop() { lock.withLock { wasStopped = true } }
}

private final class XMLTVTransferRegistry: @unchecked Sendable {
    static let shared = XMLTVTransferRegistry()
    private let lock = NSLock()
    private var probes: [String: XMLTVTransferProbe] = [:]

    func register(_ probe: XMLTVTransferProbe) -> URL {
        let host = UUID().uuidString.lowercased() + ".xmltv.invalid"
        lock.withLock { probes[host] = probe }
        return URL(string: "https://" + host)!
    }

    func probe(_ request: URLRequest) -> XMLTVTransferProbe? {
        lock.withLock { probes[request.url?.host ?? ""] }
    }

    func remove(_ url: URL) { lock.withLock { probes[url.host ?? ""] = nil } }
}

private final class XMLTVTransferProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".xmltv.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let probe = XMLTVTransferRegistry.shared.probe(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var headers: [String: String] = [:]
        if let length = probe.declaredLength { headers["Content-Length"] = String(length) }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Foundation's URLProtocol bridge waits for an initial chunk before
        // delivering the response delegate callback. Keep sending to prove cancellation.
        sendChunk(0, probe: probe)
    }

    private func sendChunk(_ index: Int, probe: XMLTVTransferProbe) {
        guard !probe.stopped else { return }
        if index == probe.chunkCount {
            if probe.finishes { client?.urlProtocolDidFinishLoading(self) }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
            guard let self, !probe.stopped else { return }
            probe.delivered()
            self.client?.urlProtocol(self, didLoad: probe.chunk)
            self.sendChunk(index + 1, probe: probe)
        }
    }

    override func stopLoading() { XMLTVTransferRegistry.shared.probe(request)?.stop() }
}
