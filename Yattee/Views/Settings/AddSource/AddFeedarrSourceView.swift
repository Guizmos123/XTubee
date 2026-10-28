//  AddFeedarrSourceView.swift
//  Yattee
//
//  Native sheet for adding or editing the single Feedarr source.

import Foundation
import SwiftUI

struct AddFeedarrSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: AddFeedarrSourceModel
    @State private var saveTask: Task<Void, Never>?
    private let dismissSheet: DismissAction?
    private let includesNavigationStack: Bool

    init(
        manager: FeedarrSourcesManager,
        validator: FeedarrConnectionValidator,
        credentialsStore: FeedarrCredentialsStoring,
        editingSource: FeedarrSource? = nil,
        dismissSheet: DismissAction? = nil,
        includesNavigationStack: Bool = true
    ) {
        self.dismissSheet = dismissSheet
        self.includesNavigationStack = includesNavigationStack
        _model = State(initialValue: AddFeedarrSourceModel(
            manager: manager, validator: validator, credentialsStore: credentialsStore,
            editingSource: editingSource
        ))
    }

    var body: some View {
        Group {
            if includesNavigationStack {
                NavigationStack { formContent }
            } else {
                formContent
            }
        }
        .task { model.loadCredentials() }
        .onDisappear {
            model.cancelValidation()
            saveTask?.cancel()
        }
    }

    private var formContent: some View {
            Form {
                Section(AppLocalization.string("sources.feedarr.server")) {
                    TextField(AppLocalization.string("sources.field.name"), text: $model.name)
                    TextField(AppLocalization.string("sources.feedarr.address"), text: $model.serverURL)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                Section {
                    TextField(AppLocalization.string("sources.field.username"), text: $model.username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField(AppLocalization.string("sources.field.password"), text: $model.password)
                        .textContentType(.password)
                } header: {
                    Text(AppLocalization.string("sources.feedarr.authentication"))
                } footer: {
                    Text(AppLocalization.string("sources.feedarr.optionalCredentials"))
                }
                Section(AppLocalization.string("sources.feedarr.connection")) {
                    status
                    Button(AppLocalization.string("sources.feedarr.verify")) {
                        model.startVerification()
                    }
                    .disabled(!model.canVerify)
                }
                Section {
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Button {
                        saveTask = Task {
                            if await model.save() { close() }
                        }
                    } label: {
                        HStack {
                            if model.isSaving { ProgressView() }
                            Text(AppLocalization.string(model.editingSource == nil
                                ? "sources.feedarr.save" : "sources.feedarr.saveChanges"))
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .disabled(model.isSaving || model.isLoadingCredentials)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .reactiveNavigationTitle(AppLocalization.string(model.editingSource == nil
                ? "sources.feedarr.addTitle" : "sources.feedarr.editTitle"))
            .toolbar {
                sheetCloseToolbarItem(identifier: "addFeedarrSource.closeButton") {
                    model.cancelValidation()
                    saveTask?.cancel()
                    close()
                }
            }
    }

    private func close() {
        if let dismissSheet { dismissSheet() } else { dismiss() }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready:
            Text(model.fieldValidationMessage ?? AppLocalization.string("sources.feedarr.ready"))
                .foregroundStyle(.secondary)
        case .verifying:
            HStack { ProgressView(); Text(AppLocalization.string("sources.feedarr.verifying")) }
        case .success:
            Label(AppLocalization.string("sources.feedarr.success"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
