//
//  FeedarrExternalLinks.swift
//  Yattee
//
//  External detail destinations; never uses the authenticated Feedarr transport.
//

import Foundation
import Darwin

enum FeedarrExternalLinks {
    struct Item: Identifiable, Sendable {
        let id: String
        let url: URL
        let icon: String
    }

    static func items(for release: FeedarrRelease) -> [Item] {
        var items: [Item] = []
        if let url = validatedURL(release.trackerPageUrl) {
            items.append(Item(id: "Tracker", url: url, icon: "link"))
        }
        let media = release.mediaType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type: String?
        switch media {
        case "movie": type = "movie"
        case "series", "tv": type = "tv"
        default: type = nil
        }
        // A category alone cannot distinguish, for example, an animated film from a series.
        let category = release.unifiedCategoryKey?.lowercased()
        let conflict = (type == "movie" && category == "series") || (type == "tv" && ["films", "movies"].contains(category ?? ""))
        guard let type, !conflict, release.detailsProvider?.lowercased() != "igdb" else { return items }
        if let id = release.tmdbId, id > 0,
           let url = validatedURL("https://www.themoviedb.org/\(type)/\(id)") {
            items.append(Item(id: "TMDB", url: url, icon: "film"))
        }
        // Confirmed on the official site: /dereferrer/series/81189 → /series/breaking-bad.
        if type == "tv", let id = release.tvdbId, id > 0,
           let url = validatedURL("https://thetvdb.com/dereferrer/series/\(id)") {
            items.append(Item(id: "TVDB", url: url, icon: "tv"))
        }
        return items
    }

    static func validatedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 8_192,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !raw.contains("\\"),
              let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url, let rawHost = url.host else { return nil }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") { return isPublicAddress(host) ? url : nil }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 { return isPublicAddress(host) ? url : nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.count <= 253,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }),
              labels.last?.contains(where: { $0.isLetter }) == true else { return nil }
        for suffix in ["localhost", "local", "localdomain", "lan", "internal", "home", "home.arpa", "test", "invalid", "onion"] {
            if host == suffix || host.hasSuffix("." + suffix) { return nil }
        }
        return url
    }

    static func mayOpen(_ url: URL, resolve: @Sendable (String) async -> [String] = resolveHost) async -> Bool {
        guard validatedURL(url.absoluteString) != nil, let host = url.host else { return false }
        let addresses = await resolve(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        return !Task.isCancelled && !addresses.isEmpty && addresses.allSatisfy(isPublicAddress)
    }

    static func isPublicAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let a = value >> 24, b = (value >> 16) & 255, c = (value >> 8) & 255
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                     (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
                     (a == 172 && (16...31).contains(b)) ||
                     (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99))) ||
                     (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
                     (a == 203 && b == 0 && c == 113))
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        // Global unicast only; exclude documentation, Teredo and 6to4 tunnelling.
        return bytes[0] & 0xE0 == 0x20 &&
            !(bytes[0] == 0x20 && bytes[1] == 0x01 && ((bytes[2] == 0x0D && bytes[3] == 0xB8) || (bytes[2] == 0 && bytes[3] == 0))) &&
            !(bytes[0] == 0x20 && bytes[1] == 0x02)
    }

    private static func resolveHost(_ host: String) async -> [String] {
        await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let entry = current {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: buffer))
                }
                current = entry.pointee.ai_next
            }
            return addresses
        }.value
    }
}
