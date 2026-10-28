//
//  FeedarrCredentialsStore.swift
//  Yattee
//
//  Stores optional Feedarr HTTP Basic Auth credentials in a dedicated Keychain service.
//

import Foundation
import Security

struct FeedarrCredentials: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String

    init(username: String, password: String) throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FeedarrCredentialsStoreError.incompleteCredentials
        }
        self.username = username
        self.password = password
    }

    var description: String { "FeedarrCredentials(redacted)" }
    var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey {
        case username, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                username: container.decode(String.self, forKey: .username),
                password: container.decode(String.self, forKey: .password)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .username,
                in: container,
                debugDescription: "Incomplete Feedarr credentials"
            )
        }
    }
}

enum FeedarrCredentialsStoreError: Error, LocalizedError, Equatable, Sendable {
    case incompleteCredentials
    case encodingFailed
    case invalidStoredData
    case keychainFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .incompleteCredentials:
            return "Feedarr credentials require both a username and a password."
        case .encodingFailed:
            return "The Feedarr credentials could not be encoded."
        case .invalidStoredData:
            return "The stored Feedarr credentials are invalid."
        case .keychainFailure:
            return "The local Feedarr credential store is unavailable."
        }
    }
}

@MainActor
protocol FeedarrCredentialsStoring: AnyObject {
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials?
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws
    func deleteCredentials(for sourceID: UUID) throws
}

@MainActor
protocol FeedarrKeychainAccessing: AnyObject {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

@MainActor
final class SystemFeedarrKeychain: FeedarrKeychainAccessing {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FeedarrCredentialsStoreError.keychainFailure(status)
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
            throw FeedarrCredentialsStoreError.keychainFailure(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw FeedarrCredentialsStoreError.keychainFailure(addStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FeedarrCredentialsStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

@MainActor
final class FeedarrCredentialsStore: FeedarrCredentialsStoring {
    static let serviceName = "com.app.xtubee.feedarr.basic-auth"

    private let keychain: FeedarrKeychainAccessing
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        keychain = SystemFeedarrKeychain()
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    init(
        keychain: FeedarrKeychainAccessing,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.keychain = keychain
        self.encoder = encoder
        self.decoder = decoder
    }

    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? {
        guard let data = try keychain.read(
            service: Self.serviceName,
            account: sourceID.uuidString
        ) else {
            return nil
        }
        do {
            return try decoder.decode(FeedarrCredentials.self, from: data)
        } catch {
            throw FeedarrCredentialsStoreError.invalidStoredData
        }
    }

    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws {
        let data: Data
        do {
            data = try encoder.encode(credentials)
        } catch {
            throw FeedarrCredentialsStoreError.encodingFailed
        }
        try keychain.write(data, service: Self.serviceName, account: sourceID.uuidString)
    }

    func deleteCredentials(for sourceID: UUID) throws {
        try keychain.delete(service: Self.serviceName, account: sourceID.uuidString)
    }
}
