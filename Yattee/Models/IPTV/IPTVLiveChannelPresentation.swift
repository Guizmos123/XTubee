//
//  IPTVLiveChannelPresentation.swift
//  Yattee
//
//  Prepares complete, ordered Xtream stream choices for a future interface.
//

import Foundation

enum IPTVLiveVariantQuality: Int, Codable, Hashable, Sendable {
    case ultraHD = 0
    case fullHD = 1
    case highDefinition = 2
    case standardDefinition = 3
    case unknown = 4

    var label: String {
        switch self {
        case .ultraHD: return "UHD"
        case .fullHD: return "FHD"
        case .highDefinition: return "HD"
        case .standardDefinition: return "SD"
        case .unknown: return "Qualité inconnue"
        }
    }
}

struct IPTVLiveVariantPresentation: Identifiable, Hashable, Sendable {
    struct ID: Codable, Hashable, Sendable {
        let groupID: IPTVLiveChannelGroup.ID
        let streamID: String
    }

    let id: ID
    let streamID: String
    let label: String
    let quality: IPTVLiveVariantQuality
    let usesHEVC: Bool
    let serverOrder: Int
    let variant: IPTVLiveChannelVariant
}

enum IPTVLiveVariantSelectionMode: Hashable, Sendable {
    case direct(IPTVLiveVariantPresentation.ID)
    case requiresExplicitChoice
}

struct IPTVLiveChannelPresentation: Identifiable, Hashable, Sendable {
    let id: IPTVLiveChannelGroup.ID
    let displayName: String
    let variants: [IPTVLiveVariantPresentation]
    let firstChoices: [IPTVLiveVariantPresentation]
    let additionalChoiceCount: Int
    let selectionMode: IPTVLiveVariantSelectionMode

    init(group: IPTVLiveChannelGroup) {
        id = group.id
        displayName = group.displayName

        let ordered = group.variants.enumerated()
            .map { serverOrder, variant in
                OrderedVariant(
                    variant: variant,
                    quality: Self.quality(for: variant.attributes.announcedResolution),
                    serverOrder: serverOrder
                )
            }
            .sorted {
                if $0.quality.rawValue == $1.quality.rawValue {
                    return $0.serverOrder < $1.serverOrder
                }
                return $0.quality.rawValue < $1.quality.rawValue
            }

        let qualityCounts = Dictionary(grouping: ordered, by: \.quality)
            .mapValues { $0.count }
        var qualityIndexes: [IPTVLiveVariantQuality: Int] = [:]

        let presentedVariants = ordered.map { orderedVariant in
            let quality = orderedVariant.quality
            let duplicateCount = qualityCounts[quality, default: 0]
            qualityIndexes[quality, default: 0] += 1
            let qualityIndex = qualityIndexes[quality, default: 1]
            let label = duplicateCount > 1
                ? "\(quality.label) · Flux \(qualityIndex)"
                : quality.label

            return IPTVLiveVariantPresentation(
                id: IPTVLiveVariantPresentation.ID(
                    groupID: group.id,
                    streamID: orderedVariant.variant.stream.streamID
                ),
                streamID: orderedVariant.variant.stream.streamID,
                label: label,
                quality: quality,
                usesHEVC: orderedVariant.variant.attributes.usesHEVC,
                serverOrder: orderedVariant.serverOrder,
                variant: orderedVariant.variant
            )
        }

        variants = presentedVariants
        let initialChoices = Array(presentedVariants.prefix(3))
        firstChoices = initialChoices
        additionalChoiceCount = max(0, presentedVariants.count - initialChoices.count)
        if let onlyVariant = presentedVariants.first, presentedVariants.count == 1 {
            selectionMode = .direct(onlyVariant.id)
        } else {
            selectionMode = .requiresExplicitChoice
        }
    }

    func variant(streamID: String) -> IPTVLiveVariantPresentation? {
        variants.first { $0.streamID == streamID }
    }

    private static func quality(
        for resolution: IPTVAnnouncedResolution?
    ) -> IPTVLiveVariantQuality {
        switch resolution {
        case .ultraHD4K: return .ultraHD
        case .fullHD: return .fullHD
        case .highDefinition: return .highDefinition
        case .standardDefinition: return .standardDefinition
        case nil: return .unknown
        }
    }

    private struct OrderedVariant {
        let variant: IPTVLiveChannelVariant
        let quality: IPTVLiveVariantQuality
        let serverOrder: Int
    }
}
