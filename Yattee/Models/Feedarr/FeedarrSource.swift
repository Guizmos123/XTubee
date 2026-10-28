//
//  FeedarrSource.swift
//  Yattee
//
//  Non-sensitive configuration for a Feedarr source.
//

import Foundation

enum FeedarrSourceError: Error, LocalizedError, Equatable, Sendable {
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "The Feedarr source name must not be empty."
        }
    }
}

struct FeedarrSource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var serverURL: URL
    let dateAdded: Date
    var usesBasicAuth: Bool

    init(
        id: UUID = UUID(),
        name: String,
        serverURL: String,
        dateAdded: Date = Date(),
        usesBasicAuth: Bool = false
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw FeedarrSourceError.invalidName
        }

        self.id = id
        self.name = normalizedName
        self.serverURL = try FeedarrServerURL.normalize(serverURL)
        self.dateAdded = dateAdded
        self.usesBasicAuth = usesBasicAuth
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, serverURL, dateAdded, usesBasicAuth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decode(String.self, forKey: .name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Invalid Feedarr source name"
            )
        }

        let storedURL = try container.decode(URL.self, forKey: .serverURL)
        let normalizedURL: URL
        do {
            normalizedURL = try FeedarrServerURL.normalize(storedURL.absoluteString)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .serverURL,
                in: container,
                debugDescription: "Invalid Feedarr server URL"
            )
        }

        id = try container.decode(UUID.self, forKey: .id)
        name = decodedName
        serverURL = normalizedURL
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        usesBasicAuth = try container.decode(Bool.self, forKey: .usesBasicAuth)
    }
}
