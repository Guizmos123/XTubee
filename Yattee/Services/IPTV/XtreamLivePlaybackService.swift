//
//  XtreamLivePlaybackService.swift
//  Yattee
//
//  Prepares non-persistent Xtream Live playback objects without starting playback.
//

import Foundation

enum XtreamLiveOutputFormat: String, Codable, Hashable, Sendable {
    case m3u8
    case ts

    var mimeType: String {
        switch self {
        case .m3u8: return "application/vnd.apple.mpegurl"
        case .ts: return "video/mp2t"
        }
    }
}

enum XtreamLivePlaybackPolicy: Hashable, Sendable {
    /// Loads the canonical Xtream URL directly and lets MPV handle HTTP and HLS
    /// redirects. No authorization, cookie, or other sensitive header is added.
    /// Redirect targets remain controlled by the provider, and plain HTTP does
    /// not protect the credential-bearing URL in transit.
    case directMPV
}

struct XtreamLivePlaybackPreparation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let video: Video
    let stream: Stream
    let outputFormat: XtreamLiveOutputFormat
    let playbackPolicy: XtreamLivePlaybackPolicy

    var isPlaybackAllowed: Bool { playbackPolicy == .directMPV }
    var description: String { "XtreamLivePlaybackPreparation(redacted)" }
    var debugDescription: String { description }
}

enum XtreamLivePlaybackPreparationError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotFound
    case credentialsMissing
    case credentialStoreUnavailable
    case noSupportedOutputFormat
    case invalidStreamIdentifier
    case invalidPlaybackURL

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "The IPTV source was not found."
        case .credentialsMissing:
            return "The IPTV source credentials are unavailable."
        case .credentialStoreUnavailable:
            return "The local IPTV credential store is unavailable."
        case .noSupportedOutputFormat:
            return "The IPTV account does not advertise a supported Live output format."
        case .invalidStreamIdentifier:
            return "The IPTV stream identifier is invalid."
        case .invalidPlaybackURL:
            return "The IPTV playback address could not be prepared."
        }
    }
}

@MainActor
final class XtreamLivePlaybackService {
    private static let provider = "iptv"

    private let sourcesManager: IPTVSourcesManager
    private let credentialsStore: XtreamCredentialsStoring

    init(
        sourcesManager: IPTVSourcesManager,
        credentialsStore: XtreamCredentialsStoring
    ) {
        self.sourcesManager = sourcesManager
        self.credentialsStore = credentialsStore
    }

    /// Builds ephemeral `Video` and `Stream` values for the selected Xtream variant.
    ///
    /// The returned stream uses direct MPV playback. MPV may follow provider and
    /// HLS redirects, but this service never attaches sensitive HTTP headers.
    func prepare(
        sourceID: UUID,
        group: IPTVLiveChannelGroup,
        variant: IPTVLiveVariantPresentation,
        allowedOutputFormats: [String]?
    ) throws -> XtreamLivePlaybackPreparation {
        guard let source = sourcesManager.sources.first(where: { $0.id == sourceID }) else {
            throw XtreamLivePlaybackPreparationError.sourceNotFound
        }
        guard group.sourceID == sourceID,
              variant.id.groupID == group.id,
              group.variants.contains(variant.variant),
              !variant.streamID.isEmpty else {
            throw XtreamLivePlaybackPreparationError.invalidStreamIdentifier
        }

        let credentials: XtreamCredentials
        do {
            guard let storedCredentials = try credentialsStore.credentials(for: sourceID),
                  !storedCredentials.username.isEmpty,
                  !storedCredentials.password.isEmpty else {
                throw XtreamLivePlaybackPreparationError.credentialsMissing
            }
            credentials = storedCredentials
        } catch let error as XtreamLivePlaybackPreparationError {
            throw error
        } catch {
            throw XtreamLivePlaybackPreparationError.credentialStoreUnavailable
        }

        let outputFormat = try Self.preferredOutputFormat(from: allowedOutputFormats)
        let playbackURL = try Self.playbackURL(
            serverURL: source.serverURL,
            username: credentials.username,
            password: credentials.password,
            streamID: variant.streamID,
            outputFormat: outputFormat
        )

        let video = Video(
            id: VideoID(
                source: .extracted(extractor: Self.provider, originalURL: source.serverURL),
                videoID: "iptv:\(source.id.uuidString.lowercased()):\(variant.streamID)"
            ),
            title: group.displayName,
            description: nil,
            author: Author(
                id: "iptv:\(source.id.uuidString.lowercased())",
                name: source.name,
                hasRealChannelInfo: false
            ),
            duration: 0,
            publishedAt: nil,
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: variant.variant.stream.streamIconURL.map { [Thumbnail(url: $0)] } ?? [],
            isLive: true,
            isUpcoming: false,
            scheduledStartTime: nil
        )
        let stream = Stream(
            url: playbackURL,
            resolution: nil,
            format: outputFormat.rawValue,
            videoCodec: variant.usesHEVC ? "hevc" : nil,
            audioCodec: nil,
            isAudioOnly: false,
            isLive: true,
            mimeType: outputFormat.mimeType,
            httpHeaders: nil
        )

        return XtreamLivePlaybackPreparation(
            video: video,
            stream: stream,
            outputFormat: outputFormat,
            playbackPolicy: .directMPV
        )
    }

    static func preferredOutputFormat(
        from allowedOutputFormats: [String]?
    ) throws -> XtreamLiveOutputFormat {
        let advertised = Set(
            (allowedOutputFormats ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        if advertised.contains(XtreamLiveOutputFormat.m3u8.rawValue) { return .m3u8 }
        if advertised.contains(XtreamLiveOutputFormat.ts.rawValue) { return .ts }
        throw XtreamLivePlaybackPreparationError.noSupportedOutputFormat
    }

    private static func playbackURL(
        serverURL: URL,
        username: String,
        password: String,
        streamID: String,
        outputFormat: XtreamLiveOutputFormat
    ) throws -> URL {
        guard var components = URLComponents(
            url: try XtreamServerURL.normalize(serverURL.absoluteString),
            resolvingAgainstBaseURL: false
        ) else {
            throw XtreamLivePlaybackPreparationError.invalidPlaybackURL
        }

        let encodedSegments = try [username, password, streamID].map(percentEncodedPathSegment)
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = "\(basePath)/live/\(encodedSegments[0])/\(encodedSegments[1])/\(encodedSegments[2]).\(outputFormat.rawValue)"

        guard let url = components.url else {
            throw XtreamLivePlaybackPreparationError.invalidPlaybackURL
        }
        return url
    }

    private static func percentEncodedPathSegment(_ value: String) throws -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard !value.isEmpty,
              let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw XtreamLivePlaybackPreparationError.invalidPlaybackURL
        }
        return encoded
    }
}
