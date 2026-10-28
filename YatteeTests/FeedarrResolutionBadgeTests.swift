//
//  FeedarrResolutionBadgeTests.swift
//  Yattee
//
//  Quality badge mapping and preservation of the actual catalogue value.
//

import Foundation
import SwiftUI
import Testing
@testable import XTubee

@Suite("Feedarr Resolution Badges")
struct FeedarrResolutionBadgeTests {
    @Test func knownQualitiesUseRequestedColors() {
        let cases: [(String, FeedarrResolutionBadgeStyle, Color)] = [
            ("720p", .hd, .green), ("1080p", .fullHD, .blue),
            ("2160p", .ultraHD, .purple), ("4K", .ultraHD, .purple),
            ("480p", .sd, .gray), ("SD", .sd, .gray)
        ]
        for (value, expected, color) in cases {
            let style = FeedarrResolutionBadgeStyle(resolution: value)
            #expect(style == expected)
            #expect(style.tint == color)
        }
    }

    @Test func classificationIgnoresCaseAndPeripheralWhitespace() {
        #expect(FeedarrResolutionBadgeStyle(resolution: " \n1080P ") == .fullHD)
        #expect(FeedarrResolutionBadgeStyle(resolution: "4k") == .ultraHD)
        #expect(FeedarrResolutionBadgeStyle(resolution: " sd\t") == .sd)
    }

    @Test func unknownValuesRemainNeutralAndUnchanged() throws {
        for value in ["4320p HDR", "1080i", "custom-quality"] {
            #expect(FeedarrResolutionBadgeStyle(resolution: value) == .neutral)
        }
        let data = Data(#"{"id":1,"sourceId":2,"resolution":"4320p HDR"}"#.utf8)
        let release = try JSONDecoder().decode(FeedarrRelease.self, from: data)
        let rows = FeedarrReleaseDetailMetadata(release: release).releaseRows
        #expect(rows.first { $0.id == "feedarr.detail.resolution" }?.value == "4320p HDR")
        #expect(FeedarrResolutionBadgeStyle.neutral.tint == .secondary)
    }
}
