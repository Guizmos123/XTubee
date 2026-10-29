//
//  IPTVLiveChannelGroupingCache.swift
//  Yattee
//
//  Reuses current Live channel groups per source within a bounded LRU cache.
//

import Foundation

actor IPTVLiveChannelGroupingCache {
    struct Key: Hashable, Sendable {
        let sourceID: UUID
        let catalogLastUpdated: Date
        var configurationRevision: UUID? = nil
    }

    typealias Grouping = @Sendable (
        UUID,
        [XtreamLiveStream]
    ) -> [IPTVLiveChannelGroup]

    private let grouping: Grouping
    private let maximumCachedSources: Int
    private let maximumCachedStreams: Int
    private var cachedEntries: [UUID: (key: Key, groups: [IPTVLiveChannelGroup], streamCount: Int)] = [:]
    private var recentlyUsedSources: [UUID] = []
    private var cachedStreamCount = 0

    init(
        maximumCachedSources: Int = 3,
        maximumCachedStreams: Int = 30_000,
        grouping: @escaping Grouping = { sourceID, streams in
            IPTVLiveChannelGrouper.groups(sourceID: sourceID, streams: streams)
        }
    ) {
        precondition(maximumCachedSources > 0 && maximumCachedStreams > 0)
        self.maximumCachedSources = maximumCachedSources
        self.maximumCachedStreams = maximumCachedStreams
        self.grouping = grouping
    }

    func groups(for catalog: IPTVLiveCatalog) -> [IPTVLiveChannelGroup]? {
        guard !Task.isCancelled else { return nil }

        let key = Key(
            sourceID: catalog.sourceID,
            catalogLastUpdated: catalog.lastUpdated,
            configurationRevision: catalog.configurationRevision
        )
        if let entry = cachedEntries[catalog.sourceID], entry.key == key {
            recentlyUsedSources.removeAll { $0 == catalog.sourceID }
            recentlyUsedSources.append(catalog.sourceID)
            return entry.groups
        }

        let groups = grouping(catalog.sourceID, catalog.streams)
        guard !Task.isCancelled else { return nil }

        removeEntry(for: catalog.sourceID)
        // Count retained variants, not just groups: grouping keeps every stream.
        // An oversized catalogue is still returned but is not retained by the cache.
        guard catalog.streams.count <= maximumCachedStreams else { return groups }
        while cachedEntries.count >= maximumCachedSources
            || cachedStreamCount > maximumCachedStreams - catalog.streams.count {
            guard let oldest = recentlyUsedSources.first else { break }
            removeEntry(for: oldest)
        }
        cachedEntries[catalog.sourceID] = (key, groups, catalog.streams.count)
        cachedStreamCount += catalog.streams.count
        recentlyUsedSources.append(catalog.sourceID)
        return groups
    }

    private func removeEntry(for sourceID: UUID) {
        if let entry = cachedEntries.removeValue(forKey: sourceID) {
            cachedStreamCount -= entry.streamCount
        }
        recentlyUsedSources.removeAll { $0 == sourceID }
    }
}
