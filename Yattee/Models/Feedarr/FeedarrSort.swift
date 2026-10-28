//
//  FeedarrSort.swift
//  Yattee
//
//  Distinct API sort values and explicit client defaults for each Feedarr page.
//

import Foundation

enum FeedarrTopSort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case recent
    case seeders
    case grabs
    case score

    /// XTubee's choice; the backend defaults to recent when the parameter is omitted.
    static let defaultSort: Self = .score
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .recent: AppLocalization.string("feedarr.sort.recent")
        case .seeders: AppLocalization.string("feedarr.sort.seeders")
        case .grabs: AppLocalization.string("feedarr.sort.grabs")
        case .score: AppLocalization.string("feedarr.sort.score")
        }
    }
}

enum FeedarrReleasesSort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case date
    case seeders
    case grabs
    case score

    static let defaultSort: Self = .date
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .date: AppLocalization.string("feedarr.sort.date")
        case .seeders: AppLocalization.string("feedarr.sort.seeders")
        case .grabs: AppLocalization.string("feedarr.sort.grabs")
        case .score: AppLocalization.string("feedarr.sort.score")
        }
    }
}
