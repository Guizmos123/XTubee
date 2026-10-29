//
//  IPTVCacheGenerationCleanupTests.swift
//  Yattee
//
//  Revision collection against isolated real files, including delayed writers.
//

import Foundation
import Testing
@testable import XTubee

enum CleanupStoreKind: CaseIterable, Sendable { case live, epg }

@Suite("IPTV Cache Generation Cleanup")
@MainActor
struct IPTVCacheGenerationCleanupTests {
    @Test(arguments: CleanupStoreKind.allCases)
    func successfulReplacementOnlyCollectsItsOwnOldFiles(kind: CleanupStoreKind) async throws {
        let fixture = try GenerationFixture(kind)
        defer { fixture.cleanUp() }
        _ = try await fixture.seed(revision: nil)
        _ = try await fixture.seed(revision: UUID())
        let other = try await fixture.seed(sourceID: UUID(), revision: UUID())
        let unknown = fixture.cacheDirectory.appendingPathComponent(fixture.id.uuidString + ".not-a-revision." + fixture.fileExtension)
        try Data("unrelated file".utf8).write(to: unknown)
        let directory = fixture.cacheDirectory.appendingPathComponent(fixture.id.uuidString + "." + UUID().uuidString + "." + fixture.fileExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let b = try fixture.changeSource("B")
        await fixture.refresh()
        #expect(await fixture.load(revision: b.configurationRevision) == fixture.currentValue)
        #expect(fixture.currentValue != nil && !fixture.hasError)
        #expect(try await fixture.revisions() == [b.configurationRevision])
        #expect(await fixture.load(sourceID: other.sourceID, revision: other.revision) == other)
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: CleanupStoreKind.allCases, ["network", "save"])
    func failedSynchronizationPreservesCurrentAndPreviousCaches(kind: CleanupStoreKind, failure: String) async throws {
        let fixture = try GenerationFixture(kind)
        defer { fixture.cleanUp() }
        let a = try await fixture.seed(revision: nil)
        let b = try fixture.changeSource("B")
        let validB = try await fixture.seed(revision: b.configurationRevision)
        if failure == "network" { await fixture.behavior.setFailing(true) }
        else { await fixture.controls.setFault(.saving) }
        await fixture.refresh()
        #expect(fixture.hasError)
        #expect(fixture.currentValue == validB)
        #expect(await fixture.load(revision: b.configurationRevision) == validB)
        #expect(await fixture.load(revision: nil) == a)
    }

    @Test(arguments: CleanupStoreKind.allCases)
    func lateOldWriteCannotRepopulateCollectedGeneration(kind: CleanupStoreKind) async throws {
        let fixture = try GenerationFixture(kind)
        defer { fixture.cleanUp() }
        _ = try await fixture.seed(revision: nil)
        let gate = GenerationGate()
        defer { gate.open() }
        await fixture.controls.pauseSave(revision: nil, gate: gate)
        let oldRefresh = Task { await fixture.refresh() }
        defer { oldRefresh.cancel() }
        try await gate.waitUntilStarted()
        let b = try fixture.changeSource("B")
        await fixture.refresh()
        let validB = fixture.currentValue
        #expect(validB != nil)
        #expect(await fixture.load(revision: nil) == nil)
        gate.open() // The old persistence call now really writes A to disk.
        await oldRefresh.value
        #expect(await fixture.load(revision: nil) == nil)
        #expect(await fixture.load(revision: b.configurationRevision) == validB)
        #expect(fixture.currentValue == validB)
    }

    @Test(arguments: CleanupStoreKind.allCases, ["listing", "removal"])
    func newerRevisionSurvivesAnOlderCollector(kind: CleanupStoreKind, phase: String) async throws {
        let fixture = try GenerationFixture(kind)
        defer { fixture.cleanUp() }
        _ = try await fixture.seed(revision: nil)
        _ = try fixture.changeSource("B")
        let gate = GenerationGate()
        defer { gate.open() }
        await fixture.controls.pauseCollection(phase: phase, gate: gate)
        let bRefresh = Task { await fixture.refresh() }
        defer { bRefresh.cancel() }
        try await gate.waitUntilStarted()
        let c = try fixture.changeSource("C")
        await fixture.refresh()
        let validC = fixture.currentValue
        #expect(validC != nil)
        gate.open()
        await bRefresh.value
        #expect(await fixture.load(revision: c.configurationRevision) == validC)
        #expect(fixture.currentValue == validC)
    }

    @Test(arguments: CleanupStoreKind.allCases)
    func fullSourceRemovalStillCleansAllGenerationsAndLateWrites(kind: CleanupStoreKind) async throws {
        let fixture = try GenerationFixture(kind)
        defer { fixture.cleanUp() }
        _ = try await fixture.seed(revision: nil)
        _ = try await fixture.seed(revision: UUID())
        let other = try await fixture.seed(sourceID: UUID(), revision: nil)
        let gate = GenerationGate()
        defer { gate.open() }
        await fixture.controls.pauseSave(revision: nil, gate: gate)
        let pending = Task { await fixture.refresh() }
        defer { pending.cancel() }
        try await gate.waitUntilStarted()
        try await fixture.manager.remove(id: fixture.id)
        gate.open()
        await pending.value
        #expect(try await fixture.revisions().isEmpty)
        #expect(await fixture.load(sourceID: other.sourceID, revision: nil) == other)
    }

    @Test(arguments: CleanupStoreKind.allCases, ["listing", "removal", "interrupted"])
    func collectionFailureIsNonBlockingAndRetriedAfterNextSave(kind: CleanupStoreKind, phase: String) async throws {
        let fixture = try GenerationFixture(kind)
        defer { fixture.cleanUp() }
        _ = try await fixture.seed(revision: nil)
        let b = try fixture.changeSource("B")
        await fixture.controls.setFault(phase == "listing" ? .listing : phase == "removal" ? .removal : .interrupted)
        await fixture.refresh()
        #expect(fixture.currentValue != nil && !fixture.hasError)
        #expect(await fixture.load(revision: b.configurationRevision) == fixture.currentValue)
        #expect(await fixture.load(revision: nil) != nil)
        await fixture.controls.setFault(.none)
        await fixture.refresh()
        #expect(!fixture.hasError)
        #expect(await fixture.load(revision: nil) == nil)
        #expect(await fixture.load(revision: b.configurationRevision) == fixture.currentValue)
    }
}

private enum GenerationValue: Equatable, Sendable {
    case live(IPTVLiveCatalog), epg(IPTVEPGSnapshot)
    var sourceID: UUID { switch self { case .live(let value): value.sourceID; case .epg(let value): value.sourceID } }
    var revision: UUID? { switch self { case .live(let value): value.configurationRevision; case .epg(let value): value.configurationRevision } }
}

@MainActor
private final class GenerationFixture {
    let kind: CleanupStoreKind
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IPTVGeneration-" + UUID().uuidString)
    let manager: IPTVSourcesManager
    let id: UUID
    let live: FileIPTVLiveCatalogPersistence
    let epg: FileIPTVEPGPersistence
    let liveService: IPTVLiveCatalogSyncService
    let epgService: IPTVEPGSyncService
    let controls = GenerationControls()
    let behavior = GenerationBehavior()
    var fileExtension: String { kind == .live ? "json" : "epgcache" }
    var cacheDirectory: URL { directory.appendingPathComponent(kind == .live ? "Live" : "EPG") }
    var currentValue: GenerationValue? {
        switch kind {
        case .live: liveService.state(for: id).catalog.map(GenerationValue.live)
        case .epg: epgService.state(for: id).snapshot.map(GenerationValue.epg)
        }
    }
    var hasError: Bool { kind == .live ? liveService.state(for: id).lastError != nil : epgService.state(for: id).lastError != nil }

    init(_ kind: CleanupStoreKind) throws {
        self.kind = kind
        let credentials = GenerationCredentials()
        manager = IPTVSourcesManager(persistence: GenerationSources(), credentialsStore: credentials)
        id = try manager.add(name: "A", serverURL: "https://a.invalid", username: "user", password: "A").id
        live = FileIPTVLiveCatalogPersistence(directoryURL: directory.appendingPathComponent("Live"))
        epg = FileIPTVEPGPersistence(directoryURL: directory.appendingPathComponent("EPG"))
        let behavior = behavior
        liveService = IPTVLiveCatalogSyncService(sourcesManager: manager, credentialsStore: credentials,
            persistence: ControlledLivePersistence(file: live, controls: controls), now: { Date(timeIntervalSince1970: 2000) },
            fetchCategories: { _, _, _ in try await behavior.check(); return [] },
            fetchStreams: { _, _, _ in try await behavior.check(); return [] })
        let directory = directory
        epgService = IPTVEPGSyncService(sourcesManager: manager, credentialsStore: credentials,
            persistence: ControlledEPGPersistence(file: epg, controls: controls), now: { Date(timeIntervalSince1970: 2000) },
            downloadXMLTV: { _, _, _ in
                try await behavior.check()
                let url = directory.appendingPathComponent(UUID().uuidString + ".xml")
                try Data("<tv/>".utf8).write(to: url)
                return url
            }, parseXMLTV: { _ in EPGCatalog(channelsByID: [:], programsByChannelID: [:]) })
        manager.setDataCleaner(IPTVSourceDataCleanupCoordinator(livePersistence: live, epgPersistence: epg,
            favoritesManager: IPTVLiveFavoritesManager(persistence: GenerationFavorites()),
            hiddenCategoriesPersistence: GenerationHiddenCategories()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func changeSource(_ name: String) throws -> IPTVSource {
        try manager.update(id: id, name: name, serverURL: "https://\(name.lowercased()).invalid", username: "user", password: name)
    }
    func refresh() async { if kind == .live { await liveService.refresh(sourceID: id) } else { await epgService.refresh(sourceID: id) } }
    func seed(sourceID: UUID? = nil, revision: UUID?) async throws -> GenerationValue {
        let sourceID = sourceID ?? id
        switch kind {
        case .live:
            let value = IPTVLiveCatalog(sourceID: sourceID, categories: [], streams: [], lastUpdated: Date(timeIntervalSince1970: 1000), configurationRevision: revision)
            try await live.save(value)
            return .live(value)
        case .epg:
            let value = IPTVEPGSnapshot(sourceID: sourceID, catalog: EPGCatalog(channelsByID: [:], programsByChannelID: [:]),
                                       lastUpdated: Date(timeIntervalSince1970: 1000), configurationRevision: revision)
            try await epg.save(value)
            return .epg(value)
        }
    }
    func load(sourceID: UUID? = nil, revision: UUID?) async -> GenerationValue? {
        switch kind {
        case .live: return (try? await live.load(sourceID: sourceID ?? id, configurationRevision: revision)).map(GenerationValue.live)
        case .epg: return (try? await epg.load(sourceID: sourceID ?? id, configurationRevision: revision)).map(GenerationValue.epg)
        }
    }
    func revisions() async throws -> [UUID?] {
        switch kind {
        case .live: try await live.cachedRevisions(sourceID: id)
        case .epg: try await epg.cachedRevisions(sourceID: id)
        }
    }
    func cleanUp() {
        liveService.cancel(sourceID: id); epgService.cancel(sourceID: id)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ControlledLivePersistence: IPTVLiveCatalogPersisting {
    let file: FileIPTVLiveCatalogPersistence
    let controls: GenerationControls
    init(file: FileIPTVLiveCatalogPersistence, controls: GenerationControls) { self.file = file; self.controls = controls }
    func load(sourceID: UUID) async throws -> IPTVLiveCatalog? { try await file.load(sourceID: sourceID) }
    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVLiveCatalog? { try await file.load(sourceID: sourceID, configurationRevision: configurationRevision) }
    func save(_ value: IPTVLiveCatalog) async throws { try await controls.beforeSave(value.configurationRevision); try await file.save(value) }
    func cachedRevisions(sourceID: UUID) async throws -> [UUID?] { let values = try await file.cachedRevisions(sourceID: sourceID); try await controls.afterListing(); return values }
    func remove(sourceID: UUID, configurationRevisions: [UUID?]) async throws { try await controls.beforeRemoval(); try await file.remove(sourceID: sourceID, configurationRevisions: configurationRevisions) }
    func remove(sourceID: UUID) async throws { try await file.remove(sourceID: sourceID) }
}

private actor ControlledEPGPersistence: IPTVEPGPersisting {
    let file: FileIPTVEPGPersistence
    let controls: GenerationControls
    init(file: FileIPTVEPGPersistence, controls: GenerationControls) { self.file = file; self.controls = controls }
    func load(sourceID: UUID) async throws -> IPTVEPGSnapshot? { try await file.load(sourceID: sourceID) }
    func load(sourceID: UUID, configurationRevision: UUID?) async throws -> IPTVEPGSnapshot? { try await file.load(sourceID: sourceID, configurationRevision: configurationRevision) }
    func save(_ value: IPTVEPGSnapshot) async throws { try await controls.beforeSave(value.configurationRevision); try await file.save(value) }
    func cachedRevisions(sourceID: UUID) async throws -> [UUID?] { let values = try await file.cachedRevisions(sourceID: sourceID); try await controls.afterListing(); return values }
    func remove(sourceID: UUID, configurationRevisions: [UUID?]) async throws { try await controls.beforeRemoval(); try await file.remove(sourceID: sourceID, configurationRevisions: configurationRevisions) }
    func remove(sourceID: UUID) async throws { try await file.remove(sourceID: sourceID) }
}

private actor GenerationControls {
    enum Fault: Sendable { case none, saving, listing, removal, interrupted }
    private var fault: Fault = .none
    private var saveGate: (revision: UUID?, gate: GenerationGate)?
    private var listGate: GenerationGate?
    private var removalGate: GenerationGate?
    func setFault(_ fault: Fault) { self.fault = fault }
    func pauseSave(revision: UUID?, gate: GenerationGate) { saveGate = (revision, gate) }
    func pauseCollection(phase: String, gate: GenerationGate) { if phase == "listing" { listGate = gate } else { removalGate = gate } }
    func beforeSave(_ revision: UUID?) async throws {
        if fault == .saving { throw CocoaError(.fileWriteNoPermission) }
        if let gate = saveGate, gate.revision == revision { saveGate = nil; await gate.gate.pause() }
    }
    func afterListing() async throws {
        if fault == .listing { throw CocoaError(.fileReadNoPermission) }
        if let gate = listGate { listGate = nil; await gate.pause() }
    }
    func beforeRemoval() async throws {
        if fault == .removal { throw CocoaError(.fileWriteNoPermission) }
        if fault == .interrupted { throw CancellationError() }
        if let gate = removalGate { removalGate = nil; await gate.pause() }
    }
}

private actor GenerationBehavior {
    private var failing = false
    func setFailing(_ value: Bool) { failing = value }
    func check() throws { if failing { throw URLError(.notConnectedToInternet) } }
}

private final class GenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                started = true
                if isOpen { return true }
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func open() {
        let pending = lock.withLock { isOpen = true; let value = continuation; continuation = nil; return value }
        pending?.resume()
    }
    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !lock.withLock({ started }) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor private final class GenerationSources: IPTVSourcesPersisting {
    private var sources: [IPTVSource] = []
    private var active: UUID?
    func loadSources() throws -> [IPTVSource] { sources }
    func loadActiveSourceID() throws -> UUID? { active }
    func saveSources(_ sources: [IPTVSource]) throws { self.sources = sources }
    func saveActiveSourceID(_ sourceID: UUID?) throws { active = sourceID }
}
@MainActor private final class GenerationCredentials: XtreamCredentialsStoring {
    private var values: [UUID: XtreamCredentials] = [:]
    func credentials(for sourceID: UUID) throws -> XtreamCredentials? { values[sourceID] }
    func setCredentials(_ credentials: XtreamCredentials, for sourceID: UUID) throws { values[sourceID] = credentials }
    func deleteCredentials(for sourceID: UUID) throws { values[sourceID] = nil }
}
@MainActor private final class GenerationFavorites: IPTVLiveFavoritesPersisting {
    func load() throws -> [IPTVLiveChannelGroup.ID] { [] }
    func save(_ favoriteIDs: [IPTVLiveChannelGroup.ID]) throws {}
}
@MainActor private final class GenerationHiddenCategories: IPTVHiddenCategoriesPersisting {
    func removeCategories(for sourceID: UUID) throws {}
}
