//
//  FeedarrTopModel.swift
//  Yattee
//
//  In-memory Top state, one catalogue request for all seven rails.
//

import Foundation
import Observation

struct FeedarrTopRailContent: Identifiable, Sendable {
    let id: FeedarrTopRail
    let items: [FeedarrRelease]
    /// Server category count, after optional dedupe. Never a download count.
    let count: Int?

    var title: String {
        switch id {
        case .global: AppLocalization.string("feedarr.top.global")
        case .category(let category): category.localizedTitle
        }
    }
}

enum FeedarrTopFailure: Equatable, Sendable {
    case offline, authentication, invalidResponse, server, other

    var message: String {
        switch self {
        case .offline: AppLocalization.string("feedarr.top.error.offline")
        case .authentication: AppLocalization.string("feedarr.top.error.authentication")
        case .invalidResponse: AppLocalization.string("feedarr.top.error.invalidResponse")
        case .server: AppLocalization.string("feedarr.top.error.server")
        case .other: AppLocalization.string("feedarr.top.error.other")
        }
    }

    init(_ error: Error) {
        switch error {
        case FeedarrAPIError.transport(.networkUnavailable), FeedarrAPIError.transport(.timeout): self = .offline
        case FeedarrAPIError.http(.unauthorized, _), FeedarrAPIError.http(.forbidden, _),
             FeedarrAPIError.credentialsMissing, FeedarrAPIError.credentialsUnavailable: self = .authentication
        case FeedarrAPIError.invalidJSON: self = .invalidResponse
        case FeedarrAPIError.http: self = .server
        default: self = .other
        }
    }
}

@MainActor
@Observable
final class FeedarrTopModel {
    typealias LoadTop = @MainActor @Sendable (FeedarrTopSort) async throws -> FeedarrTopResponse

    private(set) var selectedSort: FeedarrTopSort = .score
    private(set) var response: FeedarrTopResponse?
    private(set) var isLoading = false
    private(set) var failure: FeedarrTopFailure?

    @ObservationIgnored private let sources: FeedarrSourcesManager
    @ObservationIgnored private let loadTop: LoadTop
    @ObservationIgnored private var revision: UUID
    @ObservationIgnored private var consumers: Set<UUID> = []
    @ObservationIgnored private var usesSharedConsumers = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var requestTask: Task<Void, Never>?

    init(sources: FeedarrSourcesManager, loadTop: @escaping LoadTop) {
        self.sources = sources
        self.loadTop = loadTop
        revision = sources.configurationRevision
        observeConfiguration()
    }

    var rails: [FeedarrTopRailContent] {
        guard let response else { return [] }
        return FeedarrTopRail.presentationOrder.map { rail in
            switch rail {
            case .global: return FeedarrTopRailContent(id: rail, items: response.globalTop, count: nil)
            case .category(let category):
                let data = response.category(for: category)
                return FeedarrTopRailContent(id: rail, items: data?.top ?? [], count: data?.count)
            }
        }
    }

    var isEmpty: Bool { response != nil && rails.allSatisfy { $0.items.isEmpty } }

    /// Shared Home/Hub consumers must not cancel one another's request.
    func setConsumer(_ id: UUID, active: Bool) {
        usesSharedConsumers = true
        if active { consumers.insert(id) } else { consumers.remove(id) }
        synchronizeConfiguration(reload: false)
        visible = !consumers.isEmpty
        // A tab transition can briefly have no consumers. Keep a valid in-flight
        // response for the next page instead of cancelling and downloading twice.
        if visible { loadIfNeeded() }
    }

    var configurationRevision: UUID { revision }

    var currentResponse: FeedarrTopResponse? {
        sources.configurationRevision == revision ? response : nil
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        synchronizeConfiguration(reload: false)
        if visible { loadIfNeeded() } else { cancelRequest() }
    }

    func selectSort(_ sort: FeedarrTopSort) {
        guard sort != selectedSort else { return }
        selectedSort = sort
        cancelRequest()
        response = nil
        failure = nil
        loadIfNeeded()
    }

    func retry() { _ = startRequest() }

    func refresh() async {
        synchronizeConfiguration(reload: false)
        guard let task = startRequest() else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private var configured: Bool { sources.source != nil && sources.loadError == nil }

    private func loadIfNeeded() {
        guard response == nil, failure == nil, !isLoading else { return }
        _ = startRequest()
    }

    @discardableResult
    private func startRequest() -> Task<Void, Never>? {
        synchronizeConfiguration(reload: false)
        guard visible, configured else { return nil }
        cancelRequest()
        let id = requestID
        let configuration = sources.configurationRevision
        let sort = selectedSort
        let loader = loadTop
        isLoading = true
        failure = nil
        let task = Task { [weak self] in
            do {
                let result = try await loader(sort)
                guard let self, self.accepts(id: id, configuration: configuration) else { return }
                self.isLoading = false
                self.requestTask = nil
                if !Task.isCancelled { self.response = result }
            } catch {
                guard let self, self.accepts(id: id, configuration: configuration) else { return }
                self.isLoading = false
                self.requestTask = nil
                if !Task.isCancelled && !(error is CancellationError) && (error as? FeedarrAPIError) != .cancelled {
                    self.failure = FeedarrTopFailure(error)
                }
            }
        }
        requestTask = task
        return task
    }

    private func accepts(id: UUID, configuration: UUID) -> Bool {
        synchronizeConfiguration()
        return requestID == id && sources.configurationRevision == configuration && (visible || usesSharedConsumers) && configured
    }

    private func cancelRequest() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
    }

    private func synchronizeConfiguration(reload: Bool = true) {
        guard revision != sources.configurationRevision else { return }
        revision = sources.configurationRevision
        cancelRequest()
        response = nil
        failure = nil
        if reload { loadIfNeeded() }
    }

    private func observeConfiguration() {
        withObservationTracking {
            _ = sources.configurationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.synchronizeConfiguration()
                self.observeConfiguration()
            }
        }
    }
}
