//
//  FeedarrDTOFixtures.swift
//  Yattee
//
//  Synthetic JSON matching the local FeedController contract; no live service data.
//

import Foundation

enum FeedarrDTOFixtures {
    static let completeRelease = #"""
    {
      "id": 4294967310, "sourceId": 4294967311,
      "title": "Example.Film.2024.1080p.WEB.H265-GROUP", "titleClean": "Example Film",
      "year": 2024, "season": 1, "episode": 2, "resolution": "1080p",
      "source": "WEB", "codec": "H265", "releaseGroup": "GROUP", "mediaType": "movie",
      "seeders": 12, "leechers": 3, "grabs": 120, "sizeBytes": 8589934592,
      "publishedAt": 4294967300, "categoryId": 2000, "categoryName": "Films HD", "seen": 0,
      "downloadPath": "/api/releases/4294967310/download",
      "trackerPageUrl": "https://tracker.invalid/details/123",
      "entityId": 4294967312,
      "posterUrl": "/api/posters/release/4294967310?v=4294967301", "posterUpdatedAtTs": 4294967301,
      "posterProvider": "tmdb", "posterLang": "fr", "posterSize": "w500",
      "posterLastError": null, "posterLastAttemptTs": 4294967301,
      "overview": "Un synopsis synthétique en français.", "tagline": "Un exemple de film.",
      "genres": "Drame, Aventure", "releaseDate": "2024-06-12", "runtimeMinutes": 126,
      "rating": 7.75, "ratingVotes": 4294967313, "detailsProvider": "tmdb",
      "detailsProviderId": "123456", "detailsUpdatedAtTs": 4294967301,
      "directors": "Example Director", "writers": "Example Writer", "cast": "Example Actor",
      "stdCategoryId": 2000, "specCategoryId": 2040, "categoryIds": "[2000,2040]",
      "unifiedCategory": "Film", "unifiedCategoryKey": "films", "unifiedCategoryLabel": "Films",
      "tmdbId": 123456, "tvdbId": 234567,
      "isInSonarr": false, "isInRadarr": true,
      "sonarrUrl": null, "radarrUrl": "http://radarr.invalid/movie/123456",
      "openUrl": "http://radarr.invalid/movie/123456", "arrCheckedAtTs": 4294967301
    }
    """#

    static let nullRelease = #"""
    {
      "id": 1, "sourceId": 2,
      "title": null, "titleClean": null, "year": null, "season": null, "episode": null,
      "resolution": null, "source": null, "codec": null, "releaseGroup": null, "mediaType": null,
      "seeders": null, "leechers": null, "grabs": null, "sizeBytes": null, "publishedAt": null,
      "categoryId": null, "categoryName": null, "seen": null, "downloadPath": null,
      "trackerPageUrl": null, "entityId": null, "posterUrl": null, "posterUpdatedAtTs": null,
      "posterProvider": null, "posterLang": null, "posterSize": null,
      "posterLastError": null, "posterLastAttemptTs": null,
      "overview": null, "tagline": null, "genres": null, "releaseDate": null,
      "runtimeMinutes": null, "rating": null, "ratingVotes": null, "detailsProvider": null,
      "detailsProviderId": null, "detailsUpdatedAtTs": null, "directors": null, "writers": null,
      "cast": null, "stdCategoryId": null, "specCategoryId": null, "categoryIds": null,
      "unifiedCategory": null, "unifiedCategoryKey": null, "unifiedCategoryLabel": null,
      "tmdbId": null, "tvdbId": null, "isInSonarr": null, "isInRadarr": null,
      "sonarrUrl": null, "radarrUrl": null, "openUrl": null, "arrCheckedAtTs": null
    }
    """#

    static let minimalRelease = #"{"id":1,"sourceId":2}"#

    // A fixed base64url cursor vector. Tests and DTOs only transport this string verbatim.
    static let nextCursor = "eyJ2ZXJzaW9uIjoxLCJzb3J0IjoiZGF0ZSIsImxhc3RQdWJsaXNoZWRBdCI6NDI5NDk2NzMwMCwibGFzdElkIjo0Mjk0OTY3MzEwLCJzbmFwc2hvdE1heElkIjo5MDAwMDAwMDAwLCJxdWVyeUZpbmdlcnByaW50IjoiQUJGMUMxNTlBOUY0RjQ1QTExNTVCNzY0NzE4RjI0MDIyRDE4NzUwOEZFRjhGNTYwNjMxOTkyMjBBRTBDMTE2QSIsImxhc3RQcmltYXJ5VmFsdWUiOm51bGwsImxhc3RTZWNvbmRhcnlWYWx1ZSI6bnVsbH0"

    static let completeTop = """
    {
      "window":{"hours":24,"sinceUtc":"2026-01-01T00:00:00.0000000Z","field":"published_at_ts"},
      "takeUsed":5,"perCategoryTakeUsed":1,"sortUsed":"score","dedupeUsed":"entity",
      "supportsEntityDedupe":true,"globalTop":[\(completeRelease),{"id":7,"sourceId":2},{"id":6,"sourceId":2},{"id":5,"sourceId":2},{"id":4,"sourceId":2}],
      "categories":[
        {"key":"spectacle","label":"Spectacle","count":2,"top":[{"id":7,"sourceId":2}]},
        {"key":"games","label":"Jeux PC","count":8,"top":[{"id":5,"sourceId":2}]},
        {"key":"series","label":"Série TV","count":30,"top":[{"id":3,"sourceId":2}]},
        {"key":"films","label":"Films","count":100,"top":[\(completeRelease)]},
        {"key":"animation","label":"Animation","count":6,"top":[{"id":6,"sourceId":2}]},
        {"key":"emissions","label":"Emissions","count":4,"top":[{"id":4,"sourceId":2}]}
      ]
    }
    """

    static let sparseTop = #"""
    {
      "window":{"hours":24,"sinceUtc":"2026-01-01T00:00:00Z","field":"published_at_ts"},
      "takeUsed":5,"perCategoryTakeUsed":5,"sortUsed":"recent","dedupeUsed":"none",
      "supportsEntityDedupe":true,"globalTop":[],
      "categories":[{"key":"films","label":"Films","count":1,"top":[{"id":1,"sourceId":2}]}]
    }
    """#

    static let emptyTop = #"""
    {
      "window":{"hours":24,"sinceUtc":"2026-01-01T00:00:00Z","field":"published_at_ts"},
      "takeUsed":5,"perCategoryTakeUsed":5,"sortUsed":"score","dedupeUsed":"none",
      "supportsEntityDedupe":true,"globalTop":[],"categories":[]
    }
    """#

    static let unknownCategoriesTop = #"""
    {
      "window":{"hours":24,"sinceUtc":"2026-01-01T00:00:00Z","field":"published_at_ts"},
      "takeUsed":1,"perCategoryTakeUsed":1,"sortUsed":"score","dedupeUsed":"none",
      "supportsEntityDedupe":true,"globalTop":[{"id":5,"sourceId":2}],
      "categories":[
        {"key":"anime","label":"Anime","count":1,"top":[{"id":1,"sourceId":2,"unifiedCategoryKey":"anime"}]},
        {"key":"books","label":"Livres","count":2,"top":[{"id":2,"sourceId":2}]},
        {"key":"comics","label":"Comics","count":3,"top":[{"id":3,"sourceId":2}]},
        {"key":"audio","label":"Audio","count":4,"top":[{"id":4,"sourceId":2}]},
        {"key":"future-category","label":"Future category","count":5,"top":[{"id":5,"sourceId":2}]}
      ]
    }
    """#

    static let pagedReleases = """
    {
      "items":[\(completeRelease)],
      "pagination":{"limit":1,"hasMore":true,"nextCursor":"\(nextCursor)","snapshotMaxId":9000000000},
      "query":{"sort":"date","direction":"desc","q":null,"sourceIds":[],"unifiedCategory":null,"seen":null,"minSeeders":null}
    }
    """

    static let emptyReleases = #"""
    {
      "items":[],"pagination":{"limit":50,"hasMore":false,"nextCursor":null,"snapshotMaxId":0},
      "query":{"sort":"date","direction":"desc","q":null,"sourceIds":[],"unifiedCategory":null,"seen":null,"minSeeders":null}
    }
    """#
}
