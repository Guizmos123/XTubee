//
//  AddIPTVSourceView.swift
//  Yattee
//
//  Native form for validating and adding an Xtream IPTV source.
//

import Foundation
import SwiftUI

// MARK: - Form Model

@MainActor
@Observable
final class AddIPTVSourceModel {
    enum State: Equatable {
        case ready
        case verifying
        case success(XtreamValidatedAccount)
        case failure(String)
    }

    struct ValidatedInput: Equatable {
        let serverURL: URL
        let username: String
        let password: String
    }

    typealias Validate = (URL, String, String) async throws -> XtreamValidatedAccount
    typealias AddSource = (String, String, String, String) throws -> IPTVSource

    var name: String
    var serverURL: String {
        didSet {
            guard oldValue != serverURL else { return }
            if Self.origin(oldValue) != Self.origin(serverURL) {
                hasChangedServerOrigin = true
                originRevision = UUID()
                username = ""
                password = ""
                validatedInput = nil
            }
            fieldsDidChange()
        }
    }
    var username = ""
    var password = ""
    private(set) var state: State = .ready

    @ObservationIgnored private let validateAccount: Validate
    @ObservationIgnored private var validatedInput: ValidatedInput?
    @ObservationIgnored private(set) var hasChangedServerOrigin = false
    @ObservationIgnored private var originRevision = UUID()

    init(
        prefillName: String = "",
        prefillServerURL: String = "",
        validateAccount: @escaping Validate = { serverURL, username, password in
            try await XtreamAccountValidator().validate(
                serverURL: serverURL,
                username: username,
                password: password
            )
        }
    ) {
        name = prefillName
        serverURL = prefillServerURL
        self.validateAccount = validateAccount
    }

    var isVerifying: Bool {
        state == .verifying
    }

    var canVerify: Bool {
        !trimmedName.isEmpty
            && !trimmedServerURL.isEmpty
            && !username.isEmpty
            && !password.isEmpty
            && !isVerifying
    }

    var canSave: Bool {
        guard case .success = state,
              let validatedInput,
              let currentInput = try? normalizedInput() else {
            return false
        }
        return currentInput == validatedInput && !trimmedName.isEmpty
    }

    func fieldsDidChange() {
        guard !isVerifying else { return }
        validatedInput = nil
        state = .ready
    }

    func showFailure(_ message: String) {
        validatedInput = nil
        state = .failure(message)
    }

    func verify() async {
        guard canVerify else {
            state = .failure(AppLocalization.string("sources.iptv.error.completeFields"))
            return
        }

        let input: ValidatedInput
        do {
            input = try normalizedInput()
        } catch {
            state = .failure(AppLocalization.string("sources.iptv.error.invalidURL"))
            return
        }

        let revision = originRevision
        state = .verifying
        do {
            let account = try await validateAccount(
                input.serverURL,
                input.username,
                input.password
            )
            try Task.checkCancellation()

            guard revision == originRevision, (try? normalizedInput()) == input else {
                state = .ready
                return
            }
            validatedInput = input
            state = .success(account)
        } catch is CancellationError {
            state = .ready
        } catch let error as XtreamAccountValidationError {
            validatedInput = nil
            state = .failure(error.localizedDescription)
        } catch {
            validatedInput = nil
            state = .failure(AppLocalization.string("sources.iptv.error.validationFailed"))
        }
    }

    @discardableResult
    func save(using addSource: AddSource) throws -> IPTVSource {
        guard canSave, let validatedInput else {
            throw IPTVSourcesManagerError.credentialFailure
        }

        do {
            return try addSource(
                trimmedName,
                validatedInput.serverURL.absoluteString,
                validatedInput.username,
                validatedInput.password
            )
        } catch let error as IPTVSourcesManagerError {
            state = .failure(error.localizedDescription)
            throw error
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedInput() throws -> ValidatedInput {
        ValidatedInput(
            serverURL: try XtreamServerURL.normalize(trimmedServerURL),
            username: username,
            password: password
        )
    }

    private static func origin(_ value: String) -> String? {
        guard let url = try? XtreamServerURL.normalize(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

// MARK: - View

struct AddIPTVSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    @State private var model: AddIPTVSourceModel
    @State private var validationTask: Task<Void, Never>?
    @State private var didLoadEditingCredentials = false
    private let dismissSheet: DismissAction?
    private let editingSource: IPTVSource?

    init(
        prefillName: String = "",
        prefillServerURL: String = "",
        dismissSheet: DismissAction? = nil,
        editingSource: IPTVSource? = nil
    ) {
        self.dismissSheet = dismissSheet
        self.editingSource = editingSource
        _model = State(
            initialValue: AddIPTVSourceModel(
                prefillName: editingSource?.name ?? prefillName,
                prefillServerURL: editingSource?.serverURL.absoluteString ?? prefillServerURL
            )
        )
    }

    var body: some View {
        Form {
            sourceSection
            credentialsSection
            statusSection
            actionSection
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .reactiveNavigationTitle(
            AppLocalization.string(
                editingSource == nil ? "sources.addIPTVServer" : "sources.iptv.edit.title"
            )
        )
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            sheetCloseToolbarItem(identifier: "addIPTVSource.closeButton") {
                validationTask?.cancel()
                dismiss()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        .onDisappear {
            validationTask?.cancel()
        }
        .task {
            loadEditingCredentialsIfNeeded()
        }
    }

    private var sourceSection: some View {
        Section {
            TextField(AppLocalization.string("sources.field.name"), text: $model.name)
                .textContentType(.name)
                .disabled(model.isVerifying)
                .accessibilityIdentifier("addIPTVSource.nameField")
                .onChange(of: model.name) { model.fieldsDidChange() }

            TextField(AppLocalization.string("sources.field.url"), text: $model.serverURL)
                .textContentType(.URL)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .disabled(model.isVerifying)
                .accessibilityIdentifier("addIPTVSource.urlField")
                .onChange(of: model.serverURL) { model.fieldsDidChange() }
        } header: {
            Text(AppLocalization.string("sources.iptv.section.source"))
        } footer: {
            Text(AppLocalization.string("sources.iptv.footer.serverURL"))
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField(AppLocalization.string("sources.field.username"), text: $model.username)
                .textContentType(.username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .disabled(model.isVerifying)
                .accessibilityIdentifier("addIPTVSource.usernameField")
                .onChange(of: model.username) { model.fieldsDidChange() }

            SecureField(AppLocalization.string("sources.field.password"), text: $model.password)
                .textContentType(.password)
                .disabled(model.isVerifying)
                .accessibilityIdentifier("addIPTVSource.passwordField")
                .onChange(of: model.password) { model.fieldsDidChange() }
        } header: {
            Text(AppLocalization.string("sources.iptv.section.account"))
        } footer: {
            Text(AppLocalization.string("sources.iptv.footer.credentials"))
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.state {
        case .ready:
            Section {
                Label(AppLocalization.string("sources.iptv.status.ready"), systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }

        case .verifying:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppLocalization.string("sources.iptv.status.verifying"))
                }
                .accessibilityIdentifier("addIPTVSource.verifyingState")
            }

        case .failure(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("addIPTVSource.errorState")
            }

        case .success(let account):
            accountSection(account)
        }
    }

    private func accountSection(_ account: XtreamValidatedAccount) -> some View {
        Section {
            Label(AppLocalization.string("sources.iptv.status.verified"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("addIPTVSource.successState")

            LabeledContent(AppLocalization.string("sources.iptv.field.status"), value: account.status)

            if let expirationDate = account.expirationDate {
                LabeledContent(
                    AppLocalization.string("sources.iptv.field.expires"),
                    value: expirationDate.formatted(date: .abbreviated, time: .omitted)
                )
            }

            if account.activeConnections != nil || account.maxConnections != nil {
                LabeledContent(
                    AppLocalization.string("sources.iptv.field.connections"),
                    value: connectionsDescription(account)
                )
            }

            if let formats = account.allowedOutputFormats, !formats.isEmpty {
                LabeledContent(
                    AppLocalization.string("sources.iptv.field.formats"),
                    value: formats.joined(separator: ", ")
                )
            }
        } header: {
            Text(AppLocalization.string("sources.iptv.section.account"))
        }
    }

    private var actionSection: some View {
        Section {
            if model.canSave {
                Button(
                    AppLocalization.string(editingSource == nil ? "sources.addSource" : "common.save")
                ) {
                    saveSource()
                }
                .disabled(appEnvironment == nil)
                .accessibilityIdentifier("addIPTVSource.addButton")
            } else {
                Button {
                    validationTask?.cancel()
                    validationTask = Task {
                        await model.verify()
                        validationTask = nil
                    }
                } label: {
                    if model.isVerifying {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(AppLocalization.string("sources.iptv.status.verifyingShort"))
                        }
                    } else {
                        Text(AppLocalization.string("sources.iptv.action.verify"))
                    }
                }
                .disabled(!model.canVerify)
                .accessibilityIdentifier("addIPTVSource.verifyButton")
            }
        }
    }

    private func connectionsDescription(_ account: XtreamValidatedAccount) -> String {
        switch (account.activeConnections, account.maxConnections) {
        case let (active?, maximum?): return "\(active) / \(maximum)"
        case let (active?, nil): return String(active)
        case let (nil, maximum?): return "— / \(maximum)"
        case (nil, nil): return "—"
        }
    }

    private func saveSource() {
        guard let manager = appEnvironment?.iptvSourcesManager else { return }
        do {
            try model.save { name, serverURL, username, password in
                if let editingSource {
                    return try manager.update(
                        id: editingSource.id,
                        name: name,
                        serverURL: serverURL,
                        username: username,
                        password: password
                    )
                } else {
                    return try manager.add(
                        name: name,
                        serverURL: serverURL,
                        username: username,
                        password: password
                    )
                }
            }
            if let dismissSheet {
                dismissSheet()
            } else {
                dismiss()
            }
        } catch {
            // The model publishes the non-sensitive manager error in its failure state.
        }
    }

    private func loadEditingCredentialsIfNeeded() {
        guard !didLoadEditingCredentials,
              let editingSource,
              let credentialsStore = appEnvironment?.xtreamCredentialsStore else {
            return
        }
        didLoadEditingCredentials = true
        // A delayed view task must never restore credentials after an origin change,
        // even if the user has since returned to the original server address.
        guard !model.hasChangedServerOrigin else { return }

        do {
            guard let credentials = try credentialsStore.credentials(for: editingSource.id) else {
                model.showFailure(AppLocalization.string("sources.iptv.error.credentialsUnavailable"))
                return
            }
            model.username = credentials.username
            model.password = credentials.password
            model.fieldsDidChange()
        } catch {
            model.showFailure(AppLocalization.string("sources.iptv.error.credentialsUnavailable"))
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AddIPTVSourceView(
            prefillName: "Living Room",
            prefillServerURL: "https://example.invalid"
        )
        .appEnvironment(.preview)
    }
}
