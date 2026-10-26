//
//  XtreamAccountValidatorTests.swift
//  YatteeTests
//
//  Business validation tests for Xtream account responses.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Xtream Account Validator Tests", .serialized)
struct XtreamAccountValidatorTests {
    private static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Returns non-sensitive metadata for an active authenticated account")
    func activeAccount() async throws {
        let validator = makeValidator(json: #"""
        {
          "user_info": {
            "auth": 1,
            "status": "Active",
            "exp_date": "1900000000",
            "active_cons": "1",
            "max_connections": "3",
            "allowed_output_formats": ["m3u8", "ts"]
          },
          "server_info": {}
        }
        """#)

        let account = try await validate(with: validator)

        #expect(account.status == "Active")
        #expect(account.expirationDate == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(account.activeConnections == 1)
        #expect(account.maxConnections == 3)
        #expect(account.allowedOutputFormats == ["m3u8", "ts"])
        #expect(!String(reflecting: account).contains("fictional-user"))
        #expect(!String(reflecting: account).contains("fictional-password"))
    }

    @Test("Rejects false authentication", arguments: ["0", "false"])
    func authenticationRefused(auth: String) async {
        let validator = makeValidator(json: "{\"user_info\":{\"auth\":\(auth),\"status\":\"Active\"},\"server_info\":{}}")
        await expect(.authenticationRefused, from: validator)
    }

    @Test("Rejects authenticated accounts with disabled or suspended status", arguments: [
        ("Disabled", XtreamAccountValidationError.accountDisabled),
        ("Suspended", XtreamAccountValidationError.accountSuspended),
        ("Banned", XtreamAccountValidationError.accountSuspended)
    ])
    func unavailableStatus(status: String, expected: XtreamAccountValidationError) async {
        let validator = makeValidator(json: "{\"user_info\":{\"auth\":1,\"status\":\"\(status)\"},\"server_info\":{}}")
        await expect(expected, from: validator)
    }

    @Test("Rejects status-expired and date-expired accounts")
    func expiredAccounts() async {
        let statusExpired = makeValidator(json: #"{"user_info":{"auth":1,"status":"Expired"},"server_info":{}}"#)
        let dateExpired = makeValidator(json: #"{"user_info":{"auth":1,"status":"Active","exp_date":"1700000000"},"server_info":{}}"#)

        await expect(.accountExpired, from: statusExpired)
        await expect(.accountExpired, from: dateExpired)
    }

    @Test("Accepts an active account without expiration date")
    func noExpirationDate() async throws {
        let validator = makeValidator(json: #"{"user_info":{"auth":1,"status":"Active"},"server_info":{}}"#)
        let account = try await validate(with: validator)
        #expect(account.expirationDate == nil)
    }

    @Test("Preserves absent and present output formats")
    func outputFormats() async throws {
        let absent = try await validate(with: makeValidator(
            json: #"{"user_info":{"auth":1,"status":"Active"},"server_info":{}}"#
        ))
        let present = try await validate(with: makeValidator(
            json: #"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts"]},"server_info":{}}"#
        ))

        #expect(absent.allowedOutputFormats == nil)
        #expect(present.allowedOutputFormats == ["ts"])
    }

    @Test("Distinguishes invalid JSON from incomplete Xtream response")
    func malformedAndIncompleteResponses() async {
        await expect(.invalidJSONResponse, from: makeValidator(json: "not-json"))
        await expect(.incompleteResponse, from: makeValidator(json: #"{"user_info":{"auth":1},"server_info":{}}"#))
        await expect(.incompleteResponse, from: makeValidator(json: #"{"unexpected":true}"#))
    }

    @Test("Maps HTTP authentication failures", arguments: [401, 403])
    func HTTPAuthenticationFailures(statusCode: Int) async {
        let validator = makeValidator(statusCode: statusCode, json: "{}")
        await expect(.httpError(statusCode), from: validator)
    }

    @Test("Maps network, timeout, and cancellation errors", arguments: [
        (URLError.Code.cannotConnectToHost, XtreamAccountValidationError.serverUnavailable),
        (URLError.Code.timedOut, XtreamAccountValidationError.timeout),
        (URLError.Code.cancelled, XtreamAccountValidationError.cancelled)
    ])
    func transportErrors(code: URLError.Code, expected: XtreamAccountValidationError) async {
        let validator = makeValidator(error: URLError(code))
        await expect(expected, from: validator)
    }

    @Test("Credentials are absent from errors and application logs")
    @MainActor
    func credentialsDoNotLeak() async {
        let logging = LoggingService.shared
        let wasEnabled = logging.isEnabled
        defer {
            logging.clearLogs()
            logging.isEnabled = wasEnabled
        }
        logging.isEnabled = true
        logging.clearLogs()

        let validator = makeValidator(error: URLError(.cannotConnectToHost))
        do {
            _ = try await validate(with: validator)
            Issue.record("Expected validation to fail")
        } catch {
            #expect(!error.localizedDescription.contains("fictional-user"))
            #expect(!error.localizedDescription.contains("fictional-password"))
            #expect(!String(reflecting: error).contains("fictional-user"))
            #expect(!String(reflecting: error).contains("fictional-password"))
        }

        #expect(logging.entries.allSatisfy {
            !$0.message.contains("fictional-user")
                && !$0.message.contains("fictional-password")
                && !($0.details?.contains("fictional-user") ?? false)
                && !($0.details?.contains("fictional-password") ?? false)
        })
    }

    private func validate(with validator: XtreamAccountValidator) async throws -> XtreamValidatedAccount {
        try await validator.validate(
            serverURL: URL(string: "https://server.invalid")!,
            username: "fictional-user",
            password: "fictional-password"
        )
    }

    private func expect(
        _ expected: XtreamAccountValidationError,
        from validator: XtreamAccountValidator
    ) async {
        await #expect(throws: expected) {
            _ = try await validate(with: validator)
        }
    }

    private func makeValidator(
        statusCode: Int = 200,
        json: String
    ) -> XtreamAccountValidator {
        makeValidator { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }
    }

    private func makeValidator(error: Error) -> XtreamAccountValidator {
        makeValidator { _ in throw error }
    }

    private func makeValidator(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> XtreamAccountValidator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XtreamAccountMockURLProtocol.self]
        XtreamAccountMockURLProtocol.setHandler(handler)
        let client = XtreamHTTPClient(configuration: configuration)
        return XtreamAccountValidator(client: client, currentDate: { Self.referenceDate })
    }
}

private final class XtreamAccountMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock { requestHandler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.requestHandler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
