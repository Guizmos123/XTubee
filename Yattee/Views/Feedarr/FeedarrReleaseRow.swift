//
//  FeedarrReleaseRow.swift
//  Yattee
//
//  Three poster-based row sizes using the existing authenticated artwork pipeline.
//

import Foundation
import SwiftUI

struct FeedarrReleaseRow: View {
    let release: FeedarrRelease
    let posterService: FeedarrPosterService
    let style: VideoRowStyle
    var onSelectRelease: ((FeedarrRelease) -> Void)? = nil

    private var posterWidth: CGFloat {
        switch style {
        case .compact: 52
        case .regular: 76
        case .large: 104
        }
    }

    private var title: String {
        nonBlank(release.titleClean) ?? nonBlank(release.title) ?? AppLocalization.string("feedarr.top.untitled")
    }

    private var category: String? {
        nonBlank(release.unifiedCategoryLabel) ?? nonBlank(release.categoryName) ?? nonBlank(release.unifiedCategory)
    }

    private var characteristics: String {
        [release.year.flatMap { $0 > 0 ? String($0) : nil }, nonBlank(release.resolution), nonBlank(release.codec)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        if let onSelectRelease {
            Button { onSelectRelease(release) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            FeedarrPosterView(release: release, service: posterService)
                .frame(width: posterWidth)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: style == .compact ? 4 : 6) {
                Text(title)
                    .font(style == .large ? .headline : .subheadline.weight(.medium))
                    .lineLimit(style == .compact ? 2 : style == .regular ? 3 : 4)
                    .foregroundStyle(.primary)
                if style != .compact, let category {
                    Text(category).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !characteristics.isEmpty {
                    Text(characteristics).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if style != .compact, let bytes = release.sizeBytes, bytes >= 0 {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if style == .large {
                    if let group = nonBlank(release.releaseGroup) {
                        Text(group).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let timestamp = release.publishedAt, timestamp >= 0,
                       Double(timestamp) <= Date.distantFuture.timeIntervalSince1970 {
                        Text(Date(timeIntervalSince1970: Double(timestamp)), format: .dateTime.day().month().year())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
