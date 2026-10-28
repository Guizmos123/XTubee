//
//  QueuedPlaybackResumeContractTests.swift
//  Yattee
//
//  Static regression checks for queued playback entry points. These do not
//  replace execution tests of saved progress and backend seek completion.
//

import Foundation
import Testing

@Suite("Queued Playback Resume Contracts")
struct QueuedPlaybackResumeContractTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Every queued loading path leaves the resume position unspecified")
    func queuedLoadingPathsDelegateResume() throws {
        let player = try source("Yattee/Services/Player/PlayerService.swift")
        let start = try #require(player.range(of: "private func playQueuedVideo("))
        let end = try #require(player.range(of: "///   - startTime:", range: start.upperBound..<player.endIndex))
        let queuedPlayback = String(player[start.lowerBound..<end.lowerBound])
        let calls = queuedPlayback.split(separator: "\n").filter { $0.contains("await play(video:") }

        #expect(calls.count == 3)
        #expect(calls.contains { $0.contains("audioStream: nil)") })
        #expect(calls.contains { $0.contains("video: downloadedVideo, stream: localStream") })
        #expect(calls.contains { $0.contains("video: queuedVideo.video, stream: stream, audioStream: audioStream)") })
        #expect(calls.allSatisfy { !$0.contains("startTime:") })
        #expect(!queuedPlayback.contains("resumeAction"))
    }

    @Test("Next and automatic completion use the shared queue path; repeat one restarts")
    func nextAndCompletionShareQueuePath() throws {
        let player = try source("Yattee/Services/Player/PlayerService.swift")
        let start = try #require(player.range(of: "func playNext() async"))
        let end = try #require(player.range(of: "private func pushCurrentToHistoryIfNeeded", range: start.upperBound..<player.endIndex))
        let next = String(player[start.lowerBound..<end.lowerBound])
        #expect(next.components(separatedBy: "await playQueuedVideo(next)").count - 1 == 2)
        #expect(next.contains("await seek(to: 0)"))

        let completionStart = try #require(player.range(of: "func backendDidFinishPlaying("))
        let completionEnd = try #require(player.range(of: "func notifyVideoStarted()", range: completionStart.upperBound..<player.endIndex))
        #expect(player[completionStart.lowerBound..<completionEnd.lowerBound].contains("await playNext()"))

        let autoplay = try source("Yattee/Views/Player/ExpandedPlayerSheet+Autoplay.swift")
        #expect(autoplay.contains("await playerService.playNext()"))
    }
}
