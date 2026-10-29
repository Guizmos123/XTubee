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

    @Test("A to B to A reuses A and keeps source identities isolated")
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
        let returned = await cache.groups(
            for: try makeCatalog(sourceID: firstSourceID, updatedAt: updatedAt)
        )

        #expect(counter.value == 2)
        #expect(returned == first)
        #expect(first?.first?.sourceID != second?.first?.sourceID)
    }

    @Test("Connection revisions invalidate derived groups even with the same UUID and timestamp")
    func invalidatesConnectionRevision() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache { sourceID, streams in
            counter.group(sourceID: sourceID, streams: streams)
        }
        let old = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let changed = try makeCatalog(sourceID: old.sourceID, updatedAt: old.lastUpdated, names: ["New HD"])
        let current = IPTVLiveCatalog(sourceID: old.sourceID, categories: old.categories,
                                      streams: changed.streams, lastUpdated: old.lastUpdated,
                                      configurationRevision: UUID())
        _ = await cache.groups(for: old)
        let groups = await cache.groups(for: current)
        _ = await cache.groups(for: current)
        #expect(counter.value == 2)
        #expect(groups?.map(\.displayName) == ["New"])
    }

    @Test("Source eviction is least recently used and regrouping preserves results")
    func evictsLeastRecentlyUsedSource() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache(maximumCachedSources: 2) { counter.group(sourceID: $0, streams: $1) }
        let a = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let b = try makeCatalog(sourceID: UUID(), updatedAt: Date(), names: ["B HD", "B FHD"])
        let c = try makeCatalog(sourceID: UUID(), updatedAt: Date(), names: ["C HD"])
        _ = await cache.groups(for: a)
        let firstB = await cache.groups(for: b)
        _ = await cache.groups(for: a) // A is now newer than B.
        _ = await cache.groups(for: c) // Evicts B.
        _ = await cache.groups(for: a)
        #expect(counter.value == 3)
        let regroupedB = await cache.groups(for: b)
        #expect(counter.value == 4)
        #expect(regroupedB == firstB)
    }

    @Test("The total variant budget evicts entries even below the source limit")
    func boundsRetainedVariants() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache(maximumCachedStreams: 6) { counter.group(sourceID: $0, streams: $1) }
        let a = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let b = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let c = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let firstA = await cache.groups(for: a)
        _ = await cache.groups(for: b)
        _ = await cache.groups(for: c) // Three variants each: evicts A despite room for three sources.
        _ = await cache.groups(for: b)
        #expect(counter.value == 3)
        let regroupedA = await cache.groups(for: a)
        #expect(counter.value == 4)
        #expect(regroupedA == firstA)
    }

    @Test("Oversized catalogues remain usable without displacing other sources")
    func doesNotRetainOversizedCatalogue() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache(maximumCachedStreams: 2) { counter.group(sourceID: $0, streams: $1) }
        let small = try makeCatalog(sourceID: UUID(), updatedAt: Date(), names: ["Small HD"])
        let large = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        _ = await cache.groups(for: small)
        let first = await cache.groups(for: large)
        let second = await cache.groups(for: large)
        _ = await cache.groups(for: small)
        #expect(counter.value == 3)
        #expect(first == second)
        #expect(first?.flatMap(\.variants).count == large.streams.count)
    }

    @Test("Replacing a revision releases its previous variant budget")
    func replacingRevisionReleasesBudget() async throws {
        let counter = LockedGroupingCounter()
        let cache = IPTVLiveChannelGroupingCache(maximumCachedStreams: 6) { counter.group(sourceID: $0, streams: $1) }
        let a = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let b = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let revised = IPTVLiveCatalog(sourceID: a.sourceID, categories: a.categories, streams: a.streams,
                                      lastUpdated: a.lastUpdated, configurationRevision: UUID())
        _ = await cache.groups(for: a)
        _ = await cache.groups(for: b)
        _ = await cache.groups(for: revised)
        _ = await cache.groups(for: b)
        _ = await cache.groups(for: revised)
        #expect(counter.value == 3)
    }

    @Test("Cancelled grouping returns no publishable result and is not cached")
    func discardsCancelledGrouping() async throws {
        let counter = LockedGroupingCounter()
        let gate = GroupingGate()
        let cache = IPTVLiveChannelGroupingCache { sourceID, streams in
            gate.wait()
            return counter.group(sourceID: sourceID, streams: streams)
        }
        let catalog = try makeCatalog(sourceID: UUID(), updatedAt: Date())
        let task = Task.detached { await cache.groups(for: catalog) }
        defer { gate.open(); task.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.started {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        gate.open()
        #expect(await task.value == nil)
        let current = await cache.groups(for: catalog)
        #expect(current != nil)
        #expect(counter.value == 2)
        #expect(await cache.groups(for: catalog) == current)
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

private final class GroupingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var didStart = false
    var started: Bool { condition.withLock { didStart } }
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        didStart = true
        while !isOpen { condition.wait() }
    }
    func open() { condition.withLock { isOpen = true; condition.broadcast() } }
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
