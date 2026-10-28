//
//  FeedarrDTOTests.swift
//  Yattee
//
//  Strict decoding and round-trip tests for synthetic Feedarr response contracts.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Release DTO Tests")
struct FeedarrReleaseDTOTests {
    @Test("Complete metadata uses the real camel-case names and types")
    func completeRelease() throws {
        let value = try decode(FeedarrDTOFixtures.completeRelease)
        #expect(value.id == 4_294_967_310 && value.sourceId == 4_294_967_311)
        #expect(value.title == "Example.Film.2024.1080p.WEB.H265-GROUP")
        #expect(value.titleClean == "Example Film" && value.year == 2024)
        #expect(value.season == 1 && value.episode == 2)
        #expect(value.resolution == "1080p" && value.codec == "H265")
        #expect(value.source == "WEB" && value.releaseGroup == "GROUP" && value.mediaType == "movie")
        #expect(value.seeders == 12 && value.leechers == 3 && value.grabs == 120)
        #expect(value.sizeBytes == 8_589_934_592 && value.publishedAt == 4_294_967_300)
        #expect(value.seen == 0 && value.categoryId == 2000 && value.categoryName == "Films HD")
        #expect(value.genres == "Drame, Aventure" && value.rating == 7.75)
        #expect(value.overview == "Un synopsis synthétique en français.")
        #expect(value.tagline == "Un exemple de film." && value.releaseDate == "2024-06-12")
        #expect(value.runtimeMinutes == 126 && value.ratingVotes == 4_294_967_313)
        #expect(value.detailsProvider == "tmdb" && value.detailsProviderId == "123456")
        #expect(value.unifiedCategory == "Film" && value.unifiedCategoryKey == "films")
        #expect(value.unifiedCategoryLabel == "Films" && value.entityId == 4_294_967_312)
        #expect(value.tmdbId == 123456 && value.tvdbId == 234567)
        #expect(value.isInSonarr == false && value.isInRadarr == true)
        #expect(value.posterUrl == "/api/posters/release/4294967310?v=4294967301")
        #expect(value.downloadPath == "/api/releases/4294967310/download")
        #expect(value.trackerPageUrl == "https://tracker.invalid/details/123")
        #expect(value.sonarrUrl == nil && value.radarrUrl == value.openUrl)
    }

    @Test("All nullable metadata can be null")
    func nullableRelease() throws {
        let value = try decode(FeedarrDTOFixtures.nullRelease)
        let minimal = try decode(FeedarrDTOFixtures.minimalRelease)
        #expect(value == minimal)
        #expect(value.title == nil && value.rating == nil && value.genres == nil)
        #expect(value.isInSonarr == nil && value.isInRadarr == nil)
        #expect(value.seen == nil && value.publishedAt == nil)
    }

    @Test("Optional properties can be absent")
    func absentMetadata() throws {
        let value = try decode(FeedarrDTOFixtures.minimalRelease)
        #expect(value.id == 1 && value.sourceId == 2)
        #expect(value.posterUrl == nil && value.overview == nil && value.sizeBytes == nil)
    }

    @Test("Both identifiers are required", arguments: [#"{"sourceId":2}"#, #"{"id":1}"#, #"{}"#])
    func missingIdentifiers(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test("Identifier types and range are strict", arguments: [
        #"{"id":"1","sourceId":2}"#,
        #"{"id":1,"sourceId":"2"}"#,
        #"{"id":true,"sourceId":2}"#,
        #"{"id":1.5,"sourceId":2}"#,
        #"{"id":null,"sourceId":2}"#,
        #"{"id":9223372036854775808,"sourceId":2}"#
    ])
    func invalidIdentifiers(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test("Wrong optional types are never silently replaced", arguments: [
        #"{"id":1,"sourceId":2,"genres":["Drama"]}"#,
        #"{"id":1,"sourceId":2,"rating":"7.75"}"#,
        #"{"id":1,"sourceId":2,"publishedAt":"1700000000"}"#,
        #"{"id":1,"sourceId":2,"isInSonarr":0}"#,
        #"{"id":1,"sourceId":2,"seen":false}"#,
        #"{"id":1,"sourceId":2,"sizeBytes":1.25}"#,
        #"{"id":1,"sourceId":2,"title":123}"#
    ])
    func wrongMetadataType(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test("Codable and Hashable preserve metadata and emit camel-case keys")
    func roundTrip() throws {
        let original = try decode(FeedarrDTOFixtures.completeRelease)
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FeedarrRelease.self, from: encoded) == original)
        #expect(Set([original, original]).count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["sourceId"] != nil && object["SourceId"] == nil)
        #expect(object["genres"] is String && object["rating"] is Double)
        #expect(object["score"] == nil && object["backdropUrl"] == nil)
    }

    private func decode(_ json: String) throws -> FeedarrRelease {
        try JSONDecoder().decode(FeedarrRelease.self, from: Data(json.utf8))
    }
}

@Suite("Feedarr Top DTO Tests")
struct FeedarrTopDTOTests {
    @Test("Top envelope and window match the API")
    func completeTop() throws {
        let value = try decode(FeedarrDTOFixtures.completeTop)
        #expect(value.window.hours == 24 && value.window.field == "published_at_ts")
        #expect(value.window.sinceUtc == "2026-01-01T00:00:00.0000000Z")
        #expect(value.takeUsed == 5 && value.perCategoryTakeUsed == 1)
        #expect(value.sortUsed == .score && value.dedupeUsed == "entity" && value.supportsEntityDedupe)
        #expect(value.globalTop.first?.id == 4_294_967_310)
        #expect(value.categories.count == 6)
    }

    @Test("Empty categories and global results are valid")
    func emptyTop() throws {
        let value = try decode(FeedarrDTOFixtures.emptyTop)
        #expect(value.categories.isEmpty && value.globalTop.isEmpty && value.orderedKnownCategories.isEmpty)
    }

    @Test("Absent category rails never create synthetic releases")
    func missingCategories() throws {
        let value = try decode(FeedarrDTOFixtures.sparseTop)
        #expect(value.category(for: .series) == nil)
        #expect(value.orderedKnownCategories.map(\.key) == ["films"])
    }

    @Test("Additional and future categories remain intact")
    func unknownCategories() throws {
        let value = try decode(FeedarrDTOFixtures.unknownCategoriesTop)
        #expect(value.categories.map(\.key) == ["anime", "books", "comics", "audio", "future-category"])
        #expect(value.categories.allSatisfy { $0.knownCategory == nil })
        #expect(value.categories.first?.top.first?.unifiedCategoryKey == "anime")
        #expect(value.orderedKnownCategories.isEmpty)
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(FeedarrTopResponse.self, from: encoded) == value)
    }

    @Test("Rail order is independent of the server array and starts globally")
    func fixedRailOrder() throws {
        let value = try decode(FeedarrDTOFixtures.completeTop)
        #expect(value.categories.first?.key == "spectacle")
        #expect(value.orderedKnownCategories.map(\.key) == ["films", "series", "emissions", "games", "animation", "spectacle"])
        #expect(FeedarrTopRail.presentationOrder.map(\.id) == ["global", "films", "series", "emissions", "games", "animation", "spectacle"])
    }

    @Test("Category count is independent of displayed items and swarm metrics")
    func countSemantics() throws {
        let films = try #require(decode(FeedarrDTOFixtures.completeTop).category(for: .films))
        #expect(films.count == 100 && films.top.count == 1)
        #expect(films.count != films.top.first?.seeders && films.count != films.top.first?.grabs)
    }

    @Test("Envelope properties keep strict server types")
    func strictEnvelope() {
        let invalid = FeedarrDTOFixtures.emptyTop.replacingOccurrences(of: "\"categories\":[]", with: "\"categories\":{}")
        #expect(throws: DecodingError.self) { try decode(invalid) }
    }

    private func decode(_ json: String) throws -> FeedarrTopResponse {
        try JSONDecoder().decode(FeedarrTopResponse.self, from: Data(json.utf8))
    }
}

@Suite("Feedarr Releases DTO Tests")
struct FeedarrReleasesDTOTests {
    @Test("Paged response preserves opaque cursor and 64-bit snapshot boundary")
    func pagedResponse() throws {
        let value = try decode(FeedarrDTOFixtures.pagedReleases)
        #expect(value.items.count == 1 && value.pagination.limit == 1 && value.pagination.hasMore)
        #expect(value.pagination.snapshotMaxId == 9_000_000_000)
        #expect(value.pagination.nextCursor == FeedarrDTOFixtures.nextCursor)
        #expect(value.query?.sort == .date && value.query?.direction == "desc")
        #expect(value.query?.q == nil && value.query?.unifiedCategory == nil)
    }

    @Test("Empty catalogue and null cursor are valid")
    func emptyCatalogue() throws {
        let value = try decode(FeedarrDTOFixtures.emptyReleases)
        #expect(value.items.isEmpty && !value.pagination.hasMore)
        #expect(value.pagination.nextCursor == nil && value.pagination.snapshotMaxId == 0)
    }

    @Test("Query is optional and unknown catalogue categories are preserved")
    func queryContract() throws {
        let withoutQuery = #"{"items":[],"pagination":{"limit":1,"hasMore":false,"nextCursor":null,"snapshotMaxId":0}}"#
        #expect(try decode(withoutQuery).query == nil)
        let unknown = FeedarrDTOFixtures.emptyReleases.replacingOccurrences(of: "\"unifiedCategory\":null", with: "\"unifiedCategory\":\"books\"")
        #expect(try decode(unknown).query?.unifiedCategory == "books")
    }

    @Test("Pagination types remain strict", arguments: [
        #"{"limit":"1","hasMore":false,"nextCursor":null,"snapshotMaxId":0}"#,
        #"{"limit":1,"hasMore":0,"nextCursor":null,"snapshotMaxId":0}"#,
        #"{"limit":1,"hasMore":false,"nextCursor":5,"snapshotMaxId":0}"#,
        #"{"limit":1,"hasMore":false,"nextCursor":null,"snapshotMaxId":"0"}"#
    ])
    func strictPagination(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FeedarrPagination.self, from: Data(json.utf8))
        }
    }

    @Test("Response round trip leaves the cursor unchanged")
    func roundTrip() throws {
        let original = try decode(FeedarrDTOFixtures.pagedReleases)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FeedarrReleasesResponse.self, from: data)
        #expect(decoded == original && decoded.pagination.nextCursor == FeedarrDTOFixtures.nextCursor)
    }

    private func decode(_ json: String) throws -> FeedarrReleasesResponse {
        try JSONDecoder().decode(FeedarrReleasesResponse.self, from: Data(json.utf8))
    }
}

@Suite("Feedarr Sort DTO Tests")
struct FeedarrSortDTOTests {
    @Test("Each endpoint has its own recent/date vocabulary and client default")
    func distinctSorts() {
        #expect(FeedarrTopSort.allCases.map(\.rawValue) == ["recent", "seeders", "grabs", "score"])
        #expect(FeedarrReleasesSort.allCases.map(\.rawValue) == ["date", "seeders", "grabs", "score"])
        #expect(FeedarrTopSort(rawValue: "date") == nil && FeedarrReleasesSort(rawValue: "recent") == nil)
        #expect(FeedarrTopSort.defaultSort == .score && FeedarrReleasesSort.defaultSort == .date)
    }

    @Test("Every Top sort round trips", arguments: FeedarrTopSort.allCases)
    func topSortRoundTrip(sort: FeedarrTopSort) throws {
        #expect(try JSONDecoder().decode(FeedarrTopSort.self, from: JSONEncoder().encode(sort)) == sort)
    }

    @Test("Every Releases sort round trips", arguments: FeedarrReleasesSort.allCases)
    func releasesSortRoundTrip(sort: FeedarrReleasesSort) throws {
        #expect(try JSONDecoder().decode(FeedarrReleasesSort.self, from: JSONEncoder().encode(sort)) == sort)
    }
}
