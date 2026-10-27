//
//  PlayerPlaybackContextTests.swift
//  YatteeTests
//
//  Tests for ephemeral IPTV playback policy and sensitive reference cleanup.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Player Playback Context Tests")
@MainActor
struct PlayerPlaybackContextTests {
    @Test("Standard playback preserves existing queue and history behavior")
    func standardPlaybackKeepsQueueAndHistory() {
        let state = PlayerState()
        let video = makeVideo(id: "standard")

        state.addToQueue(video)
        state.pushToHistory(QueuedVideo(video: video))

        #expect(state.playbackContext == .standard)
        #expect(state.playbackContext.allowsPersistence)
        #expect(state.queue.count == 1)
        #expect(state.history.count == 1)
    }

    @Test("Entering IPTV clears and blocks queue and previous history")
    func iptvBlocksQueueStorage() {
        let state = PlayerState()
        let video = makeVideo(id: "queued")
        state.addToQueue(video)
        state.pushToHistory(QueuedVideo(video: video))

        state.transitionPlaybackContext(to: .iptv(sourceID: UUID()))
        state.addToQueue(video, stream: makeSensitiveStream())
        state.insertNext(video, stream: makeSensitiveStream())
        state.pushToHistory(QueuedVideo(video: video, stream: makeSensitiveStream()))

        #expect(!state.playbackContext.allowsPersistence)
        #expect(!state.playbackContext.allowsSharing)
        #expect(state.queue.isEmpty)
        #expect(state.history.isEmpty)
    }

    @Test("Leaving IPTV removes current sensitive playback references")
    func leavingIPTVClearsSensitiveReferences() {
        let state = PlayerState()
        let sourceID = UUID()
        state.transitionPlaybackContext(to: .iptv(sourceID: sourceID))
        state.setCurrentVideo(
            makeVideo(id: "iptv-channel"),
            stream: makeSensitiveStream(),
            audioStream: makeSensitiveStream()
        )

        state.transitionPlaybackContext(to: .standard)

        #expect(state.playbackContext == .standard)
        #expect(state.currentVideo == nil)
        #expect(state.currentStream == nil)
        #expect(state.currentAudioStream == nil)
    }

    @Test("Stopping state restores the standard context and removes streams")
    func stopStateCleanup() {
        let state = PlayerState()
        state.transitionPlaybackContext(to: .iptv(sourceID: UUID()))
        state.setCurrentVideo(makeVideo(id: "iptv-channel"), stream: makeSensitiveStream())

        state.setCurrentVideo(nil, stream: nil)

        #expect(state.playbackContext == .standard)
        #expect(state.currentVideo == nil)
        #expect(state.currentStream == nil)
        #expect(state.currentAudioStream == nil)
    }

    private func makeVideo(id: String) -> Video {
        Video(
            id: .global(id),
            title: "Video",
            description: nil,
            author: Author(id: "author", name: "Author"),
            duration: 0,
            publishedAt: nil,
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: [],
            isLive: true,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }

    private func makeSensitiveStream() -> Stream {
        Stream(
            url: URL(string: "https://server.invalid/live/private-user/private-password/42.m3u8")!,
            format: "m3u8",
            isLive: true,
            mimeType: "application/vnd.apple.mpegurl"
        )
    }
}
