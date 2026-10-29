//
//  AddIPTVSourceModelTests.swift
//  YatteeTests
//
//  Tests for Xtream source form validation and save gating.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Add IPTV Source Model Tests")
@MainActor
struct AddIPTVSourceModelTests {
    @Test("Successful validation exposes account metadata and enables save")
    func successfulValidation() async throws {
        let account = XtreamValidatedAccount(
            status: "Active",
            expirationDate: nil,
            activeConnections: 1,
            maxConnections: 2,
            allowedOutputFormats: ["m3u8"]
        )
        let model = makeModel(result: .success(account))

        await model.verify()

        #expect(model.state == .success(account))
        #expect(model.canSave)

        var savedInput: (String, String, String, String)?
        let source = try model.save { name, serverURL, username, password in
            savedInput = (name, serverURL, username, password)
            return try IPTVSource(name: name, serverURL: serverURL)
        }
        #expect(source.name == "Test Source")
        #expect(savedInput?.0 == "Test Source")
        #expect(savedInput?.1 == "https://server.invalid")
        #expect(savedInput?.2 == "demo-user")
        #expect(savedInput?.3 == "demo-password")
    }

    @Test("Failed validation never enables persistence")
    func failedValidation() async {
        let model = makeModel(result: .failure(XtreamAccountValidationError.authenticationRefused))

        await model.verify()

        #expect(model.state == .failure("The IPTV server rejected the credentials."))
        #expect(!model.canSave)
        var didSave = false
        #expect(throws: IPTVSourcesManagerError.credentialFailure) {
            try model.save { _, _, _, _ in
                didSave = true
                return try IPTVSource(name: "Unexpected", serverURL: "https://server.invalid")
            }
        }
        #expect(!didSave)
    }

    @Test("Invalid URL is rejected before network validation")
    func invalidURL() async {
        var validationCalls = 0
        let model = AddIPTVSourceModel { _, _, _ in
            validationCalls += 1
            return XtreamValidatedAccount(
                status: "Active",
                expirationDate: nil,
                activeConnections: nil,
                maxConnections: nil,
                allowedOutputFormats: nil
            )
        }
        populate(model)
        model.serverURL = "ftp://server.invalid"
        model.username = "demo-user"
        model.password = "demo-password"

        await model.verify()

        #expect(validationCalls == 0)
        #expect(model.state == .failure(AppLocalization.string("sources.iptv.error.invalidURL")))
    }

    @Test("Editing fields invalidates a successful validation")
    func editingInvalidatesValidation() async {
        let account = XtreamValidatedAccount(
            status: "Active",
            expirationDate: nil,
            activeConnections: nil,
            maxConnections: nil,
            allowedOutputFormats: nil
        )
        let model = makeModel(result: .success(account))
        await model.verify()
        #expect(model.canSave)

        model.username = "another-user"
        model.fieldsDidChange()

        #expect(model.state == .ready)
        #expect(!model.canSave)
    }

    @Test("Unexpected validation errors do not expose credentials")
    func unexpectedErrorsAreSanitized() async {
        struct SensitiveError: Error, LocalizedError {
            var errorDescription: String? { "demo-user demo-password" }
        }
        let model = makeModel(result: .failure(SensitiveError()))

        await model.verify()

        guard case .failure(let message) = model.state else {
            Issue.record("Expected validation failure")
            return
        }
        #expect(!message.contains("demo-user"))
        #expect(!message.contains("demo-password"))
    }

    @Test("Changing scheme, host or effective port clears credentials and blocks validation and save", arguments: [
        "http://server.invalid", "https://other.invalid", "https://server.invalid:444", ""
    ])
    func originChangeRequiresNewCredentials(url: String) async throws {
        var validationCalls = 0
        let model = AddIPTVSourceModel(prefillName: "Source", prefillServerURL: "https://server.invalid") { _, _, _ in
            validationCalls += 1
            return XtreamValidatedAccount(status: "Active", expirationDate: nil, activeConnections: nil,
                                          maxConnections: nil, allowedOutputFormats: nil)
        }
        model.username = "old-user"
        model.password = "old-password"
        await model.verify()
        #expect(model.canSave)

        model.serverURL = url

        #expect(model.username.isEmpty && model.password.isEmpty)
        #expect(model.hasChangedServerOrigin)
        #expect(!model.canVerify && !model.canSave)
        await model.verify()
        #expect(validationCalls == 1)
        #expect(throws: IPTVSourcesManagerError.credentialFailure) {
            try model.save { _, _, _, _ in
                Issue.record("Obsolete credentials must not be saved")
                return try IPTVSource(name: "Unexpected", serverURL: "https://server.invalid")
            }
        }
        model.serverURL = "https://server.invalid"
        #expect(model.hasChangedServerOrigin)
        #expect(model.username.isEmpty && model.password.isEmpty)
        model.username = "new-user"
        model.password = "new-password"
        await model.verify()
        #expect(model.canSave)
        #expect(validationCalls == 2)
    }

    @Test("Same-origin path, casing and explicit default port edits retain credentials", arguments: [
        "https://server.invalid/base", "HTTPS://SERVER.INVALID:443/another?value=1"
    ])
    func sameOriginRetainsCredentials(url: String) {
        let model = AddIPTVSourceModel(prefillServerURL: "https://server.invalid")
        model.username = "old-user"
        model.password = "old-password"
        model.serverURL = url
        #expect(model.username == "old-user" && model.password == "old-password")
        #expect(!model.hasChangedServerOrigin)
    }

    @Test("An in-flight validation cannot restore approval after an origin change", arguments: [false, true])
    func originChangeDuringValidation(returnToOriginal: Bool) async {
        var pending: CheckedContinuation<XtreamValidatedAccount, Never>?
        let model = AddIPTVSourceModel(prefillName: "Source", prefillServerURL: "https://server.invalid") { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        }
        model.username = "old-user"
        model.password = "old-password"
        let verification = Task { await model.verify() }
        while pending == nil { await Task.yield() }
        model.serverURL = "https://other.invalid"
        #expect(model.username.isEmpty && model.password.isEmpty)
        if returnToOriginal {
            model.serverURL = "https://server.invalid"
            model.username = "old-user"
            model.password = "old-password"
        }
        pending?.resume(returning: XtreamValidatedAccount(status: "Active", expirationDate: nil,
                                                         activeConnections: nil, maxConnections: nil,
                                                         allowedOutputFormats: nil))
        await verification.value
        #expect(model.username == (returnToOriginal ? "old-user" : ""))
        #expect(model.password == (returnToOriginal ? "old-password" : ""))
        #expect(model.state == .ready)
        #expect(model.canVerify == returnToOriginal)
        #expect(!model.canSave)
    }

    private func makeModel(
        result: Result<XtreamValidatedAccount, Error>
    ) -> AddIPTVSourceModel {
        let model = AddIPTVSourceModel { _, _, _ in
            try result.get()
        }
        populate(model)
        return model
    }

    private func populate(_ model: AddIPTVSourceModel) {
        model.name = " Test Source "
        model.serverURL = "HTTPS://server.invalid"
        model.username = "demo-user"
        model.password = "demo-password"
    }
}
