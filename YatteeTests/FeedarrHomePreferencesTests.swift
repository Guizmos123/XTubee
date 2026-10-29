//
//  FeedarrHomePreferencesTests.swift
//  Yattee
//
//  Feedarr sections retain independent Home/Hub order and presentation settings.
//

import Foundation
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
}
