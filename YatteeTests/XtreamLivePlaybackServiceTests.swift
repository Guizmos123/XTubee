//
//  XtreamLivePlaybackServiceTests.swift
//  YatteeTests
//
//  Tests for secure Xtream Live playback preparation.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Xtream Live Playback Service Tests")
@MainActor
struct XtreamLivePlaybackServiceTests {
    @Test("M3U8 is preferred over TS regardless of advertised order")
    func prefersM3U8() throws {
        let fixture = try makeFixture()
        let preparation = try fixture.service.prepare(
            sourceID: fixture.source.id,
            group: fixture.group,
            variant: fixture.variant,
            allowedOutputFormats: ["ts", "M3U8"]
        )

        #expect(preparation.outputFormat == .m3u8)
        #expect(preparation.stream.format == "m3u8")
        #expect(preparation.stream.mimeType == "application/vnd.apple.mpegurl")
        #expect(preparation.stream.isLive)
        #expect(preparation.isPlaybackAllowed)
        #expect(preparation.playbackPolicy == .directMPV)
        #expect(preparation.stream.httpHeaders == nil)
    }

    @Test("TS is selected only when M3U8 is not advertised")
    func fallsBackToTS() throws {
        let fixture = try makeFixture()
        let preparation = try fixture.service.prepare(
            sourceID: fixture.source.id,
            group: fixture.group,
            variant: fixture.variant,
            allowedOutputFormats: [" ts "]
        )

        #expect(preparation.outputFormat == .ts)
        #expect(preparation.stream.mimeType == "video/mp2t")
        #expect(preparation.stream.url.pathExtension == "ts")
    }

    @Test("Absent or unknown output formats are rejected")
    func rejectsUnadvertisedFormats() throws {
        let fixture = try makeFixture()
        let unsupportedFormats: [[String]?] = [nil, [], ["mp4"], ["unknown", "dash"]]

        for formats in unsupportedFormats {
            #expect(throws: XtreamLivePlaybackPreparationError.noSupportedOutputFormat) {
                _ = try fixture.service.prepare(
                    sourceID: fixture.source.id,
                    group: fixture.group,
                    variant: fixture.variant,
                    allowedOutputFormats: formats
                )
            }
        }
    }

    @Test("Credentials and stream identifiers are encoded as individual path segments")
    func encodesPathSegments() throws {
        let fixture = try makeFixture(
            serverURL: "https://server.invalid/base%20path",
            username: "user/name@example.com",
            password: "p@ss word?#%",
            streamID: "stream/é ?#"
        )
        let preparation = try fixture.service.prepare(
            sourceID: fixture.source.id,
            group: fixture.group,
            variant: fixture.variant,
            allowedOutputFormats: ["m3u8"]
        )

        #expect(preparation.stream.url.absoluteString == "https://server.invalid/base%20path/live/user%2Fname%40example.com/p%40ss%20word%3F%23%25/stream%2F%C3%A9%20%3F%23.m3u8")
    }

    @Test("Missing source and credentials return typed non-sensitive errors")
    func missingSourceAndCredentials() throws {
        let fixture = try makeFixture(storeCredentials: false)

        #expect(throws: XtreamLivePlaybackPreparationError.sourceNotFound) {
            _ = try fixture.service.prepare(
                sourceID: UUID(),
                group: fixture.group,
                variant: fixture.variant,
                allowedOutputFormats: ["m3u8"]
            )
        }
        #expect(throws: XtreamLivePlaybackPreparationError.credentialsMissing) {
            _ = try fixture.service.prepare(
                sourceID: fixture.source.id,
                group: fixture.group,
                variant: fixture.variant,
                allowedOutputFormats: ["m3u8"]
            )
        }
    }

    @Test("Prepared identities and descriptions contain no credentials or playback URL")
    func identitiesAreNonSensitive() throws {
        let username = "private-user"
        let password = "private-password"
        let fixture = try makeFixture(username: username, password: password)
        let preparation = try fixture.service.prepare(
            sourceID: fixture.source.id,
            group: fixture.group,
            variant: fixture.variant,
            allowedOutputFormats: ["m3u8", "ts"]
        )

        let identityText = String(reflecting: preparation.video.id)
        let publicDescription = String(describing: preparation)
        let debugDescription = String(reflecting: preparation)
        for value in [username, password, preparation.stream.url.absoluteString] {
            #expect(!identityText.contains(value))
            #expect(!publicDescription.contains(value))
            #expect(!debugDescription.contains(value))
        }
        #expect(preparation.video.isLive)
        #expect(preparation.video.id.videoID.contains(fixture.source.id.uuidString.lowercased()))
    }

    private func makeFixture(
        serverURL: String = "https://server.invalid",
        username: String = "user",
        password: String = "password",
        streamID: String = "42",
        storeCredentials: Bool = true
    ) throws -> Fixture {
        let credentialsStore = PlaybackCredentialsStore()
        let source = try IPTVSource(name: "Provider", serverURL: serverURL)
        if storeCredentials {
            credentialsStore.values[source.id] = XtreamCredentials(
                username: username,
                password: password
            )
        }
        let sourcesManager = IPTVSourcesManager(
            persistence: PlaybackSourcesPersistence(sources: [source], activeID: source.id),
            credentialsStore: credentialsStore
        )
        let encodedStreamID = try encodedJSONStringContent(streamID)
        let rawStream = try JSONDecoder().decode(
            XtreamLiveStream.self,
            from: Data("{\"stream_id\":\"\(encodedStreamID)\",\"name\":\"Channel HD\",\"category_id\":\"news\"}".utf8)
        )
        let group = try #require(
            IPTVLiveChannelGrouper.groups(sourceID: source.id, streams: [rawStream]).first
        )
        let variant = try #require(IPTVLiveChannelPresentation(group: group).variants.first)
        return Fixture(
            source: source,
            group: group,
            variant: variant,
            service: XtreamLivePlaybackService(
                sourcesManager: sourcesManager,
                credentialsStore: credentialsStore
            )
        )
    }

    private func encodedJSONStringContent(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    private struct Fixture {
        let source: IPTVSource
        let group: IPTVLiveChannelGroup
        let variant: IPTVLiveVariantPresentation
        let service: XtreamLivePlaybackService
    }
}

@MainActor
private final class PlaybackSourcesPersistence: IPTVSourcesPersisting {
    private var sources: [IPTVSource]
    private var activeID: UUID?

    init(sources: [IPTVSource], activeID: UUID?) {
        self.sources = sources
        self.activeID = activeID
    }

    func loadSources() throws -> [IPTVSource] { sources }
    func loadActiveSourceID() throws -> UUID? { activeID }
    func saveSources(_ sources: [IPTVSource]) throws { self.sources = sources }
    func saveActiveSourceID(_ sourceID: UUID?) throws { activeID = sourceID }
}

@MainActor
private final class PlaybackCredentialsStore: XtreamCredentialsStoring {
    var values: [UUID: XtreamCredentials] = [:]

    func credentials(for sourceID: UUID) throws -> XtreamCredentials? { values[sourceID] }
    func setCredentials(_ credentials: XtreamCredentials, for sourceID: UUID) throws {
        values[sourceID] = credentials
    }
    func deleteCredentials(for sourceID: UUID) throws { values.removeValue(forKey: sourceID) }
}
