//
//  IPTVLiveChannelGroupingCacheTests.swift
//  YatteeTests
//
//  Tests catalog-version invalidation and reuse of derived Live channel groups.
//

import Foundation
import Testing
@testable import XTubee

@Suite("IPTV Live Channel Grouping Cache Tests")
struct IPTVLiveChannelGroupingCacheTests {
    @Test("A catalog version is grouped only once")
    func reusesCatalogVersion() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache { sourceID, streams in
            counter.group(sourceID: sourceID, streams: streams)
        }
        let catalog = try makeCatalog(sourceID: UUID(), updatedAt: Date())

        let first = await cache.groups(for: catalog)
        let second = await cache.groups(for: catalog)

        #expect(first == second)
        #expect(counter.value == 1)
    }

    @Test("A refreshed catalog invalidates groups and preserves server order")
    func invalidatesRefreshedCatalog() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache { sourceID, streams in
            counter.group(sourceID: sourceID, streams: streams)
        }
        let sourceID = UUID()
        let first = try makeCatalog(sourceID: sourceID, updatedAt: Date())
        let refreshed = try makeCatalog(
            sourceID: sourceID,
            updatedAt: first.lastUpdated.addingTimeInterval(1),
            names: ["M6 HD", "TF1 FHD", "TF1 HD"]
        )

        _ = await cache.groups(for: first)
        let groups = await cache.groups(for: refreshed)

        #expect(counter.value == 2)
        #expect(groups?.map(\.displayName) == ["M6", "TF1"])
        #expect(groups?.last?.variants.map(\.stream.streamID) == ["2", "3"])
    }

    @Test("Changing source invalidates otherwise identical catalog versions")
    func invalidatesChangedSource() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache { sourceID, streams in
            counter.group(sourceID: sourceID, streams: streams)
        }
        let updatedAt = Date()
        let firstSourceID = UUID()

        let first = await cache.groups(
            for: try makeCatalog(sourceID: firstSourceID, updatedAt: updatedAt)
        )
        let second = await cache.groups(
            for: try makeCatalog(sourceID: UUID(), updatedAt: updatedAt)
        )
        _ = await cache.groups(
            for: try makeCatalog(sourceID: firstSourceID, updatedAt: updatedAt)
        )

        #expect(counter.value == 2)
        #expect(first?.first?.sourceID != second?.first?.sourceID)
    }

    @Test("Connection revisions invalidate derived groups even with the same UUID and timestamp")
    func invalidatesConnectionRevision() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache { sourceID, streams in
            counter.group(sourceID: sourceID, streams: streams)
        }
        let old = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let current = IPTVLiveCatalog(sourceID: old.sourceID, categories: old.categories,
                                      streams: old.streams, lastUpdated: old.lastUpdated,
                                      configurationRevision: UUID())
        _ = await cache.groups(for: old)
        _ = await cache.groups(for: current)
        _ = await cache.groups(for: current)
        #expect(counter.value == 2)
    }

    private func makeCatalog(
        sourceID: UUID,
        updatedAt: Date,
        names: [String] = ["TF1 HD", "TF1 FHD", "M6 HD"]
    ) throws -> IPTVLiveCatalog {
        let objects = names.enumerated().map { index, name in
            [
                "stream_id": String(index + 1),
                "name": name,
                "category_id": "general"
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: objects)
        return IPTVLiveCatalog(
            sourceID: sourceID,
            categories: [],
            streams: try JSONDecoder().decode([XtreamLiveStream].self, from: data),
            lastUpdated: updatedAt
        )
    }
}

private final class LockedGroupingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func group(
        sourceID: UUID,
        streams: [XtreamLiveStream]
    ) -> [IPTVLiveChannelGroup] {
        lock.withLock { count += 1 }
        return IPTVLiveChannelGrouper.groups(sourceID: sourceID, streams: streams)
    }
}
