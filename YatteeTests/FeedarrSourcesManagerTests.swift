//
//  FeedarrSourcesManagerTests.swift
//  YatteeTests
//
//  Tests single-source Feedarr persistence and credential transactions.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Sources Manager Tests")
@MainActor
struct FeedarrSourcesManagerTests {
    @Test("No source is configured initially")
    func initiallyEmpty() {
        let manager = makeManager()
        #expect(manager.source == nil)
        #expect(manager.loadError == nil)
    }

    @Test("A saved source is loaded")
    func loadsSavedSource() throws {
        let saved = try source()
        let manager = makeManager(persistence: MockFeedarrSourcePersistence(source: saved))
        #expect(manager.source == saved)
        #expect(manager.loadError == nil)
    }

    @Test("An open source is added without Keychain data")
    func addsOpenSource() throws {
        let persistence = MockFeedarrSourcePersistence()
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(persistence: persistence, credentials: credentials)

        let added = try manager.add(
            name: " Local ",
            serverURL: "http://feedarr.local:8080/",
            usesBasicAuth: false
        )

        #expect(added.name == "Local")
        #expect(persistence.source == added)
        #expect(credentials.values.isEmpty)
    }

    @Test("HTTPS Basic Auth stores complete credentials")
    func addsHTTPSBasicAuth() throws {
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(credentials: credentials)
        let added = try manager.add(
            name: "Secure",
            serverURL: "https://feedarr.example",
            usesBasicAuth: true,
            username: "alice",
            password: "secret"
        )
        let expected = try FeedarrCredentials(username: "alice", password: "secret")
        #expect(credentials.values[added.id] == expected)
    }

    @Test("A second source is rejected")
    func rejectsSecondSource() throws {
        let manager = makeManager()
        _ = try manager.add(name: "One", serverURL: "https://one.invalid", usesBasicAuth: false)
        #expect(throws: FeedarrSourcesManagerError.sourceAlreadyExists) {
            try manager.add(name: "Two", serverURL: "https://two.invalid", usesBasicAuth: false)
        }
    }

    @Test("HTTP Basic Auth is rejected")
    func rejectsHTTPBasicAuth() {
        let manager = makeManager()
        #expect(throws: FeedarrSourcesManagerError.insecureBasicAuth) {
            try manager.add(
                name: "Unsafe",
                serverURL: "http://feedarr.local",
                usesBasicAuth: true,
                username: "user",
                password: "pass"
            )
        }
    }

    @Test("Incomplete credentials are rejected")
    func rejectsIncompleteCredentials() {
        let manager = makeManager()
        #expect(throws: FeedarrSourcesManagerError.incompleteCredentials) {
            try manager.add(
                name: "Incomplete",
                serverURL: "https://feedarr.example",
                usesBasicAuth: true,
                username: "user"
            )
        }
    }

    @Test("Basic Auth without credentials is rejected")
    func rejectsMissingCredentials() {
        let manager = makeManager()
        #expect(throws: FeedarrSourcesManagerError.missingCredentials) {
            try manager.add(
                name: "Missing",
                serverURL: "https://feedarr.example",
                usesBasicAuth: true
            )
        }
    }

    @Test("Renaming preserves identity and date")
    func renamesSource() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = makeManager()
        let added = try manager.add(
            name: "Old",
            serverURL: "https://feedarr.example",
            usesBasicAuth: false,
            dateAdded: date
        )
        let updated = try manager.update(
            id: added.id,
            name: "New",
            serverURL: added.serverURL.absoluteString,
            usesBasicAuth: false
        )
        #expect(updated.name == "New")
        #expect(updated.id == added.id)
        #expect(updated.dateAdded == date)
    }

    @Test("Credentials can be replaced")
    func updatesCredentials() throws {
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(credentials: credentials)
        let added = try addAuthenticated(to: manager)
        _ = try manager.update(
            id: added.id,
            name: added.name,
            serverURL: added.serverURL.absoluteString,
            usesBasicAuth: true,
            username: "new-user",
            password: "new-pass"
        )
        let expected = try FeedarrCredentials(username: "new-user", password: "new-pass")
        #expect(credentials.values[added.id] == expected)
    }

    @Test("Switching to open access removes credentials")
    func opensSource() throws {
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(credentials: credentials)
        let added = try addAuthenticated(to: manager)
        _ = try manager.update(
            id: added.id,
            name: added.name,
            serverURL: added.serverURL.absoluteString,
            usesBasicAuth: false
        )
        #expect(credentials.values[added.id] == nil)
    }

    @Test("A URL change never reuses Basic Auth credentials")
    func URLChangeRequiresCredentials() throws {
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(credentials: credentials)
        let added = try addAuthenticated(to: manager)
        #expect(throws: FeedarrSourcesManagerError.missingCredentials) {
            try manager.update(
                id: added.id,
                name: added.name,
                serverURL: "https://other.invalid",
                usesBasicAuth: true
            )
        }
        #expect(manager.source == added)
    }

    @Test("Removing a source removes metadata and credentials")
    func removesSource() throws {
        let persistence = MockFeedarrSourcePersistence()
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(persistence: persistence, credentials: credentials)
        let added = try addAuthenticated(to: manager)
        try manager.remove(id: added.id)
        #expect(manager.source == nil)
        #expect(persistence.source == nil)
        #expect(credentials.values.isEmpty)
    }

    @Test("Unknown identifiers cannot update or remove")
    func rejectsUnknownIdentifiers() throws {
        let manager = makeManager()
        _ = try manager.add(name: "Saved", serverURL: "https://feedarr.example", usesBasicAuth: false)
        #expect(throws: FeedarrSourcesManagerError.sourceNotFound) {
            try manager.update(id: UUID(), name: "Other", serverURL: "https://other.invalid", usesBasicAuth: false)
        }
        #expect(throws: FeedarrSourcesManagerError.sourceNotFound) {
            try manager.remove(id: UUID())
        }
    }

    @Test("A Keychain write failure publishes nothing")
    func keychainWriteFailure() {
        let credentials = MockFeedarrCredentialsStore(failingSetCalls: [1])
        let manager = makeManager(credentials: credentials)
        #expect(throws: FeedarrSourcesManagerError.credentialFailure) {
            try addAuthenticated(to: manager)
        }
        #expect(manager.source == nil)
    }

    @Test("A metadata failure removes newly written credentials")
    func addPersistenceRollback() {
        let persistence = MockFeedarrSourcePersistence(failSave: true)
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(persistence: persistence, credentials: credentials)
        #expect(throws: FeedarrSourcesManagerError.persistenceFailure) {
            try addAuthenticated(to: manager)
        }
        #expect(manager.source == nil)
        #expect(credentials.values.isEmpty)
    }

    @Test("An update failure restores old credentials and memory")
    func updateRollback() throws {
        let persistence = MockFeedarrSourcePersistence()
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(persistence: persistence, credentials: credentials)
        let added = try addAuthenticated(to: manager)
        persistence.failSave = true
        #expect(throws: FeedarrSourcesManagerError.persistenceFailure) {
            try manager.update(
                id: added.id,
                name: "Changed",
                serverURL: added.serverURL.absoluteString,
                usesBasicAuth: true,
                username: "new",
                password: "value"
            )
        }
        #expect(manager.source == added)
        let expected = try FeedarrCredentials(username: "old-user", password: "old-pass")
        #expect(credentials.values[added.id] == expected)
    }

    @Test("A failed compensation is reported")
    func rollbackFailure() {
        let persistence = MockFeedarrSourcePersistence(failSave: true)
        let credentials = MockFeedarrCredentialsStore(failDelete: true)
        let manager = makeManager(persistence: persistence, credentials: credentials)
        #expect(throws: FeedarrSourcesManagerError.rollbackFailure) {
            try addAuthenticated(to: manager)
        }
    }

    @Test("Removal restores credentials when metadata deletion fails")
    func removeRollback() throws {
        let persistence = MockFeedarrSourcePersistence()
        let credentials = MockFeedarrCredentialsStore()
        let manager = makeManager(persistence: persistence, credentials: credentials)
        let added = try addAuthenticated(to: manager)
        persistence.failSave = true
        #expect(throws: FeedarrSourcesManagerError.persistenceFailure) {
            try manager.remove(id: added.id)
        }
        #expect(manager.source == added)
        #expect(credentials.values[added.id] != nil)
    }

    @Test("Corrupted persisted data preserves memory and reports an error")
    func corruptedPersistence() throws {
        let persistence = MockFeedarrSourcePersistence(source: try source())
        let manager = makeManager(persistence: persistence)
        let previous = manager.source
        persistence.failLoad = true
        #expect(throws: FeedarrSourcesManagerError.persistenceFailure) {
            try manager.reload()
        }
        #expect(manager.source == previous)
        #expect(manager.loadError == .persistenceFailure)
    }

    @Test("Missing stored credentials are exposed as a loading error")
    func missingCredentialsOnLoad() throws {
        let saved = try source(usesBasicAuth: true)
        let manager = makeManager(persistence: MockFeedarrSourcePersistence(source: saved))
        #expect(manager.source == saved)
        #expect(manager.loadError == .missingCredentials)
    }

    @Test("Feedarr persistence is isolated from YouTube and IPTV keys")
    func persistenceIsolation() throws {
        let suiteName = "FeedarrSourcesManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("youtube".utf8), forKey: "configuredInstances")
        defaults.set(Data("iptv".utf8), forKey: UserDefaultsIPTVSourcesPersistence.sourcesKey)
        let persistence = UserDefaultsFeedarrSourcePersistence(defaults: defaults)
        let saved = try source()
        try persistence.saveSource(saved)
        #expect(try persistence.loadSource() == saved)
        #expect(defaults.data(forKey: "configuredInstances") == Data("youtube".utf8))
        #expect(defaults.data(forKey: UserDefaultsIPTVSourcesPersistence.sourcesKey) == Data("iptv".utf8))
    }

    @Test("Persisted metadata never contains credentials")
    func persistedMetadataContainsNoSecrets() throws {
        let persistence = MockFeedarrSourcePersistence()
        let manager = makeManager(persistence: persistence)
        _ = try manager.add(
            name: "Secure",
            serverURL: "https://feedarr.example",
            usesBasicAuth: true,
            username: "private-user",
            password: "private-password"
        )
        let payload = String(decoding: try JSONEncoder().encode(try #require(persistence.source)), as: UTF8.self)
        #expect(!payload.contains("private-user"))
        #expect(!payload.contains("private-password"))
    }

    private func makeManager(
        persistence: MockFeedarrSourcePersistence? = nil,
        credentials: MockFeedarrCredentialsStore? = nil
    ) -> FeedarrSourcesManager {
        FeedarrSourcesManager(
            persistence: persistence ?? MockFeedarrSourcePersistence(),
            credentialsStore: credentials ?? MockFeedarrCredentialsStore()
        )
    }

    private func source(usesBasicAuth: Bool = false) throws -> FeedarrSource {
        try FeedarrSource(
            name: "Saved",
            serverURL: "https://feedarr.example",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            usesBasicAuth: usesBasicAuth
        )
    }

    private func addAuthenticated(to manager: FeedarrSourcesManager) throws -> FeedarrSource {
        try manager.add(
            name: "Secure",
            serverURL: "https://feedarr.example",
            usesBasicAuth: true,
            username: "old-user",
            password: "old-pass"
        )
    }
}

@MainActor
private final class MockFeedarrSourcePersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    var failLoad = false
    var failSave: Bool

    init(source: FeedarrSource? = nil, failSave: Bool = false) {
        self.source = source
        self.failSave = failSave
    }

    func loadSource() throws -> FeedarrSource? {
        if failLoad { throw FeedarrSourcesManagerError.persistenceFailure }
        return source
    }

    func saveSource(_ source: FeedarrSource?) throws {
        if failSave { throw FeedarrSourcesManagerError.persistenceFailure }
        self.source = source
    }
}

@MainActor
private final class MockFeedarrCredentialsStore: FeedarrCredentialsStoring {
    var values: [UUID: FeedarrCredentials] = [:]
    var failRead = false
    var failDelete: Bool
    var failingSetCalls: Set<Int>
    private var setCallCount = 0

    init(failingSetCalls: Set<Int> = [], failDelete: Bool = false) {
        self.failingSetCalls = failingSetCalls
        self.failDelete = failDelete
    }

    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? {
        if failRead { throw FeedarrCredentialsStoreError.keychainFailure(-1) }
        return values[sourceID]
    }

    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws {
        setCallCount += 1
        if failingSetCalls.contains(setCallCount) {
            throw FeedarrCredentialsStoreError.keychainFailure(-1)
        }
        values[sourceID] = credentials
    }

    func deleteCredentials(for sourceID: UUID) throws {
        if failDelete { throw FeedarrCredentialsStoreError.keychainFailure(-1) }
        values.removeValue(forKey: sourceID)
    }
}
