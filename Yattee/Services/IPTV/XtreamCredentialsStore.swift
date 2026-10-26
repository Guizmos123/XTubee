//
//  XtreamCredentialsStore.swift
//  Yattee
//
//  Stores Xtream credentials locally in the Keychain without iCloud sync.
//

import Foundation
import Security

struct XtreamCredentials: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String

    var description: String { "XtreamCredentials(redacted)" }
    var debugDescription: String { description }
}

enum XtreamCredentialsStoreError: Error, LocalizedError, Equatable, Sendable {
    case encodingFailed
    case invalidStoredData
    case keychainFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "The IPTV credentials could not be encoded."
        case .invalidStoredData:
            return "The stored IPTV credentials are invalid."
        case .keychainFailure:
            return "The local credential store is unavailable."
        }
    }
}

@MainActor
protocol XtreamCredentialsStoring: AnyObject {
    func credentials(for sourceID: UUID) throws -> XtreamCredentials?
    func setCredentials(_ credentials: XtreamCredentials, for sourceID: UUID) throws
    func deleteCredentials(for sourceID: UUID) throws
}

@MainActor
protocol XtreamKeychainAccessing: AnyObject {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

@MainActor
final class SystemXtreamKeychain: XtreamKeychainAccessing {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw XtreamCredentialsStoreError.keychainFailure(status)
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw XtreamCredentialsStoreError.keychainFailure(updateStatus)
        }

        let attributes = addAttributes(
            data: data,
            service: service,
            account: account
        )
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw XtreamCredentialsStoreError.keychainFailure(addStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw XtreamCredentialsStoreError.keychainFailure(status)
        }
    }

    func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func addAttributes(data: Data, service: String, account: String) -> [String: Any] {
        var attributes = baseQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }
}

@MainActor
final class XtreamCredentialsStore: XtreamCredentialsStoring {
    static let serviceName = "com.app.xtubee.iptv.xtream"

    private let keychain: XtreamKeychainAccessing
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        keychain = SystemXtreamKeychain()
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    init(
        keychain: XtreamKeychainAccessing,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.keychain = keychain
        self.encoder = encoder
        self.decoder = decoder
    }

    func credentials(for sourceID: UUID) throws -> XtreamCredentials? {
        guard let data = try keychain.read(
            service: Self.serviceName,
            account: sourceID.uuidString
        ) else {
            return nil
        }

        guard let credentials = try? decoder.decode(XtreamCredentials.self, from: data) else {
            throw XtreamCredentialsStoreError.invalidStoredData
        }
        return credentials
    }

    func setCredentials(_ credentials: XtreamCredentials, for sourceID: UUID) throws {
        guard let data = try? encoder.encode(credentials) else {
            throw XtreamCredentialsStoreError.encodingFailed
        }
        try keychain.write(data, service: Self.serviceName, account: sourceID.uuidString)
    }

    func deleteCredentials(for sourceID: UUID) throws {
        try keychain.delete(service: Self.serviceName, account: sourceID.uuidString)
    }
}
