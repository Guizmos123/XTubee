//
//  FeedarrTrackerService.swift
//  Yattee
//
//  Shared, short-lived tracker directory. Credentials never enter the cached projection.
//

import Foundation
import Observation

@MainActor
@Observable
final class FeedarrTrackerService {
    typealias Loader = @MainActor @Sendable () async throws -> [FeedarrTracker]

    private(set) var trackers: [Int64: FeedarrTracker] = [:]
    private(set) var isLoading = false
    private(set) var loadFailed = false

    @ObservationIgnored private let sources: FeedarrSourcesManager
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let now: @MainActor @Sendable () -> Date
    @ObservationIgnored private let validity: TimeInterval
    private var revision: UUID
    @ObservationIgnored private var generation = UUID()
    private var validUntil: Date?
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private var flight: Task<Void, Never>?

    init(sources: FeedarrSourcesManager, validity: TimeInterval = 300,
         now: @escaping @MainActor @Sendable () -> Date = { Date() }, loader: @escaping Loader) {
        precondition(validity > 0 && validity.isFinite)
        self.sources = sources
        self.loader = loader
        self.validity = validity
        self.now = now
        revision = sources.configurationRevision
        observeConfiguration()
    }

    func tracker(for sourceID: Int64) -> FeedarrTracker? {
        // Fail closed immediately, even before the observation callback has cleared the dictionary.
        guard revision == sources.configurationRevision, sources.source != nil, sources.loadError == nil,
              let validUntil, now() < validUntil else { return nil }
        return trackers[sourceID]
    }

    func loadIfNeeded() async { await load(force: false) }
    func refresh() async { await load(force: true) }

    private func load(force: Bool) async {
        synchronizeConfiguration()
        guard sources.source != nil, sources.loadError == nil else { return }
        if let flight { await flight.value; return }
        if !force {
            if let validUntil, now() < validUntil { return }
            if let retryAfter, now() < retryAfter { return }
        }
        let token = generation
        let fetch = loader
        isLoading = true
        loadFailed = false
        let task = Task { [weak self] in
            do {
                let rows = try await fetch()
                guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                var map: [Int64: FeedarrTracker] = [:]
                for row in rows where row.id > 0 {
                    let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { continue }
                    map[row.id] = FeedarrTracker(id: row.id, name: name, color: row.color)
                }
                self.trackers = map
                self.validUntil = self.now().addingTimeInterval(self.validity)
                self.retryAfter = nil
                self.isLoading = false
                self.flight = nil
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.isLoading = false
                self.flight = nil
                self.loadFailed = true
                // An unavailable directory must not cause a request on every sheet opening.
                self.retryAfter = self.now().addingTimeInterval(30)
            }
        }
        flight = task
        // A disappearing sheet doesn't cancel a shared fetch. Configuration changes do.
        await task.value
    }

    private func isCurrent(_ token: UUID) -> Bool {
        synchronizeConfiguration()
        return token == generation && sources.source != nil && sources.loadError == nil
    }

    private func synchronizeConfiguration() {
        guard revision != sources.configurationRevision else { return }
        revision = sources.configurationRevision
        generation = UUID()
        flight?.cancel()
        flight = nil
        trackers = [:]
        validUntil = nil
        retryAfter = nil
        isLoading = false
        loadFailed = false
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
