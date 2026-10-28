//
//  FeedarrTopResponse.swift
//  Yattee
//
//  GET /api/feed/top response and its window/category envelopes.
//

import Foundation

struct FeedarrTopResponse: Codable, Hashable, Sendable {
    let window: FeedarrTopWindow
    let takeUsed: Int
    let perCategoryTakeUsed: Int
    let sortUsed: FeedarrTopSort
    let dedupeUsed: String
    let supportsEntityDedupe: Bool
    let globalTop: [FeedarrRelease]
    let categories: [FeedarrTopCategoryResponse]

    /// Only existing known categories, in native rail order. Unknown categories
    /// remain intact in categories, and absent rails never acquire synthetic items.
    var orderedKnownCategories: [FeedarrTopCategoryResponse] {
        FeedarrTopCategory.railOrder.compactMap { category in
            categories.first { $0.key == category.rawValue }
        }
    }

    func category(for category: FeedarrTopCategory) -> FeedarrTopCategoryResponse? {
        categories.first { $0.key == category.rawValue }
    }
}

struct FeedarrTopWindow: Codable, Hashable, Sendable {
    let hours: Int
    /// Preserve the server's ISO 8601 representation, including fractional precision.
    let sinceUtc: String
    let field: String
}

struct FeedarrTopCategoryResponse: Identifiable, Codable, Hashable, Sendable {
    let key: String
    let label: String
    /// Count after optional dedupe, before per-category take; not grabs or seeders.
    let count: Int
    let top: [FeedarrRelease]

    var id: String { key }
    var knownCategory: FeedarrTopCategory? { FeedarrTopCategory(rawValue: key) }
}
