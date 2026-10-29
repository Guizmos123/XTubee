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
    var selectedRelease: FeedarrReleaseSelection?

    func selectRelease(_ release: FeedarrRelease, configurationRevision: UUID) {
        selectedRelease = FeedarrReleaseSelection(release: release, configurationRevision: configurationRevision)
    }

    func invalidateSelection(configurationRevision: UUID?) {
        guard selectedRelease?.configurationRevision != configurationRevision else { return }
        selectedRelease = nil
    }
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
    @State private var showingReleasesOptions = false
    @Namespace private var optionsSheetTransition
    @State private var topModel: FeedarrTopModel?
    @State private var releasesModel: FeedarrReleasesModel?
    @State private var posterService: FeedarrPosterService?
    @State private var trackerService: FeedarrTrackerService?
    @State private var isReleasesSearchPresented = false
    @AppStorage("feedarrReleasesLayout") private var releasesLayout: VideoListLayout = .grid
    @AppStorage("feedarrReleasesRowStyle") private var releasesRowStyle: VideoRowStyle = .regular
    @AppStorage("feedarrReleasesGridColumns") private var releasesGridColumns = 2
    @AppStorage("feedarrReleasesShowsInformation") private var releasesShowsInformation = true
    @State private var releasesViewWidth: CGFloat = 0
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshID: UUID?
    @State private var syncCapsuleState: SyncStatusCapsule.State?
    @State private var syncCapsuleDismissTask: Task<Void, Never>?


    private var manager: FeedarrSourcesManager? { appEnvironment?.feedarrSourcesManager }

    private var presentation: FeedarrRootPresentation {
        FeedarrRootPresentation(source: manager?.source, loadError: manager?.loadError)
    }

    private var releaseSelectionAction: (FeedarrRelease) -> Void {
        // Capture the revision of the catalogue currently rendered, not the one
        // that happens to be active when a delayed tap callback executes.
        let revision = manager?.configurationRevision
        return { release in
            guard let revision else { return }
            let selection = FeedarrReleaseSelection(release: release, configurationRevision: revision)
            guard selection.isCurrent(sources: manager) else { return }
            navigation.selectRelease(release, configurationRevision: revision)
        }
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
                                               isVisible: navigation.selectedPage == .top,
                                               isManuallyRefreshing: refreshID != nil && navigation.selectedPage == .top,
                                               onSelectRelease: releaseSelectionAction)
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
                                                    isManuallyRefreshing: refreshID != nil && navigation.selectedPage == .releases,
                                                    isSearchPresented: $isReleasesSearchPresented,
                                                    onSelectRelease: releaseSelectionAction)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { releasesViewWidth = $0 }
        .reactiveNavigationTitle(AppLocalization.string("feedarr.title"))
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if presentation == .configured, navigation.selectedPage == .top, let topModel {
                ToolbarItemGroup(placement: .primaryAction) {
                    refreshButton
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
                    refreshButton
                    Button {
                        showingReleasesOptions = true
                    } label: {
                        Label(AppLocalization.string("feedarr.releases.filters"), systemImage: "slider.horizontal.3")
                            .foregroundStyle(.blue)
                    }
                    .accessibilityIdentifier("feedarr.releases.filters")
                    .liquidGlassTransitionSource(id: "feedarrReleasesOptions", in: optionsSheetTransition)
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
            posterService = appEnvironment.feedarrPosterService
            let trackers = appEnvironment.feedarrTrackerService
            trackerService = trackers
            await trackers.loadIfNeeded()
        }
        .task(id: manager?.configurationRevision) { await trackerService?.loadIfNeeded() }
        .sheet(isPresented: $showingReleasesOptions) {
            if let releasesModel {
                NavigationStack {
                    releasesOptionsForm(releasesModel)
                        .reactiveNavigationTitle(AppLocalization.string("feedarr.releases.options.title"))
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.height(520), .large])
                .presentationDragIndicator(.visible)
                .liquidGlassSheetContent(sourceID: "feedarrReleasesOptions", in: optionsSheetTransition)
            }
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
        .sheet(item: $navigation.selectedRelease) { selection in
            if let posterService {
                FeedarrReleaseDetailSheet(selection: selection, posterService: posterService, trackerService: trackerService)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: manager?.configurationRevision) {
            cancelManualRefresh()
            navigation.invalidateSelection(configurationRevision: manager?.configurationRevision)
        }
        .onChange(of: navigation.selectedPage) { cancelManualRefresh() }
        .onDisappear { cancelManualRefresh() }
        .overlay(alignment: .top) {
            if let syncCapsuleState {
                SyncStatusCapsule(state: syncCapsuleState, accentColor: .accentColor)
                    .transition(.move(edge: .top).combined(with: .opacity)
                        .combined(with: .scale(scale: 0.94, anchor: .top)))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: manager?.source?.id) {
            navigation.selectedPage = .top
            navigation.selectedRelease = nil
        }
    }

    private var refreshButton: some View {
        Button {
            startManualRefresh()
        } label: {
            if isActivePageLoading && refreshID == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isActivePageLoading || refreshID != nil)
        .accessibilityLabel(AppLocalization.string("common.refresh"))
        .accessibilityIdentifier("feedarr.refresh")
    }

    private var isActivePageLoading: Bool {
        navigation.selectedPage == .top ? topModel?.isLoading == true : releasesModel?.isLoading == true
    }

    private func startManualRefresh() {
        guard refreshID == nil, !isActivePageLoading,
              presentation == .configured, let revision = manager?.configurationRevision else { return }
        let id = UUID()
        let page = navigation.selectedPage
        refreshID = id
        presentSyncCapsule(.synchronizing(AppLocalization.string("feedarr.sync.synchronizing")))
        refreshTask = Task { @MainActor in
            defer {
                if refreshID == id {
                    refreshTask = nil
                    refreshID = nil
                }
            }
            let failureMessage: String?
            switch page {
            case .top:
                guard let topModel else { return }
                let sort = topModel.selectedSort
                await topModel.refresh()
                guard sort == topModel.selectedSort, !topModel.isLoading else {
                    if refreshID == id { dismissSyncCapsule() }
                    return
                }
                failureMessage = topModel.failure?.message
            case .releases:
                guard let releasesModel else { return }
                let filters = (releasesModel.query, releasesModel.selectedSort, releasesModel.selectedCategory)
                await releasesModel.refresh()
                guard filters == (releasesModel.query, releasesModel.selectedSort, releasesModel.selectedCategory),
                      !releasesModel.isLoadingInitial else {
                    if refreshID == id { dismissSyncCapsule() }
                    return
                }
                failureMessage = releasesModel.failure?.message
            }
            guard !Task.isCancelled, refreshID == id,
                  manager?.configurationRevision == revision, navigation.selectedPage == page else { return }
            if let failureMessage {
                presentSyncCapsule(.error(failureMessage), dismissAfter: .seconds(3))
            } else {
                presentSyncCapsule(.success(AppLocalization.string("feedarr.sync.success")), dismissAfter: .seconds(2))
            }
        }
    }

    private func presentSyncCapsule(_ state: SyncStatusCapsule.State, dismissAfter delay: Duration? = nil) {
        syncCapsuleDismissTask?.cancel()
        syncCapsuleDismissTask = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            syncCapsuleState = state
        }
        guard let delay else { return }
        syncCapsuleDismissTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, syncCapsuleState == state else { return }
            dismissSyncCapsule()
        }
    }

    private func dismissSyncCapsule() {
        syncCapsuleDismissTask?.cancel()
        syncCapsuleDismissTask = nil
        withAnimation(.easeOut(duration: 0.22)) { syncCapsuleState = nil }
    }

    private func cancelManualRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        dismissSyncCapsule()
    }

    private var maximumReleasesColumns: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? max(2, maxGridColumns(forWidth: releasesViewWidth)) : 4
    }

    private var effectiveReleasesColumns: Int {
        min(max(2, releasesGridColumns), maximumReleasesColumns)
    }

    private func releasesOptionsForm(_ model: FeedarrReleasesModel) -> some View {
        Form {
            Section {
                PlatformMenuPicker(AppLocalization.string("viewOptions.layout"), selection: $releasesLayout) {
                    ForEach(VideoListLayout.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                if releasesLayout == .grid {
                    Stepper(
                        "viewOptions.columns \(effectiveReleasesColumns)",
                        value: Binding(get: { effectiveReleasesColumns }, set: { releasesGridColumns = $0 }),
                        in: 2...maximumReleasesColumns
                    )
                    Toggle(AppLocalization.string("feedarr.releases.options.showInformation"), isOn: $releasesShowsInformation)
                } else {
                    PlatformMenuPicker(AppLocalization.string("viewOptions.rowSize"), selection: $releasesRowStyle) {
                        Text("viewOptions.rowSize.compact").tag(VideoRowStyle.compact)
                        Text("viewOptions.rowSize.regular").tag(VideoRowStyle.regular)
                        Text("viewOptions.rowSize.large").tag(VideoRowStyle.large)
                    }
                }
            }
            Section {
                PlatformMenuPicker(AppLocalization.string("feedarr.releases.filters.sort"), selection: Binding(
                    get: { model.selectedSort }, set: { model.selectSort($0) }
                )) {
                    ForEach(FeedarrReleasesSort.allCases) { sort in
                        Text(sort.localizedTitle).tag(sort)
                    }
                }
                PlatformMenuPicker(AppLocalization.string("feedarr.releases.filters.category"), selection: Binding(
                    get: { model.selectedCategory }, set: { model.selectCategory($0) }
                )) {
                    Text(AppLocalization.string("feedarr.releases.filters.all"))
                        .tag(Optional<FeedarrTopCategory>.none)
                    ForEach(FeedarrTopCategory.railOrder) { category in
                        Text(category.localizedTitle).tag(Optional(category))
                    }
                }
            }
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
