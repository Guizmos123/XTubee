//
//  EPGModels.swift
//  Yattee
//
//  Typed models for an indexed XMLTV programme guide.
//

import Foundation

struct EPGChannelID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct EPGChannel: Codable, Hashable, Sendable {
    let id: EPGChannelID
    let displayName: String?
}

struct EPGProgram: Codable, Hashable, Sendable {
    let epgChannelID: EPGChannelID
    let title: String
    let description: String?
    let start: Date
    let end: Date
}

struct EPGCatalog: Codable, Equatable, Sendable {
    let channelsByID: [EPGChannelID: EPGChannel]
    let programsByChannelID: [EPGChannelID: [EPGProgram]]

    func channel(for id: EPGChannelID) -> EPGChannel? {
        channelsByID[id]
    }

    func programs(for id: EPGChannelID) -> [EPGProgram] {
        programsByChannelID[id] ?? []
    }
}
