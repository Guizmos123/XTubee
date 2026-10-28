//
//  FeedarrTracker.swift
//  Yattee
//
//  Minimal GET /api/sources projection. URLs, authentication and provider fields are discarded.
//

import Foundation

struct FeedarrTracker: Identifiable, Codable, Hashable, Sendable {
    let id: Int64
    let name: String
    let color: String?

    var badgeColor: FeedarrTrackerColor? { FeedarrTrackerColor(hex: color) }
}

/// Same six-digit RGB input normalization as Feedarr's sourceColors.js.
struct FeedarrTrackerColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String?) {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(value, radix: 16) else { return nil }
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
    }

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The stronger black/white contrast is always at least 4.5:1 on this opaque RGB background.
    var usesDarkText: Bool { (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) }
}
