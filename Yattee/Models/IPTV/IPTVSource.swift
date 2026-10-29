//
//  IPTVSource.swift
//  Yattee
//
//  Non-sensitive configuration for an Xtream IPTV source.
//

import Foundation

struct IPTVSource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var serverURL: URL
    let dateAdded: Date
    /// Non-secret generation; nil keeps existing installations' valid caches readable.
    var configurationRevision: UUID?

    var cacheIdentity: UUID { configurationRevision ?? id }

    init(
        id: UUID = UUID(),
        name: String,
        serverURL: String,
        dateAdded: Date = Date(),
        configurationRevision: UUID? = nil
    ) throws {
        self.id = id
        self.name = name
        self.serverURL = try XtreamServerURL.normalize(serverURL)
        self.dateAdded = dateAdded
        self.configurationRevision = configurationRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, serverURL, dateAdded, configurationRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        configurationRevision = try container.decodeIfPresent(UUID.self, forKey: .configurationRevision)

        let storedURL = try container.decode(URL.self, forKey: .serverURL)
        do {
            serverURL = try XtreamServerURL.normalize(storedURL.absoluteString)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .serverURL,
                in: container,
                debugDescription: "Invalid IPTV server URL"
            )
        }
    }
}
