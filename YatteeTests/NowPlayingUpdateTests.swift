//
//  NowPlayingUpdateTests.swift
//  Yattee
//
//  High-frequency time callbacks must preserve explicit Now Playing changes.
//

import Foundation
import SwiftUI
import MediaPlayer
import Observation
import Testing
@testable import XTubee

@Suite("Now Playing Updates", .serialized)
@MainActor
struct NowPlayingUpdateTests {
    private static let factory = BackendFactory()
    private static let backend = MPVBackend()

    @Test func repeatedTicksPublishOncePerBucketAndKeepMetadata() throws {
        try withPlayer { service, center in
            service.backend(Self.backend, didUpdateTime: 2.1)
            #expect(elapsed(center) == 2.1)
            service.backend(Self.backend, didUpdateTime: 2.2)
            service.backend(Self.backend, didUpdateTime: 4.9)
            #expect(service.state.currentTime == 4.9)
            #expect(elapsed(center) == 2.1)
            service.backend(Self.backend, didUpdateTime: 5.1)
            #expect(elapsed(center) == 5.1)
            service.backend(Self.backend, didUpdateTime: 5.2)
            #expect(elapsed(center) == 5.1)
            #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Metadata")
        }
    }

    @Test func sourceAndDurationChangesAreNotSuppressed() throws {
        try withPlayer { service, center in
            service.backend(Self.backend, didUpdateTime: 2.1)
            service.state.setCurrentVideo(video(.federated("a", instance: URL(string: "https://peertube.invalid")!)), stream: nil)
            service.state.duration = 100
            service.backend(Self.backend, didUpdateTime: 2.2)
            #expect(elapsed(center) == 2.2)
            service.state.duration = 120
            service.backend(Self.backend, didUpdateTime: 2.3)
            #expect(elapsed(center) == 2.3)
            #expect(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 120)
            service.state.setCurrentVideo(video(.global("b")), stream: nil)
            service.state.duration = 100
            service.backend(Self.backend, didUpdateTime: 2.4)
            #expect(elapsed(center) == 2.4)
        }
    }

    @Test func pauseResumeAndForegroundRefreshWithinSameBucket() throws {
        try withPlayer { service, center in
            service.backend(Self.backend, didUpdateTime: 2.1)
            service.backend(Self.backend, didUpdateTime: 2.2)
            service.pause(saveProgress: false)
            #expect(elapsed(center) == 2.2)
            #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
            service.state.currentTime = 2.3
            service.resume()
            #expect(elapsed(center) == 2.3)
            #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
            service.backend(Self.backend, didUpdateTime: 2.5)
            service.handleScenePhase(.background)
            service.state.currentTime = 2.75
            service.handleScenePhase(.active)
            #expect(elapsed(center) == 2.75)
        }
    }

    @Test func seekWithinSameBucketUpdatesImmediately() async throws {
        let center = MPNowPlayingInfoCenter.default()
        let previous = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previous }
        let service = try player()
        seed(center)
        service.backend(Self.backend, didUpdateTime: 2.1)
        await service.seek(to: 3.25)
        #expect(elapsed(center) == 3.25)
        service.backend(Self.backend, didUpdateTime: 3.5)
        #expect(elapsed(center) == 3.25)
    }

    @Test func nilSponsorBlockSegmentIsNotPublishedAgain() throws {
        try withPlayer { service, _ in
            let changes = ChangeCounter()
            withObservationTracking { _ = service.state.currentSegment } onChange: { changes.increment() }
            service.backend(Self.backend, didUpdateTime: 2.1)
            service.backend(Self.backend, didUpdateTime: 2.2)
            #expect(changes.count == 0)
        }
    }

    private func withPlayer(_ body: (PlayerService, MPNowPlayingInfoCenter) throws -> Void) throws {
        let center = MPNowPlayingInfoCenter.default()
        let previous = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previous }
        let service = try player()
        seed(center)
        try body(service, center)
    }

    private func player() throws -> PlayerService {
        let http = HTTPClient()
        let service = PlayerService(httpClient: http, contentService: ContentService(httpClient: http),
                                    dataManager: try DataManager(inMemory: true), backendFactory: Self.factory)
        service.state.setCurrentVideo(video(.global("a")), stream: nil)
        service.state.duration = 100
        service.state.setPlaybackState(.playing)
        return service
    }

    private func seed(_ center: MPNowPlayingInfoCenter) {
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Metadata",
                                 MPMediaItemPropertyPlaybackDuration: 100.0,
                                 MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
                                 MPNowPlayingInfoPropertyPlaybackRate: 1.0]
    }

    private func elapsed(_ center: MPNowPlayingInfoCenter) -> Double? {
        center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
    }

    private func video(_ id: VideoID) -> Video {
        Video(id: id, title: "Video", description: nil, author: Author(id: "author", name: "Author"),
              duration: 100, publishedAt: nil, publishedText: nil, viewCount: nil, likeCount: nil,
              thumbnails: [], isLive: false, isUpcoming: false, scheduledStartTime: nil)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
