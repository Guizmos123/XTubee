//
//  PlayerProgressSaveTests.swift
//  Yattee
//
//  Periodic progress deduplication must not suppress final saves or privacy rules.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Player Progress Save", .serialized)
@MainActor
struct PlayerProgressSaveTests {
    private static let backendFactory = BackendFactory()
    private let sentinel = Date(timeIntervalSince1970: 100)

    @Test func unchangedPositionDoesNotRewriteButMovementDoes() throws {
        let (service, manager) = try fixture()
        set(video(.global("a")), on: service, seconds: 10)
        service.saveProgress()
        let entry = try #require(manager.watchEntry(for: "a"))
        entry.updatedAt = sentinel
        service.saveProgress()
        #expect(entry.updatedAt == sentinel)
        service.state.currentTime = 11
        service.saveProgress()
        #expect(entry.updatedAt != sentinel)
        #expect(entry.watchedSeconds == 11)
    }

    @Test(arguments: [false, true])
    func samePositionOnAnotherVideoOrSourceIsSaved(sameBareID: Bool) throws {
        let (service, manager) = try fixture()
        set(video(.global("a")), on: service, seconds: 10)
        service.saveProgress()
        let first = try #require(manager.watchEntry(for: "a"))
        first.updatedAt = sentinel
        let nextID: VideoID = sameBareID
            ? .federated("a", instance: URL(string: "https://peertube.invalid")!)
            : .global("b")
        set(video(nextID), on: service, seconds: 10)
        service.saveProgress()
        let next = try #require(manager.watchEntry(for: nextID.videoID))
        #expect(next.updatedAt != sentinel)
        #expect(next.watchedSeconds == 10)
    }

    @Test func finalBackgroundAndStopSavesBypassDeduplication() throws {
        let (service, manager) = try fixture()
        let media = video(.global("a"))
        set(media, on: service, seconds: 10)
        service.saveProgress()
        let entry = try #require(manager.watchEntry(for: "a"))
        entry.updatedAt = sentinel
        service.syncWatchProgress() // Existing background-transition entry point.
        #expect(entry.updatedAt != sentinel)
        entry.updatedAt = sentinel
        service.stop()
        #expect(entry.updatedAt != sentinel)
        #expect(service.state.currentVideo == nil)
        entry.updatedAt = sentinel
        set(media, on: service, seconds: 10)
        service.saveProgress()
        #expect(entry.updatedAt != sentinel) // Stop reset the periodic snapshot.
    }

    @Test func completionThresholdStillSettlesAtAnUnchangedPosition() throws {
        let (service, manager) = try fixture()
        set(video(.global("a")), on: service, seconds: 90)
        service.saveProgress()
        service.saveProgress() // Existing follow-up applies updateProgress's threshold.
        let entry = try #require(manager.watchEntry(for: "a"))
        #expect(entry.isFinished)
        entry.updatedAt = sentinel
        service.saveProgress()
        #expect(entry.updatedAt == sentinel)
    }

    @Test(arguments: ["iptv", "incognito", "disabled"])
    func persistenceGuardsApplyToPeriodicAndFinalSaves(mode: String) throws {
        let (service, manager) = try fixture()
        let settings = SettingsManager()
        settings._incognitoModeEnabled = mode == "incognito"
        settings._saveWatchHistory = mode != "disabled"
        service.setSettingsManager(settings)
        if mode == "iptv" { service.state.transitionPlaybackContext(to: .iptv(sourceID: UUID())) }
        set(video(.global("a")), on: service, seconds: 10)
        service.saveProgress()
        service.syncWatchProgress()
        #expect(manager.watchHistoryCount() == 0)
    }

    private func fixture() throws -> (PlayerService, DataManager) {
        let manager = try DataManager(inMemory: true)
        let http = HTTPClient()
        return (PlayerService(httpClient: http, contentService: ContentService(httpClient: http),
                              dataManager: manager, backendFactory: Self.backendFactory), manager)
    }

    private func set(_ video: Video, on service: PlayerService, seconds: TimeInterval) {
        service.state.setCurrentVideo(video, stream: nil)
        service.state.duration = 100
        service.state.currentTime = seconds
    }

    private func video(_ id: VideoID) -> Video {
        Video(id: id, title: "Video", description: nil, author: Author(id: "author", name: "Author"),
              duration: 100, publishedAt: nil, publishedText: nil, viewCount: nil, likeCount: nil,
              thumbnails: [], isLive: false, isUpcoming: false, scheduledStartTime: nil)
    }
}
