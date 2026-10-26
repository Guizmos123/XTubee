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

        await model.verify()

        #expect(validationCalls == 0)
        #expect(model.state == .failure("Enter a valid HTTP or HTTPS Xtream server URL."))
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
