//
//  FeedarrCategory.swift
//  Yattee
//
//  Native Top rail ordering. This is deliberately not a catalogue filter whitelist.
//

import Foundation

enum FeedarrTopCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case films
    case series
    case emissions
    case games
    case animation
    case spectacle

    static let railOrder: [Self] = [.films, .series, .emissions, .games, .animation, .spectacle]
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .films: AppLocalization.string("feedarr.category.films")
        case .series: AppLocalization.string("feedarr.category.series")
        case .emissions: AppLocalization.string("feedarr.category.emissions")
        case .games: AppLocalization.string("feedarr.category.games")
        case .animation: AppLocalization.string("feedarr.category.animation")
        case .spectacle: AppLocalization.string("feedarr.category.spectacle")
        }
    }
}

enum FeedarrTopRail: Hashable, Identifiable, Sendable {
    case global
    case category(FeedarrTopCategory)

    static let presentationOrder: [Self] = [.global] + FeedarrTopCategory.railOrder.map { .category($0) }

    var id: String {
        switch self {
        case .global: "global"
        case .category(let category): category.rawValue
        }
    }
}
