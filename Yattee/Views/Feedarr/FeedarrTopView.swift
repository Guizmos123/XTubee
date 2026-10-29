//
//  FeedarrTopView.swift
//  Yattee
//
//  Seven native horizontal rails, sharing a single Top response and sort menu.
//

import Foundation
import SwiftUI

struct FeedarrTopView: View {
    let model: FeedarrTopModel
    let posterService: FeedarrPosterService
    let isVisible: Bool
    var isManuallyRefreshing = false
    var onSelectRelease: ((FeedarrRelease) -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if model.isLoading && model.response == nil && !isManuallyRefreshing {
                        ProgressView(AppLocalization.string("feedarr.top.loading"))
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    if let failure = model.failure {
                        ContentUnavailableView {
                            Label(AppLocalization.string("feedarr.top.error.title"), systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
                        } description: {
                            Text(failure.message)
                        } actions: {
                            Button(AppLocalization.string("feedarr.retry")) { model.retry() }
                        }
                    }
                    if model.isEmpty {
                        ContentUnavailableView(AppLocalization.string("feedarr.top.empty.title"), systemImage: "rectangle.stack",
                                               description: Text(AppLocalization.string("feedarr.top.empty.description")))
                    } else {
                        ForEach(model.rails) { rail in railView(rail) }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear { model.setVisible(isVisible) }
        .onChange(of: isVisible) { model.setVisible(isVisible) }
        .onDisappear { model.setVisible(false) }
    }

    private func railView(_ rail: FeedarrTopRailContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rail.title).font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if let count = rail.count {
                    Text(count.formatted()).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            if rail.items.isEmpty {
                Text(AppLocalization.string("feedarr.top.rail.empty"))
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(rail.items) { release in
                            FeedarrReleaseCard(release: release, posterService: posterService, onSelectRelease: onSelectRelease)
                                .frame(width: sizeClass == .regular ? 168 : 144, alignment: .topLeading)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}
