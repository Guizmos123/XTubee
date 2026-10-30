//
//  FeedarrHomeSectionView.swift
//  Yattee
//
//  Home and Hub shelves using Feedarr's shared Top state and artwork pipeline.
//

import Foundation
import SwiftUI

#if os(iOS)
struct FeedarrHomeSectionView: View {
    let kind: FeedarrHomeSection
    let model: FeedarrTopModel
    let layout: HomeSectionLayout
    let listStyle: VideoListStyle
    let limit: Int

    @Environment(\.appEnvironment) private var appEnvironment
    @State private var consumerID = UUID()
    @State private var selectedRelease: FeedarrReleaseSelection?

    var body: some View {
        let revision = model.configurationRevision
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.title)
                .fontWeight(.semibold)
                .foregroundStyle(appEnvironment?.settingsManager.resolvedAccentColor ?? .accentColor)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, listStyle == .inset ? 32 : 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let environment = appEnvironment {
                if let error = environment.feedarrSourcesManager.loadError {
                    status(error.localizedDescription)
                } else if environment.feedarrSourcesManager.source == nil {
                    status(AppLocalization.string("feedarr.empty.description"))
                } else {
                    if let failure = model.failure {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(failure.message).foregroundStyle(.secondary)
                            Button(AppLocalization.string("feedarr.retry")) { model.retry() }
                                .disabled(model.isLoading)
                        }
                        .padding(.horizontal, 16)
                    }
                    if let response = model.currentResponse {
                        let releases = Array(kind.releases(in: response).prefix(max(1, min(20, limit))))
                        if releases.isEmpty {
                            status(AppLocalization.string("feedarr.top.rail.empty"))
                        } else {
                            cards(releases, environment: environment, revision: revision)
                        }
                    } else if model.isLoading || model.failure == nil {
                        ProgressView(AppLocalization.string("feedarr.top.loading"))
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
            }
        }
        .onAppear { model.setConsumer(consumerID, active: true) }
        .onDisappear { model.setConsumer(consumerID, active: false) }
        .onChange(of: appEnvironment?.feedarrSourcesManager.configurationRevision) { _, _ in
            selectedRelease = nil
        }
        .sheet(item: $selectedRelease) { selection in
            if let environment = appEnvironment {
                FeedarrReleaseDetailSheet(selection: selection, posterService: environment.feedarrPosterService,
                                          trackerService: environment.feedarrTrackerService)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .task { await environment.feedarrTrackerService.loadIfNeeded() }
            }
        }
    }

    private func status(_ message: String) -> some View {
        Text(message).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private var usesCompactCarousel: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && layout == .grid
    }

    @ViewBuilder
    private func cards(_ releases: [FeedarrRelease], environment: AppEnvironment, revision: UUID) -> some View {
        let select: (FeedarrRelease) -> Void = { release in
            let selection = FeedarrReleaseSelection(release: release, configurationRevision: revision)
            guard selection.isCurrent(sources: environment.feedarrSourcesManager) else { return }
            selectedRelease = selection
        }
        if layout == .list {
            VideoListContent(listStyle: listStyle) {
                ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                    VideoListRow(isLast: index == releases.count - 1, rowStyle: .regular, listStyle: listStyle) {
                        FeedarrReleaseRow(release: release, posterService: environment.feedarrPosterService,
                                          style: .regular, onSelectRelease: select)
                    }
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: layout == .large || usesCompactCarousel ? 12 : 28) {
                    ForEach(releases) { release in
                        if layout == .large {
                            FeedarrReleaseCard(release: release, posterService: environment.feedarrPosterService,
                                               onSelectRelease: select, titleLineLimit: 3)
                                .containerRelativeFrame(.horizontal) { width, _ in min(width * 0.8, 280) }
                        } else if usesCompactCarousel {
                            FeedarrReleaseCard(release: release, posterService: environment.feedarrPosterService,
                                               onSelectRelease: select, titleLineLimit: 3)
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    // Two full posters, two gaps and the start of a third.
                                    max(1, (width - 24) / 2.3)
                                }
                        } else {
                            FeedarrReleaseCard(release: release, posterService: environment.feedarrPosterService,
                                               onSelectRelease: select, titleLineLimit: 3)
                                .frame(width: 180, alignment: .topLeading)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

#endif
