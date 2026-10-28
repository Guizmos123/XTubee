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
    @State private var posterService: FeedarrPosterService?

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
                        placeholder(for: .releases)
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

    private func placeholder(for page: FeedarrPage) -> some View {
        ContentUnavailableView {
            Label(page.title, systemImage: page.systemImage)
        } description: {
            Text(AppLocalization.string("feedarr.placeholder.description"))
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
