//
//  FeedarrTorrentTests.swift
//  Yattee
//
//  Simulated binary downloads; no tracker or NAS access.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Feedarr torrent export")
@MainActor
struct FeedarrTorrentTests {
    static let valid = Data("d4:infod6:lengthi1e4:name1:x12:piece lengthi16384e6:pieces20:12345678901234567890ee".utf8)

    @Test func authenticatedBinaryDownloadAndTemporaryCleanup() async throws {
        let transport = TorrentTransport(data: Self.valid)
        let service = try service(transport)
        guard case .file(let url) = try await service.download(releaseID: 42) else { Issue.record("Expected torrent file"); return }
        defer { FeedarrTorrentService.cleanUp(url) }
        #expect(try Data(contentsOf: url) == Self.valid)
        #expect(url.lastPathComponent == "release-42.torrent")
        #expect(!url.path.contains("untrusted"))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/base/api/releases/42/download")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("login:secret".utf8).base64EncodedString())
        #expect(requests[0].value(forHTTPHeaderField: "Accept")?.contains("bittorrent") == true)
        #expect(await transport.limit == FeedarrTorrentService.maximumBytes)
        FeedarrTorrentService.cleanUp(url)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func validatesContentRatherThanHeadersOrExtension() async throws {
        for data in [Data(), Data("<html>error</html>".utf8), Data("d4:info0:e".utf8), Self.valid.dropLast(), Self.valid + Data("junk".utf8)] {
            #expect(!FeedarrTorrentService.isTorrent(Data(data)))
        }
        #expect(FeedarrTorrentService.isTorrent(Self.valid))
        let service = try service(TorrentTransport(data: Data("not a torrent".utf8)))
        await #expect(throws: FeedarrTorrentError.invalidTorrent) { try await service.download(releaseID: 1) }
    }

    @Test func magnetIsReturnedWithoutCreatingAFile() async throws {
        let link = "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"
        let transport = TorrentTransport(status: 302, location: link)
        let service = try service(transport)
        guard case .magnet(let value) = try await service.download(releaseID: 1) else { Issue.record("Expected magnet"); return }
        #expect(value == link)
        #expect(await transport.requests.count == 1)
        #expect(!FeedarrRedirectPolicy.allowsRedirect(from: URL(string: "https://feedarr.invalid")!, to: URL(string: link)!))
    }

    @Test func malformedMagnetAndExternalRedirectAreRejected() async throws {
        let invalid = try service(TorrentTransport(status: 302, location: "magnet:?dn=no-hash"))
        await #expect(throws: FeedarrTorrentError.invalidMagnet) { try await invalid.download(releaseID: 1) }
        let external = try service(TorrentTransport(status: 302, location: "https://external.invalid/file"))
        await #expect(throws: FeedarrAPIError.transport(.redirectForbidden)) { try await external.download(releaseID: 1) }
        #expect(!FeedarrRedirectPolicy.allowsRedirect(from: URL(string: "https://feedarr.invalid")!, to: URL(string: "https://external.invalid")!))
    }

    @Test func authenticationRequiresHTTPS() throws {
        #expect(throws: FeedarrHTTPError.insecureBasicAuth) {
            try FeedarrHTTPClient(serverURL: "http://feedarr.invalid", username: "login", password: "secret")
        }
    }

    @Test func httpErrorsAndCancellationArePreserved() async throws {
        for (status, error) in [(401, FeedarrHTTPError.unauthorized), (403, .forbidden), (502, .httpStatus(502))] {
            let service = try service(TorrentTransport(status: status))
            await #expect(throws: FeedarrAPIError.transport(error)) { try await service.download(releaseID: 1) }
        }
        let service = try service(TorrentTransport(cancelled: true))
        await #expect(throws: FeedarrAPIError.cancelled) { try await service.download(releaseID: 1) }
    }

    @Test func binaryBoundIsEnforced() async throws {
        let http = try FeedarrHTTPClient(serverURL: "https://feedarr.invalid", transport: TorrentTransport(data: Data(repeating: 0, count: 11)), maximumResponseSize: 10)
        await #expect(throws: FeedarrHTTPError.responseTooLarge(maximumBytes: 10)) {
            try await http.downloadResponse(pathComponents: ["api", "releases", "1", "download"])
        }
    }

    private func service(_ transport: TorrentTransport) throws -> FeedarrTorrentService {
        let credentials = TorrentCredentials()
        let manager = FeedarrSourcesManager(persistence: TorrentPersistence(), credentialsStore: credentials)
        try manager.add(name: "Test", serverURL: "https://feedarr.invalid/base", usesBasicAuth: true, username: "login", password: "secret")
        return FeedarrTorrentService(api: FeedarrAPIClient(sources: manager, credentialsStore: credentials, transport: transport))
    }
}

private actor TorrentTransport: FeedarrHTTPTransport {
    let body: Data
    let status: Int
    let location: String?
    let cancelled: Bool
    private(set) var requests: [URLRequest] = []
    private(set) var limit: Int?
    init(data: Data = Data(), status: Int = 200, location: String? = nil, cancelled: Bool = false) {
        body = data; self.status = status; self.location = location; self.cancelled = cancelled
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if cancelled { throw CancellationError() }
        var headers = ["Content-Type": "application/x-bittorrent", "Content-Disposition": "attachment; filename=../../untrusted.torrent"]
        headers["Location"] = location
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func data(for request: URLRequest, maximumResponseSize: Int) async throws -> (Data, URLResponse) {
        limit = maximumResponseSize
        let result = try await data(for: request)
        guard result.0.count <= maximumResponseSize else { throw FeedarrHTTPError.responseTooLarge(maximumBytes: maximumResponseSize) }
        return result
    }
}

@MainActor private final class TorrentPersistence: FeedarrSourcePersisting {
    var source: FeedarrSource?
    func loadSource() throws -> FeedarrSource? { source }
    func saveSource(_ source: FeedarrSource?) throws { self.source = source }
}

@MainActor private final class TorrentCredentials: FeedarrCredentialsStoring {
    var value: FeedarrCredentials?
    func credentials(for sourceID: UUID) throws -> FeedarrCredentials? { value }
    func setCredentials(_ credentials: FeedarrCredentials, for sourceID: UUID) throws { value = credentials }
    func deleteCredentials(for sourceID: UUID) throws { value = nil }
}
