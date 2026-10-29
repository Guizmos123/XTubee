//
//  IPTVLiveChannelGroupingCache.swift
//  Yattee
//
//  Keeps the derived Live channel groups in memory for one catalog version.
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
    private var cachedEntries: [UUID: (key: Key, groups: [IPTVLiveChannelGroup])] = [:]

    init(
        grouping: @escaping Grouping = { sourceID, streams in
            IPTVLiveChannelGrouper.groups(sourceID: sourceID, streams: streams)
        }
    ) {
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
            return entry.groups
        }

        let groups = grouping(catalog.sourceID, catalog.streams)
        guard !Task.isCancelled else { return nil }

        cachedEntries[catalog.sourceID] = (key, groups)
        return groups
    }
}
