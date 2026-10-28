//
//  FeedarrReleasesModel.swift
//  Yattee
//
//  Sequential, in-memory cursor pagination for the active Feedarr source.
//

import Foundation
import Observation

enum FeedarrReleasesFailure: Equatable, Sendable {
    case offline, authentication, invalidResponse, server, other

    var message: String {
        switch self {
        case .offline: AppLocalization.string("feedarr.releases.error.offline")
        case .authentication: AppLocalization.string("feedarr.releases.error.authentication")
        case .invalidResponse: AppLocalization.string("feedarr.releases.error.invalidResponse")
        case .server: AppLocalization.string("feedarr.releases.error.server")
        case .other: AppLocalization.string("feedarr.releases.error.other")
        }
    }

    init(_ error: Error) {
        switch error {
        case FeedarrAPIError.transport(.networkUnavailable), FeedarrAPIError.transport(.timeout): self = .offline
        case FeedarrAPIError.credentialsMissing, FeedarrAPIError.credentialsUnavailable,
             FeedarrAPIError.http(.unauthorized, _), FeedarrAPIError.http(.forbidden, _): self = .authentication
        case FeedarrAPIError.invalidJSON: self = .invalidResponse
        case FeedarrAPIError.http: self = .server
        default: self = .other
        }
    }
}

@MainActor
@Observable
final class FeedarrReleasesModel {
    typealias LoadPage = @MainActor @Sendable (String?) async throws -> FeedarrReleasesResponse

    private(set) var items: [FeedarrRelease] = []
    private(set) var hasLoadedInitial = false
    private(set) var isLoadingInitial = false
    private(set) var isLoadingNextPage = false
    private(set) var hasMore = false
    private(set) var nextCursor: String?
    /// Insertion boundary only; metrics and categories can still change between pages.
    private(set) var snapshotMaxId: Int64?
    private(set) var failure: FeedarrReleasesFailure?
    /// Changes only when replacing the catalogue, never when changing segments or appending.
    private(set) var catalogGeneration = UUID()

    @ObservationIgnored private let sources: FeedarrSourcesManager
    @ObservationIgnored private let loadPage: LoadPage
    @ObservationIgnored private var revision: UUID
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var identifiers: Set<Int64> = []
    @ObservationIgnored private var consumedCursors: Set<String> = []
    @ObservationIgnored private var failedRequest: Request?

    init(sources: FeedarrSourcesManager, loadPage: @escaping LoadPage) {
        self.sources = sources
        self.loadPage = loadPage
        revision = sources.configurationRevision
        observeConfiguration()
    }

    var isLoading: Bool { isLoadingInitial || isLoadingNextPage }
    var isEmpty: Bool { hasLoadedInitial && items.isEmpty }
    var isAtEnd: Bool { hasLoadedInitial && !hasMore }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        synchronizeConfiguration(reload: false)
        if visible { loadIfNeeded() } else { cancelRequest() }
    }

    func loadNextPage() {
        synchronizeConfiguration()
        guard hasLoadedInitial, hasMore, let nextCursor, failure == nil else { return }
        _ = start(.next(nextCursor))
    }

    func itemAppeared(_ id: Int64) {
        guard items.suffix(10).contains(where: { $0.id == id }) else { return }
        loadNextPage()
    }

    func retry() {
        synchronizeConfiguration()
        guard let failedRequest else { return }
        _ = start(failedRequest)
    }

    func refresh() async {
        synchronizeConfiguration(reload: false)
        guard visible, configured else { return }
        cancelRequest()
        guard let task = start(.first) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private enum Request: Sendable {
        case first
        case next(String)
        var cursor: String? { if case .next(let cursor) = self { cursor } else { nil } }
    }

    private var configured: Bool { sources.source != nil && sources.loadError == nil }

    private func loadIfNeeded() {
        guard !hasLoadedInitial, failure == nil else { return }
        _ = start(.first)
    }

    @discardableResult
    private func start(_ request: Request) -> Task<Void, Never>? {
        guard visible, configured, !isLoading else { return nil }
        let token = UUID()
        requestID = token
        let configuration = revision
        let loader = loadPage
        failure = nil
        failedRequest = nil
        isLoadingInitial = request.cursor == nil
        isLoadingNextPage = request.cursor != nil
        let task = Task { [weak self] in
            do {
                let response = try await loader(request.cursor)
                guard let self, self.accepts(token, configuration: configuration) else { return }
                self.finishLoading()
                guard !Task.isCancelled else { return }
                let next = response.pagination.nextCursor
                if response.pagination.hasMore {
                    guard let next, !next.isEmpty,
                          request.cursor == nil || (next != request.cursor && !self.consumedCursors.contains(next)) else {
                        self.failure = .invalidResponse
                        self.failedRequest = request
                        return
                    }
                }
                if request.cursor == nil {
                    self.items = []
                    self.identifiers = []
                    self.consumedCursors = []
                    self.catalogGeneration = UUID()
                }
                for release in response.items where self.identifiers.insert(release.id).inserted {
                    self.items.append(release)
                }
                if let cursor = request.cursor { self.consumedCursors.insert(cursor) }
                self.hasLoadedInitial = true
                self.hasMore = response.pagination.hasMore
                self.nextCursor = response.pagination.hasMore ? next : nil
                self.snapshotMaxId = response.pagination.snapshotMaxId
            } catch {
                guard let self, self.accepts(token, configuration: configuration) else { return }
                self.finishLoading()
                if !Task.isCancelled && !(error is CancellationError) && (error as? FeedarrAPIError) != .cancelled {
                    self.failure = FeedarrReleasesFailure(error)
                    self.failedRequest = request
                }
            }
        }
        requestTask = task
        return task
    }

    private func accepts(_ token: UUID, configuration: UUID) -> Bool {
        synchronizeConfiguration()
        return requestID == token && revision == configuration && visible && configured
    }

    private func finishLoading() {
        isLoadingInitial = false
        isLoadingNextPage = false
        requestTask = nil
    }

    private func cancelRequest() {
        requestID = UUID()
        requestTask?.cancel()
        finishLoading()
    }

    private func synchronizeConfiguration(reload: Bool = true) {
        guard revision != sources.configurationRevision else { return }
        revision = sources.configurationRevision
        cancelRequest()
        items = []
        identifiers = []
        consumedCursors = []
        hasLoadedInitial = false
        hasMore = false
        nextCursor = nil
        snapshotMaxId = nil
        failure = nil
        failedRequest = nil
        catalogGeneration = UUID()
        if reload { loadIfNeeded() }
    }

    private func observeConfiguration() {
        withObservationTracking { _ = sources.configurationRevision } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.synchronizeConfiguration()
                self.observeConfiguration()
            }
        }
    }
}
