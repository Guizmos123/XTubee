//
//  XtreamCredentialsStoreTests.swift
//  YatteeTests
//
//  Tests for local-only Xtream credential storage.
//

import Foundation
import Security
import Testing
@testable import XTubee

@Suite("Xtream Credentials Store Tests")
@MainActor
struct XtreamCredentialsStoreTests {
    @Test("Stores, replaces, reads, and deletes credentials by source ID")
    func lifecycle() throws {
        let keychain = MockXtreamKeychain()
        let store = XtreamCredentialsStore(keychain: keychain)
        let firstID = UUID()
        let secondID = UUID()

        try store.setCredentials(.init(username: "first", password: "secret-1"), for: firstID)
        try store.setCredentials(.init(username: "second", password: "secret-2"), for: secondID)
        try store.setCredentials(.init(username: "updated", password: "secret-3"), for: firstID)

        #expect(try store.credentials(for: firstID)?.username == "updated")
        #expect(try store.credentials(for: secondID)?.username == "second")

        try store.deleteCredentials(for: firstID)
        #expect(try store.credentials(for: firstID) == nil)
        #expect(try store.credentials(for: secondID) != nil)
    }

    @Test("Uses a dedicated service and UUID account")
    func namespace() throws {
        let keychain = MockXtreamKeychain()
        let store = XtreamCredentialsStore(keychain: keychain)
        let id = UUID()

        try store.setCredentials(.init(username: "user", password: "pass"), for: id)

        #expect(XtreamCredentialsStore.serviceName == "com.app.xtubee.iptv.xtream")
        #expect(keychain.lastService == XtreamCredentialsStore.serviceName)
        #expect(keychain.lastAccount == id.uuidString)
    }

    @Test("System Keychain attributes are local-only and device-only")
    func localOnlyAttributes() {
        let keychain = SystemXtreamKeychain()
        let query = keychain.baseQuery(service: "test", account: "account")
        let attributes = keychain.addAttributes(data: Data(), service: "test", account: "account")

        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test("Maps corrupt stored data without exposing it")
    func corruptData() {
        let keychain = MockXtreamKeychain()
        let id = UUID()
        keychain.values[id.uuidString] = Data("not-json".utf8)
        let store = XtreamCredentialsStore(keychain: keychain)

        #expect(throws: XtreamCredentialsStoreError.invalidStoredData) {
            try store.credentials(for: id)
        }
    }

    @Test("Propagates simulated Keychain failures with non-sensitive errors")
    func failuresAreNonSensitive() {
        let keychain = MockXtreamKeychain()
        keychain.error = .keychainFailure(-1)
        let store = XtreamCredentialsStore(keychain: keychain)
        let credentials = XtreamCredentials(username: "fictional-user", password: "fictional-password")

        do {
            try store.setCredentials(credentials, for: UUID())
            Issue.record("Expected storage to fail")
        } catch {
            #expect(!error.localizedDescription.contains(credentials.username))
            #expect(!error.localizedDescription.contains(credentials.password))
            #expect(!String(reflecting: error).contains(credentials.username))
            #expect(!String(reflecting: error).contains(credentials.password))
        }
    }

    @Test("Credential descriptions are redacted")
    func descriptionsAreRedacted() {
        let credentials = XtreamCredentials(username: "fictional-user", password: "fictional-password")

        #expect(!String(describing: credentials).contains(credentials.username))
        #expect(!String(describing: credentials).contains(credentials.password))
        #expect(!String(reflecting: credentials).contains(credentials.username))
        #expect(!String(reflecting: credentials).contains(credentials.password))
    }
}

@MainActor
private final class MockXtreamKeychain: XtreamKeychainAccessing {
    var values: [String: Data] = [:]
    var error: XtreamCredentialsStoreError?
    var lastService: String?
    var lastAccount: String?

    func read(service: String, account: String) throws -> Data? {
        try record(service: service, account: account)
        return values[account]
    }

    func write(_ data: Data, service: String, account: String) throws {
        try record(service: service, account: account)
        values[account] = data
    }

    func delete(service: String, account: String) throws {
        try record(service: service, account: account)
        values.removeValue(forKey: account)
    }

    private func record(service: String, account: String) throws {
        lastService = service
        lastAccount = account
        if let error { throw error }
    }
}
