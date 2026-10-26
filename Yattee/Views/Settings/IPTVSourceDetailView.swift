//
//  IPTVSourceDetailView.swift
//  Yattee
//
//  Displays and manages one configured Xtream IPTV source.
//

import Foundation
import SwiftUI

struct IPTVSourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    let sourceID: UUID

    @State private var account: XtreamValidatedAccount?
    @State private var maskedUsername: String?
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var catalogSyncService: IPTVLiveCatalogSyncService?

    private var source: IPTVSource? {
        appEnvironment?.iptvSourcesManager.sources.first { $0.id == sourceID }
    }

    private var isActive: Bool {
        appEnvironment?.iptvSourcesManager.activeSourceID == sourceID
    }

    var body: some View {
        Form {
            if let source {
                identitySection(source)
                accountSection
                actionsSection(source)
            } else {
                ContentUnavailableView(
                    AppLocalization.string("sources.iptv.detail.unavailable"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        .reactiveNavigationTitle(AppLocalization.string("sources.iptv.detail.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            sheetCloseToolbarItem(identifier: "iptvSourceDetail.closeButton") {
                refreshTask?.cancel()
                dismiss()
            }
        }
        .task(id: sourceID) {
            prepareCatalogCache()
            startRefresh()
        }
        .onDisappear {
            refreshTask?.cancel()
        }
        .sheet(isPresented: $showingEditSheet, onDismiss: {
            startRefresh(refreshCatalog: true)
        }) {
            NavigationStack {
                if let source {
                    AddIPTVSourceView(editingSource: source)
                }
            }
            .presentationCompactAdaptation(.sheet)
        }
        .confirmationDialog(
            source.map {
                AppLocalization.string("sources.delete.confirmation.single \($0.name)")
            } ?? AppLocalization.string("sources.delete.confirmation"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("common.delete"), role: .destructive) {
                deleteSource()
            }
            Button(AppLocalization.string("common.cancel"), role: .cancel) {}
        }
    }

    private func identitySection(_ source: IPTVSource) -> some View {
        Section {
            detailRow(
                AppLocalization.string("sources.field.name"),
                icon: "textformat",
                value: source.name
            )
            detailRow(
                AppLocalization.string("sources.iptv.detail.host"),
                icon: "network",
                value: source.serverURL.host ?? notProvided
            )
            detailRow(
                AppLocalization.string("sources.field.username"),
                icon: "person.crop.circle",
                value: maskedUsername ?? notProvided
            )
        } header: {
            Label(AppLocalization.string("sources.iptv.section.source"), systemImage: "play.tv")
        }
    }

    private var accountSection: some View {
        Section {
            if isRefreshing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalization.string("sources.iptv.status.verifying"))
                }
            }

            detailRow(
                AppLocalization.string("sources.iptv.field.status"),
                icon: "checkmark.circle",
                value: account?.status ?? notProvided,
                valueColor: statusColor,
                showsBadge: account != nil
            )
            detailRow(
                AppLocalization.string("sources.iptv.field.expires"),
                icon: "calendar",
                value: account?.expirationDate?.formatted(date: .abbreviated, time: .omitted) ?? notProvided,
                valueColor: expirationColor,
                showsBadge: account?.expirationDate != nil
            )
            detailRow(
                AppLocalization.string("sources.iptv.detail.activeConnections"),
                icon: "person.2",
                value: account?.activeConnections.map { String($0) } ?? notProvided
            )
            detailRow(
                AppLocalization.string("sources.iptv.detail.maxConnections"),
                icon: "person.3",
                value: account?.maxConnections.map { String($0) } ?? notProvided
            )
            detailRow(
                AppLocalization.string("sources.iptv.detail.channels"),
                icon: "tv",
                value: streamCountDescription
            )
            detailRow(
                AppLocalization.string("sources.iptv.field.formats"),
                icon: "play.rectangle.on.rectangle",
                value: formatsDescription
            )

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Label(AppLocalization.string("sources.iptv.section.account"), systemImage: "person.badge.key")
        }
    }

    private func detailRow(
        _ title: String,
        icon: String,
        value: String,
        valueColor: Color = .secondary,
        showsBadge: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .padding(.horizontal, showsBadge ? 8 : 0)
                .padding(.vertical, showsBadge ? 4 : 0)
                .background {
                    if showsBadge {
                        Capsule().fill(valueColor.opacity(0.12))
                    }
                }
        }
    }

    private func actionsSection(_ source: IPTVSource) -> some View {
        Section {
            Button {
                startRefresh(refreshCatalog: true)
            } label: {
                Label(AppLocalization.string("common.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)

            Button {
                showingEditSheet = true
            } label: {
                Label(AppLocalization.string("common.edit"), systemImage: "pencil")
            }
            .disabled(isRefreshing)

            if !isActive {
                Button {
                    setActive(source)
                } label: {
                    Label(
                        AppLocalization.string("sources.iptv.action.setActive"),
                        systemImage: "checkmark.circle"
                    )
                }
            }

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(AppLocalization.string("common.delete"), systemImage: "trash")
            }
        }
    }

    private var notProvided: String {
        AppLocalization.string("sources.iptv.detail.notProvided")
    }

    private var formatsDescription: String {
        guard let formats = account?.allowedOutputFormats, !formats.isEmpty else {
            return notProvided
        }
        return formats.joined(separator: ", ")
    }

    private var streamCountDescription: String {
        guard let catalog = catalogSyncService?.state(for: sourceID).catalog else {
            return AppLocalization.string("sources.iptv.detail.unavailableValue")
        }
        return String(catalog.streams.count)
    }

    private var statusColor: Color {
        guard let status = account?.status.lowercased() else { return .secondary }
        switch status {
        case "active":
            return .green
        case "inactive", "expired":
            return .red
        default:
            return .secondary
        }
    }

    private var expirationColor: Color {
        guard let expirationDate = account?.expirationDate else { return .secondary }
        let calendar = Calendar.current
        let expirationDay = calendar.startOfDay(for: expirationDate)
        let today = calendar.startOfDay(for: Date())
        return expirationDay > today ? .green : .red
    }

    private func startRefresh(refreshCatalog: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task {
            if refreshCatalog, let catalogSyncService {
                async let accountRefresh: Void = refresh()
                async let catalogRefresh: Void = catalogSyncService.refresh(sourceID: sourceID)
                _ = await (accountRefresh, catalogRefresh)
            } else {
                await refresh()
            }
            refreshTask = nil
        }
    }

    private func prepareCatalogCache() {
        guard catalogSyncService == nil,
              let environment = appEnvironment else {
            return
        }
        let service = IPTVLiveCatalogSyncService(
            sourcesManager: environment.iptvSourcesManager,
            credentialsStore: environment.xtreamCredentialsStore
        )
        service.loadCachedCatalog(sourceID: sourceID)
        catalogSyncService = service
    }

    @MainActor
    private func refresh() async {
        guard let source,
              let credentialsStore = appEnvironment?.xtreamCredentialsStore else {
            return
        }

        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            guard let credentials = try credentialsStore.credentials(for: source.id) else {
                account = nil
                maskedUsername = nil
                errorMessage = AppLocalization.string("sources.iptv.error.credentialsUnavailable")
                return
            }

            maskedUsername = Self.mask(credentials.username)
            account = try await XtreamAccountValidator().validate(
                serverURL: source.serverURL,
                username: credentials.username,
                password: credentials.password
            )
        } catch is CancellationError {
            return
        } catch let error as XtreamAccountValidationError {
            account = nil
            if error != .cancelled {
                errorMessage = error.localizedDescription
            }
        } catch {
            account = nil
            errorMessage = AppLocalization.string("sources.iptv.error.credentialsUnavailable")
        }
    }

    private func setActive(_ source: IPTVSource) {
        do {
            try appEnvironment?.iptvSourcesManager.setActive(id: source.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSource() {
        do {
            try appEnvironment?.iptvSourcesManager.remove(id: sourceID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func mask(_ username: String) -> String {
        guard !username.isEmpty else { return "" }
        let characters = Array(username)
        guard characters.count > 2 else {
            return String(repeating: "•", count: characters.count)
        }
        return "\(characters.first!)\(String(repeating: "•", count: characters.count - 2))\(characters.last!)"
    }
}
