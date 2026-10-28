//
//  FeedarrReleasesView.swift
//  Yattee
//
//  Adaptive poster grid, retained between segments and paginated near its end.
//

import Foundation
import SwiftUI

struct FeedarrReleasesView: View {
    let model: FeedarrReleasesModel
    let posterService: FeedarrPosterService
    let isVisible: Bool

    private let columns = [GridItem(.adaptive(minimum: 144), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 20) {
                    if model.isLoadingInitial && model.items.isEmpty {
                        ProgressView(AppLocalization.string("feedarr.releases.loading"))
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if model.isEmpty && model.failure == nil {
                        ContentUnavailableView(AppLocalization.string("feedarr.releases.empty"), systemImage: "rectangle.stack")
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(model.items) { release in
                            FeedarrReleaseCard(release: release, posterService: posterService)
                                .onAppear { model.itemAppeared(release.id) }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .id(model.catalogGeneration)
            .refreshable { await model.refresh() }
        }
        .onAppear { model.setVisible(isVisible) }
        .onChange(of: isVisible) { model.setVisible(isVisible) }
        .onDisappear { model.setVisible(false) }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let failure = model.failure {
                Label(failure.message, systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(AppLocalization.string("feedarr.retry")) { model.retry() }
                    .buttonStyle(.bordered)
            } else if model.isLoadingNextPage {
                ProgressView(AppLocalization.string("feedarr.releases.loadingMore"))
            } else if model.isAtEnd && !model.items.isEmpty && !model.isLoadingInitial {
                Text(AppLocalization.string("feedarr.releases.end"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Color.clear.frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        // Also advances through empty/duplicate-only pages when the footer stays visible.
        .task(id: PageTrigger(cursor: model.nextCursor, visible: isVisible)) {
            if isVisible { model.loadNextPage() }
        }
    }

    private struct PageTrigger: Equatable {
        let cursor: String?
        let visible: Bool
    }
}
