//
//  FeedarrHomePreferencesTests.swift
//  Yattee
//
//  Feedarr sections retain independent Home/Hub order and presentation settings.
//

import Foundation
import SwiftUI
import Testing
@testable import XTubee

@Suite("Feedarr Home Preferences")
struct FeedarrHomePreferencesTests {
    @Test func independentSectionsRoundTrip() throws {
        let sections = FeedarrHomeSection.allCases.map { HomeSectionItem.feedarr($0) }
        let home = HomePresentationSettings(
            shortcutLayout: .cards, shortcutCardStyle: .regular, shortcutCardColor: .soft,
            shortcutColorfulPalette: .accent, shortcutCustomPaletteColors: [],
            shortcutOrder: [], shortcutVisibility: [:],
            sectionOrder: [.history] + sections,
            sectionVisibility: [.history: true, .feedarr(.global): true, .feedarr(.films): false, .feedarr(.series): true],
            sectionItemsLimit: 1, sectionLayout: .list
        )
        var hub = home
        hub.sectionOrder = [.feedarr(.films), .feedarr(.global)]
        hub.sectionVisibility[.feedarr(.films)] = true
        hub.sectionItemsLimit = 20
        hub.sectionLayout = .large
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let savedHome = try decoder.decode(HomePresentationSettings.self, from: encoder.encode(home))
        let savedHub = try decoder.decode(HomePresentationSettings.self, from: encoder.encode(hub))
        #expect(savedHome == home)
        #expect(savedHub == hub)
        #expect(savedHome.visibleSections == [.history, .feedarr(.global), .feedarr(.series)])
        #expect(savedHub.visibleSections == [.feedarr(.films), .feedarr(.global)])
        #expect(savedHome.sectionItemsLimit == 1)
        #expect(savedHub.sectionItemsLimit == 20)
        for layout in HomeSectionLayout.allCases {
            hub.sectionLayout = layout
            #expect(try decoder.decode(HomePresentationSettings.self, from: encoder.encode(hub)).sectionLayout == layout)
        }
    }

    @Test func existingPreferencesAndDefaultsRemainUnchanged() throws {
        let oldJSON = Data("[{\"type\":\"history\"},{\"type\":\"feed\"}]".utf8)
        #expect(try JSONDecoder().decode([HomeSectionItem].self, from: oldJSON) == [.history, .feed])
        for kind in FeedarrHomeSection.allCases {
            #expect(!HomeSectionItem.defaultOrder.contains(.feedarr(kind)))
            #expect(HomeSectionItem.defaultVisibility[.feedarr(kind)] == nil)
        }
        #expect(Set(FeedarrHomeSection.allCases.map { HomeSectionItem.feedarr($0).id }).count == 3)
    }
    @Test func legacyPresentationMigratesWithoutLosingOrderOrVisibility() throws {
        let legacy = legacyPresentation()
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["feedarrPresentation"] == nil)
        let decoded = try decoder.decode(HomePresentationSettings.self, from: data)
        var migrated = decoded.migratingFeedarrPresentation()
        #expect(migrated.feedarrPresentation == FeedarrHomePresentation(layout: .large, itemsLimit: 12))
        #expect(migrated.sectionOrder == legacy.sectionOrder)
        #expect(migrated.sectionVisibility == legacy.sectionVisibility)
        migrated.sectionLayout = .grid
        migrated.sectionItemsLimit = 1
        #expect(migrated.resolvedFeedarrPresentation == FeedarrHomePresentation(layout: .large, itemsLimit: 12))
        #expect(try decoder.decode(HomePresentationSettings.self, from: encoder.encode(migrated)) == migrated)
    }

    @Test func youtubeFeedarrAndPagePreferencesAreIndependent() throws {
        var home = legacyPresentation().migratingFeedarrPresentation()
        var hub = home
        home.feedarrPresentation = FeedarrHomePresentation(layout: .grid, itemsLimit: 20)
        hub.sectionLayout = .list
        hub.sectionItemsLimit = 2
        hub.feedarrPresentation = FeedarrHomePresentation(layout: .list, itemsLimit: 3)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let savedHome = try decoder.decode(HomePresentationSettings.self, from: encoder.encode(home))
        let savedHub = try decoder.decode(HomePresentationSettings.self, from: encoder.encode(hub))
        #expect(savedHome.sectionLayout == .large)
        #expect(savedHome.sectionItemsLimit == 12)
        #expect(savedHome.resolvedFeedarrPresentation == FeedarrHomePresentation(layout: .grid, itemsLimit: 20))
        #expect(savedHub.sectionLayout == .list)
        #expect(savedHub.sectionItemsLimit == 2)
        #expect(savedHub.resolvedFeedarrPresentation == FeedarrHomePresentation(layout: .list, itemsLimit: 3))
    }

    @Test func absentSourceHidesEditorWithoutRemovingPreferences() throws {
        let saved = legacyPresentation().migratingFeedarrPresentation()
        #expect(HomeSectionItem.customizationSections(in: saved.sectionOrder, feedarr: true, sourceConfigured: false).isEmpty)
        #expect(HomeSectionItem.customizationSections(in: saved.sectionOrder, feedarr: false, sourceConfigured: false) == [.history, .bookmarks])
        #expect(HomeSectionItem.customizationSections(in: saved.sectionOrder, feedarr: true, sourceConfigured: true) == [.feedarr(.global), .feedarr(.films), .feedarr(.series)])
        #expect(saved.visibleSections == [.history, .feedarr(.global), .bookmarks, .feedarr(.series)])
        #expect(saved.resolvedFeedarrPresentation.itemsLimit == 12)
    }

    @Test func groupReorderingPreservesOtherSlotsAndGlobalOrderCanInterleave() {
        let order = legacyPresentation().sectionOrder
        let moved = HomeSectionItem.reorderedGroup(in: order, feedarr: true, from: IndexSet(integer: 2), to: 0)
        #expect(moved == [.history, .feedarr(.series), .bookmarks, .feedarr(.global), .feedarr(.films)])
        let youtubeMoved = HomeSectionItem.reorderedGroup(in: moved, feedarr: false, from: IndexSet(integer: 0), to: 2)
        #expect(youtubeMoved == [.bookmarks, .feedarr(.series), .history, .feedarr(.global), .feedarr(.films)])
        var global = order
        global.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(global == [.feedarr(.series), .history, .feedarr(.global), .bookmarks, .feedarr(.films)])
    }

    @Test func addedAndAvailableFeedarrSectionsNeverOverlap() {
        var order: [HomeSectionItem] = [.history, .feedarr(.global)]
        #expect(HomeSectionItem.availableFeedarrSections(in: order) == [.feedarr(.films), .feedarr(.series)])
        let added = HomeSectionItem.customizationSections(in: order, feedarr: true, sourceConfigured: true)
        #expect(Set(added).isDisjoint(with: HomeSectionItem.availableFeedarrSections(in: order)))
        order.append(.feedarr(.films))
        #expect(HomeSectionItem.availableFeedarrSections(in: order) == [.feedarr(.series)])
        order.removeAll { $0 == .feedarr(.global) }
        #expect(HomeSectionItem.availableFeedarrSections(in: order) == [.feedarr(.global), .feedarr(.series)])
    }

    @Test func movingVisibleSectionsPreservesHiddenPositionsAndVisibility() throws {
        var presentation = legacyPresentation().migratingFeedarrPresentation()
        presentation.sectionVisibility[.bookmarks] = false
        presentation.sectionVisibility[.feedarr(.series)] = false
        let visibility = presentation.sectionVisibility
        #expect(presentation.visibleSections == [.history, .feedarr(.global)])
        presentation.sectionOrder = HomeSectionItem.reorderedVisible(
            in: presentation.sectionOrder, visibility: visibility, from: IndexSet(integer: 1), to: 0)
        #expect(presentation.visibleSections == [.feedarr(.global), .history])
        #expect(presentation.sectionOrder == [.feedarr(.global), .history, .bookmarks, .feedarr(.films), .feedarr(.series)])
        #expect(presentation.sectionVisibility == visibility)
        presentation.sectionVisibility[.bookmarks] = true
        #expect(presentation.visibleSections == [.feedarr(.global), .history, .bookmarks])
        let saved = try JSONDecoder().decode(HomePresentationSettings.self, from: JSONEncoder().encode(presentation))
        #expect(saved == presentation)
    }

    @Test func visibleOrderChangesPersistIndependentlyForHomeAndHub() throws {
        let home = legacyPresentation().migratingFeedarrPresentation()
        var hub = home
        hub.sectionOrder = HomeSectionItem.reorderedVisible(
            in: hub.sectionOrder, visibility: hub.sectionVisibility, from: IndexSet(integer: 3), to: 0)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let savedHome = try decoder.decode(HomePresentationSettings.self, from: encoder.encode(home))
        let savedHub = try decoder.decode(HomePresentationSettings.self, from: encoder.encode(hub))
        #expect(savedHome.sectionOrder == home.sectionOrder)
        #expect(savedHub.visibleSections == [.feedarr(.series), .history, .feedarr(.global), .bookmarks])
        #expect(savedHome.sectionVisibility == savedHub.sectionVisibility)
        #expect(savedHub.sectionOrder[3] == .feedarr(.films))
    }

    private func legacyPresentation() -> HomePresentationSettings {
        HomePresentationSettings(
            shortcutLayout: .cards, shortcutCardStyle: .regular, shortcutCardColor: .soft,
            shortcutColorfulPalette: .accent, shortcutCustomPaletteColors: [],
            shortcutOrder: [], shortcutVisibility: [:],
            sectionOrder: [.history, .feedarr(.global), .bookmarks, .feedarr(.films), .feedarr(.series)],
            sectionVisibility: [.history: true, .bookmarks: true, .feedarr(.global): true, .feedarr(.films): false, .feedarr(.series): true],
            sectionItemsLimit: 12, sectionLayout: .large
        )
    }

}
