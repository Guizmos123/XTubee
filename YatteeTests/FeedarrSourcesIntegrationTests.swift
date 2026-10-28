//  FeedarrSourcesIntegrationTests.swift
//  Yattee
//
//  Tests shared Feedarr dependencies and Sources integration contracts.

import Foundation
import SwiftUI
import Testing
@testable import XTubee

@Suite("Feedarr Sources Integration Tests", .serialized)
@MainActor
struct FeedarrSourcesIntegrationTests {
    @Test("Environment shares the credential store with its persistent manager")
    func environmentSharesAndRestoresSource() throws {
        let persistence = IntegrationPersistence()
        let keychain = IntegrationKeychain()
        let store = FeedarrCredentialsStore(keychain: keychain)
        let transport = IntegrationTransport()
        let environment = try self.environment(persistence: persistence, store: store, transport: transport)
        #expect(environment.feedarrCredentialsStore === store)
        #expect(environment.feedarrSourcesManager === environment.feedarrSourcesManager)
        let saved = try environment.feedarrSourcesManager.add(
            name: "Home", serverURL: "https://feedarr.invalid", usesBasicAuth: true,
            username: "alice", password: "secret"
        )
        #expect(try store.credentials(for: saved.id)?.username == "alice")
        let restarted = try self.environment(persistence: persistence, store: store, transport: transport)
        #expect(restarted.feedarrSourcesManager.source == saved)
        #expect(restarted.feedarrSourcesManager.loadError == nil)
        #expect(transport.calls == 0)
    }

    @Test("An existing Feedarr disables addition and the manager rejects a second source")
    func singleSourcePolicy() throws {
        let fixture = fixture()
        #expect(AddSourceView.canAddFeedarr(using: fixture.manager))
        #expect(!AddSourceView.canAddFeedarr(using: nil))
        let saved = try add(to: fixture.manager)
        #expect(!AddSourceView.canAddFeedarr(using: fixture.manager))
        #expect(throws: FeedarrSourcesManagerError.sourceAlreadyExists) {
            try fixture.manager.add(name: "Second", serverURL: "https://other.invalid", usesBasicAuth: false)
        }
        #expect(fixture.manager.source == saved)
    }

    @Test("The injected form edits the saved UUID and preserves its creation date")
    func editUsesSharedManagerAndStore() async throws {
        let fixture = fixture()
        let original = try add(to: fixture.manager)
        let form = AddFeedarrSourceModel(
            manager: fixture.manager,
            validator: FeedarrConnectionValidator(transport: fixture.transport),
            credentialsStore: fixture.store,
            editingSource: original
        )
        form.loadCredentials()
        #expect(form.username == "alice")
        form.name = "Renamed"
        await form.verify()
        #expect(await form.save())
        #expect(fixture.manager.source?.name == "Renamed")
        #expect(fixture.manager.source?.id == original.id)
        #expect(fixture.manager.source?.dateAdded == original.dateAdded)
        #expect(fixture.transport.calls == 2)
    }

    @Test("Deletion removes metadata and credentials and re-enables addition")
    func deletionUpdatesAvailability() throws {
        let fixture = fixture()
        let original = try add(to: fixture.manager)
        try fixture.manager.remove(id: original.id)
        #expect(fixture.manager.source == nil && fixture.persistence.source == nil)
        #expect(try fixture.store.credentials(for: original.id) == nil)
        #expect(AddSourceView.canAddFeedarr(using: fixture.manager))
        #expect(SourcesListView.hasNoSources(hasRemoteSources: false, hasIPTVSources: false,
                                           feedarrSource: fixture.manager.source, hasFileSources: false))
    }

    @Test("Failed deletion preserves the source and restores its credentials")
    func failedDeletionPreservesConfiguration() throws {
        let fixture = fixture()
        let original = try add(to: fixture.manager)
        fixture.persistence.failSave = true
        #expect(throws: FeedarrSourcesManagerError.persistenceFailure) {
            try fixture.manager.remove(id: original.id)
        }
        #expect(fixture.manager.source == original && fixture.persistence.source == original)
        #expect(try fixture.store.credentials(for: original.id)?.username == "alice")
        #expect(!AddSourceView.canAddFeedarr(using: fixture.manager))
    }

    @Test("Feedarr alone prevents the global empty state")
    func feedarrOnlyIsNotEmpty() throws {
        let fixture = fixture()
        _ = try add(to: fixture.manager)
        #expect(!SourcesListView.hasNoSources(hasRemoteSources: false, hasIPTVSources: false,
                                            feedarrSource: fixture.manager.source, hasFileSources: false))
    }

    @Test("Other source families retain their independent empty-state behavior", arguments: [1, 2, 4, 7])
    func otherFamiliesRemainIndependent(mask: Int) {
        #expect(!SourcesListView.hasNoSources(hasRemoteSources: mask & 1 != 0,
                                            hasIPTVSources: mask & 2 != 0,
                                            feedarrSource: nil, hasFileSources: mask & 4 != 0))
    }

    @Test("Reload checks credentials locally without requesting Feedarr")
    func authenticationStatusWithoutNetwork() throws {
        let fixture = fixture()
        let original = try add(to: fixture.manager)
        try fixture.store.deleteCredentials(for: original.id)
        try fixture.manager.reload()
        #expect(fixture.manager.source == original)
        #expect(fixture.manager.loadError == .missingCredentials)
        #expect(fixture.transport.calls == 0)
    }

    @Test("New Source keeps the disabled Feedarr entry between IPTV and PeerTube")
    func additionNavigationContract() throws {
        let view = try source("Yattee/Views/Settings/AddSourceView.swift")
        let iptv = try #require(view.range(of: "sources.addIPTVServer"))
        let feedarr = try #require(view.range(of: "sources.feedarr.addTitle"))
        let peerTube = try #require(view.range(of: "sources.browsePeerTube"))
        #expect(iptv.lowerBound < feedarr.lowerBound && feedarr.lowerBound < peerTube.lowerBound)
        #expect(view.contains(".disabled(!Self.canAddFeedarr(using:"))
        #expect(view.contains("includesNavigationStack: false"))
        #expect(view.contains("sources.feedarr.singleServer"))
    }

    @Test("Sources routes editing and deletion through Feedarr without automatic validation")
    func sourcesNavigationContract() throws {
        let view = try source("Yattee/Views/Settings/SourcesListView.swift")
        #expect(view.contains("iptvServersSection\n                        feedarrServersSection\n                        fileSourcesSection"))
        #expect(view.contains("editingSource: source"))
        #expect(view.contains("try manager.remove(id: source.id)"))
        #expect(view.contains("pendingDeleteFeedarrSource = source"))
        #expect(!view.contains(".validate("))
        #expect(!view.contains("URLSession"))
    }

    private func environment(
        persistence: IntegrationPersistence,
        store: FeedarrCredentialsStore,
        transport: IntegrationTransport
    ) throws -> AppEnvironment {
        AppEnvironment(
            feedarrSourcePersistence: persistence,
            feedarrCredentialsStore: store,
            feedarrConnectionValidator: FeedarrConnectionValidator(transport: transport),
            dataManager: try DataManager(inMemory: true)
        )
    }

    private func fixture() -> Fixture {
        let persistence = IntegrationPersistence()
        let store = FeedarrCredentialsStore(keychain: IntegrationKeychain())
        return Fixture(persistence: persistence, store: store,
                       manager: FeedarrSourcesManager(persistence: persistence, credentialsStore: store),
                       transport: IntegrationTransport())
    }

    private func add(to manager: FeedarrSourcesManager) throws -> FeedarrSource {
        try manager.add(name: "Home", serverURL: "https://feedarr.invalid", usesBasicAuth: true,
                        username: "alice", password: "secret", dateAdded: Date(timeIntervalSince1970: 1234))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private struct Fixture: Sendable {
        let persistence: IntegrationPersistence
        let store: FeedarrCredentialsStore
        let manager: FeedarrSourcesManager
        let transport: IntegrationTransport
    }
}

@MainActor
private final class IntegrationPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    var failSave = false
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws {
        if failSave { throw FeedarrSourcesManagerError.persistenceFailure }
        self.source = source
    }
}

@MainActor
private final class IntegrationKeychain: FeedarrKeychainAccessing {
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { values[service + account] }
    func write(_ data: Data, service: String, account: String) throws { values[service + account] = data }
    func delete(service: String, account: String) throws { values[service + account] = nil }
}

private final class IntegrationTransport: FeedarrHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0
    var calls: Int { lock.withLock { requestCount } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requestCount += 1 }
        let body = request.url!.path == "/health" ? #"{"status":"up"}"#
            : #"{"items":[],"pagination":{"limit":1,"hasMore":false,"nextCursor":null,"snapshotMaxId":0}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "application/json"])!)
    }
}
