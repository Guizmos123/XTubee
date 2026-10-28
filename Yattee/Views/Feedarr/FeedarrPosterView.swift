//
//  FeedarrPosterView.swift
//  Yattee
//
//  Reusable poster surface; loading follows the SwiftUI view's task lifetime.
//

import Foundation
import SwiftUI

struct FeedarrPosterView: View {
    let release: FeedarrRelease
    let service: FeedarrPosterService
    var aspectRatio: CGFloat = 2.0 / 3.0

    @State private var image: Image?
    @State private var loadedGeneration: UUID?
    @State private var failed = false

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(aspectRatio > 0 && aspectRatio.isFinite ? aspectRatio : 2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image, loadedGeneration == service.generation {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: LoadID(releaseID: release.id, posterURL: release.posterUrl, generation: service.generation)) {
                image = nil
                loadedGeneration = nil
                failed = false
                guard let url = release.posterUrl, !url.isEmpty else { return }
                do {
                    let poster = try await service.image(for: release)
                    try Task.checkCancellation()
                    #if canImport(UIKit)
                    image = Image(uiImage: poster)
                    #else
                    image = Image(nsImage: poster)
                    #endif
                    loadedGeneration = service.generation
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
            .onDisappear { image = nil; loadedGeneration = nil }
    }

    private struct LoadID: Equatable {
        let releaseID: Int64
        let posterURL: String?
        let generation: UUID
    }
}
