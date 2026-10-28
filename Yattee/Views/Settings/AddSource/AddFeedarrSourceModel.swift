//  AddFeedarrSourceModel.swift
//  Yattee
//
//  Transient state and validation for the Feedarr source sheet.

import Foundation
import SwiftUI

@MainActor
@Observable
final class AddFeedarrSourceModel {
    enum State: Equatable, Sendable {
        case ready, verifying, success
        case failure(String)
    }

    typealias Validate = @MainActor (String, String?, String?) async throws -> FeedarrConnectionValidationResult
    typealias Save = @MainActor (UUID?, String, String, Bool, String?, String?) throws -> Void

    var name: String
    var serverURL: String {
        didSet {
            guard oldValue != serverURL else { return }
            if Self.origin(oldValue) != Self.origin(serverURL) {
                username = ""
                password = ""
            }
            configurationChanged()
        }
    }
    var username = "" { didSet { if oldValue != username { configurationChanged() } } }
    var password = "" { didSet { if oldValue != password { configurationChanged() } } }
    private(set) var state: State = .ready
    private(set) var isLoadingCredentials = false
    private(set) var isSaving = false
    private(set) var didSave = false
    private(set) var errorMessage: String?
    let editingSource: FeedarrSource?

    @ObservationIgnored private let validateConnection: Validate
    @ObservationIgnored private let saveSource: Save
    @ObservationIgnored private let readCredentials: () throws -> FeedarrCredentials?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var validatedRevision: Int?
    @ObservationIgnored private var credentialsLoaded = false
    @ObservationIgnored private var verificationTask: Task<Void, Never>?

    init(
        manager: FeedarrSourcesManager,
        validator: FeedarrConnectionValidator,
        credentialsStore: FeedarrCredentialsStoring,
        editingSource: FeedarrSource? = nil
    ) {
        self.editingSource = editingSource
        name = editingSource?.name ?? ""
        serverURL = editingSource?.serverURL.absoluteString ?? ""
        validateConnection = { url, username, password in
            try await validator.validate(serverURL: url, username: username, password: password)
        }
        readCredentials = {
            guard let editingSource else { return nil }
            return try credentialsStore.credentials(for: editingSource.id)
        }
        saveSource = { id, name, url, authenticated, username, password in
            if let id {
                _ = try manager.update(id: id, name: name, serverURL: url, usesBasicAuth: authenticated,
                                       username: username, password: password)
            } else {
                _ = try manager.add(name: name, serverURL: url, usesBasicAuth: authenticated,
                                    username: username, password: password)
            }
        }
    }

    init(
        editingSource: FeedarrSource? = nil,
        readCredentials: @escaping () throws -> FeedarrCredentials? = { nil },
        validate: @escaping Validate,
        save: @escaping Save
    ) {
        self.editingSource = editingSource
        name = editingSource?.name ?? ""
        serverURL = editingSource?.serverURL.absoluteString ?? ""
        self.readCredentials = readCredentials
        validateConnection = validate
        saveSource = save
    }

    var isVerifying: Bool { state == .verifying }
    var canVerify: Bool {
        !isVerifying && !isSaving && !isLoadingCredentials && !didSave && fieldErrorKey == nil
    }
    var canSave: Bool {
        state == .success && validatedRevision == revision && fieldErrorKey == nil
            && !isSaving && !isLoadingCredentials && !didSave
    }
    var fieldValidationMessage: String? {
        guard !name.isEmpty || !serverURL.isEmpty || !username.isEmpty || !password.isEmpty,
              let key = fieldErrorKey else { return nil }
        return text(key)
    }

    func loadCredentials() {
        guard !credentialsLoaded else { return }
        credentialsLoaded = true
        guard editingSource?.usesBasicAuth == true else { return }
        isLoadingCredentials = true
        defer { isLoadingCredentials = false }
        do {
            guard let credentials = try readCredentials() else {
                errorMessage = text("credentialsUnavailable")
                return
            }
            username = credentials.username
            password = credentials.password
        } catch {
            errorMessage = text("credentialsUnavailable")
        }
    }

    func startVerification() {
        guard !isVerifying && !isSaving else { return }
        verificationTask = Task { await verify() }
    }

    func verify() async {
        guard !isVerifying && !isSaving && !didSave else { return }
        if let key = fieldErrorKey {
            state = .failure(text(key))
            return
        }
        let currentRevision = revision
        state = .verifying
        errorMessage = nil
        do {
            _ = try await validateConnection(serverURL, username.isEmpty ? nil : username,
                                             password.isEmpty ? nil : password)
            guard revision == currentRevision else { return }
            guard !Task.isCancelled else { state = .ready; return }
            validatedRevision = currentRevision
            state = .success
        } catch {
            guard revision == currentRevision else { return }
            validatedRevision = nil
            if Task.isCancelled || (error as? FeedarrConnectionValidationError) == .transport(.cancelled)
                || error is CancellationError {
                state = .ready
            } else {
                state = .failure(Self.message(for: error))
            }
        }
    }

    func cancelValidation() {
        verificationTask?.cancel()
        verificationTask = nil
        revision += 1
        validatedRevision = nil
        state = .ready
    }

    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        let currentRevision = revision
        defer { isSaving = false }
        // Allow SwiftUI to display progress before the synchronous local transaction.
        await Task.yield()
        guard currentRevision == revision, !Task.isCancelled, fieldErrorKey == nil else { return false }
        do {
            try saveSource(editingSource?.id, name.trimmingCharacters(in: .whitespacesAndNewlines),
                           serverURL, !username.isEmpty, username.isEmpty ? nil : username,
                           password.isEmpty ? nil : password)
            didSave = true
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private func configurationChanged() {
        cancelValidation()
        errorMessage = nil
    }

    private var fieldErrorKey: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "nameRequired" }
        guard let url = try? FeedarrServerURL.normalize(serverURL) else { return "invalidURL" }
        if username.isEmpty != password.isEmpty { return "incompleteCredentials" }
        if !username.isEmpty {
            guard (try? FeedarrCredentials(username: username, password: password)) != nil else {
                return "incompleteCredentials"
            }
            if url.scheme != "https" { return "insecureBasicAuth" }
        }
        return nil
    }

    private static func origin(_ value: String) -> String? {
        guard let url = try? FeedarrServerURL.normalize(value), let host = url.host?.lowercased(),
              let scheme = url.scheme?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    private func text(_ suffix: String) -> String { Self.localized(suffix) }
    private static func localized(_ suffix: String) -> String {
        AppLocalization.string(String.LocalizationValue("sources.feedarr." + suffix))
    }

    static func message(for error: any Error) -> String {
        if let validationError = error as? FeedarrConnectionValidationError {
            switch validationError {
            case .transport(let http): return message(for: http)
            default: return localized("incompatible")
            }
        }
        if let http = error as? FeedarrHTTPError {
            switch http {
            case .invalidURL: return localized("invalidURL")
            case .incompleteCredentials: return localized("incompleteCredentials")
            case .insecureBasicAuth: return localized("insecureBasicAuth")
            case .unauthorized: return localized("unauthorized")
            case .forbidden: return localized("forbidden")
            case .notFound: return localized("notFound")
            case .rateLimited: return localized("rateLimited")
            case .serviceUnavailable: return localized("unavailable")
            case .timeout: return localized("timeout")
            case .invalidTLS: return localized("invalidTLS")
            case .cancelled: return localized("cancelled")
            case .responseTooLarge, .invalidHTTPResponse: return localized("incompatible")
            default: return localized("networkError")
            }
        }
        if let managerError = error as? FeedarrSourcesManagerError {
            switch managerError {
            case .sourceAlreadyExists: return localized("alreadyExists")
            case .sourceNotFound: return localized("sourceNotFound")
            case .insecureBasicAuth: return localized("insecureBasicAuth")
            case .incompleteCredentials: return localized("incompleteCredentials")
            case .missingCredentials, .credentialFailure: return localized("credentialsUnavailable")
            case .rollbackFailure: return localized("rollbackFailure")
            case .persistenceFailure: return localized("saveFailed")
            }
        }
        return localized("saveFailed")
    }
}
