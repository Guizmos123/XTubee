//
//  XtreamLiveCatalogClient.swift
//  Yattee
//
//  Fetches Xtream live categories and streams without persistence or caching.
//

import Foundation

struct XtreamLiveCatalogClient: Sendable {
    private let client: XtreamHTTPClient

    init(client: XtreamHTTPClient = XtreamHTTPClient()) {
        self.client = client
    }

    func fetchCategories(
        serverURL: URL,
        username: String,
        password: String
    ) async throws -> [XtreamLiveCategory] {
        try await client.request(
            serverURL: serverURL,
            username: username,
            password: password,
            action: "get_live_categories"
        )
    }

    func fetchStreams(
        serverURL: URL,
        username: String,
        password: String
    ) async throws -> [XtreamLiveStream] {
        try await client.request(
            serverURL: serverURL,
            username: username,
            password: password,
            action: "get_live_streams"
        )
    }
}
