//
//  FeedarrExternalLinksTests.swift
//  Yattee
//
//  Destination construction and public HTTPS validation, without external traffic.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr external links")
struct FeedarrExternalLinksTests {
    @Test func officialDestinationsAndTracker() throws {
        let film = try release(["mediaType": "movie", "tmdbId": 42, "tvdbId": 123, "trackerPageUrl": "https://tracker.example/details?id=1"])
        let filmLinks = FeedarrExternalLinks.items(for: film)
        #expect(filmLinks.map(\.id) == ["Tracker", "TMDB"])
        #expect(filmLinks.last?.url.absoluteString == "https://www.themoviedb.org/movie/42")
        let series = try release(["mediaType": "series", "tmdbId": 100, "tvdbId": 81189])
        #expect(FeedarrExternalLinks.items(for: series).map(\.url.absoluteString) == ["https://www.themoviedb.org/tv/100", "https://thetvdb.com/dereferrer/series/81189"])
    }

    @Test func ambiguousOrMissingMetadataDoesNotInventLinks() throws {
        for values: [String: Any] in [[:], ["tmdbId": 1, "tvdbId": 2], ["mediaType": "animation", "tmdbId": 1], ["mediaType": "series", "unifiedCategoryKey": "films", "tmdbId": 1], ["mediaType": "movie", "tmdbId": 0], ["mediaType": "movie", "tmdbId": 1, "detailsProvider": "igdb"]] {
            #expect(FeedarrExternalLinks.items(for: try release(values)).isEmpty)
        }
    }

    @Test func invalidAndPrivateDestinationsAreRejected() {
        for raw in ["/relative", "//tracker.example/page", "http://tracker.example", "file:///tmp/file", "https://user:secret@tracker.example", "https://user@tracker.example", "https://localhost", "https://nas.local/page", "https://nas.home.arpa", "https://127.0.0.1", "https://2130706433", "https://0x7f000001", "https://10.0.0.1", "https://172.16.1.2", "https://192.168.1.1", "https://100.64.0.1", "https://169.254.169.254", "https://[::1]", "https://[fd00::1]", "https://[::ffff:127.0.0.1]", "https://tracker.example:99999", "https://tracker.example\\@127.0.0.1", "https://tracker.example/\npage"] {
            #expect(FeedarrExternalLinks.validatedURL(raw) == nil, "Unexpectedly accepted: \(raw)")
        }
        #expect(FeedarrExternalLinks.validatedURL("https://tracker.example/details?id=1") != nil)
        #expect(FeedarrExternalLinks.validatedURL("https://8.8.8.8/") != nil)
    }

    @Test func DNSMustResolveExclusivelyToPublicAddresses() async throws {
        let url = try #require(FeedarrExternalLinks.validatedURL("https://tracker.example/page"))
        #expect(await FeedarrExternalLinks.mayOpen(url, resolve: { _ in ["8.8.8.8", "2606:4700:4700::1111"] }))
        #expect(await !FeedarrExternalLinks.mayOpen(url, resolve: { _ in ["8.8.8.8", "192.168.0.1"] }))
        #expect(await !FeedarrExternalLinks.mayOpen(url, resolve: { _ in [] }))
        #expect(await !FeedarrExternalLinks.mayOpen(url, resolve: { _ in ["::ffff:10.1.2.3"] }))
    }

    private func release(_ values: [String: Any]) throws -> FeedarrRelease {
        var json = values
        json["id"] = 1
        json["sourceId"] = 2
        return try JSONDecoder().decode(FeedarrRelease.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
