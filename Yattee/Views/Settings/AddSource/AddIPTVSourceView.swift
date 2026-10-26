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
    var serverURL: String
    var username = ""
    var password = ""
    private(set) var state: State = .ready

    @ObservationIgnored private let validateAccount: Validate
    @ObservationIgnored private var validatedInput: ValidatedInput?

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

    func verify() async {
        guard canVerify else {
            state = .failure("Complete all fields before verifying the account.")
            return
        }

        let input: ValidatedInput
        do {
            input = try normalizedInput()
        } catch {
            state = .failure("Enter a valid HTTP or HTTPS Xtream server URL.")
            return
        }

        state = .verifying
        do {
            let account = try await validateAccount(
                input.serverURL,
                input.username,
                input.password
            )
            try Task.checkCancellation()

            guard (try? normalizedInput()) == input else {
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
            state = .failure("The IPTV account could not be verified.")
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
}

// MARK: - View

struct AddIPTVSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    @State private var model: AddIPTVSourceModel
    @State private var validationTask: Task<Void, Never>?

    init(prefillName: String = "", prefillServerURL: String = "") {
        _model = State(
            initialValue: AddIPTVSourceModel(
                prefillName: prefillName,
                prefillServerURL: prefillServerURL
            )
        )
    }

    var body: some View {
        NavigationStack {
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
            .reactiveNavigationTitle("Add IPTV Source")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                sheetCloseToolbarItem(identifier: "addIPTVSource.closeButton") {
                    validationTask?.cancel()
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        .onDisappear {
            validationTask?.cancel()
        }
    }

    private var sourceSection: some View {
        Section {
            TextField("Name", text: $model.name)
                .textContentType(.name)
                .disabled(model.isVerifying)
                .accessibilityIdentifier("addIPTVSource.nameField")
                .onChange(of: model.name) { model.fieldsDidChange() }

            TextField("Server URL", text: $model.serverURL)
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
            Text("Source")
        } footer: {
            Text("Use the HTTP or HTTPS address supplied by your IPTV provider.")
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Username", text: $model.username)
                .textContentType(.username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .disabled(model.isVerifying)
                .accessibilityIdentifier("addIPTVSource.usernameField")
                .onChange(of: model.username) { model.fieldsDidChange() }

            SecureField("Password", text: $model.password)
                .textContentType(.password)
                .disabled(model.isVerifying)
                .accessibilityIdentifier("addIPTVSource.passwordField")
                .onChange(of: model.password) { model.fieldsDidChange() }
        } header: {
            Text("Xtream Account")
        } footer: {
            Text("Credentials remain in memory until validation and are saved locally only after you add the source.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.state {
        case .ready:
            Section {
                Label("Ready to verify", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }

        case .verifying:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying account…")
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
            Label("Account verified", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("addIPTVSource.successState")

            LabeledContent("Status", value: account.status)

            if let expirationDate = account.expirationDate {
                LabeledContent(
                    "Expires",
                    value: expirationDate.formatted(date: .abbreviated, time: .omitted)
                )
            }

            if account.activeConnections != nil || account.maxConnections != nil {
                LabeledContent("Connections", value: connectionsDescription(account))
            }

            if let formats = account.allowedOutputFormats, !formats.isEmpty {
                LabeledContent("Formats", value: formats.joined(separator: ", "))
            }
        } header: {
            Text("Account")
        }
    }

    private var actionSection: some View {
        Section {
            if model.canSave {
                Button("Add Source") {
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
                            Text("Verifying…")
                        }
                    } else {
                        Text("Verify Account")
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
                try manager.add(
                    name: name,
                    serverURL: serverURL,
                    username: username,
                    password: password
                )
            }
            dismiss()
        } catch {
            // The model publishes the non-sensitive manager error in its failure state.
        }
    }
}

// MARK: - Preview

#Preview {
    AddIPTVSourceView(
        prefillName: "Living Room",
        prefillServerURL: "https://example.invalid"
    )
    .appEnvironment(.preview)
}
