//
//  FeedarrNavigationTests.swift
//  Yattee
//
//  Execution tests for preferences and root state, plus static navigation contracts.
//

import Foundation
import SwiftUI
import Testing
@testable import XTubee

@Suite("Feedarr Navigation Preferences", .serialized)
@MainActor
struct FeedarrNavigationPreferenceTests {
    @Test("Shared Codable values include Feedarr without losing older items")
    func sharedCodableValues() throws {
        let tabs = try JSONDecoder().decode([TabBarItem].self, from: Data(#"["iptv","feedarr","sources"]"#.utf8))
        let sidebar = try JSONDecoder().decode([SidebarMainItem].self, from: Data(#"["home","feedarr","settings"]"#.utf8))
        #expect(tabs == [.iptv, .feedarr, .sources])
        #expect(sidebar == [.home, .feedarr, .settings])
        #expect(try JSONDecoder().decode([TabBarItem].self, from: JSONEncoder().encode(tabs)) == tabs)
        #expect(SidebarMainItem(tabBarItem: .feedarr) == .feedarr)
        #expect(SidebarMainItem.feedarr.sidebarItem == .feedarr)
        #expect(SidebarItem.feedarr.navigationDestination() == nil)
        #expect(SidebarItem.feedarr.systemImage == "rectangle.stack")
    }

    @Test("Feedarr defaults immediately after IPTV and is visible")
    func defaultPlacement() throws {
        let compactIndex = try #require(TabBarItem.defaultOrder.firstIndex(of: .iptv))
        let sidebarIndex = try #require(SidebarMainItem.defaultOrder.firstIndex(of: .iptv))
        #expect(TabBarItem.defaultOrder[compactIndex + 1] == .feedarr)
        #expect(SidebarMainItem.defaultOrder[sidebarIndex + 1] == .feedarr)
        #expect(TabBarItem.defaultVisibility[.feedarr] == true)
        #expect(SidebarMainItem.defaultVisibility[.feedarr] == true)
        #if os(iOS)
        #expect(TabBarItem.feedarr.isAvailableOnCurrentPlatform)
        #expect(SidebarMainItem.feedarr.isAvailableOnCurrentPlatform)
        #else
        #expect(!TabBarItem.feedarr.isAvailableOnCurrentPlatform)
        #expect(!SidebarMainItem.feedarr.isAvailableOnCurrentPlatform)
        #endif
    }

    @Test("Legacy compact order is merged without moving or hiding existing tabs")
    func legacyCompactPreferences() throws {
        let settings = SettingsManager()
        let order = TabBarItem.defaultOrder.filter { $0 != .feedarr }.reversed().map { $0 }
        let visibility = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset % 2 == 0) })
        try withPreferences(settings, values: [
            .tabBarItemOrder: JSONEncoder().encode(order),
            .tabBarItemVisibility: JSONEncoder().encode(visibility)
        ]) {
            #expect(settings.tabBarItemOrder.filter { $0 != .feedarr } == order)
            for item in order { #expect(settings.tabBarItemVisibility[item] == visibility[item]) }
            #expect(settings.tabBarItemVisibility[.feedarr] == true)
            let visible = settings.visibleTabBarItems()
            #expect(visible.filter { $0 != .feedarr } == order.filter { visibility[$0] == true && $0.isAvailableOnCurrentPlatform })
        }
    }

    @Test("Legacy sidebar order and explicit visibility survive the new item")
    func legacySidebarPreferences() throws {
        let settings = SettingsManager()
        let order = SidebarMainItem.defaultOrder.filter { $0 != .feedarr }.reversed().map { $0 }
        let visibility = Dictionary(uniqueKeysWithValues: order.map { ($0, $0 != .iptv && $0 != .hub) })
        try withPreferences(settings, values: [
            .sidebarMainItemOrder: JSONEncoder().encode(order),
            .sidebarMainItemVisibility: JSONEncoder().encode(visibility)
        ]) {
            #expect(settings.sidebarMainItemOrder.filter { $0 != .feedarr } == order)
            for item in order { #expect(settings.sidebarMainItemVisibility[item] == visibility[item]) }
            #expect(settings.sidebarMainItemVisibility[.feedarr] == true)
        }
    }

    @Test("An explicitly hidden Feedarr stays hidden and cannot be the effective startup tab")
    func explicitHiddenPreference() throws {
        let settings = SettingsManager()
        try withPreferences(settings, values: [
            .tabBarItemOrder: JSONEncoder().encode(TabBarItem.defaultOrder),
            .tabBarItemVisibility: JSONEncoder().encode([TabBarItem.feedarr: false]),
            .sidebarMainItemVisibility: JSONEncoder().encode([SidebarMainItem.feedarr: false])
        ]) {
            settings._tabBarStartupTab = .feedarr
            settings._sidebarStartupTab = .feedarr
            #expect(!settings.visibleTabBarItems().contains(.feedarr))
            #expect(!settings.visibleSidebarMainItems().contains(.feedarr))
            #expect(settings.effectiveStartupTabForTabBar() == .home)
            #expect(settings.effectiveStartupTabForSidebar() == .home)
        }
    }

    @Test("Visible Feedarr can be the startup tab only on iOS")
    func feedarrStartup() {
        let settings = SettingsManager()
        settings._tabBarItemOrder = TabBarItem.defaultOrder
        settings._tabBarItemVisibility = TabBarItem.defaultVisibility
        settings._sidebarMainItemOrder = SidebarMainItem.defaultOrder
        settings._sidebarMainItemVisibility = SidebarMainItem.defaultVisibility
        settings._tabBarStartupTab = .feedarr
        settings._sidebarStartupTab = .feedarr
        #if os(iOS)
        #expect(settings.effectiveStartupTabForTabBar() == .feedarr)
        #expect(settings.effectiveStartupTabForSidebar() == .feedarr)
        #else
        #expect(settings.effectiveStartupTabForTabBar() == .home)
        #expect(settings.effectiveStartupTabForSidebar() == .home)
        #endif
    }

    private func withPreferences(
        _ settings: SettingsManager,
        values: [SettingsKey: Data],
        body: () throws -> Void
    ) rethrows {
        let defaults = settings.localDefaults
        let previous = values.keys.map { (settings.platformKey($0), defaults.object(forKey: settings.platformKey($0))) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (key, value) in values { defaults.set(value, forKey: settings.platformKey(key)) }
        try body()
    }
}

#if os(iOS)
@Suite("Feedarr Root Navigation")
@MainActor
struct FeedarrRootNavigationTests {
    @Test("A new root starts on Top 24h")
    func initialPage() {
        #expect(FeedarrNavigationState().selectedPage == .top)
        #expect(FeedarrPage.allCases == [.top, .releases])
    }

    @Test("The same root state retains its selected segment")
    func selectionIsRetained() {
        let state = FeedarrNavigationState()
        state.selectedPage = .releases
        let retained = state
        #expect(retained.selectedPage == .releases)
        retained.selectedPage = .top
        #expect(state.selectedPage == .top)
    }

    @Test("Adding and removing a local source changes root presentation without network")
    func configurationTransition() throws {
        let persistence = NavigationPersistence()
        let store = NavigationCredentials()
        let manager = FeedarrSourcesManager(persistence: persistence, credentialsStore: store)
        #expect(FeedarrRootPresentation(source: manager.source, loadError: manager.loadError) == .unconfigured)
        let source = try manager.add(name: "Local", serverURL: "http://feedarr.invalid", usesBasicAuth: false)
        #expect(FeedarrRootPresentation(source: manager.source, loadError: manager.loadError) == .configured)
        try manager.remove(id: source.id)
        #expect(FeedarrRootPresentation(source: manager.source, loadError: manager.loadError) == .unconfigured)
        #expect(store.writes == 0)
    }

    @Test("A loading error is never presented as an empty configuration")
    func corruptConfiguration() {
        let persistence = NavigationPersistence()
        persistence.failLoad = true
        let manager = FeedarrSourcesManager(persistence: persistence, credentialsStore: NavigationCredentials())
        #expect(FeedarrRootPresentation(source: manager.source, loadError: manager.loadError)
                == .configurationError(.persistenceFailure))
        #expect(persistence.saves == 0)
    }

    @Test("Missing credentials are visible even when source metadata exists")
    func missingCredentials() throws {
        let source = try FeedarrSource(name: "Private", serverURL: "https://feedarr.invalid", usesBasicAuth: true)
        let persistence = NavigationPersistence()
        persistence.source = source
        let manager = FeedarrSourcesManager(persistence: persistence, credentialsStore: NavigationCredentials())
        #expect(FeedarrRootPresentation(source: manager.source, loadError: manager.loadError)
                == .configurationError(.missingCredentials))
    }
}

@MainActor private final class NavigationPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    var failLoad = false
    var saves = 0
    func loadSource() throws -> FeedarrSource? {
        if failLoad { throw FeedarrSourcesManagerError.persistenceFailure }
        return source
    }
    func saveSource(_ source: FeedarrSource?) throws {
        saves += 1
        self.source = source
    }
}

@MainActor private final class NavigationCredentials: FeedarrCredentialsStoring {
    var writes = 0
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { nil }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { writes += 1 }
    func deleteCredentials(for sourceID: UUID) throws {}
}
#endif

@Suite("Feedarr Static Navigation Contracts")
struct FeedarrNavigationContractTests {
    @Test("Both iOS navigation containers host the same isolated Feedarr root")
    func iOSRootIntegration() throws {
        let compact = try source("Yattee/Views/Navigation/CompactTabView.swift")
        let unified = try source("Yattee/Views/Navigation/UnifiedTabView.swift")
        #expect(compact.contains("case .feedarr:\n            NavigationStack {\n                FeedarrRootView()"))
        #expect(unified.contains("Tab(value: SidebarItem.feedarr)"))
        #expect(unified.components(separatedBy: "FeedarrRootView()").count - 1 == 1)
        #expect(!compact.contains("feedarrPath"))
        #expect(!unified.contains("feedarrPath"))
    }

    @Test("Global destinations fall back to Home instead of entering Feedarr")
    func globalRoutingFallback() throws {
        let compact = try source("Yattee/Views/Navigation/CompactTabView.swift")
        let unified = try source("Yattee/Views/Navigation/UnifiedTabView.swift")
        #expect(compact.contains("case TabBarItem.feedarr.rawValue:\n            // Feedarr never hosts global video destinations.\n            selectedTab = \"home\"\n            homePath.append(destination)"))
        #expect(unified.contains("case .feedarr:\n            // Preserve the Home fallback instead of pushing video routes into Feedarr.\n            selection = .home\n            homePath.append(destination)"))
    }

    @Test("The root only presents local placeholders and the existing configuration form")
    func noAutomaticNetworkOrPlayback() throws {
        let root = try source("Yattee/Views/Feedarr/FeedarrRootView.swift")
        #expect(root.contains("AddFeedarrSourceView("))
        #expect(root.contains("placeholder(for: .top)"))
        #expect(root.contains("placeholder(for: .releases)"))
        #expect(!root.contains("URLSession"))
        #expect(!root.contains(".validate("))
        #expect(!root.contains(".task"))
        #expect(!root.contains("playerService"))
        #expect(!root.contains("queueManager"))
        #expect(!root.contains(".withNavigationDestinations()"))
    }

    @Test("Mini-player ownership remains in existing navigation hosts")
    func miniPlayerHostsArePreserved() throws {
        let compact = try source("Yattee/Views/Navigation/CompactTabView.swift")
        let unified = try source("Yattee/Views/Navigation/UnifiedTabView.swift")
        let root = try source("Yattee/Views/Feedarr/FeedarrRootView.swift")
        #expect(compact.contains("shouldShowAccessory: shouldShowAccessory && usesMiniPlayerAccessory"))
        #expect(unified.contains("MiniPlayerView(isTabAccessory: true)"))
        #expect(!root.contains("MiniPlayer"))
        #expect(!root.contains(".id("))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
