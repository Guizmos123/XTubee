//
//  FeedarrHTTPExecutionTests.swift
//  Yattee
//
//  Executor and cancellation checks for bounded Feedarr HTTP work.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr HTTP Execution")
struct FeedarrHTTPExecutionTests {
    @MainActor
    @Test func httpWorkLeavesMainActor() async throws {
        let transport = ExecutorProbeTransport()
        let http = try FeedarrHTTPClient(serverURL: "https://feedarr.invalid", transport: transport)
        #expect(try await http.get(pathComponents: ["test"]) == Data("ok".utf8))
        #expect(transport.calls == 1)
        MainActor.assertIsolated()
    }

    @MainActor
    @Test func decodingLeavesMainActorAndReturnsToCaller() async throws {
        let decoded: ExecutorCheckedResponse = try await FeedarrAPIClient.decode(Data("{\"value\":7}".utf8))
        #expect(decoded.value == 7)
        MainActor.assertIsolated()
    }

    @MainActor
    @Test func cancelledDecodingDoesNotStart() async {
        let task = Task { () throws -> ExecutorCheckedResponse in
            try await FeedarrAPIClient.decode(Data("{\"value\":7}".utf8))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor
    @Test func cancelledHTTPDoesNotStartTransport() async throws {
        let transport = ExecutorProbeTransport()
        let http = try FeedarrHTTPClient(serverURL: "https://feedarr.invalid", transport: transport)
        let task = Task { try await http.get(pathComponents: ["test"]) }
        task.cancel()
        await #expect(throws: FeedarrHTTPError.cancelled) { try await task.value }
        #expect(transport.calls == 0)
    }

    @MainActor
    @Test func cancellationStopsProductionReception() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingFeedarrProtocol.self]
        let transport = URLSessionFeedarrTransport(configuration: configuration)
        let http = try FeedarrHTTPClient(serverURL: "https://feedarr.invalid", transport: transport)
        let id = UUID().uuidString
        defer { PendingFeedarrProtocol.events.remove(id) }
        let task = Task { try await http.get(pathComponents: [id]) }
        defer { task.cancel() }
        try await waitUntil { PendingFeedarrProtocol.events.hasStarted(id) }
        task.cancel()
        await #expect(throws: FeedarrHTTPError.cancelled) { try await task.value }
        try await waitUntil { PendingFeedarrProtocol.events.hasStopped(id) }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct ExecutorCheckedResponse: Decodable, Sendable {
    let value: Int
    private enum CodingKeys: CodingKey { case value }

    init(from decoder: Decoder) throws {
        #expect(!Thread.isMainThread)
        value = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .value)
    }
}

private final class ExecutorProbeTransport: FeedarrHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        #expect(!Thread.isMainThread)
        lock.withLock { count += 1 }
        return (Data("ok".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class PendingFeedarrProtocol: URLProtocol, @unchecked Sendable {
    static let events = Events()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Leave the response open so cancellation must stop URLSession itself.
        Self.events.start(request.url!.lastPathComponent)
    }

    override func stopLoading() { Self.events.stop(request.url!.lastPathComponent) }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var started: Set<String> = []
        private var stopped: Set<String> = []
        func start(_ id: String) { lock.withLock { _ = started.insert(id) } }
        func stop(_ id: String) { lock.withLock { _ = stopped.insert(id) } }
        func hasStarted(_ id: String) -> Bool { lock.withLock { started.contains(id) } }
        func hasStopped(_ id: String) -> Bool { lock.withLock { stopped.contains(id) } }
        func remove(_ id: String) { lock.withLock { _ = started.remove(id); _ = stopped.remove(id) } }
    }
}
