//
//  FeedarrReleasesResponse.swift
//  Yattee
//
//  GET /api/feed/releases contract. Cursor contents are opaque to the client.
//

import Foundation

struct FeedarrReleasesResponse: Codable, Hashable, Sendable {
    let items: [FeedarrRelease]
    let pagination: FeedarrPagination
    let query: FeedarrReleasesQuery?
}

struct FeedarrPagination: Codable, Hashable, Sendable {
    let limit: Int
    let hasMore: Bool
    let nextCursor: String?
    /// Insertion boundary, not an immutable snapshot of metrics or categories.
    let snapshotMaxId: Int64
}

struct FeedarrReleasesQuery: Codable, Hashable, Sendable {
    let sort: FeedarrReleasesSort
    let direction: String
    let q: String?
    let sourceIds: [Int64]
    /// Not restricted to the six Top rails: preserve any server category key.
    let unifiedCategory: String?
    let seen: Int?
    let minSeeders: Int?
}
