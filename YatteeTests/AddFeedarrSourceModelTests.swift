//  AddFeedarrSourceModelTests.swift
//  Yattee
//
//  Tests transient Feedarr form validation, editing and explicit saving.

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr Form Tests")
@MainActor
struct AddFeedarrSourceModelTests {
    @Test func initialAdd() {
        let model = make()
        #expect(model.name.isEmpty && model.serverURL.isEmpty)
        #expect(model.username.isEmpty && model.password.isEmpty)
        #expect(model.state == .ready && !model.canSave)
        #expect(model.fieldValidationMessage == nil)
    }

    @Test func editingPrefillAndCredentials() throws {
        let source = try saved()
        let model = make(source: source)
        #expect(model.name == source.name && model.serverURL == source.serverURL.absoluteString)
        model.loadCredentials()
        #expect(model.username == "alice" && model.password == "secret")
        #expect(!model.isLoadingCredentials)
    }

    @Test func missingEditingCredentials() throws {
        let model = AddFeedarrSourceModel(editingSource: try saved(), readCredentials: { nil },
                                         validate: Self.success, save: { _,_,_,_,_,_ in })
        model.loadCredentials()
        #expect(model.errorMessage != nil)
    }

    @Test func openAuthentication() async {
        let calls = Calls()
        let model = make(calls: calls)
        fill(model, url: "http://feedarr.invalid")
        await model.verify()
        #expect(model.canSave)
        #expect(calls.username == nil && calls.password == nil)
    }

    @Test(arguments: [("alice", ""), ("", "secret"), (" ", "secret")])
    func incompleteCredentials(username: String, password: String) async {
        let calls = Calls()
        let model = make(calls: calls)
        fill(model)
        model.username = username
        model.password = password
        #expect(model.fieldValidationMessage == AppLocalization.string("sources.feedarr.incompleteCredentials"))
        await model.verify()
        #expect(!model.canSave && calls.validations == 0)
    }

    @Test func HTTPBasicAuthRejected() async {
        let calls = Calls()
        let model = make(calls: calls)
        fill(model, url: "http://feedarr.invalid")
        model.username = "alice"
        model.password = "secret"
        #expect(model.fieldValidationMessage == AppLocalization.string("sources.feedarr.insecureBasicAuth"))
        await model.verify()
        #expect(calls.validations == 0 && !model.canSave)
    }

    @Test func HTTPSBasicAuthAllowed() async {
        let calls = Calls()
        let model = make(calls: calls)
        fill(model)
        model.username = "alice"
        model.password = "secret"
        await model.verify()
        #expect(model.state == .success && model.canSave)
        #expect(calls.username == "alice" && calls.password == "secret")
    }

    @Test func validationFailurePreservesFields() async {
        let model = AddFeedarrSourceModel(validate: { _,_,_ in
            throw FeedarrConnectionValidationError.transport(.timeout)
        }, save: { _,_,_,_,_,_ in })
        fill(model)
        await model.verify()
        #expect(!model.canSave && model.name == "Home")
        if case .failure = model.state {} else { Issue.record("Expected failure") }
    }

    @Test func unauthorizedMessage() {
        let message = AddFeedarrSourceModel.message(for: FeedarrConnectionValidationError.transport(.unauthorized))
        #expect(message == AppLocalization.string("sources.feedarr.unauthorized"))
        #expect(message != AppLocalization.string("sources.feedarr.incompatible"))
    }

    @Test(arguments: ["url", "username", "password"])
    func invalidatesValidation(field: String) async {
        let model = make()
        fill(model)
        await model.verify()
        switch field {
        case "url": model.serverURL = "https://other.invalid"
        case "username": model.username = "alice"
        default: model.password = "secret"
        }
        #expect(model.state == .ready && !model.canSave)
    }

    @Test func nameOnlyKeepsValidation() async {
        let model = make()
        fill(model)
        await model.verify()
        model.name = "Renamed"
        #expect(model.canSave)
    }

    @Test func obsoleteResponseIsIgnored() async {
        let gate = Gate()
        let model = AddFeedarrSourceModel(validate: { url,_,_ in
            await gate.wait()
            return FeedarrConnectionValidationResult(serverURL: URL(string: url)!)
        }, save: { _,_,_,_,_,_ in })
        fill(model)
        let task = Task { await model.verify() }
        while gate.continuation == nil { await Task.yield() }
        model.serverURL = "https://other.invalid"
        gate.release()
        await task.value
        #expect(model.state == .ready && !model.canSave)
    }

    @Test func cancellationIgnoresLateResponse() async {
        let gate = Gate()
        let model = AddFeedarrSourceModel(validate: { url,_,_ in
            await gate.wait()
            return FeedarrConnectionValidationResult(serverURL: URL(string: url)!)
        }, save: { _,_,_,_,_,_ in })
        fill(model)
        model.startVerification()
        while gate.continuation == nil { await Task.yield() }
        model.cancelValidation()
        gate.release()
        await Task.yield()
        #expect(!model.canSave && model.state == .ready)
    }

    @Test func refusesUnvalidatedSave() async {
        let calls = Calls()
        let model = make(calls: calls)
        fill(model)
        #expect(await model.save() == false)
        #expect(calls.saves == 0)
    }

    @Test func explicitSaveSucceeds() async {
        let calls = Calls()
        let model = make(calls: calls)
        fill(model)
        await model.verify()
        #expect(calls.saves == 0)
        #expect(await model.save())
        #expect(model.didSave && calls.saves == 1)
    }

    @Test func saveFailureKeepsFormOpen() async {
        let model = AddFeedarrSourceModel(validate: Self.success, save: { _,_,_,_,_,_ in
            throw FeedarrSourcesManagerError.persistenceFailure
        })
        fill(model)
        await model.verify()
        #expect(await model.save() == false)
        #expect(!model.didSave && model.errorMessage != nil && model.name == "Home")
    }

    @Test func editingIdentityAndCredentialsPreserved() async throws {
        let persistence = MemoryPersistence()
        let credentials = MemoryCredentials()
        let manager = FeedarrSourcesManager(persistence: persistence, credentialsStore: credentials)
        let original = try manager.add(name: "Old", serverURL: "https://feedarr.invalid", usesBasicAuth: true,
                                       username: "alice", password: "secret", dateAdded: Date(timeIntervalSince1970: 1234))
        let writes = credentials.writes
        let model = AddFeedarrSourceModel(manager: manager,
            validator: FeedarrConnectionValidator(transport: FormTransport()),
            credentialsStore: credentials, editingSource: original)
        model.loadCredentials()
        model.name = "New"
        await model.verify()
        #expect(await model.save())
        #expect(manager.source?.id == original.id && manager.source?.dateAdded == original.dateAdded)
        #expect(credentials.writes == writes)
    }

    @Test func originChangeClearsSecretsPermanently() async throws {
        let calls = Calls()
        let model = make(source: try saved(), calls: calls)
        model.loadCredentials()
        let oldURL = model.serverURL
        model.serverURL = "https://other.invalid"
        #expect(model.username.isEmpty && model.password.isEmpty)
        await model.verify()
        #expect(calls.username == nil && calls.password == nil)
        model.serverURL = oldURL
        #expect(model.username.isEmpty && model.password.isEmpty)
    }

    @Test func removesBasicAuthExplicitly() async throws {
        let calls = Calls()
        let model = make(source: try saved(), calls: calls)
        model.loadCredentials()
        model.username = ""
        model.password = ""
        await model.verify()
        #expect(await model.save())
        #expect(calls.authenticated == false)
    }

    @Test func preventsConcurrentSaves() async {
        let calls = Calls()
        let model = make(calls: calls)
        fill(model)
        await model.verify()
        async let first = model.save()
        async let second = model.save()
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1 && calls.saves == 1)
    }

    @Test func preventsConcurrentValidation() async {
        let gate = Gate()
        let calls = Calls()
        let model = AddFeedarrSourceModel(validate: { url,_,_ in
            calls.validations += 1
            await gate.wait()
            return FeedarrConnectionValidationResult(serverURL: URL(string: url)!)
        }, save: { _,_,_,_,_,_ in })
        fill(model)
        let first = Task { await model.verify() }
        while gate.continuation == nil { await Task.yield() }
        await model.verify()
        gate.release()
        await first.value
        #expect(calls.validations == 1)
    }

    private func make(source: FeedarrSource? = nil, calls: Calls? = nil) -> AddFeedarrSourceModel {
        let calls = calls ?? Calls()
        return AddFeedarrSourceModel(editingSource: source,
            readCredentials: { try FeedarrCredentials(username: "alice", password: "secret") },
            validate: { url, username, password in
                calls.validations += 1
                calls.username = username
                calls.password = password
                return try await Self.success(url, username, password)
            }, save: { _,_,_, authenticated,_,_ in
                calls.saves += 1
                calls.authenticated = authenticated
            })
    }

    private func fill(_ model: AddFeedarrSourceModel, url: String = "https://feedarr.invalid") {
        model.name = "Home"
        model.serverURL = url
    }

    private func saved() throws -> FeedarrSource {
        try FeedarrSource(name: "Saved", serverURL: "https://feedarr.invalid", usesBasicAuth: true)
    }

    private static func success(_ url: String, _ username: String?, _ password: String?) async throws -> FeedarrConnectionValidationResult {
        FeedarrConnectionValidationResult(serverURL: URL(string: url)!)
    }
}

@MainActor private final class Calls {
    var validations = 0
    var saves = 0
    var username: String?
    var password: String?
    var authenticated: Bool?
}

@MainActor private final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class MemoryPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor private final class MemoryCredentials: FeedarrCredentialsStoring {
    var values: [UUID: FeedarrCredentials] = [:]
    var writes = 0
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { values[sourceID] }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws {
        values[sourceID] = credentials
        writes += 1
    }
    func deleteCredentials(for sourceID: UUID) throws { values[sourceID] = nil }
}

private struct FormTransport: FeedarrHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = request.url!.path == "/health" ? #"{"status":"up"}"#
            : #"{"items":[],"pagination":{"limit":1,"hasMore":false,"nextCursor":null,"snapshotMaxId":0}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "application/json"])!)
    }
}
