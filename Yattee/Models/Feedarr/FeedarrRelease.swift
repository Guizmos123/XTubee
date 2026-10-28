//
//  FeedarrRelease.swift
//  Yattee
//
//  Camel-case FeedRow contract shared by the Top and Releases endpoints.
//

import Foundation

struct FeedarrRelease: Identifiable, Codable, Hashable, Sendable {
    let id: Int64
    let sourceId: Int64

    // MARK: - Release metadata

    let title: String?
    let titleClean: String?
    let year: Int?
    let season: Int?
    let episode: Int?
    let resolution: String?
    let source: String?
    let codec: String?
    let releaseGroup: String?
    let mediaType: String?
    let seeders: Int?
    let leechers: Int?
    let grabs: Int?
    /// Bytes, without conversion to a presentation unit.
    let sizeBytes: Int64?
    /// Unix timestamp in seconds, not milliseconds.
    let publishedAt: Int64?
    let categoryId: Int?
    let categoryName: String?
    /// Backend integer flag; this is not a JSON boolean.
    let seen: Int?
    let downloadPath: String?
    let trackerPageUrl: String?
    let entityId: Int64?

    // MARK: - Poster metadata

    /// May be relative to the Feedarr installation. URL resolution belongs to the client.
    let posterUrl: String?
    let posterUpdatedAtTs: Int64?
    let posterProvider: String?
    let posterLang: String?
    let posterSize: String?
    let posterLastError: String?
    let posterLastAttemptTs: Int64?

    // MARK: - Provider metadata supplied by Feedarr

    let overview: String?
    let tagline: String?
    /// The API exposes a string, not an array of genres.
    let genres: String?
    let releaseDate: String?
    let runtimeMinutes: Int64?
    let rating: Double?
    let ratingVotes: Int64?
    let detailsProvider: String?
    let detailsProviderId: String?
    let detailsUpdatedAtTs: Int64?
    let directors: String?
    let writers: String?
    let cast: String?

    // MARK: - Categories

    let stdCategoryId: Int?
    let specCategoryId: Int?
    let categoryIds: String?
    let unifiedCategory: String?
    /// Keep the raw key so additional server categories remain decodable.
    let unifiedCategoryKey: String?
    let unifiedCategoryLabel: String?

    // MARK: - External library status

    let tmdbId: Int64?
    let tvdbId: Int64?
    /// nil means unknown, rather than absent from the library.
    let isInSonarr: Bool?
    let isInRadarr: Bool?
    let sonarrUrl: String?
    let radarrUrl: String?
    let openUrl: String?
    let arrCheckedAtTs: Int64?
}
