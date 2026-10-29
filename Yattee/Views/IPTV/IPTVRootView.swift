//
//  IPTVRootView.swift
//  Yattee
//
//  Displays the cached Xtream Live catalog for the active IPTV source.
//

import SwiftUI

typealias IPTVStreamSelectionAction = (
    UUID,
    IPTVLiveChannelGroup,
    IPTVLiveVariantPresentation
) -> Void

private enum IPTVRootSection: String, CaseIterable, Identifiable {
    case favorites
    case channels
    case categories

    var id: Self { self }

    var title: String {
        switch self {
        case .favorites: AppLocalization.string("iptv.favorites.title")
        case .channels: AppLocalization.string("iptv.navigation.channels")
        case .categories: AppLocalization.string("iptv.navigation.categories")
        }
    }
}

private struct IPTVSearchConfiguration {
    let text: Binding<String>
    let isPresented: Binding<Bool>
    let suggestions: AnyView
}

private extension View {
    @ViewBuilder
    func iptvSearchable(_ configuration: IPTVSearchConfiguration?) -> some View {
        if let configuration, configuration.isPresented.wrappedValue {
            #if os(iOS)
            searchable(
                text: configuration.text,
                isPresented: configuration.isPresented,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: AppLocalization.string("iptv.search.prompt")
            )
            .searchSuggestions {
                configuration.suggestions
            }
            #elseif !os(tvOS)
            searchable(
                text: configuration.text,
                isPresented: configuration.isPresented,
                prompt: AppLocalization.string("iptv.search.prompt")
            )
            .searchSuggestions {
                configuration.suggestions
            }
            #else
            self
            #endif
        } else {
            self
        }
    }

}

struct IPTVRootView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    @State private var catalogService: IPTVLiveCatalogSyncService?
    @State private var epgService: IPTVEPGSyncService?
    @State private var channelGroups: [IPTVLiveChannelGroup] = []
    @State private var groupedCatalogKey: IPTVLiveChannelGroupingCache.Key?
    @State private var channelGroupingCache = IPTVLiveChannelGroupingCache()
    @State private var loadedSourceID: UUID?
    @State private var loadedEPGSourceID: UUID?
    @State private var epgReferenceDate = Date()
    @State private var selectedSection: IPTVRootSection = .categories
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var searchVariantSelection: IPTVVariantSelectionContext?
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackRequestID: UUID?
    @State private var playbackErrorMessage: String?
    @State private var isPreparingPlayback = false
    @Namespace private var optionsSheetTransition
    @State private var showingIPTVOptions = false
    @State private var manualCatalogRefreshTask: Task<Void, Never>?
    @State private var manualCatalogRefreshID: UUID?
    @State private var automaticSynchronizationID: UUID?
    @State private var automaticSynchronizationDidStart = false
    @State private var syncCapsuleState: SyncStatusCapsule.State?
    @State private var syncCapsuleDismissTask: Task<Void, Never>?
    @AppStorage("iptv.hiddenCategories") private var hiddenCategoriesJSON = ""
    @AppStorage("iptv.navigation.startPage") private var startPageRawValue = IPTVRootSection.categories.rawValue
    @AppStorage("iptv.navigation.showFavorites") private var showsFavoritesSection = true
    @AppStorage("iptv.navigation.showChannels") private var showsChannelsSection = true
    @AppStorage("iptv.navigation.showCategories") private var showsCategoriesSection = true
    private let injectedStreamSelectionAction: IPTVStreamSelectionAction?

    init(
        onStreamSelected: IPTVStreamSelectionAction? = nil
    ) {
        injectedStreamSelectionAction = onStreamSelected
    }

    private var sourcesManager: IPTVSourcesManager? {
        appEnvironment?.iptvSourcesManager
    }

    private var favoritesManager: IPTVLiveFavoritesManager? {
        appEnvironment?.iptvLiveFavoritesManager
    }

    private var activeSource: IPTVSource? {
        sourcesManager?.activeSource
    }

    private var catalogState: IPTVLiveCatalogState {
        guard let sourceID = activeSource?.id else { return .empty }
        return catalogService?.state(for: sourceID) ?? .empty
    }

    private var epgState: IPTVEPGState {
        guard let sourceID = activeSource?.id else { return .empty }
        return epgService?.state(for: sourceID) ?? .empty
    }

    private var iptvSearchConfiguration: IPTVSearchConfiguration {
        IPTVSearchConfiguration(
            text: $searchText,
            isPresented: $isSearchPresented,
            suggestions: AnyView(globalSearchSuggestions)
        )
    }

    var body: some View {
        Group {
            if sourcesManager?.sources.isEmpty ?? true {
                noSourceView
            } else if let activeSource {
                catalogContent(for: activeSource)
            } else {
                noActiveSourceView
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("tabs.iptv"))
        #if !os(tvOS)
        .toolbarTitleDisplayMode(.inlineLarge)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: viewOptionsPlacement) {
                #if !os(tvOS)
                Button {
                    isSearchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(catalogState.catalog == nil || isSearchPresented)
                .accessibilityLabel(AppLocalization.string("iptv.search.prompt"))
                #endif

                Button {
                    startManualCatalogRefresh()
                } label: {
                    if isCatalogLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(
                    activeSource == nil
                        || catalogService == nil
                        || epgService == nil
                        || isCatalogLoading
                )
                .accessibilityLabel(AppLocalization.string("iptv.catalog.refresh"))

                Button {
                    showingIPTVOptions = true
                } label: {
                    Label(
                        AppLocalization.string("viewOptions.title"),
                        systemImage: "slider.horizontal.3"
                    )
                }
                .liquidGlassTransitionSource(id: "iptvOptions", in: optionsSheetTransition)
            }
        }
        .sheet(isPresented: $showingIPTVOptions) {
            NavigationStack {
                IPTVOptionsView(
                    startPageRawValue: $startPageRawValue,
                    showsFavorites: $showsFavoritesSection,
                    showsChannels: $showsChannelsSection,
                    showsCategories: $showsCategoriesSection,
                    sourceID: activeSource?.id,
                    categories: catalogState.catalog?.categories ?? [],
                    channelGroups: channelGroups,
                    favoritesManager: favoritesManager,
                    hiddenCategoriesJSON: $hiddenCategoriesJSON
                )
            }
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
            .liquidGlassSheetContent(sourceID: "iptvOptions", in: optionsSheetTransition)
        }
        .sheet(item: $searchVariantSelection) { context in
            IPTVStreamVariantPickerSheet(
                presentation: context.presentation,
                select: { variant in
                    streamSelectionAction(context.group.sourceID, context.group, variant)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: activeSource?.cacheIdentity) {
            await loadCatalogForActiveSource()
        }
        .task(id: catalogGroupingKey) {
            await updateChannelGroups()
        }
        .task(id: activeSource?.id) {
            epgReferenceDate = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                epgReferenceDate = Date()
            }
        }
        .onChange(of: activeSource?.cacheIdentity) {
            cancelPlaybackPreparation()
            cancelManualCatalogRefresh()
            cancelAutomaticSynchronizationPresentation()
            searchText = ""
            isSearchPresented = false
            channelGroups = []
            groupedCatalogKey = nil
            searchVariantSelection = nil
        }
        .onAppear {
            repairNavigationSelection(useStartPage: true)
        }
        .onChange(of: visibleSections) {
            repairNavigationSelection(useStartPage: false)
        }
        .onChange(of: startPageRawValue) {
            repairNavigationSelection(useStartPage: true)
        }
        .onDisappear {
            cancelPlaybackPreparation()
            cancelManualCatalogRefresh()
            cancelAutomaticSynchronizationPresentation()
        }
        .overlay {
            ZStack {
                VStack {
                    if let syncCapsuleState {
                        SyncStatusCapsule(
                            state: syncCapsuleState,
                            accentColor: .accentColor
                        )
                        .transition(
                            .move(edge: .top)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.94, anchor: .top))
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if isPreparingPlayback {
                    ProgressView()
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .alert(
            AppLocalization.string("common.error"),
            isPresented: playbackErrorBinding
        ) {
            Button(AppLocalization.string("common.ok"), role: .cancel) {}
        } message: {
            Text(playbackErrorMessage ?? AppLocalization.string("iptv.catalog.error.description"))
        }
    }

    @ViewBuilder
    private func catalogContent(for source: IPTVSource) -> some View {
        if let catalog = catalogState.catalog {
            if isSearchPresented {
                List {
                    globalSearchSuggestions
                }
                .iptvSearchable(iptvSearchConfiguration)
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $selectedSection) {
                        ForEach(visibleSections) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    #if os(macOS)
                    Color(nsColor: .windowBackgroundColor)
                        .frame(height: 12)
                    #else
                    Color(uiColor: .systemBackground)
                        .frame(height: 12)
                    #endif

                    selectedCatalogSection(catalog: catalog, source: source)
                }
            }
        } else if catalogState.loadingState == .loading || catalogService == nil {
            ContentUnavailableView {
                Label(AppLocalization.string("iptv.catalog.loading"), systemImage: "play.tv")
            } description: {
                ProgressView()
            }
        } else {
            ContentUnavailableView {
                Label(AppLocalization.string("iptv.catalog.error.title"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(AppLocalization.string("iptv.catalog.error.description"))
            } actions: {
                Button(AppLocalization.string("common.retry")) {
                    startManualCatalogRefresh()
                }
                .buttonStyle(.borderedProminent)
                sourcesLink
            }
        }
    }

    @ViewBuilder
    private func selectedCatalogSection(catalog: IPTVLiveCatalog, source: IPTVSource) -> some View {
        switch selectedSection {
        case .favorites:
            channelsContent(sourceID: source.id, mode: .favorites)
        case .channels:
            channelsContent(sourceID: source.id, mode: .all)
        case .categories:
            categoriesContent(catalog: catalog, source: source)
        }
    }

    @ViewBuilder
    private func channelsContent(sourceID: UUID, mode: IPTVChannelsMode) -> some View {
        if let favoritesManager {
            IPTVChannelsView(
                sourceID: sourceID,
                mode: mode,
                groups: groupedCatalogKey == catalogGroupingKey ? channelGroups : [],
                favoritesManager: favoritesManager,
                onStreamSelected: streamSelectionAction,
                showsNavigationChrome: false,
                searchConfiguration: iptvSearchConfiguration,
                epgCatalog: epgState.catalog,
                epgReferenceDate: epgReferenceDate
            )
        }
    }

    @ViewBuilder
    private func categoriesContent(catalog: IPTVLiveCatalog, source: IPTVSource) -> some View {
        if catalog.categories.isEmpty {
            ScrollView {
                emptyCategoriesView
                    .frame(maxWidth: .infinity, minHeight: 360)
            }
            .iptvSearchable(iptvSearchConfiguration)
        } else {
            let orderedCategories = hiddenCategoriesPreferences.ordered(
                catalog.categories,
                sourceID: source.id
            )
            let visibleCategories = orderedCategories.filter {
                !isCategoryHidden($0.categoryID, sourceID: source.id)
            }
            List {
                catalogStatusSections

                Section(source.name) {
                    if visibleCategories.isEmpty {
                        Label(
                            AppLocalization.string("iptv.categories.allHidden"),
                            systemImage: "eye.slash"
                        )
                        .foregroundStyle(.secondary)
                    }

                    ForEach(visibleCategories, id: \.categoryID) { category in
                        NavigationLink {
                            if let favoritesManager {
                                IPTVChannelsView(
                                    sourceID: source.id,
                                    mode: .category(category),
                                    groups: groupedCatalogKey == catalogGroupingKey ? channelGroups : [],
                                    favoritesManager: favoritesManager,
                                    onStreamSelected: streamSelectionAction,
                                    epgCatalog: epgState.catalog,
                                    epgReferenceDate: epgReferenceDate
                                )
                            }
                        } label: {
                            Label(category.name, systemImage: "rectangle.stack")
                        }
                        .contextMenu {
                            Button {
                                setCategoryHidden(
                                    true,
                                    categoryID: category.categoryID,
                                    sourceID: source.id
                                )
                            } label: {
                                Label(
                                    AppLocalization.string("iptv.categories.hide"),
                                    systemImage: "eye.slash"
                                )
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                setCategoryHidden(
                                    true,
                                    categoryID: category.categoryID,
                                    sourceID: source.id
                                )
                            } label: {
                                Label(
                                    AppLocalization.string("iptv.categories.hide"),
                                    systemImage: "eye.slash"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                }

            }
            .iptvSearchable(iptvSearchConfiguration)
        }
    }

    @ViewBuilder
    private var catalogStatusSections: some View {
        if catalogState.lastError != nil {
            Section {
                Label(
                    AppLocalization.string("iptv.catalog.cachedWarning"),
                    systemImage: "wifi.slash"
                )
                .foregroundStyle(.orange)
            }
        }

        if catalogState.loadingState == .refreshing {
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalization.string("iptv.catalog.refreshing"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchCategories: [XtreamLiveCategory] {
        guard !normalizedSearchText.isEmpty,
              let catalog = catalogState.catalog else {
            return []
        }
        return catalog.categories.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedSearchText)
        }
    }

    private var searchChannelGroups: [IPTVLiveChannelGroup] {
        guard !normalizedSearchText.isEmpty,
              groupedCatalogKey == catalogGroupingKey else {
            return []
        }
        return channelGroups.filter {
            !$0.isDecorativeSeparator
                && $0.displayName.localizedCaseInsensitiveContains(normalizedSearchText)
        }
    }

    @ViewBuilder
    private var globalSearchSuggestions: some View {
        if !normalizedSearchText.isEmpty,
           let source = activeSource,
           let favoritesManager {
            if !searchCategories.isEmpty {
                Section(AppLocalization.string("iptv.navigation.categories")) {
                    ForEach(searchCategories, id: \.categoryID) { category in
                        NavigationLink {
                            IPTVChannelsView(
                                sourceID: source.id,
                                mode: .category(category),
                                groups: groupedCatalogKey == catalogGroupingKey ? channelGroups : [],
                                favoritesManager: favoritesManager,
                                onStreamSelected: streamSelectionAction,
                                epgCatalog: epgState.catalog,
                                epgReferenceDate: epgReferenceDate
                            )
                        } label: {
                            Label(category.name, systemImage: "rectangle.stack")
                        }
                    }
                }
            }

            if !searchChannelGroups.isEmpty {
                Section(AppLocalization.string("iptv.navigation.channels")) {
                    ForEach(searchChannelGroups) { group in
                        ZStack(alignment: .trailing) {
                            Button {
                                selectSearchResult(group)
                            } label: {
                                HStack(spacing: 10) {
                                    IPTVChannelLogo(
                                        url: group.variants.lazy.compactMap(\.stream.streamIconURL).first
                                    )
                                    .frame(width: 48, height: 27)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.displayName)
                                            .foregroundStyle(.primary)
                                            .padding(.trailing, 32)
                                        if let program = programPresentation(for: group) {
                                            IPTVCurrentProgramCompactView(program: program)
                                        }
                                        if let categoryName = categoryName(for: group) {
                                            Text(categoryName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            Button {
                                toggleSearchFavorite(group)
                            } label: {
                                Image(
                                    systemName: favoritesManager.isFavorite(group)
                                        ? "star.fill"
                                        : "star"
                                )
                                .foregroundStyle(
                                    favoritesManager.isFavorite(group)
                                        ? Color.yellow
                                        : Color.secondary
                                )
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                AppLocalization.string(
                                    favoritesManager.isFavorite(group)
                                        ? "iptv.favorites.remove"
                                        : "iptv.favorites.add"
                                )
                            )
                        }
                        .listRowInsets(
                            EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
                        )
                    }
                }
            }

            if searchCategories.isEmpty && searchChannelGroups.isEmpty {
                Text(AppLocalization.string("iptv.search.noResults"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryName(for group: IPTVLiveChannelGroup) -> String? {
        guard let categoryID = group.categoryID else { return nil }
        return catalogState.catalog?.categories.first {
            $0.categoryID == categoryID
        }?.name
    }

    private func programPresentation(
        for group: IPTVLiveChannelGroup
    ) -> IPTVCurrentProgramPresentation? {
        guard let catalog = epgState.catalog else { return nil }
        return IPTVCurrentProgramPresentation(
            nowAndNext: IPTVChannelEPGAssociator(catalog: catalog)
                .nowAndNext(for: group, at: epgReferenceDate),
            referenceDate: epgReferenceDate
        )
    }

    private func selectSearchResult(_ group: IPTVLiveChannelGroup) {
        let presentation = IPTVLiveChannelPresentation(group: group)
        switch presentation.selectionMode {
        case .direct(let variantID):
            guard let variant = presentation.variants.first(where: { $0.id == variantID }) else {
                return
            }
            searchText = ""
            streamSelectionAction(group.sourceID, group, variant)
        case .requiresExplicitChoice:
            searchText = ""
            searchVariantSelection = IPTVVariantSelectionContext(
                group: group,
                presentation: presentation
            )
        }
    }

    private func toggleSearchFavorite(_ group: IPTVLiveChannelGroup) {
        do {
            try favoritesManager?.toggleFavorite(group)
        } catch {
            playbackErrorMessage = AppLocalization.string("iptv.favorites.error")
        }
    }

    private var viewOptionsPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .primaryAction
        #endif
    }

    private var visibleSections: [IPTVRootSection] {
        IPTVRootSection.allCases.filter { section in
            switch section {
            case .favorites: showsFavoritesSection
            case .channels: showsChannelsSection
            case .categories: showsCategoriesSection
            }
        }
    }

    @MainActor
    private func repairNavigationSelection(useStartPage: Bool) {
        if visibleSections.isEmpty {
            showsFavoritesSection = true
        }

        let availableSections = visibleSections
        guard let firstVisibleSection = availableSections.first else { return }
        let preferredSection = IPTVRootSection(rawValue: startPageRawValue)

        if let preferredSection {
            if !availableSections.contains(preferredSection) {
                startPageRawValue = firstVisibleSection.rawValue
            }
        } else {
            startPageRawValue = firstVisibleSection.rawValue
        }

        if useStartPage,
           let startSection = IPTVRootSection(rawValue: startPageRawValue),
           availableSections.contains(startSection) {
            selectedSection = startSection
        } else if !availableSections.contains(selectedSection) {
            selectedSection = firstVisibleSection
        }
    }

    private var noSourceView: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("iptv.empty.title"), systemImage: "play.tv")
        } description: {
            Text(AppLocalization.string("iptv.empty.description"))
        } actions: {
            sourcesLink
        }
    }

    private var noActiveSourceView: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("iptv.noActiveSource.title"), systemImage: "play.tv")
        } description: {
            Text(AppLocalization.string("iptv.noActiveSource.description"))
        } actions: {
            sourcesLink
        }
    }

    private var emptyCategoriesView: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("iptv.categories.empty.title"), systemImage: "rectangle.stack")
        } description: {
            Text(AppLocalization.string("iptv.categories.empty.description"))
        }
    }

    private var sourcesLink: some View {
        NavigationLink {
            SourcesListView()
        } label: {
            Label(AppLocalization.string("iptv.action.manageSources"), systemImage: "server.rack")
        }
        .buttonStyle(.borderedProminent)
    }

    @MainActor
    private func loadCatalogForActiveSource() async {
        guard let environment = appEnvironment,
              let source = environment.iptvSourcesManager.activeSource else {
            catalogService = nil
            epgService = nil
            loadedSourceID = nil
            loadedEPGSourceID = nil
            return
        }

        let service: IPTVLiveCatalogSyncService
        if let catalogService, loadedSourceID == source.id {
            service = catalogService
        } else {
            service = IPTVLiveCatalogSyncService(
                sourcesManager: environment.iptvSourcesManager,
                credentialsStore: environment.xtreamCredentialsStore,
                persistence: environment.iptvLiveCatalogPersistence
            )
            service.selectSource(source.id)
            await service.loadCachedCatalog(sourceID: source.id)
            guard !Task.isCancelled, activeSource?.cacheIdentity == source.cacheIdentity else { return }
            catalogService = service
            loadedSourceID = source.id
        }

        let guideService: IPTVEPGSyncService
        if let epgService, loadedEPGSourceID == source.id {
            guideService = epgService
        } else {
            guideService = IPTVEPGSyncService(
                sourcesManager: environment.iptvSourcesManager,
                credentialsStore: environment.xtreamCredentialsStore,
                persistence: environment.iptvEPGPersistence
            )
            guideService.selectSource(source.id)
            await guideService.loadCachedCatalog(sourceID: source.id)
            guard !Task.isCancelled, activeSource?.cacheIdentity == source.cacheIdentity else { return }
            epgService = guideService
            loadedEPGSourceID = source.id
        }

        let synchronizationID = UUID()
        automaticSynchronizationID = synchronizationID
        automaticSynchronizationDidStart = false
        defer {
            if automaticSynchronizationID == synchronizationID {
                automaticSynchronizationID = nil
                automaticSynchronizationDidStart = false
            }
        }

        let synchronizationStarted: @MainActor @Sendable () -> Void = {
            self.presentAutomaticSynchronization(
                synchronizationID: synchronizationID,
                sourceID: source.id
            )
        }
        async let catalogUpdate: Void = service.synchronizeIfNeeded(
            sourceID: source.id,
            onSynchronizationStarted: synchronizationStarted
        )
        async let guideUpdate: Void = guideService.synchronizeIfNeeded(
            sourceID: source.id,
            onSynchronizationStarted: synchronizationStarted
        )
        _ = await (catalogUpdate, guideUpdate)

        guard !Task.isCancelled,
              activeSource?.cacheIdentity == source.cacheIdentity,
              automaticSynchronizationID == synchronizationID,
              automaticSynchronizationDidStart else {
            return
        }

        presentSynchronizationResult(
            catalogSucceeded: service.state(for: source.id).lastError == nil,
            epgSucceeded: guideService.state(for: source.id).lastError == nil
        )
    }

    private var isCatalogLoading: Bool {
        manualCatalogRefreshTask != nil
            || catalogState.loadingState != .idle
            || epgState.loadingState != .idle
    }

    private var catalogGroupingKey: IPTVLiveChannelGroupingCache.Key? {
        guard let catalog = catalogState.catalog else { return nil }
        return IPTVLiveChannelGroupingCache.Key(
            sourceID: catalog.sourceID,
            catalogLastUpdated: catalog.lastUpdated,
            configurationRevision: catalog.configurationRevision
        )
    }

    @MainActor
    private func updateChannelGroups() async {
        guard let catalog = catalogState.catalog else {
            channelGroups = []
            groupedCatalogKey = nil
            return
        }

        let expectedKey = IPTVLiveChannelGroupingCache.Key(
            sourceID: catalog.sourceID,
            catalogLastUpdated: catalog.lastUpdated,
            configurationRevision: catalog.configurationRevision
        )
        guard let groups = await channelGroupingCache.groups(for: catalog),
              !Task.isCancelled,
              catalogGroupingKey == expectedKey,
              activeSource?.id == catalog.sourceID else {
            return
        }

        channelGroups = groups
        groupedCatalogKey = expectedKey
    }

    @MainActor
    private func startManualCatalogRefresh() {
        guard manualCatalogRefreshTask == nil,
              automaticSynchronizationID == nil,
              catalogState.loadingState == .idle,
              epgState.loadingState == .idle,
              let sourceID = activeSource?.id,
              let catalogService,
              let epgService else {
            return
        }

        let refreshID = UUID()
        manualCatalogRefreshID = refreshID
        presentSyncCapsule(
            .synchronizing(AppLocalization.string("iptv.catalog.sync.synchronizing"))
        )

        manualCatalogRefreshTask = Task { @MainActor in
            defer {
                if manualCatalogRefreshID == refreshID {
                    manualCatalogRefreshTask = nil
                    manualCatalogRefreshID = nil
                }
            }

            async let catalogRefresh: Void = catalogService.refresh(sourceID: sourceID)
            async let guideRefresh: Void = epgService.refresh(sourceID: sourceID)
            _ = await (catalogRefresh, guideRefresh)
            guard !Task.isCancelled,
                  activeSource?.id == sourceID,
                  manualCatalogRefreshID == refreshID else {
                return
            }

            presentSynchronizationResult(
                catalogSucceeded: catalogService.state(for: sourceID).lastError == nil,
                epgSucceeded: epgService.state(for: sourceID).lastError == nil
            )
        }
    }

    @MainActor
    private func presentAutomaticSynchronization(
        synchronizationID: UUID,
        sourceID: UUID
    ) {
        guard automaticSynchronizationID == synchronizationID,
              activeSource?.id == sourceID else {
            return
        }
        guard !automaticSynchronizationDidStart else { return }
        automaticSynchronizationDidStart = true
        presentSyncCapsule(
            .synchronizing(AppLocalization.string("iptv.catalog.sync.synchronizing"))
        )
    }

    @MainActor
    private func presentSynchronizationResult(
        catalogSucceeded: Bool,
        epgSucceeded: Bool
    ) {
        if catalogSucceeded, epgSucceeded {
            presentSyncCapsule(
                .success(AppLocalization.string("iptv.catalog.sync.success")),
                dismissAfter: .seconds(2)
            )
        } else {
            presentSyncCapsule(
                .error(AppLocalization.string("iptv.catalog.sync.error")),
                dismissAfter: .seconds(3)
            )
        }
    }

    @MainActor
    private func presentSyncCapsule(
        _ state: SyncStatusCapsule.State,
        dismissAfter delay: Duration? = nil
    ) {
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

    @MainActor
    private func dismissSyncCapsule() {
        syncCapsuleDismissTask?.cancel()
        syncCapsuleDismissTask = nil
        withAnimation(.easeOut(duration: 0.22)) {
            syncCapsuleState = nil
        }
    }

    @MainActor
    private func cancelManualCatalogRefresh() {
        manualCatalogRefreshTask?.cancel()
        manualCatalogRefreshTask = nil
        manualCatalogRefreshID = nil
        dismissSyncCapsule()
    }

    @MainActor
    private func cancelAutomaticSynchronizationPresentation() {
        automaticSynchronizationID = nil
        automaticSynchronizationDidStart = false
        dismissSyncCapsule()
    }

    private func isCategoryHidden(_ categoryID: String, sourceID: UUID) -> Bool {
        hiddenCategoriesPreferences.isHidden(categoryID, sourceID: sourceID)
    }

    private func setCategoryHidden(
        _ isHidden: Bool,
        categoryID: String,
        sourceID: UUID
    ) {
        var preferences = hiddenCategoriesPreferences
        preferences.setHidden(isHidden, categoryID: categoryID, sourceID: sourceID)
        hiddenCategoriesJSON = preferences.encoded
    }

    private var hiddenCategoriesPreferences: IPTVHiddenCategoriesPreferences {
        IPTVHiddenCategoriesPreferences.decode(hiddenCategoriesJSON)
    }

    private var streamSelectionAction: IPTVStreamSelectionAction {
        { sourceID, group, variant in
            if let injectedStreamSelectionAction {
                injectedStreamSelectionAction(sourceID, group, variant)
            } else {
                prepareAndOpenStream(sourceID: sourceID, group: group, variant: variant)
            }
        }
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(
            get: { playbackErrorMessage != nil },
            set: { if !$0 { playbackErrorMessage = nil } }
        )
    }

    @MainActor
    private func prepareAndOpenStream(
        sourceID: UUID,
        group: IPTVLiveChannelGroup,
        variant: IPTVLiveVariantPresentation
    ) {
        playbackTask?.cancel()
        let requestID = UUID()
        playbackRequestID = requestID
        playbackErrorMessage = nil
        isPreparingPlayback = true

        playbackTask = Task { @MainActor in
            defer {
                if playbackRequestID == requestID {
                    playbackTask = nil
                    playbackRequestID = nil
                    isPreparingPlayback = false
                }
            }

            do {
                guard let environment = appEnvironment else { return }
                guard let source = environment.iptvSourcesManager.sources.first(where: {
                    $0.id == sourceID
                }) else {
                    throw XtreamLivePlaybackPreparationError.sourceNotFound
                }
                guard let credentials = try environment.xtreamCredentialsStore.credentials(
                    for: sourceID
                ) else {
                    throw XtreamLivePlaybackPreparationError.credentialsMissing
                }

                let account = try await XtreamAccountValidator().validate(
                    serverURL: source.serverURL,
                    username: credentials.username,
                    password: credentials.password
                )
                try Task.checkCancellation()

                let preparation = try XtreamLivePlaybackService(
                    sourcesManager: environment.iptvSourcesManager,
                    credentialsStore: environment.xtreamCredentialsStore
                ).prepare(
                    sourceID: sourceID,
                    group: group,
                    variant: variant,
                    allowedOutputFormats: account.allowedOutputFormats
                )
                try Task.checkCancellation()

                guard preparation.playbackPolicy == .directMPV,
                      preparation.isPlaybackAllowed else {
                    return
                }
                environment.playerService.openVideo(
                    preparation.video,
                    stream: preparation.stream,
                    context: .iptv(
                        sourceID: sourceID,
                        presentation: playbackPresentation(
                            sourceName: source.name,
                            group: group
                        )
                    )
                )
            } catch is CancellationError {
                return
            } catch let error as XtreamAccountValidationError where error == .cancelled {
                return
            } catch let error as XtreamAccountValidationError {
                if playbackRequestID == requestID {
                    playbackErrorMessage = error.localizedDescription
                }
            } catch let error as XtreamLivePlaybackPreparationError {
                if playbackRequestID == requestID {
                    playbackErrorMessage = error.localizedDescription
                }
            } catch {
                if playbackRequestID == requestID {
                    playbackErrorMessage = AppLocalization.string("iptv.catalog.error.description")
                }
            }
        }
    }

    private func playbackPresentation(
        sourceName: String,
        group: IPTVLiveChannelGroup
    ) -> IPTVPlaybackPresentation {
        guard let catalog = epgState.catalog,
              let channelID = IPTVChannelEPGAssociator(catalog: catalog)
                .nowAndNext(for: group, at: Date())?.channelID else {
            return IPTVPlaybackPresentation(
                sourceName: sourceName,
                group: group,
                epgCatalog: nil
            )
        }

        let channel = catalog.channel(for: channelID)
        let focusedCatalog = EPGCatalog(
            channelsByID: channel.map { [channelID: $0] } ?? [:],
            programsByChannelID: [channelID: catalog.programs(for: channelID)]
        )
        return IPTVPlaybackPresentation(
            sourceName: sourceName,
            group: group,
            epgCatalog: focusedCatalog
        )
    }

    @MainActor
    private func cancelPlaybackPreparation() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackRequestID = nil
        isPreparingPlayback = false
    }

}

private struct IPTVOptionsView: View {
    @Binding var startPageRawValue: String
    @Binding var showsFavorites: Bool
    @Binding var showsChannels: Bool
    @Binding var showsCategories: Bool
    let sourceID: UUID?
    let categories: [XtreamLiveCategory]
    let channelGroups: [IPTVLiveChannelGroup]
    let favoritesManager: IPTVLiveFavoritesManager?
    @Binding var hiddenCategoriesJSON: String

    @State private var showingCategoriesManager = false
    @State private var showingFavoritesManager = false
    @State private var showingSourcesManager = false

    private var visibleSections: [IPTVRootSection] {
        IPTVRootSection.allCases.filter(isVisible)
    }

    private var startPage: Binding<IPTVRootSection> {
        Binding(
            get: {
                let stored = IPTVRootSection(rawValue: startPageRawValue)
                return stored.flatMap { visibleSections.contains($0) ? $0 : nil }
                    ?? visibleSections.first
                    ?? .favorites
            },
            set: { startPageRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Button {
                    showingCategoriesManager = true
                } label: {
                    IPTVOptionRow(
                        title: AppLocalization.string("iptv.categories.manage"),
                        systemImage: "square.stack.3d.up"
                    )
                }
                .buttonStyle(.plain)
                .disabled(sourceID == nil)

                Button {
                    showingFavoritesManager = true
                } label: {
                    IPTVOptionRow(
                        title: AppLocalization.string("iptv.favorites.manage"),
                        systemImage: "star"
                    )
                }
                .buttonStyle(.plain)
                .disabled(sourceID == nil || favoritesManager == nil)

                Button {
                    showingSourcesManager = true
                } label: {
                    IPTVOptionRow(
                        title: AppLocalization.string("iptv.options.manageSources"),
                        systemImage: "server.rack"
                    )
                }
                .buttonStyle(.plain)
            }

            Section(AppLocalization.string("iptv.options.startPage")) {
                PlatformMenuPicker(
                    AppLocalization.string("iptv.options.startPage"),
                    selection: startPage
                ) {
                    ForEach(visibleSections) { section in
                        Text(section.title).tag(section)
                    }
                }
            }

            Section {
                ForEach(IPTVRootSection.allCases) { section in
                    Toggle(section.title, isOn: visibilityBinding(for: section))
                        .disabled(visibleSections.count == 1 && isVisible(section))
                }
            } header: {
                Text(AppLocalization.string("iptv.options.visibleSections"))
            } footer: {
                Text(AppLocalization.string("iptv.options.visibleSections.footer"))
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("iptv.options.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(isPresented: $showingCategoriesManager) {
            if let sourceID {
                IPTVManageCategoriesView(
                    sourceID: sourceID,
                    categories: categories,
                    hiddenCategoriesJSON: $hiddenCategoriesJSON
                )
            }
        }
        .navigationDestination(isPresented: $showingSourcesManager) {
            SourcesListView()
        }
        .sheet(isPresented: $showingFavoritesManager) {
            if let sourceID, let favoritesManager {
                NavigationStack {
                    IPTVManageFavoritesView(
                        sourceID: sourceID,
                        groups: channelGroups,
                        favoritesManager: favoritesManager
                    )
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func isVisible(_ section: IPTVRootSection) -> Bool {
        switch section {
        case .favorites: showsFavorites
        case .channels: showsChannels
        case .categories: showsCategories
        }
    }

    private func visibilityBinding(for section: IPTVRootSection) -> Binding<Bool> {
        Binding(
            get: { isVisible(section) },
            set: { newValue in
                guard newValue || visibleSections.count > 1 else { return }
                switch section {
                case .favorites: showsFavorites = newValue
                case .channels: showsChannels = newValue
                case .categories: showsCategories = newValue
                }
            }
        )
    }
}

private struct IPTVOptionRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .labelStyle(IPTVOptionLabelStyle())

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct IPTVOptionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, alignment: .center)

            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

private struct IPTVManageCategoriesView: View {
    let sourceID: UUID
    let categories: [XtreamLiveCategory]
    @Binding var hiddenCategoriesJSON: String

    private var preferences: IPTVHiddenCategoriesPreferences {
        IPTVHiddenCategoriesPreferences.decode(hiddenCategoriesJSON)
    }

    private var orderedCategories: [XtreamLiveCategory] {
        preferences.ordered(categories, sourceID: sourceID)
    }

    var body: some View {
        List {
            Section {
                ForEach(orderedCategories, id: \.categoryID) { category in
                    Toggle(category.name, isOn: visibilityBinding(for: category.categoryID))
                }
                .onMove(perform: moveCategories)
            } footer: {
                Text(AppLocalization.string("iptv.categories.manage.footer"))
            }

            if preferences.hiddenCount(sourceID: sourceID) > 0 {
                Section {
                    Button(AppLocalization.string("iptv.categories.showAll")) {
                        showAllCategories()
                    }
                }
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("iptv.categories.manage"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        #endif
    }

    private func visibilityBinding(for categoryID: String) -> Binding<Bool> {
        Binding(
            get: { !preferences.isHidden(categoryID, sourceID: sourceID) },
            set: { isVisible in
                var updatedPreferences = preferences
                updatedPreferences.setHidden(
                    !isVisible,
                    categoryID: categoryID,
                    sourceID: sourceID
                )
                hiddenCategoriesJSON = updatedPreferences.encoded
            }
        )
    }

    private func showAllCategories() {
        var updatedPreferences = preferences
        updatedPreferences.showAll(sourceID: sourceID)
        hiddenCategoriesJSON = updatedPreferences.encoded
    }

    private func moveCategories(fromOffsets: IndexSet, toOffset: Int) {
        var reorderedCategories = orderedCategories
        reorderedCategories.move(fromOffsets: fromOffsets, toOffset: toOffset)
        var updatedPreferences = preferences
        updatedPreferences.setOrder(
            reorderedCategories.map(\.categoryID),
            sourceID: sourceID
        )
        hiddenCategoriesJSON = updatedPreferences.encoded
    }
}

private struct IPTVManageFavoritesView: View {
    @Environment(\.dismiss) private var dismiss

    let sourceID: UUID
    let groups: [IPTVLiveChannelGroup]
    let favoritesManager: IPTVLiveFavoritesManager

    @State private var errorMessage: String?

    private var favorites: [IPTVLiveChannelGroup] {
        favoritesManager.favorites(for: sourceID, in: groups)
    }

    var body: some View {
        List {
            if favorites.isEmpty {
                ContentUnavailableView {
                    Label(
                        AppLocalization.string("iptv.favorites.empty.title"),
                        systemImage: "star"
                    )
                } description: {
                    Text(AppLocalization.string("iptv.favorites.empty.description"))
                }
            } else {
                ForEach(favorites) { group in
                    HStack(spacing: 12) {
                        IPTVChannelLogo(
                            url: group.variants.lazy.compactMap(\.stream.streamIconURL).first
                        )
                        .frame(width: 72, height: 40.5)

                        Text(group.displayName)
                            .lineLimit(2)
                    }
                }
                .onDelete(perform: removeFavorites)
                .onMove(perform: moveFavorites)
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("iptv.favorites.manage"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            #endif
            sheetCloseToolbarItem(identifier: "iptvManageFavorites.closeButton") {
                dismiss()
            }
        }
        .alert(
            AppLocalization.string("common.error"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLocalization.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? AppLocalization.string("iptv.favorites.error"))
        }
    }

    private func removeFavorites(at offsets: IndexSet) {
        do {
            for index in offsets.sorted(by: >) {
                _ = try favoritesManager.toggleFavorite(favorites[index])
            }
        } catch {
            errorMessage = AppLocalization.string("iptv.favorites.error")
        }
    }

    private func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        do {
            try favoritesManager.moveFavorites(
                for: sourceID,
                in: groups,
                fromOffsets: fromOffsets,
                toOffset: toOffset
            )
        } catch {
            errorMessage = AppLocalization.string("iptv.favorites.error")
        }
    }
}

private enum IPTVChannelsMode {
    case all
    case favorites
    case category(XtreamLiveCategory)
}

private struct IPTVCurrentProgramPresentation: Hashable {
    let title: String
    let schedule: String
    let progress: Double

    init?(nowAndNext: IPTVChannelEPGNowNext?, referenceDate: Date) {
        guard let program = nowAndNext?.currentProgram else { return nil }
        title = program.title
        schedule = "\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))"
        let duration = program.end.timeIntervalSince(program.start)
        progress = duration > 0
            ? min(max(referenceDate.timeIntervalSince(program.start) / duration, 0), 1)
            : 0
    }
}

private struct IPTVCurrentProgramCompactView: View {
    let program: IPTVCurrentProgramPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(program.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(program.schedule)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            ProgressView(value: program.progress)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IPTVChannelsView: View {
    let sourceID: UUID
    let mode: IPTVChannelsMode
    let groups: [IPTVLiveChannelGroup]
    let favoritesManager: IPTVLiveFavoritesManager
    let onStreamSelected: IPTVStreamSelectionAction
    var showsNavigationChrome = true
    var searchConfiguration: IPTVSearchConfiguration? = nil
    var epgCatalog: EPGCatalog? = nil
    var epgReferenceDate = Date()

    @AppStorage("iptv.display.layout") private var layoutRawValue = VideoListLayout.list.rawValue
    @AppStorage("iptv.display.rowStyle") private var rowStyleRawValue = VideoRowStyle.regular.rawValue
    @AppStorage("iptv.display.gridColumns") private var gridColumns = 2
    @State private var showingViewOptions = false
    @State private var favoriteErrorMessage: String?
    @State private var variantSelection: IPTVVariantSelectionContext?

    private var visibleChannelGroups: [IPTVLiveChannelGroup] {
        let availableGroups = groups.filter { !$0.isDecorativeSeparator }
        switch mode {
        case .all:
            return availableGroups
        case .favorites:
            return favoritesManager.favorites(for: sourceID, in: availableGroups)
        case .category(let category):
            return availableGroups.filter { $0.categoryID == category.categoryID }
        }
    }

    private var title: String {
        switch mode {
        case .all:
            return AppLocalization.string("iptv.navigation.channels")
        case .favorites:
            return AppLocalization.string("iptv.favorites.title")
        case .category(let category):
            return category.name
        }
    }

    private var layout: VideoListLayout {
        VideoListLayout(rawValue: layoutRawValue) ?? .list
    }

    private var rowStyle: VideoRowStyle {
        VideoRowStyle(rawValue: rowStyleRawValue) ?? .regular
    }

    private func programPresentation(
        for group: IPTVLiveChannelGroup
    ) -> IPTVCurrentProgramPresentation? {
        guard let epgCatalog else { return nil }
        return IPTVCurrentProgramPresentation(
            nowAndNext: IPTVChannelEPGAssociator(catalog: epgCatalog)
                .nowAndNext(for: group, at: epgReferenceDate),
            referenceDate: epgReferenceDate
        )
    }

    var body: some View {
        let visibleGroups = visibleChannelGroups
        Group {
            if visibleGroups.isEmpty {
                ScrollView {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySystemImage)
                    } description: {
                        Text(emptyDescription)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
                .iptvSearchable(searchConfiguration)
            } else if layout == .grid {
                ScrollView {
                    LazyVGrid(
                        columns: makeGridColumns(count: gridColumns),
                        spacing: GridConstants.spacing
                    ) {
                        ForEach(visibleGroups) { group in
                            IPTVChannelGridCard(
                                group: group,
                                isFavorite: favoritesManager.isFavorite(group),
                                program: programPresentation(for: group),
                                select: { select(group) },
                                toggleFavorite: { toggleFavorite(group) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .iptvSearchable(searchConfiguration)
            } else {
                List {
                    if showsNavigationChrome {
                        channelListRows(visibleGroups)
                    } else {
                        Section(title) {
                            channelListRows(visibleGroups)
                        }
                    }
                }
                .iptvSearchable(searchConfiguration)
            }
        }
        .reactiveNavigationTitle(
            showsNavigationChrome ? title : AppLocalization.string("tabs.iptv")
        )
        #if os(iOS)
        .toolbarTitleDisplayMode(showsNavigationChrome ? .inline : .inlineLarge)
        #endif
        .toolbar {
            if showsNavigationChrome {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingViewOptions = true
                    } label: {
                        Label(AppLocalization.string("viewOptions.title"), systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(isPresented: $showingViewOptions) {
            ViewOptionsSheet(
                layout: layoutBinding,
                rowStyle: rowStyleBinding,
                gridColumns: $gridColumns,
                hideWatched: nil,
                channelStripSize: nil,
                maxGridColumns: 4
            )
        }
        .sheet(item: $variantSelection) { context in
            IPTVStreamVariantPickerSheet(
                presentation: context.presentation,
                select: { variant in
                    onStreamSelected(sourceID, context.group, variant)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            AppLocalization.string("common.error"),
            isPresented: favoriteErrorBinding
        ) {
            Button(AppLocalization.string("common.ok"), role: .cancel) {}
        } message: {
            Text(favoriteErrorMessage ?? AppLocalization.string("iptv.favorites.error"))
        }
    }

    @ViewBuilder
    private func channelListRows(_ groups: [IPTVLiveChannelGroup]) -> some View {
        ForEach(groups) { group in
            IPTVChannelRow(
                group: group,
                rowStyle: rowStyle,
                isFavorite: favoritesManager.isFavorite(group),
                program: programPresentation(for: group),
                select: { select(group) },
                toggleFavorite: { toggleFavorite(group) }
            )
            .listRowInsets(
                EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            )
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .all: AppLocalization.string("iptv.channels.empty.title")
        case .favorites: AppLocalization.string("iptv.favorites.empty.title")
        case .category: AppLocalization.string("iptv.category.empty.title")
        }
    }

    private var emptyDescription: String {
        switch mode {
        case .all: AppLocalization.string("iptv.channels.empty.description")
        case .favorites: AppLocalization.string("iptv.favorites.empty.description")
        case .category: AppLocalization.string("iptv.category.empty.description")
        }
    }

    private var emptySystemImage: String {
        switch mode {
        case .all: "play.tv"
        case .favorites: "star"
        case .category: "play.tv"
        }
    }

    private var layoutBinding: Binding<VideoListLayout> {
        Binding(
            get: { layout },
            set: { layoutRawValue = $0.rawValue }
        )
    }

    private var rowStyleBinding: Binding<VideoRowStyle> {
        Binding(
            get: { rowStyle },
            set: { rowStyleRawValue = $0.rawValue }
        )
    }

    private var favoriteErrorBinding: Binding<Bool> {
        Binding(
            get: { favoriteErrorMessage != nil },
            set: { if !$0 { favoriteErrorMessage = nil } }
        )
    }

    private func toggleFavorite(_ group: IPTVLiveChannelGroup) {
        do {
            try favoritesManager.toggleFavorite(group)
        } catch {
            favoriteErrorMessage = AppLocalization.string("iptv.favorites.error")
        }
    }

    private func select(_ group: IPTVLiveChannelGroup) {
        let presentation = IPTVLiveChannelPresentation(group: group)
        switch presentation.selectionMode {
        case .direct(let variantID):
            guard let variant = presentation.variants.first(where: { $0.id == variantID }) else {
                return
            }
            onStreamSelected(sourceID, group, variant)
        case .requiresExplicitChoice:
            variantSelection = IPTVVariantSelectionContext(
                group: group,
                presentation: presentation
            )
        }
    }
}

private struct IPTVVariantSelectionContext: Identifiable {
    let group: IPTVLiveChannelGroup
    let presentation: IPTVLiveChannelPresentation

    var id: IPTVLiveChannelGroup.ID { presentation.id }
}

private struct IPTVChannelRow: View {
    let group: IPTVLiveChannelGroup
    let rowStyle: VideoRowStyle
    let isFavorite: Bool
    let program: IPTVCurrentProgramPresentation?
    let select: () -> Void
    let toggleFavorite: () -> Void

    private var logoURL: URL? {
        group.variants.lazy.compactMap(\.stream.streamIconURL).first
    }

    private var logoSize: CGSize {
        switch rowStyle {
        case .compact: CGSize(width: 48, height: 27)
        case .regular: CGSize(width: 72, height: 40.5)
        case .large: CGSize(width: 96, height: 54)
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 12) {
                    IPTVChannelLogo(url: logoURL)
                        .frame(width: logoSize.width, height: logoSize.height)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .padding(.trailing, 32)

                        if let program {
                            IPTVCurrentProgramCompactView(program: program)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            favoriteButton
        }
        .padding(.vertical, 3)
    }

    private var favoriteButton: some View {
        Button(action: toggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(
            AppLocalization.string(
                isFavorite ? "iptv.favorites.remove" : "iptv.favorites.add"
            )
        )
    }
}

private struct IPTVChannelGridCard: View {
    let group: IPTVLiveChannelGroup
    let isFavorite: Bool
    let program: IPTVCurrentProgramPresentation?
    let select: () -> Void
    let toggleFavorite: () -> Void

    private var logoURL: URL? {
        group.variants.lazy.compactMap(\.stream.streamIconURL).first
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 8) {
                    IPTVChannelLogo(url: logoURL)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)

                    Text(group.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let program {
                        IPTVCurrentProgramCompactView(program: program)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.white)
                    .padding(7)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel(
                AppLocalization.string(
                    isFavorite ? "iptv.favorites.remove" : "iptv.favorites.add"
                )
            )
        }
    }
}

private struct IPTVStreamVariantPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: IPTVLiveChannelPresentation
    let select: (IPTVLiveVariantPresentation) -> Void

    @State private var isExpanded = false

    private var visibleVariants: [IPTVLiveVariantPresentation] {
        isExpanded ? presentation.variants : presentation.firstChoices
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleVariants) { variant in
                    Button {
                        select(variant)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle")
                                .foregroundStyle(.tint)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(variant.label)
                                    .foregroundStyle(.primary)

                                if variant.usesHEVC {
                                    Text(AppLocalization.string("iptv.streams.hevc"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("iptv.stream.\(variant.streamID)")
                }

                if presentation.additionalChoiceCount > 0 {
                    Button {
                        withAnimation {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(
                            isExpanded
                                ? AppLocalization.string("iptv.streams.showLess")
                                : AppLocalization.string(
                                    "iptv.streams.showMore \(presentation.additionalChoiceCount)"
                                ),
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                    }
                }
            }
            .reactiveNavigationTitle(presentation.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                sheetCloseToolbarItem(identifier: "iptvStreamPicker.closeButton") {
                    dismiss()
                }
            }
        }
    }
}

struct IPTVChannelLogo: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.clear

            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .empty, .failure:
                    Image(systemName: "play.tv")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                @unknown default:
                    Image(systemName: "play.tv")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    NavigationStack {
        IPTVRootView()
    }
    .appEnvironment(.preview)
}
