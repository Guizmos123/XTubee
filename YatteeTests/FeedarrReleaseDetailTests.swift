//
//  FeedarrReleaseDetailTests.swift
//  Yattee
//
//  Shared selection and local-only detail formatting contracts.
//

import Foundation
import SwiftUI
import Testing
@testable import XTubee

#if os(iOS)
@Suite("Feedarr Release Details")
@MainActor
struct FeedarrReleaseDetailTests {
    @Test func bothPagesSelectTheSameRootSheetItem() throws {
        let fixture = DetailFixture()
        defer { fixture.cleanUp() }
        let navigation = FeedarrNavigationState()
        let release = try decode(FeedarrDTOFixtures.completeRelease)
        let select: (FeedarrRelease) -> Void = {
            navigation.selectRelease($0, configurationRevision: fixture.manager.configurationRevision)
        }
        let top = FeedarrTopView(model: fixture.top, posterService: fixture.posters, isVisible: true,
                                 onSelectRelease: select)
        let releases = FeedarrReleasesView(model: fixture.releases, posterService: fixture.posters, isVisible: false,
                                           isSearchPresented: .constant(false), onSelectRelease: select)
        let topCard = FeedarrReleaseCard(release: release, posterService: fixture.posters, onSelectRelease: top.onSelectRelease)
        let selectFromTop: (FeedarrRelease) -> Void = try #require(topCard.onSelectRelease)
        selectFromTop(topCard.release)
        let fromTop = try #require(navigation.selectedRelease)
        navigation.selectedRelease = nil
        navigation.selectedPage = .releases
        let releasesCard = FeedarrReleaseCard(release: release, posterService: fixture.posters, onSelectRelease: releases.onSelectRelease)
        let selectFromReleases: (FeedarrRelease) -> Void = try #require(releasesCard.onSelectRelease)
        selectFromReleases(releasesCard.release)
        #expect(navigation.selectedRelease == fromTop)
        let sheet = FeedarrReleaseDetailSheet(selection: try #require(navigation.selectedRelease), posterService: fixture.posters)
        #expect(sheet.release == release)
        #expect(fixture.catalogueCalls == 0) // Selection only writes the root item, never a video or API action.
    }

    @Test func dismissingSelectionPreservesBothCatalogues() async throws {
        let fixture = DetailFixture()
        defer { fixture.cleanUp() }
        fixture.top.setVisible(true)
        fixture.releases.updateSearchText("term")
        fixture.releases.selectSort(.score)
        fixture.releases.selectCategory(.films)
        fixture.releases.setVisible(true)
        for _ in 0..<100 {
            if fixture.top.response != nil && fixture.releases.hasLoadedInitial { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let top = try #require(fixture.top.response)
        let items = fixture.releases.items
        let identity = fixture.releases.catalogGeneration
        let calls = fixture.catalogueCalls
        let navigation = FeedarrNavigationState()
        navigation.selectedPage = .releases
        navigation.selectRelease(try #require(items.first), configurationRevision: fixture.manager.configurationRevision)
        let item = Binding(get: { navigation.selectedRelease }, set: { navigation.selectedRelease = $0 })
        item.wrappedValue = nil // Same write performed by sheet(item:) on dismiss/swipe.
        #expect(navigation.selectedPage == .releases && navigation.selectedRelease == nil)
        #expect(fixture.top.response == top && fixture.releases.items == items)
        #expect(fixture.releases.catalogGeneration == identity)
        #expect(fixture.releases.query == "term" && fixture.releases.selectedSort == .score && fixture.releases.selectedCategory == .films)
        #expect(fixture.catalogueCalls == calls && calls == 2)
    }

    @Test func absentAndBlankMetadataDoesNotCreateFields() throws {
        let minimal = FeedarrReleaseDetailMetadata(release: try decode(FeedarrDTOFixtures.minimalRelease))
        #expect(minimal.title == nil && minimal.overview == nil)
        #expect(minimal.releaseRows.isEmpty && minimal.mediaRows.isEmpty && minimal.statisticsRows.isEmpty)
        let blank = FeedarrReleaseDetailMetadata(release: try decode(#"{"id":1,"sourceId":2,"title":"  ","titleClean":"","overview":"\n ","genres":" ","categoryName":" "}"#))
        #expect(blank.title == nil && blank.overview == nil)
        #expect(blank.releaseRows.isEmpty && blank.mediaRows.isEmpty)
    }

    @Test func fullTitleSynopsisAndAvailableStatisticsArePreserved() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(FeedarrDTOFixtures.completeRelease.utf8)) as? [String: Any])
        let synopsis = "\n" + String(repeating: "Synopsis intégral. ", count: 500) + "\n"
        json["overview"] = synopsis
        json["seeders"] = 0
        json["leechers"] = 0
        let release = try JSONDecoder().decode(FeedarrRelease.self, from: JSONSerialization.data(withJSONObject: json))
        let metadata = FeedarrReleaseDetailMetadata(release: release)
        #expect(metadata.title == release.title)
        #expect(metadata.overview == synopsis)
        #expect(Set(metadata.releaseRows.map(\.id)).isSuperset(of: ["feedarr.detail.cleanTitle", "feedarr.detail.category", "feedarr.detail.year", "feedarr.detail.season", "feedarr.detail.episode", "feedarr.detail.codec", "feedarr.detail.size", "feedarr.detail.published"]))
        #expect(metadata.mediaRows.count == 5)
        #expect(metadata.statisticsRows.map(\.value) == ["0", "0", "120"])
        #expect(metadata.releaseRows.allSatisfy { !$0.value.isEmpty })
    }

    @Test func configurationChangeInvalidatesSelectionWithoutChangingPage() throws {
        let fixture = DetailFixture()
        defer { fixture.cleanUp() }
        let navigation = FeedarrNavigationState()
        navigation.selectedPage = .releases
        navigation.selectRelease(try decode(FeedarrDTOFixtures.completeRelease),
                                 configurationRevision: fixture.manager.configurationRevision)
        let selected = try #require(navigation.selectedRelease)
        navigation.invalidateSelection(configurationRevision: fixture.manager.configurationRevision)
        #expect(navigation.selectedRelease == selected)
        try changeServer(fixture.manager)
        #expect(!selected.isCurrent(sources: fixture.manager))
        navigation.invalidateSelection(configurationRevision: fixture.manager.configurationRevision)
        #expect(navigation.selectedRelease == nil)
        #expect(navigation.selectedPage == .releases)
    }

    @Test func staleSelectionCannotStartDownloadEvenAfterReturningToOriginalServer() async throws {
        let fixture = DetailFixture()
        defer { fixture.cleanUp() }
        let selection = FeedarrReleaseSelection(release: try decode(FeedarrDTOFixtures.completeRelease),
                                                configurationRevision: fixture.manager.configurationRevision)
        try changeServer(fixture.manager)
        try changeServer(fixture.manager, url: "https://feedarr.invalid")
        var calls = 0
        await #expect(throws: FeedarrAPIError.obsoleteResponse) {
            try await selection.downloadTorrent(sources: fixture.manager) {
                calls += 1
                return .magnet("magnet:?xt=urn:btih:old")
            }
        }
        #expect(calls == 0)
    }

    @Test(arguments: [false, true])
    func obsoleteAsynchronousResultsAreRejected(andCleanedFile: Bool) async throws {
        let fixture = DetailFixture()
        defer { fixture.cleanUp() }
        let selection = FeedarrReleaseSelection(release: try decode(FeedarrDTOFixtures.completeRelease),
                                                configurationRevision: fixture.manager.configurationRevision)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedarrTorrent-" + UUID().uuidString)
        let file = directory.appendingPathComponent("release.torrent")
        defer { try? FileManager.default.removeItem(at: directory) }
        var pending: CheckedContinuation<FeedarrTorrentResult, Never>?
        let download = Task { @MainActor in
            await #expect(throws: FeedarrAPIError.obsoleteResponse) {
                try await selection.downloadTorrent(sources: fixture.manager) {
                    await withCheckedContinuation { pending = $0 }
                }
            }
        }
        while pending == nil { await Task.yield() }
        try changeServer(fixture.manager)
        if andCleanedFile {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("temporary result".utf8).write(to: file)
            pending?.resume(returning: .file(file))
        } else {
            pending?.resume(returning: .magnet("magnet:?xt=urn:btih:old"))
        }
        await download.value
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func unchangedConfigurationAllowsNormalActions() async throws {
        let fixture = DetailFixture()
        defer { fixture.cleanUp() }
        let release = try decode(FeedarrDTOFixtures.completeRelease)
        let selection = FeedarrReleaseSelection(release: release, configurationRevision: fixture.manager.configurationRevision)
        #expect(selection.isCurrent(sources: fixture.manager))
        var calls = 0
        let result = try await selection.downloadTorrent(sources: fixture.manager) {
            calls += 1
            return .magnet("magnet:?xt=urn:btih:current")
        }
        guard case .magnet(let link) = result else { Issue.record("Expected current magnet"); return }
        #expect(link == "magnet:?xt=urn:btih:current")
        #expect(calls == 1)
        #expect(selection.release == release)
        #expect(selection.isCurrent(sources: fixture.manager))
    }

    private func changeServer(_ manager: FeedarrSourcesManager, url: String = "https://other.invalid") throws {
        let source = try #require(manager.source)
        _ = try manager.update(id: source.id, name: source.name, serverURL: url, usesBasicAuth: false)
        #expect(manager.source?.id == source.id)
    }

    private func decode(_ json: String) throws -> FeedarrRelease {
        try JSONDecoder().decode(FeedarrRelease.self, from: Data(json.utf8))
    }
}

@MainActor
private final class DetailFixture {
    let manager: FeedarrSourcesManager
    let posters: FeedarrPosterService
    private(set) var catalogueCalls = 0
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedarrDetailTests-" + UUID().uuidString)
    lazy var top = FeedarrTopModel(sources: manager) { [weak self] _ in
        self?.catalogueCalls += 1
        return try JSONDecoder().decode(FeedarrTopResponse.self, from: Data(FeedarrDTOFixtures.completeTop.utf8))
    }
    lazy var releases = FeedarrReleasesModel(sources: manager, debounce: {}) { [weak self] _, _, _, _ in
        self?.catalogueCalls += 1
        return try JSONDecoder().decode(FeedarrReleasesResponse.self, from: Data(FeedarrDTOFixtures.emptyReleases.replacingOccurrences(of: "\"items\":[]", with: "\"items\":[\(FeedarrDTOFixtures.minimalRelease)]").utf8))
    }

    init() {
        manager = FeedarrSourcesManager(persistence: DetailPersistence(), credentialsStore: DetailCredentials())
        posters = FeedarrPosterService(sources: manager, credentialsStore: DetailCredentials(), transport: DetailTransport(), cacheDirectory: directory)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class DetailPersistence: FeedarrSourcePersisting {
    // Valid synthetic metadata; no live service and no persistent defaults.
    func loadSource() throws -> FeedarrSource? { try FeedarrSource(name: "Test", serverURL: "https://feedarr.invalid") }
    func saveSource(_ source: FeedarrSource?) throws {}
}

@MainActor
private final class DetailCredentials: FeedarrCredentialsStoring {
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { nil }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws {}
    func deleteCredentials(for sourceID: UUID) throws {}
}

private struct DetailTransport: FeedarrHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.unsupportedURL) }
}
#endif
