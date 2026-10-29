//
//  IPTVSourcesManagerTests.swift
//  YatteeTests
//
//  Tests for local IPTV source persistence and selection.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Sources Manager Tests")
@MainActor
struct IPTVSourcesManagerTests {
    @Test("First source becomes active and metadata contains no credentials")
    func firstSourceBecomesActive() throws {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)

        let source = try manager.add(
            name: "Home",
            serverURL: "HTTPS://server.invalid/base",
            username: "alice",
            password: "secret"
        )

        #expect(manager.activeSourceID == source.id)
        #expect(manager.sources == [source])
        #expect(source.serverURL.scheme == "https")
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(!encoded.contains("alice"))
        #expect(!encoded.contains("secret"))
    }

    @Test("Several accounts on one server are allowed but exact account duplicates are rejected")
    func duplicatePolicy() throws {
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(
            persistence: MockIPTVPersistence(),
            credentialsStore: credentials
        )

        _ = try manager.add(name: "One", serverURL: "https://server.invalid", username: "alice", password: "one")
        _ = try manager.add(name: "Two", serverURL: "https://server.invalid", username: "bob", password: "two")

        #expect(throws: IPTVSourcesManagerError.duplicateSource) {
            try manager.add(name: "Duplicate", serverURL: "https://server.invalid", username: "alice", password: "three")
        }
        #expect(manager.sources.count == 2)
    }

    @Test("Selection persists and deleting active source selects the first remaining source")
    func selectionAndRemoval() async throws {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        let first = try manager.add(name: "First", serverURL: "https://one.invalid", username: "one", password: "pass")
        let second = try manager.add(name: "Second", serverURL: "https://two.invalid", username: "two", password: "pass")

        try manager.setActive(id: second.id)
        try await manager.remove(id: second.id)

        #expect(manager.activeSourceID == first.id)
        #expect(persistence.activeID == first.id)
        #expect(credentials.values[second.id] == nil)

        try await manager.remove(id: first.id)
        #expect(manager.activeSourceID == nil)
    }

    @Test("Successful removal cleans source data after metadata and credentials")
    func removalRunsSecondaryCleanup() async throws {
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(
            persistence: MockIPTVPersistence(),
            credentialsStore: credentials
        )
        let cleaner = MockIPTVSourceDataCleaner()
        manager.setDataCleaner(cleaner)
        let source = try manager.add(
            name: "Deleted",
            serverURL: "https://deleted.invalid",
            username: "user",
            password: "pass"
        )

        try await manager.remove(id: source.id)

        #expect(cleaner.removedSourceIDs == [source.id])
        #expect(credentials.values[source.id] == nil)
        #expect(manager.lastCleanupError == nil)
    }

    @Test("Cleanup failure never restores a deleted source or its credentials")
    func cleanupFailureDoesNotRollbackRemoval() async throws {
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(
            persistence: MockIPTVPersistence(),
            credentialsStore: credentials
        )
        let cleaner = MockIPTVSourceDataCleaner()
        cleaner.shouldFail = true
        manager.setDataCleaner(cleaner)
        let source = try manager.add(
            name: "Deleted",
            serverURL: "https://deleted.invalid",
            username: "user",
            password: "pass"
        )

        try await manager.remove(id: source.id)

        #expect(manager.sources.isEmpty)
        #expect(credentials.values[source.id] == nil)
        #expect(manager.lastCleanupError == .cleanupFailed)
    }

    @Test("Reload repairs an obsolete active source identifier")
    func repairsObsoleteActiveID() throws {
        let first = try IPTVSource(name: "First", serverURL: "https://one.invalid")
        let persistence = MockIPTVPersistence(sources: [first], activeID: UUID())
        let manager = IPTVSourcesManager(
            persistence: persistence,
            credentialsStore: MockXtreamCredentialsStore()
        )

        #expect(manager.activeSourceID == first.id)
        #expect(persistence.activeID == first.id)
    }

    @Test("Reload preserves order, identifiers, and dates")
    func reload() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try IPTVSource(id: UUID(), name: "Saved", serverURL: "https://saved.invalid", dateAdded: date)
        let persistence = MockIPTVPersistence(sources: [source], activeID: source.id)
        let manager = IPTVSourcesManager(
            persistence: persistence,
            credentialsStore: MockXtreamCredentialsStore()
        )

        try manager.reload()
        #expect(manager.sources == [source])
        #expect(manager.activeSource == source)
    }

    @Test("A Keychain write failure leaves no partially added source")
    func addCredentialFailure() {
        let credentials = MockXtreamCredentialsStore()
        credentials.failSet = true
        let manager = IPTVSourcesManager(
            persistence: MockIPTVPersistence(),
            credentialsStore: credentials
        )

        #expect(throws: IPTVSourcesManagerError.credentialFailure) {
            try manager.add(name: "Failed", serverURL: "https://server.invalid", username: "user", password: "pass")
        }
        #expect(manager.sources.isEmpty)
        #expect(manager.activeSourceID == nil)
    }

    @Test("A metadata write failure rolls back newly stored credentials")
    func addPersistenceFailureRollsBackCredentials() {
        let persistence = MockIPTVPersistence()
        persistence.failSavingSources = true
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)

        #expect(throws: IPTVSourcesManagerError.persistenceFailure) {
            try manager.add(name: "Failed", serverURL: "https://server.invalid", username: "user", password: "pass")
        }
        #expect(manager.sources.isEmpty)
        #expect(credentials.values.isEmpty)
    }

    @Test("Add compensates Keychain when persistence rollback also fails")
    func addRollbackFailureStillDeletesCredentials() {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        persistence.failSavingActiveID = true

        #expect(throws: IPTVSourcesManagerError.rollbackFailure) {
            try manager.add(name: "Failed", serverURL: "https://server.invalid", username: "user", password: "pass")
        }
        #expect(manager.sources.isEmpty)
        #expect(credentials.values.isEmpty)
    }

    @Test("A failed Keychain compensation is reported as rollback failure")
    func addFailedCompensationIsNotMasked() {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        persistence.failSavingActiveID = true
        credentials.failDelete = true

        #expect(throws: IPTVSourcesManagerError.rollbackFailure) {
            try manager.add(name: "Failed", serverURL: "https://server.invalid", username: "user", password: "pass")
        }
    }

    @Test("A Keychain delete failure preserves source metadata")
    func removeCredentialFailure() async throws {
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(
            persistence: MockIPTVPersistence(),
            credentialsStore: credentials
        )
        let source = try manager.add(name: "Saved", serverURL: "https://server.invalid", username: "user", password: "pass")
        credentials.failDelete = true

        await #expect(throws: IPTVSourcesManagerError.credentialFailure) {
            try await manager.remove(id: source.id)
        }
        #expect(manager.sources == [source])
        #expect(manager.activeSourceID == source.id)
    }

    @Test("Removal restores Keychain when persistence rollback also fails")
    func removeRollbackFailureRestoresCredentials() async throws {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        let source = try manager.add(name: "Saved", serverURL: "https://server.invalid", username: "user", password: "pass")
        persistence.failSavingActiveID = true

        await #expect(throws: IPTVSourcesManagerError.rollbackFailure) {
            try await manager.remove(id: source.id)
        }
        #expect(manager.sources == [source])
        #expect(credentials.values[source.id]?.username == "user")
        #expect(credentials.values[source.id]?.password == "pass")
    }

    @Test("A failed Keychain restoration is reported as rollback failure")
    func removeFailedRestorationIsNotMasked() async throws {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        let source = try manager.add(name: "Saved", serverURL: "https://server.invalid", username: "user", password: "pass")
        persistence.failSavingActiveID = true
        credentials.failSet = true

        await #expect(throws: IPTVSourcesManagerError.rollbackFailure) {
            try await manager.remove(id: source.id)
        }
    }

    @Test("Malformed persisted active identifier falls back to first source")
    func malformedActiveIdentifierFallsBack() throws {
        let suiteName = "IPTVSourcesManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try IPTVSource(name: "First", serverURL: "https://server.invalid")
        defaults.set(try JSONEncoder().encode([source]), forKey: UserDefaultsIPTVSourcesPersistence.sourcesKey)
        defaults.set("not-a-uuid", forKey: UserDefaultsIPTVSourcesPersistence.activeSourceKey)
        let persistence = UserDefaultsIPTVSourcesPersistence(defaults: defaults)

        let manager = IPTVSourcesManager(
            persistence: persistence,
            credentialsStore: MockXtreamCredentialsStore()
        )

        #expect(manager.loadError == nil)
        #expect(manager.activeSourceID == source.id)
        #expect(defaults.string(forKey: UserDefaultsIPTVSourcesPersistence.activeSourceKey) == source.id.uuidString)
    }

    @Test("Malformed source data remains a loading error")
    func malformedSourcesAreNotMasked() throws {
        let suiteName = "IPTVSourcesManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsIPTVSourcesPersistence.sourcesKey)

        let manager = IPTVSourcesManager(
            persistence: UserDefaultsIPTVSourcesPersistence(defaults: defaults),
            credentialsStore: MockXtreamCredentialsStore()
        )

        #expect(manager.loadError == .persistenceFailure)
        #expect(manager.sources.isEmpty)
    }

    @Test("Only connection changes rotate the persisted cache revision", arguments: ["host", "username", "password"])
    func connectionRevision(kind: String) throws {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        let source = try manager.add(name: "Original", serverURL: "https://server.invalid", username: "user", password: "pass")
        let other = try manager.add(name: "Other", serverURL: "https://other.invalid", username: "user", password: "pass")
        let renamed = try manager.update(id: source.id, name: "Renamed", serverURL: source.serverURL.absoluteString,
                                         username: "user", password: "pass")
        #expect(renamed.cacheIdentity == source.cacheIdentity)
        let reformatted = try manager.update(id: source.id, name: "Renamed", serverURL: "HTTPS://SERVER.INVALID:443/",
                                             username: "user", password: "pass")
        #expect(reformatted.cacheIdentity == source.cacheIdentity)
        let updated = try manager.update(id: source.id, name: "Changed",
                                         serverURL: kind == "host" ? "https://new.invalid" : source.serverURL.absoluteString,
                                         username: kind == "username" ? "new-user" : "user",
                                         password: kind == "password" ? "new-pass" : "pass")
        #expect(updated.id == source.id)
        #expect(updated.cacheIdentity != source.cacheIdentity)
        #expect(manager.sources.first { $0.id == other.id } == other)
        let restored = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        #expect(restored.activeSource?.cacheIdentity == updated.cacheIdentity)
        let decoded = try JSONDecoder().decode(IPTVSource.self, from: JSONEncoder().encode(updated))
        #expect(decoded.cacheIdentity == updated.cacheIdentity)
    }

    @Test("Update keeps stable identity and rolls credentials back if metadata persistence fails")
    func updateRollback() throws {
        let persistence = MockIPTVPersistence()
        let credentials = MockXtreamCredentialsStore()
        let manager = IPTVSourcesManager(persistence: persistence, credentialsStore: credentials)
        let source = try manager.add(name: "Old", serverURL: "https://old.invalid", username: "old-user", password: "old-pass")
        persistence.failSavingSources = true

        #expect(throws: IPTVSourcesManagerError.persistenceFailure) {
            try manager.update(id: source.id, name: "New", serverURL: "https://new.invalid", username: "new-user", password: "new-pass")
        }
        #expect(manager.sources == [source])
        #expect(credentials.values[source.id]?.username == "old-user")
        #expect(credentials.values[source.id]?.password == "old-pass")
    }
}

@MainActor
private final class MockIPTVPersistence: IPTVSourcesPersisting {
    var storedSources: [IPTVSource]
    var activeID: UUID?
    var failSavingSources = false
    var failSavingActiveID = false

    init(sources: [IPTVSource] = [], activeID: UUID? = nil) {
        storedSources = sources
        self.activeID = activeID
    }

    func loadSources() throws -> [IPTVSource] { storedSources }
    func loadActiveSourceID() throws -> UUID? { activeID }

    func saveSources(_ sources: [IPTVSource]) throws {
        if failSavingSources { throw IPTVSourcesManagerError.persistenceFailure }
        storedSources = sources
    }

    func saveActiveSourceID(_ sourceID: UUID?) throws {
        if failSavingActiveID { throw IPTVSourcesManagerError.persistenceFailure }
        activeID = sourceID
    }
}

@MainActor
private final class MockXtreamCredentialsStore: XtreamCredentialsStoring {
    var values: [UUID: XtreamCredentials] = [:]
    var failRead = false
    var failSet = false
    var failDelete = false

    func credentials(for sourceID: UUID) throws -> XtreamCredentials? {
        if failRead { throw XtreamCredentialsStoreError.keychainFailure(-1) }
        return values[sourceID]
    }

    func setCredentials(_ credentials: XtreamCredentials, for sourceID: UUID) throws {
        if failSet { throw XtreamCredentialsStoreError.keychainFailure(-1) }
        values[sourceID] = credentials
    }

    func deleteCredentials(for sourceID: UUID) throws {
        if failDelete { throw XtreamCredentialsStoreError.keychainFailure(-1) }
        values.removeValue(forKey: sourceID)
    }
}

@MainActor
private final class MockIPTVSourceDataCleaner: IPTVSourceDataCleaning {
    var removedSourceIDs: [UUID] = []
    var shouldFail = false

    func removeData(for sourceID: UUID) async throws {
        removedSourceIDs.append(sourceID)
        if shouldFail {
            throw IPTVSourceDataCleanupError.cleanupFailed
        }
    }
}
