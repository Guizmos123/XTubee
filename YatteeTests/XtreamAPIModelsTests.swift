//
//  XtreamAPIModelsTests.swift
//  YatteeTests
//
//  Decoding tests for Xtream Codes live TV API response models.
//

import Foundation
import Testing
@testable import XTubee

@Suite("Xtream API Models Tests")
struct XtreamAPIModelsTests {
    @Test("Decodes a valid account response")
    func validAccount() throws {
        let response = try decode(XtreamAccountResponse.self, from: #"""
        {
          "user_info": {
            "auth": 1,
            "status": "Active",
            "exp_date": "1893456000",
            "max_connections": "3",
            "active_cons": 1,
            "allowed_output_formats": ["m3u8", "ts"],
            "username": "ignored-user",
            "password": "ignored-pass"
          },
          "server_info": {
            "url": "iptv.invalid",
            "port": "8080",
            "https_port": 8443,
            "server_protocol": "https",
            "timezone": "Europe/Paris"
          }
        }
        """#)

        #expect(response.userInfo.isAuthenticated == true)
        #expect(response.userInfo.status == "Active")
        #expect(response.userInfo.expirationDate == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(response.userInfo.maxConnections == 3)
        #expect(response.userInfo.activeConnections == 1)
        #expect(response.userInfo.allowedOutputFormats == ["m3u8", "ts"])
        #expect(response.serverInfo.host == "iptv.invalid")
        #expect(response.serverInfo.port == 8080)
        #expect(response.serverInfo.httpsPort == 8443)
        #expect(response.serverInfo.serverProtocol == "https")
        #expect(response.serverInfo.timezone == "Europe/Paris")
    }

    @Test("Decodes auth from numeric and string representations", arguments: ["1", "\"1\"", "true", "\"true\""])
    func flexibleAuth(authJSON: String) throws {
        let response = try decode(
            XtreamAccountResponse.self,
            from: "{\"user_info\":{\"auth\":\(authJSON)},\"server_info\":{}}"
        )
        #expect(response.userInfo.isAuthenticated == true)
    }

    @Test("Represents expired or inactive accounts without network validation")
    func inactiveAccount() throws {
        let response = try decode(XtreamAccountResponse.self, from: #"""
        {
          "user_info": {"auth": "0", "status": "Expired", "exp_date": null},
          "server_info": {}
        }
        """#)

        #expect(response.userInfo.isAuthenticated == false)
        #expect(response.userInfo.status == "Expired")
        #expect(response.userInfo.expirationDate == nil)
    }

    @Test("Decodes category identifiers from numbers and strings")
    func flexibleCategoryIdentifiers() throws {
        let categories = try decode([XtreamLiveCategory].self, from: #"""
        [
          {"category_id": 10, "category_name": "News", "parent_id": "0"},
          {"category_id": "sports", "category_name": "Sports", "parent_id": null}
        ]
        """#)

        #expect(categories[0].categoryID == "10")
        #expect(categories[0].parentID == "0")
        #expect(categories[1].categoryID == "sports")
        #expect(categories[1].parentID == nil)
    }

    @Test("Decodes stream identifiers from numbers and strings")
    func flexibleStreamIdentifiers() throws {
        let streams = try decode([XtreamLiveStream].self, from: #"""
        [
          {"stream_id": 101, "name": "Channel One", "category_id": 10, "added": "1700000000"},
          {"stream_id": "channel-two", "name": "Channel Two", "category_id": "sports", "added": 1700000001}
        ]
        """#)

        #expect(streams[0].streamID == "101")
        #expect(streams[0].categoryID == "10")
        #expect(streams[0].addedDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(streams[1].streamID == "channel-two")
        #expect(streams[1].categoryID == "sports")
    }

    @Test("Treats absent, empty, and invalid logo URLs as unavailable")
    func invalidLogos() throws {
        let streams = try decode([XtreamLiveStream].self, from: #"""
        [
          {"stream_id": "1", "name": "Absent"},
          {"stream_id": "2", "name": "Empty", "stream_icon": ""},
          {"stream_id": "3", "name": "Invalid", "stream_icon": "not a URL"},
          {"stream_id": "4", "name": "Valid", "stream_icon": "https://images.invalid/logo.png"}
        ]
        """#)

        #expect(streams[0].streamIconURL == nil)
        #expect(streams[1].streamIconURL == nil)
        #expect(streams[2].streamIconURL == nil)
        #expect(streams[3].streamIconURL?.absoluteString == "https://images.invalid/logo.png")
    }

    @Test("Handles missing and null optional fields")
    func missingOptionalFields() throws {
        let account = try decode(
            XtreamAccountResponse.self,
            from: #"{"user_info":{"auth":null},"server_info":{"port":null}}"#
        )
        let stream = try decode(
            XtreamLiveStream.self,
            from: #"{"stream_id":"1","name":"Minimal","category_id":null,"stream_type":null,"added":null}"#
        )

        #expect(account.userInfo.isAuthenticated == nil)
        #expect(account.userInfo.allowedOutputFormats == nil)
        #expect(account.serverInfo.port == nil)
        #expect(stream.categoryID == nil)
        #expect(stream.streamType == nil)
        #expect(stream.addedDate == nil)
    }

    @Test("Decodes empty category and stream arrays")
    func emptyArrays() throws {
        #expect(try decode([XtreamLiveCategory].self, from: "[]").isEmpty)
        #expect(try decode([XtreamLiveStream].self, from: "[]").isEmpty)
    }

    @Test("Rejects structurally invalid responses")
    func invalidStructure() {
        #expect(throws: DecodingError.self) {
            try decode(XtreamAccountResponse.self, from: #"{"error":"invalid response"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode([XtreamLiveStream].self, from: #"{"stream_id":"1"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode([XtreamLiveCategory].self, from: #"[{"category_name":"Missing ID"}]"#)
        }
    }

    @Test("Ignores unknown fields and does not retain direct_source")
    func unknownFields() throws {
        let stream = try decode(XtreamLiveStream.self, from: #"""
        {
          "stream_id": "500",
          "name": "Demo Channel",
          "stream_type": "live",
          "direct_source": "https://origin.invalid/live/ignored/path/500.ts",
          "epg_channel_id": "ignored",
          "custom_sid": "ignored"
        }
        """#)

        #expect(stream.streamID == "500")
        #expect(stream.name == "Demo Channel")
        #expect(stream.streamType == "live")
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
