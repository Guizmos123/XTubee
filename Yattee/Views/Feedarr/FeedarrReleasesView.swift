//
//  FeedarrReleasesView.swift
//  Yattee
//
//  Poster grid or list, retained between segments and paginated near its end.
//

import Foundation
import SwiftUI

struct FeedarrReleasesView: View {
    let model: FeedarrReleasesModel
    let posterService: FeedarrPosterService
    let isVisible: Bool
    var isManuallyRefreshing = false
    @Binding var isSearchPresented: Bool
    var onSelectRelease: ((FeedarrRelease) -> Void)? = nil
    @FocusState private var searchFocused: Bool
    @AppStorage("feedarrReleasesLayout") private var layout: VideoListLayout = .grid
    @AppStorage("feedarrReleasesRowStyle") private var rowStyle: VideoRowStyle = .regular
    @AppStorage("feedarrReleasesGridColumns") private var gridColumns = 2
    @AppStorage("feedarrReleasesShowsInformation") private var showsInformation = true
    @State private var viewWidth: CGFloat = 0

    private var columns: [GridItem] {
        if layout == .list { return makeGridColumns(count: 1) }
        #if os(iOS)
        let maximum = UIDevice.current.userInterfaceIdiom == .pad ? max(2, maxGridColumns(forWidth: viewWidth)) : 4
        #else
        let maximum = max(2, maxGridColumns(forWidth: viewWidth))
        #endif
        return makeGridColumns(count: min(max(2, gridColumns), maximum)).map { column in
            var column = column
            if !showsInformation { column.spacing = 6 }
            return column
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible && isSearchPresented {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(AppLocalization.string("feedarr.releases.search.placeholder"),
                                  text: Binding(get: { model.searchText }, set: { model.updateSearchText($0) }))
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .accessibilityIdentifier("feedarr.releases.searchField")
                            .task { searchFocused = true }
                        if !model.searchText.isEmpty {
                            Button { model.updateSearchText("") } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(AppLocalization.string("feedarr.releases.search.clear"))
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    Button(AppLocalization.string("common.cancel")) {
                        searchFocused = false
                        isSearchPresented = false
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(spacing: 20) {
                    if !isManuallyRefreshing && (model.isLoadingInitial || model.isDebouncing) && model.items.isEmpty {
                        ProgressView(AppLocalization.string("feedarr.releases.loading"))
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if model.isEmpty && model.failure == nil {
                        if let query = model.query {
                            ContentUnavailableView.search(text: query)
                        } else {
                            ContentUnavailableView(AppLocalization.string("feedarr.releases.empty"), systemImage: "rectangle.stack")
                        }
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: layout == .grid ? (showsInformation ? 24 : 6) : 12) {
                        ForEach(model.items) { release in
                            Group {
                                if layout == .grid {
                                    FeedarrReleaseCard(release: release, posterService: posterService, onSelectRelease: onSelectRelease, showsInformation: showsInformation)
                                } else {
                                    FeedarrReleaseRow(release: release, posterService: posterService, style: rowStyle, onSelectRelease: onSelectRelease)
                                }
                            }
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
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
        .onAppear { model.setVisible(isVisible) }
        .onChange(of: isSearchPresented) { if !isSearchPresented { searchFocused = false } }
        .onChange(of: isVisible) {
            if !isVisible { searchFocused = false; isSearchPresented = false }
            model.setVisible(isVisible)
        }
        .onDisappear { searchFocused = false; isSearchPresented = false; model.setVisible(false) }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let failure = model.failure {
                Label(failure.message, systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(AppLocalization.string("feedarr.retry")) { model.retry() }
                    .buttonStyle(.bordered)
            } else if model.isLoadingNextPage && !isManuallyRefreshing {
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
