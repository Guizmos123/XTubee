//
//  DuplicateMetadataTests.swift
//  Yattee
//
//  Duplicate IDs retain the latest history and source-matching subscriptions.
//

import Foundation
import SwiftData
import Testing
@testable import XTubee

@Suite("Duplicate Metadata")
@MainActor
struct DuplicateMetadataTests {
    @Test(arguments: [false, true])
    func historyKeepsLatestRegardlessOfInsertionOrder(reversed: Bool) throws {
        let manager = try DataManager(inMemory: true)
        let older = watch(source: "global", updatedAt: 100)
        let newer = watch(source: "extracted", updatedAt: 200)
        let entries = reversed ? [newer, older] : [older, newer]
        for entry in entries { manager.modelContext.insert(entry) }
        try manager.modelContext.save()
        let map = manager.watchEntriesMap()
        #expect(map.count == 1)
        #expect(map["same-video"] === newer)
        #expect(manager.watchHistoryCount() == 2) // Projection only, no deletion.
    }

    @Test(arguments: [false, true])
    func subscriptionsMatchTheirSourceAndKeepLatestMetadata(reversed: Bool) throws {
        let global = subscription(source: "global", name: "Z global", updatedAt: 100)
        let federated = subscription(source: "federated", name: "A federated", updatedAt: 300)
        federated.instanceURLString = "https://peertube.invalid"
        federated.providerName = ContentSource.peertubeProvider
        let newerGlobal = subscription(source: "global", name: "Y global", updatedAt: 200)
        let otherInstance = subscription(source: "federated", name: "Other instance", updatedAt: 400)
        otherInstance.instanceURLString = "https://other-peertube.invalid"
        otherInstance.providerName = ContentSource.peertubeProvider
        let inputs = [global, federated, newerGlobal, otherInstance]
        let map = ManageChannelsView.subscriptionMetadataMap(reversed ? Array(inputs.reversed()) : inputs)
        #expect(map.count == 3)
        #expect(map[ChannelID(source: global.contentSource, channelID: "same-channel")] === newerGlobal)
        #expect(map[ChannelID(source: federated.contentSource, channelID: "same-channel")] === federated)
        #expect(map[ChannelID(source: otherInstance.contentSource, channelID: "same-channel")] === otherInstance)
    }

    @Test(arguments: [false, true])
    func equalMetadataDatesRetainOriginalSubscription(reversed: Bool) {
        let original = subscription(source: "global", name: "Original", updatedAt: 200)
        let duplicate = subscription(source: "global", name: "Duplicate", updatedAt: 200)
        original.subscribedAt = Date(timeIntervalSince1970: 10)
        duplicate.subscribedAt = Date(timeIntervalSince1970: 20)
        let inputs = reversed ? [duplicate, original] : [original, duplicate]
        let map = ManageChannelsView.subscriptionMetadataMap(inputs)
        #expect(map.values.first === original)
    }

    @Test func fullyTiedMetadataDoesNotDependOnInputOrder() {
        let first = subscription(source: "global", name: "Same", updatedAt: 200)
        let second = subscription(source: "global", name: "Same", updatedAt: 200)
        first.subscribedAt = Date(timeIntervalSince1970: 10)
        second.subscribedAt = first.subscribedAt
        let forward = ManageChannelsView.subscriptionMetadataMap([first, second])
        let reversed = ManageChannelsView.subscriptionMetadataMap([second, first])
        #expect(forward.values.first === reversed.values.first)
    }

    private func watch(source: String, updatedAt: TimeInterval) -> WatchEntry {
        let entry = WatchEntry(videoID: "same-video", sourceRawValue: source,
                               title: source, authorName: "Author", authorID: "author", duration: 100)
        entry.updatedAt = Date(timeIntervalSince1970: updatedAt)
        return entry
    }

    private func subscription(source: String, name: String, updatedAt: TimeInterval) -> Subscription {
        let entry = Subscription(channelID: "same-channel", sourceRawValue: source, name: name)
        entry.lastUpdatedAt = Date(timeIntervalSince1970: updatedAt)
        return entry
    }
}
