//
//  FeedarrFoundationTests.swift
//  YatteeTests
//
//  Tests for Feedarr source metadata, URL normalization, and credential storage.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Source Tests")
struct FeedarrSourceTests {
    @Test("A valid source normalizes its name and URL")
    func validInitialization() throws {
        let source = try FeedarrSource(
            name: " Home Feedarr ",
            serverURL: "HTTPS://feedarr.example/base/",
            usesBasicAuth: true
        )

        #expect(source.name == "Home Feedarr")
        #expect(source.serverURL.absoluteString == "https://feedarr.example/base")
        #expect(source.usesBasicAuth)
    }

    @Test("Codable round trip preserves identity and date")
    func codableRoundTrip() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try FeedarrSource(
            id: id,
            name: "Feedarr",
            serverURL: "http://192.168.1.20:8080/",
            dateAdded: date,
            usesBasicAuth: false
        )

        let decoded = try JSONDecoder().decode(
            FeedarrSource.self,
            from: JSONEncoder().encode(source)
        )

        #expect(decoded == source)
        #expect(decoded.id == id)
        #expect(decoded.dateAdded == date)
    }

    @Test("Decoding rejects an invalid stored URL")
    func invalidStoredURL() throws {
        let json = """
            {
              "id":"\(UUID().uuidString)",
              "name":"Feedarr",
              "serverURL":"ftp://feedarr.example",
              "dateAdded":0,
              "usesBasicAuth":false
            }
            """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FeedarrSource.self, from: Data(json.utf8))
        }
    }

    @Test("Source serialization contains no credentials")
    func serializationContainsNoSecrets() throws {
        let data = try JSONEncoder().encode(
            FeedarrSource(
                name: "Feedarr",
                serverURL: "https://feedarr.example",
                usesBasicAuth: true
            )
        )
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.localizedCaseInsensitiveContains("username"))
        #expect(!json.localizedCaseInsensitiveContains("password"))
        #expect(!json.localizedCaseInsensitiveContains("authorization"))
    }

    @Test("Empty names are rejected")
    func invalidName() {
        #expect(throws: FeedarrSourceError.invalidName) {
            try FeedarrSource(name: "  ", serverURL: "https://feedarr.example")
        }
    }
}

@Suite("Feedarr Server URL Tests")
struct FeedarrServerURLTests {
    @Test(
        "Valid server URLs are normalized",
        arguments: [
            ("HTTPS://feedarr.example", "https://feedarr.example"),
            ("http://feedarr.local", "http://feedarr.local"),
            ("http://192.168.1.25:8080", "http://192.168.1.25:8080"),
            ("https://feedarr.example/apps/feedarr", "https://feedarr.example/apps/feedarr"),
            ("https://feedarr.example/apps/feedarr///", "https://feedarr.example/apps/feedarr")
        ]
    )
    func validURLs(input: String, expected: String) throws {
        #expect(try FeedarrServerURL.normalize(input).absoluteString == expected)
    }

    @Test(
        "Unsafe or malformed server URLs are rejected",
        arguments: [
            "not a url",
            "https:///missing-host",
            "ftp://feedarr.example",
            "https://user:password@feedarr.example",
            "https://feedarr.example?username=alice&password=secret",
            "https://feedarr.example/#settings"
        ]
    )
    func invalidURLs(input: String) {
        #expect(throws: (any Error).self) {
            try FeedarrServerURL.normalize(input)
        }
    }

    @Test("Normalization never upgrades HTTP to HTTPS")
    func preservesHTTP() throws {
        #expect(try FeedarrServerURL.normalize("http://localhost:8080/").scheme == "http")
    }
}

@Suite("Feedarr Credentials Store Tests")
@MainActor
struct FeedarrCredentialsStoreTests {
    @Test("Credentials can be written and read")
    func writeAndRead() throws {
        let keychain = MockFeedarrKeychain()
        let store = FeedarrCredentialsStore(keychain: keychain)
        let sourceID = UUID()
        let credentials = try FeedarrCredentials(username: "alice", password: "secret")

        try store.setCredentials(credentials, for: sourceID)

        #expect(try store.credentials(for: sourceID) == credentials)
        #expect(keychain.lastService == FeedarrCredentialsStore.serviceName)
        #expect(keychain.lastAccount == sourceID.uuidString)
    }

    @Test("Writing new credentials replaces the existing value")
    func replacement() throws {
        let store = FeedarrCredentialsStore(keychain: MockFeedarrKeychain())
        let sourceID = UUID()

        try store.setCredentials(
            FeedarrCredentials(username: "first", password: "old"),
            for: sourceID
        )
        let replacement = try FeedarrCredentials(username: "second", password: "new")
        try store.setCredentials(replacement, for: sourceID)

        #expect(try store.credentials(for: sourceID) == replacement)
    }

    @Test("Credentials can be deleted")
    func deletion() throws {
        let store = FeedarrCredentialsStore(keychain: MockFeedarrKeychain())
        let sourceID = UUID()
        try store.setCredentials(
            FeedarrCredentials(username: "alice", password: "secret"),
            for: sourceID
        )

        try store.deleteCredentials(for: sourceID)

        #expect(try store.credentials(for: sourceID) == nil)
    }

    @Test("Credentials remain isolated by source identifier")
    func sourceIsolation() throws {
        let store = FeedarrCredentialsStore(keychain: MockFeedarrKeychain())
        let firstID = UUID()
        let secondID = UUID()
        let first = try FeedarrCredentials(username: "first", password: "one")
        let second = try FeedarrCredentials(username: "second", password: "two")

        try store.setCredentials(first, for: firstID)
        try store.setCredentials(second, for: secondID)

        #expect(try store.credentials(for: firstID) == first)
        #expect(try store.credentials(for: secondID) == second)
    }

    @Test("Incomplete credentials are never representable")
    func incompleteCredentials() {
        #expect(throws: FeedarrCredentialsStoreError.incompleteCredentials) {
            try FeedarrCredentials(username: "", password: "secret")
        }
        #expect(throws: FeedarrCredentialsStoreError.incompleteCredentials) {
            try FeedarrCredentials(username: "alice", password: "  ")
        }
    }

    @Test("Read and write failures are propagated")
    func keychainFailures() throws {
        let keychain = MockFeedarrKeychain()
        let store = FeedarrCredentialsStore(keychain: keychain)
        let sourceID = UUID()
        keychain.readError = FeedarrCredentialsStoreError.keychainFailure(-1)

        #expect(throws: FeedarrCredentialsStoreError.keychainFailure(-1)) {
            try store.credentials(for: sourceID)
        }

        keychain.readError = nil
        keychain.writeError = FeedarrCredentialsStoreError.keychainFailure(-2)
        #expect(throws: FeedarrCredentialsStoreError.keychainFailure(-2)) {
            try store.setCredentials(
                FeedarrCredentials(username: "alice", password: "secret"),
                for: sourceID
            )
        }
    }

    @Test("Descriptions redact all secret values")
    func redactedDescriptions() throws {
        let credentials = try FeedarrCredentials(
            username: "private-user",
            password: "private-password"
        )

        #expect(!credentials.description.contains("private-user"))
        #expect(!credentials.description.contains("private-password"))
        #expect(!credentials.debugDescription.contains("private-user"))
        #expect(!credentials.debugDescription.contains("private-password"))
    }
}

@MainActor
private final class MockFeedarrKeychain: FeedarrKeychainAccessing {
    var values: [String: Data] = [:]
    var readError: Error?
    var writeError: Error?
    var deleteError: Error?
    private(set) var lastService: String?
    private(set) var lastAccount: String?

    func read(service: String, account: String) throws -> Data? {
        lastService = service
        lastAccount = account
        if let readError { throw readError }
        return values[key(service: service, account: account)]
    }

    func write(_ data: Data, service: String, account: String) throws {
        lastService = service
        lastAccount = account
        if let writeError { throw writeError }
        values[key(service: service, account: account)] = data
    }

    func delete(service: String, account: String) throws {
        lastService = service
        lastAccount = account
        if let deleteError { throw deleteError }
        values.removeValue(forKey: key(service: service, account: account))
    }

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}
