//
//  XtreamAPIModels.swift
//  Yattee
//
//  Decodable response models for the Xtream Codes live TV API.
//

import Foundation

// MARK: - Account

struct XtreamAccountResponse: Decodable, Hashable, Sendable {
    let userInfo: XtreamUserInfo
    let serverInfo: XtreamServerInfo

    private enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

struct XtreamUserInfo: Decodable, Hashable, Sendable {
    let isAuthenticated: Bool?
    let status: String?
    let expirationDate: Date?
    let maxConnections: Int?
    let activeConnections: Int?
    let allowedOutputFormats: [String]?

    private enum CodingKeys: String, CodingKey {
        case auth
        case status
        case expirationDate = "exp_date"
        case maxConnections = "max_connections"
        case activeConnections = "active_cons"
        case allowedOutputFormats = "allowed_output_formats"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAuthenticated = try container.decodeFlexibleBoolIfPresent(forKey: .auth)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        expirationDate = try container.decodeUnixDateIfPresent(forKey: .expirationDate)
        maxConnections = try container.decodeFlexibleIntIfPresent(forKey: .maxConnections)
        activeConnections = try container.decodeFlexibleIntIfPresent(forKey: .activeConnections)
        allowedOutputFormats = try container.decodeIfPresent([String].self, forKey: .allowedOutputFormats)
    }
}

struct XtreamServerInfo: Decodable, Hashable, Sendable {
    let host: String?
    let port: Int?
    let httpsPort: Int?
    let serverProtocol: String?
    let timezone: String?

    private enum CodingKeys: String, CodingKey {
        case host = "url"
        case port
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case timezone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        port = try container.decodeFlexibleIntIfPresent(forKey: .port)
        httpsPort = try container.decodeFlexibleIntIfPresent(forKey: .httpsPort)
        serverProtocol = try container.decodeIfPresent(String.self, forKey: .serverProtocol)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
    }
}

// MARK: - Live Catalog

struct XtreamLiveCategory: Codable, Hashable, Sendable {
    let categoryID: String
    let name: String
    let parentID: String?

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case name = "category_name"
        case parentID = "parent_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = try container.decodeRequiredFlexibleString(forKey: .categoryID)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeFlexibleStringIfPresent(forKey: .parentID)
    }
}

struct XtreamLiveStream: Codable, Hashable, Sendable {
    let streamID: String
    let name: String
    let streamIconURL: URL?
    let categoryID: String?
    let streamType: String?
    let addedDate: Date?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case categoryID = "category_id"
        case streamType = "stream_type"
        case added = "added"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decodeRequiredFlexibleString(forKey: .streamID)
        name = try container.decode(String.self, forKey: .name)
        streamIconURL = try container.decodeHTTPURLIfPresent(forKey: .streamIcon)
        categoryID = try container.decodeFlexibleStringIfPresent(forKey: .categoryID)
        streamType = try container.decodeIfPresent(String.self, forKey: .streamType)
        addedDate = try container.decodeUnixDateIfPresent(forKey: .added)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(streamIconURL?.absoluteString, forKey: .streamIcon)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        try container.encodeIfPresent(streamType, forKey: .streamType)
        try container.encodeIfPresent(addedDate?.timeIntervalSince1970, forKey: .added)
    }
}

// MARK: - Flexible Xtream Values

private extension KeyedDecodingContainer {
    func decodeRequiredFlexibleString(forKey key: Key) throws -> String {
        guard let value = try decodeFlexibleStringIfPresent(forKey: key) else {
            throw DecodingError.valueNotFound(
                String.self,
                DecodingError.Context(
                    codingPath: codingPath + [key],
                    debugDescription: "Expected a string or integer identifier"
                )
            )
        }
        return value
    }

    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }

        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(UInt64.self, forKey: key) {
            return String(value)
        }

        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a string or integer"
            )
        )
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }

        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key), let integer = Int(value) {
            return integer
        }

        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected an integer or an integer encoded as a string"
            )
        )
    }

    func decodeFlexibleBoolIfPresent(forKey key: Key) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }

        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key), value == 0 || value == 1 {
            return value == 1
        }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: break
            }
        }

        throw DecodingError.typeMismatch(
            Bool.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a boolean or a 0/1 value"
            )
        )
    }

    func decodeUnixDateIfPresent(forKey key: Key) throws -> Date? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }

        if let timestamp = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let value = try? decode(String.self, forKey: key) {
            guard !value.isEmpty else { return nil }
            if let timestamp = TimeInterval(value) {
                return Date(timeIntervalSince1970: timestamp)
            }
        }

        throw DecodingError.typeMismatch(
            Date.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a Unix timestamp or a numeric timestamp string"
            )
        )
    }

    func decodeHTTPURLIfPresent(forKey key: Key) throws -> URL? {
        guard let value = try decodeIfPresent(String.self, forKey: key), !value.isEmpty,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }
        return components.url
    }
}
