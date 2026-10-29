//
//  FeedarrReleaseDetailSheet.swift
//  Yattee
//
//  Read-only release details from the catalogue DTO; artwork uses Feedarr's pipeline.
//

import Foundation
import SwiftUI

#if os(iOS)
struct FeedarrReleaseDetailSheet: View {
    let release: FeedarrRelease
    let posterService: FeedarrPosterService
    var trackerService: FeedarrTrackerService? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.openURL) private var openURL
    @State private var externalLinkTask: Task<Void, Never>?
    @State private var externalLinkRejected = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadToken = UUID()
    @State private var torrentFile: URL?
    @State private var showingExport = false
    @State private var magnetLink: String?
    @State private var showingMagnet = false
    @State private var downloadFailed = false

    private var metadata: FeedarrReleaseDetailMetadata { FeedarrReleaseDetailMetadata(release: release) }
    private var tracker: FeedarrTracker? { trackerService?.tracker(for: release.sourceId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        poster
                        VStack(alignment: .leading, spacing: 12) {
                            primaryInformation
                            Spacer(minLength: 0)
                            HStack {
                                Spacer(minLength: 0)
                                informationAction
                                downloadAction
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: (sizeClass == .regular ? 180 : 125) * 1.5, alignment: .topLeading)
                    }
                    releaseInformation
                    statistics
                    section("feedarr.detail.media", rows: metadata.mediaRows)
                    if let overview = metadata.overview {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(AppLocalization.string("feedarr.detail.overview"))
                                .font(.headline).accessibilityAddTraits(.isHeader)
                            Text(overview)
                                .font(.body)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .task { await trackerService?.loadIfNeeded() }
            .refreshable { await trackerService?.refresh() }
            .sheet(isPresented: $showingExport, onDismiss: cleanUpTorrent) {
                if let torrentFile { ShareSheet(items: [torrentFile]) }
            }
            .alert(AppLocalization.string("feedarr.download.magnetTitle"), isPresented: $showingMagnet) {
                Button(AppLocalization.string("feedarr.download.copyMagnet")) {
                    if let magnetLink { UIPasteboard.general.string = magnetLink }
                    magnetLink = nil
                }
                Button(AppLocalization.string("common.cancel"), role: .cancel) { magnetLink = nil }
            } message: { Text(AppLocalization.string("feedarr.download.magnetMessage")) }
            .alert(AppLocalization.string("feedarr.download.failed"), isPresented: $downloadFailed) {
                Button(AppLocalization.string("feedarr.download.retry")) { downloadTorrent() }
                Button(AppLocalization.string("common.cancel"), role: .cancel) {}
            } message: { Text(AppLocalization.string("feedarr.download.errorMessage")) }
            .alert(AppLocalization.string("feedarr.links.unavailable"), isPresented: $externalLinkRejected) {
                Button(AppLocalization.string("common.close"), role: .cancel) {}
            } message: { Text(AppLocalization.string("feedarr.links.rejected")) }
            .onDisappear {
                cancelDownload()
                externalLinkTask?.cancel()
                externalLinkTask = nil
            }
            .onChange(of: appEnvironment?.feedarrSourcesManager.configurationRevision) { _, _ in
                cancelDownload()
                showingExport = false
            }
            .reactiveNavigationTitle(AppLocalization.string("feedarr.detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(AppLocalization.string("common.close"))
                }
            }
        }
    }

    @ViewBuilder
    private var informationAction: some View {
        let links = FeedarrExternalLinks.items(for: release)
        if let link = links.first(where: { $0.id == "TMDB" }) ?? links.first(where: { $0.id == "TVDB" }) {
            Button { openExternalLink(link.url) } label: {
                Image(systemName: "info")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(Color.blue.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(externalLinkTask != nil)
            .accessibilityLabel(AppLocalization.string("feedarr.links.open") + " " + link.id)
        }
    }

    private func openExternalLink(_ url: URL) {
        guard externalLinkTask == nil else { return }
        externalLinkTask = Task {
            defer { if !Task.isCancelled { externalLinkTask = nil } }
            let allowed = await FeedarrExternalLinks.mayOpen(url)
            guard !Task.isCancelled else { return }
            if allowed { openURL(url) }
            else { externalLinkRejected = true }
        }
    }

    private var downloadAction: some View {
        Button(action: downloadTorrent) {
            ZStack {
                if downloadTask != nil {
                    ProgressView().tint(.blue)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                }
            }
            .foregroundStyle(.blue)
            .frame(width: 44, height: 44)
            .background(Color.blue.opacity(0.12), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.string("feedarr.download.title"))
        .disabled(downloadTask != nil || showingExport || appEnvironment?.feedarrSourcesManager.source == nil)
    }

    private func downloadTorrent() {
        guard downloadTask == nil, let manager = appEnvironment?.feedarrSourcesManager else { return }
        let token = UUID()
        downloadToken = token
        downloadFailed = false
        let service = FeedarrTorrentService(api: FeedarrAPIClient(sources: manager))
        downloadTask = Task {
            defer { if downloadToken == token { downloadTask = nil } }
            do {
                let result = try await service.download(releaseID: release.id)
                guard !Task.isCancelled, downloadToken == token else {
                    if case .file(let url) = result { FeedarrTorrentService.cleanUp(url) }
                    return
                }
                switch result {
                case .file(let url): torrentFile = url; showingExport = true
                case .magnet(let link): magnetLink = link; showingMagnet = true
                }
            } catch {
                guard !Task.isCancelled, downloadToken == token,
                      (error as? FeedarrAPIError) != .cancelled,
                      (error as? FeedarrAPIError) != .obsoleteResponse else { return }
                downloadFailed = true
            }
        }
    }

    private func cleanUpTorrent() {
        if let torrentFile { FeedarrTorrentService.cleanUp(torrentFile) }
        torrentFile = nil
    }

    private func cancelDownload() {
        downloadToken = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        magnetLink = nil
        showingMagnet = false
        cleanUpTorrent()
    }

    private var poster: some View {
        FeedarrPosterView(release: release, service: posterService)
            .frame(width: sizeClass == .regular ? 180 : 125)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var technicalTitle: String? {
        guard let title = release.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    private var cleanHeading: String? {
        guard let clean = release.titleClean?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return clean
    }

    private var primaryRows: [FeedarrReleaseDetailMetadata.Row] {
        metadata.releaseRows.filter { ["feedarr.detail.category", "feedarr.detail.year"].contains($0.id) }
    }

    private var primaryInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cleanHeading {
                Text(cleanHeading)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            }
            if !primaryRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(primaryRows) { row in
                        Text(row.value)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let episodeRows = metadata.releaseRows.filter { ["feedarr.detail.season", "feedarr.detail.episode"].contains($0.id) }
            if !episodeRows.isEmpty {
                Text(episodeRows.map { AppLocalization.string(String.LocalizationValue($0.id)) + " " + $0.value }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) { qualityBadges }
        }
    }

    @ViewBuilder
    private var qualityBadges: some View {
        let resolution = metadata.releaseRows.first { $0.id == "feedarr.detail.resolution" }?.value
        if let resolution { resolutionBadge(resolution) }
        if let codec = metadata.releaseRows.first(where: { $0.id == "feedarr.detail.codec" })?.value,
           codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != resolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            Text(codec)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1) }
        }
    }

    private var releaseGroups: [[FeedarrReleaseDetailMetadata.Row]] {
        let rows = metadata.releaseRows
        return [
            ["feedarr.detail.source"].compactMap { key in rows.first { $0.id == key } },
            ["feedarr.detail.size", "feedarr.detail.published", "feedarr.detail.group"].compactMap { key in rows.first { $0.id == key } }
        ].filter { !$0.isEmpty }
    }

    @ViewBuilder
    private var releaseInformation: some View {
        if technicalTitle != nil || !releaseGroups.isEmpty || tracker != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    if let technicalTitle {
                        if let url = FeedarrExternalLinks.validatedURL(release.trackerPageUrl) {
                            Button { openExternalLink(url) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(technicalTitle)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline.weight(.medium))
                                .lineSpacing(3)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(externalLinkTask != nil)
                            .accessibilityHint(AppLocalization.string("feedarr.links.open") + " Tracker")
                        } else {
                            Text(technicalTitle)
                                .font(.subheadline.weight(.medium))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if !releaseGroups.isEmpty { Divider() }
                    }
                    ForEach(Array(releaseGroups.enumerated()), id: \.offset) { index, rows in
                        if index > 0 { Divider() }
                        detailRows(rows)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                HStack {
                    Text(AppLocalization.string("feedarr.detail.information")).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let tracker { trackerBadge(tracker) }
                }
            }
        }
    }

    @ViewBuilder
    private var statistics: some View {
        if !metadata.statisticsRows.isEmpty {
            GroupBox {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 16) {
                    ForEach(metadata.statisticsRows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.value).font(.headline).monospacedDigit()
                            Text(AppLocalization.string(String.LocalizationValue(row.id)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(AppLocalization.string("feedarr.detail.statistics")).accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [FeedarrReleaseDetailMetadata.Row]) -> some View {
        if !rows.isEmpty {
            GroupBox {
                detailRows(rows).padding(.top, 8)
            } label: {
                Text(AppLocalization.string(String.LocalizationValue(title))).accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func detailRows(_ rows: [FeedarrReleaseDetailMetadata.Row]) -> some View {
        VStack(spacing: 14) {
            ForEach(rows) { row in
                LabeledContent(AppLocalization.string(String.LocalizationValue(row.id))) {
                    Text(row.value)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackerBadge(_ tracker: FeedarrTracker) -> some View {
        let rgb = tracker.badgeColor
        let background = rgb.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1) }
            ?? Color.secondary.opacity(0.15)
        let foreground: Color = rgb.map { $0.usesDarkText ? .black : .white } ?? .primary
        return Text(tracker.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .overlay { Capsule().strokeBorder(foreground.opacity(0.2), lineWidth: 1) }
    }

    private func resolutionBadge(_ value: String) -> some View {
        let style = FeedarrResolutionBadgeStyle(resolution: value)
        return Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.tint.opacity(colorScheme == .dark ? 0.32 : 0.18), in: Capsule())
            .overlay { Capsule().strokeBorder(style.tint.opacity(colorScheme == .dark ? 0.8 : 0.5), lineWidth: 1) }
    }
}
#endif

/// Resolution classification affects appearance only; the displayed server value stays intact.
enum FeedarrResolutionBadgeStyle: Equatable, Sendable {
    case hd, fullHD, ultraHD, sd, neutral

    init(resolution: String) {
        switch resolution.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "720p": self = .hd
        case "1080p": self = .fullHD
        case "2160p", "4k": self = .ultraHD
        case "480p", "sd": self = .sd
        default: self = .neutral
        }
    }

    var tint: Color {
        switch self {
        case .hd: .green
        case .fullHD: .blue
        case .ultraHD: .purple
        case .sd: .gray
        case .neutral: .secondary
        }
    }
}

/// Pure formatting only: no enrichment, external links, or placeholder metadata.
struct FeedarrReleaseDetailMetadata: Sendable {
    let release: FeedarrRelease

    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let value: String
    }

    var title: String? { nonBlank(release.title) ?? nonBlank(release.titleClean) }
    var overview: String? { nonBlank(release.overview) }

    var releaseRows: [Row] {
        var rows: [Row] = []
        func add(_ key: String, _ value: String?) {
            if let value = nonBlank(value) { rows.append(Row(id: "feedarr.detail." + key, value: value)) }
        }
        if nonBlank(release.titleClean) != title { add("cleanTitle", release.titleClean) }
        add("year", release.year.flatMap { $0 > 0 ? $0.formatted(.number.grouping(.never)) : nil })
        add("category", [release.unifiedCategoryLabel, release.unifiedCategory, release.categoryName, release.unifiedCategoryKey].compactMap(nonBlank).first)
        add("season", release.season.flatMap { $0 >= 0 ? $0.formatted() : nil })
        add("episode", release.episode.flatMap { $0 >= 0 ? $0.formatted() : nil })
        add("resolution", release.resolution)
        add("codec", release.codec)
        add("source", release.source)
        add("group", release.releaseGroup)
        if let size = release.sizeBytes, size >= 0 {
            add("size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let timestamp = release.publishedAt, timestamp >= 0,
           Double(timestamp) <= Date.distantFuture.timeIntervalSince1970 {
            add("published", Date(timeIntervalSince1970: Double(timestamp)).formatted(date: .abbreviated, time: .shortened))
        }
        return rows
    }

    var mediaRows: [Row] {
        var rows: [Row] = []
        if let rating = release.rating, rating.isFinite, rating >= 0 {
            rows.append(Row(id: "feedarr.detail.rating", value: rating.formatted(.number.precision(.fractionLength(0...1)))))
        }
        if let votes = release.ratingVotes, votes >= 0 {
            rows.append(Row(id: "feedarr.detail.votes", value: votes.formatted()))
        }
        if let genres = nonBlank(release.genres) { rows.append(Row(id: "feedarr.detail.genres", value: genres)) }
        if let duration = release.runtimeMinutes, duration > 0 {
            rows.append(Row(id: "feedarr.detail.runtime", value: duration.formatted()))
        }
        if let date = nonBlank(release.releaseDate) { rows.append(Row(id: "feedarr.detail.releaseDate", value: date)) }
        return rows
    }

    var statisticsRows: [Row] {
        [("seeders", release.seeders), ("leechers", release.leechers), ("grabs", release.grabs)].compactMap { key, count in
            guard let count, count >= 0 else { return nil }
            return Row(id: "feedarr.detail." + key, value: count.formatted())
        }
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
