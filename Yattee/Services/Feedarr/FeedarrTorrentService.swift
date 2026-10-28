//
//  FeedarrTorrentService.swift
//  Yattee
//
//  Bounded torrent export; magnet links remain inert until explicitly copied.
//

import Foundation

enum FeedarrTorrentError: Error, LocalizedError, Equatable, Sendable {
    case invalidTorrent
    case invalidMagnet
    case temporaryFile

    var errorDescription: String? {
        switch self {
        case .invalidTorrent: AppLocalization.string("feedarr.download.invalid")
        case .invalidMagnet: AppLocalization.string("feedarr.download.invalidMagnet")
        case .temporaryFile: AppLocalization.string("feedarr.download.fileError")
        }
    }
}

enum FeedarrTorrentResult: Sendable {
    case file(URL)
    case magnet(String)
}

actor FeedarrTorrentService {
    static let maximumBytes = 32 * 1_024 * 1_024
    private let api: FeedarrAPIClient

    init(api: FeedarrAPIClient) { self.api = api }

    func download(releaseID: Int64) async throws -> FeedarrTorrentResult {
        let (data, response) = try await api.torrentResponse(releaseID: releaseID)
        try Task.checkCancellation()
        if response.statusCode == 302 {
            guard let location = response.value(forHTTPHeaderField: "Location"), location.utf8.count <= 16_384,
                  let components = URLComponents(string: location), components.scheme?.lowercased() == "magnet",
                  components.queryItems?.contains(where: { $0.name == "xt" && ($0.value?.hasPrefix("urn:btih:") == true || $0.value?.hasPrefix("urn:btmh:") == true) }) == true else {
                throw FeedarrTorrentError.invalidMagnet
            }
            return .magnet(location)
        }
        guard data.count <= Self.maximumBytes, Self.isTorrent(data) else { throw FeedarrTorrentError.invalidTorrent }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedarrTorrent-" + UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("release-\(releaseID).torrent")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return .file(url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError { throw CancellationError() }
            throw FeedarrTorrentError.temporaryFile
        }
    }

    /// Only remove files created in our own UUID-scoped temporary directory.
    nonisolated static func cleanUp(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("FeedarrTorrent-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated static func isTorrent(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes else { return false }
        var parser = TorrentBencode(bytes: Array(data))
        guard let root = try? parser.parse(), parser.index == data.count,
              case .dictionary(let top) = root, case .dictionary(let info)? = top["info"],
              case .bytes(let name)? = info["name"], !name.isEmpty,
              case .integer(let pieceLength)? = info["piece length"], pieceLength > 0 else { return false }
        if case .integer(2)? = info["meta version"], case .dictionary(let tree)? = info["file tree"] {
            return !tree.isEmpty
        }
        guard case .bytes(let pieces)? = info["pieces"], pieces.count % 20 == 0 else { return false }
        if case .integer(let length)? = info["length"] { return length >= 0 }
        guard case .list(let files)? = info["files"], !files.isEmpty else { return false }
        return files.allSatisfy { file in
            guard case .dictionary(let fields) = file, case .integer(let length)? = fields["length"], length >= 0,
                  case .list(let path)? = fields["path"], !path.isEmpty else { return false }
            return path.allSatisfy { if case .bytes(let value) = $0 { return !value.isEmpty }; return false }
        }
    }
}

/// Full bounded bencode parsing rejects HTML, JSON, truncated values and trailing payloads.
private struct TorrentBencode {
    indirect enum Value {
        case bytes(ArraySlice<UInt8>), integer(Int64), list([Value]), dictionary([String: Value])
    }
    let bytes: [UInt8]
    var index = 0
    private var nodes = 0
    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse(depth: Int = 0) throws -> Value {
        guard depth < 32, index < bytes.count, nodes < 100_000 else { throw FeedarrTorrentError.invalidTorrent }
        nodes += 1
        let marker = bytes[index]
        if marker == 105 {
            index += 1
            let start = index
            while index < bytes.count && bytes[index] != 101 { index += 1 }
            guard index < bytes.count, let number = Int64(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw FeedarrTorrentError.invalidTorrent }
            index += 1
            return .integer(number)
        }
        if marker == 108 || marker == 100 {
            index += 1
            var list: [Value] = []
            var dictionary: [String: Value] = [:]
            while index < bytes.count && bytes[index] != 101 {
                if marker == 100 {
                    guard case .bytes(let key) = try parse(depth: depth + 1), key.count <= 1_024 else { throw FeedarrTorrentError.invalidTorrent }
                    let name = String(decoding: key, as: UTF8.self)
                    guard dictionary[name] == nil else { throw FeedarrTorrentError.invalidTorrent }
                    dictionary[name] = try parse(depth: depth + 1)
                } else { list.append(try parse(depth: depth + 1)) }
            }
            guard index < bytes.count else { throw FeedarrTorrentError.invalidTorrent }
            index += 1
            return marker == 100 ? .dictionary(dictionary) : .list(list)
        }
        let start = index
        while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        guard index > start, index < bytes.count, bytes[index] == 58,
              let length = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw FeedarrTorrentError.invalidTorrent }
        index += 1
        guard length <= bytes.count - index else { throw FeedarrTorrentError.invalidTorrent }
        let value = bytes[index..<(index + length)]
        index += length
        return .bytes(value)
    }
}
