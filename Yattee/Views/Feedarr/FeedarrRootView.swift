//
//  FeedarrRootView.swift
//  Yattee
//
//  iOS Feedarr navigation shell with retained Top state between segments.
//

import Foundation
import SwiftUI

#if os(iOS)
enum FeedarrPage: String, CaseIterable, Identifiable, Sendable {
    case top
    case releases

    var id: Self { self }

    var title: String {
        switch self {
        case .top: AppLocalization.string("feedarr.page.top")
        case .releases: AppLocalization.string("feedarr.page.releases")
        }
    }

    var systemImage: String {
        self == .top ? "flame" : "square.grid.2x2"
    }
}

@MainActor
@Observable
final class FeedarrNavigationState {
    var selectedPage: FeedarrPage = .top
}

enum FeedarrRootPresentation: Equatable, Sendable {
    case unconfigured
    case configured
    case configurationError(FeedarrSourcesManagerError)

    init(source: FeedarrSource?, loadError: FeedarrSourcesManagerError?) {
        if let loadError {
            self = .configurationError(loadError)
        } else {
            self = source == nil ? .unconfigured : .configured
        }
    }
}

struct FeedarrRootView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var navigation = FeedarrNavigationState()
    @State private var showingConfiguration = false
    @State private var topModel: FeedarrTopModel?
    @State private var releasesModel: FeedarrReleasesModel?
    @State private var posterService: FeedarrPosterService?
    @State private var isReleasesSearchPresented = false

    private var manager: FeedarrSourcesManager? { appEnvironment?.feedarrSourcesManager }

    private var presentation: FeedarrRootPresentation {
        FeedarrRootPresentation(source: manager?.source, loadError: manager?.loadError)
    }

    var body: some View {
        Group {
            switch presentation {
            case .unconfigured:
                ContentUnavailableView {
                    Label(AppLocalization.string("feedarr.empty.title"), systemImage: "rectangle.stack")
                } description: {
                    Text(AppLocalization.string("feedarr.empty.description"))
                } actions: {
                    Button(AppLocalization.string("sources.feedarr.addTitle")) {
                        showingConfiguration = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appEnvironment == nil)
                    .accessibilityIdentifier("feedarr.configureButton")
                }
            case .configurationError(let error):
                configurationError(error)
            case .configured:
                VStack(spacing: 0) {
                    Picker(AppLocalization.string("feedarr.title"), selection: $navigation.selectedPage) {
                        ForEach(FeedarrPage.allCases) { page in
                            Text(page.title).tag(page)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("feedarr.pagePicker")

                    // Both page identities stay mounted when the segment changes.
                    ZStack {
                        Group {
                            if let topModel, let posterService {
                                FeedarrTopView(model: topModel, posterService: posterService,
                                               isVisible: navigation.selectedPage == .top)
                            } else {
                                ProgressView()
                            }
                        }
                            .opacity(navigation.selectedPage == .top ? 1 : 0)
                            .allowsHitTesting(navigation.selectedPage == .top)
                            .accessibilityHidden(navigation.selectedPage != .top)
                        Group {
                            if let releasesModel, let posterService {
                                FeedarrReleasesView(model: releasesModel, posterService: posterService,
                                                    isVisible: navigation.selectedPage == .releases,
                                                    isSearchPresented: $isReleasesSearchPresented)
                            } else {
                                ProgressView()
                            }
                        }
                            .opacity(navigation.selectedPage == .releases ? 1 : 0)
                            .allowsHitTesting(navigation.selectedPage == .releases)
                            .accessibilityHidden(navigation.selectedPage != .releases)
                    }
                }
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("feedarr.title"))
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if presentation == .configured, navigation.selectedPage == .top, let topModel {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker(AppLocalization.string("feedarr.top.sort"), selection: Binding(
                            get: { topModel.selectedSort }, set: { topModel.selectSort($0) }
                        )) {
                            ForEach([FeedarrTopSort.score, .recent, .seeders, .grabs]) { sort in
                                Text(sort.localizedTitle).tag(sort)
                            }
                        }
                    } label: {
                        Label(AppLocalization.string("feedarr.top.sort"), systemImage: "slider.horizontal.3")
                    }
                }
            } else if presentation == .configured, navigation.selectedPage == .releases, let releasesModel {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isReleasesSearchPresented = true
                    } label: {
                        Label(AppLocalization.string("feedarr.releases.search.placeholder"),
                              systemImage: releasesModel.query == nil ? "magnifyingglass" : "text.magnifyingglass")
                    }
                    .accessibilityIdentifier("feedarr.releases.search")
                    Menu {
                        Menu(AppLocalization.string("feedarr.releases.filters.sort")) {
                            Picker(AppLocalization.string("feedarr.releases.filters.sort"), selection: Binding(
                                get: { releasesModel.selectedSort }, set: { releasesModel.selectSort($0) }
                            )) {
                                ForEach(FeedarrReleasesSort.allCases) { sort in
                                    Text(sort.localizedTitle).tag(sort)
                                }
                            }
                            .pickerStyle(.inline)
                        }
                        Menu(AppLocalization.string("feedarr.releases.filters.category")) {
                            Picker(AppLocalization.string("feedarr.releases.filters.category"), selection: Binding(
                                get: { releasesModel.selectedCategory }, set: { releasesModel.selectCategory($0) }
                            )) {
                                Text(AppLocalization.string("feedarr.releases.filters.all"))
                                    .tag(Optional<FeedarrTopCategory>.none)
                                ForEach(FeedarrTopCategory.railOrder) { category in
                                    Text(category.localizedTitle).tag(Optional(category))
                                }
                            }
                            .pickerStyle(.inline)
                        }
                    } label: {
                        Label(AppLocalization.string("feedarr.releases.filters"), systemImage: "slider.horizontal.3")
                            .foregroundStyle(releasesModel.hasActiveFilters ? Color.accentColor : Color.primary)
                    }
                    .accessibilityIdentifier("feedarr.releases.filters")
                }
            }
        }
        .task {
            guard topModel == nil, let appEnvironment else { return }
            let sources = appEnvironment.feedarrSourcesManager
            let credentials = appEnvironment.feedarrCredentialsStore
            let api = FeedarrAPIClient(sources: sources, credentialsStore: credentials)
            topModel = FeedarrTopModel(sources: sources) { sort in
                try await api.top(hours: 24, take: 5, perCategoryTake: 5, sort: sort)
            }
            releasesModel = FeedarrReleasesModel(sources: sources) { query, cursor, sort, category in
                try await api.releases(limit: 50, sort: sort, q: query, unifiedCategory: category?.rawValue, cursor: cursor)
            }
            posterService = FeedarrPosterService(sources: sources, credentialsStore: credentials)
        }
        .sheet(isPresented: $showingConfiguration, onDismiss: reloadConfiguration) {
            if let appEnvironment {
                AddFeedarrSourceView(
                    manager: appEnvironment.feedarrSourcesManager,
                    validator: appEnvironment.feedarrConnectionValidator,
                    credentialsStore: appEnvironment.feedarrCredentialsStore,
                    editingSource: appEnvironment.feedarrSourcesManager.source
                )
            }
        }
        .onChange(of: manager?.source?.id) {
            navigation.selectedPage = .top
        }
    }

    private func configurationError(_ error: FeedarrSourcesManagerError) -> some View {
        ContentUnavailableView {
            Label(AppLocalization.string("feedarr.configurationError.title"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(error == .persistenceFailure
                 ? AppLocalization.string("feedarr.configurationError.description")
                 : AddFeedarrSourceModel.message(for: error))
        } actions: {
            Button(AppLocalization.string("feedarr.retry")) { reloadConfiguration() }
            if manager?.source != nil {
                Button(AppLocalization.string("sources.feedarr.editTitle")) {
                    showingConfiguration = true
                }
            }
        }
    }

    private func reloadConfiguration() {
        // reload publishes loadError and preserves the last metadata on failure.
        // This is a local metadata/Keychain read, never a connection test.
        try? manager?.reload()
    }
}
#endif
