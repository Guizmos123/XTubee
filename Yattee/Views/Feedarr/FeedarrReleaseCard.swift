//
//  FeedarrReleaseCard.swift
//  Yattee
//
//  Passive, reusable catalogue card; all artwork uses the Feedarr pipeline.
//

import Foundation
import SwiftUI

struct FeedarrReleaseCard: View {
    let release: FeedarrRelease
    let posterService: FeedarrPosterService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedarrPosterView(release: release, service: posterService)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if reduceMotion {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarqueeText(text: title, delayBeforeScrolling: 0)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        [release.titleClean, release.title].compactMap { $0 }.first { !$0.isEmpty }
            ?? AppLocalization.string("feedarr.top.untitled")
    }

    private var secondary: String {
        [release.year.map(String.init), release.resolution].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
