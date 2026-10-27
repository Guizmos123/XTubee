//
//  XMLTVParserTests.swift
//  YatteeTests
//
//  Tests for progressive XMLTV decoding and deduplication.
//

import Foundation
import Testing
@testable import XTubee

@Suite("XMLTV Parser Tests")
struct XMLTVParserTests {
    @Test("Duplicate channels and programmes merge useful metadata")
    func deduplicatesAndMergesMetadata() throws {
        let catalog = try parse("""
        <tv>
          <channel id="fr.tf1"><display-name></display-name></channel>
          <channel id="fr.tf1"><display-name>TF1</display-name></channel>
          <programme channel="fr.tf1" start="20240101120000 +0000" stop="20240101130000 +0000">
            <title>Journal</title><desc>Édition nationale</desc>
          </programme>
          <programme channel="fr.tf1" start="20240101120000 +0000" stop="20240101130000 +0000">
            <title>Journal</title><desc>   </desc>
          </programme>
        </tv>
        """)

        let channelID = EPGChannelID(rawValue: "fr.tf1")
        #expect(catalog.channelsByID.count == 1)
        #expect(catalog.channel(for: channelID)?.displayName == "TF1")
        #expect(catalog.programs(for: channelID).count == 1)
        #expect(catalog.programs(for: channelID).first?.description == "Édition nationale")
    }

    @Test("A later duplicate can supply a missing description")
    func duplicateSuppliesDescription() throws {
        let catalog = try parse("""
        <tv>
          <programme channel="m6.fr" start="20240203100000 +0000" stop="20240203110000 +0000">
            <title>Magazine</title>
          </programme>
          <programme channel="m6.fr" start="20240203100000 +0000" stop="20240203110000 +0000">
            <title>Magazine</title><desc>Présentation</desc>
          </programme>
        </tv>
        """)

        let programs = catalog.programs(for: EPGChannelID(rawValue: "m6.fr"))
        #expect(programs.count == 1)
        #expect(programs.first?.description == "Présentation")
    }

    @Test("Explicit XMLTV time zones are respected and programmes are sorted")
    func timeZonesAndChronologicalOrder() throws {
        let catalog = try parse("""
        <tv>
          <programme channel="sport" start="20240101120000 +0000" stop="20240101130000 +0000">
            <title>Second</title>
          </programme>
          <programme channel="sport" start="20240101120000 +0200" stop="20240101130000 +0200">
            <title>First</title>
          </programme>
        </tv>
        """)

        let programs = catalog.programs(for: EPGChannelID(rawValue: "sport"))
        #expect(programs.map(\.title) == ["First", "Second"])
        #expect(programs[0].start == isoDate("2024-01-01T10:00:00Z"))
        #expect(programs[1].start == isoDate("2024-01-01T12:00:00Z"))
    }

    @Test("XML entities and character references are decoded")
    func decodesXMLCharacters() throws {
        let catalog = try parse("""
        <tv>
          <channel id="culture"><display-name>Arts &amp; Culture</display-name></channel>
          <programme channel="culture" start="20240101100000 +0000" stop="20240101110000 +0000">
            <title>Rock &amp; Roll</title><desc>Caf&#233; &lt;live&gt;</desc>
          </programme>
        </tv>
        """)

        let channelID = EPGChannelID(rawValue: "culture")
        #expect(catalog.channel(for: channelID)?.displayName == "Arts & Culture")
        #expect(catalog.programs(for: channelID).first?.title == "Rock & Roll")
        #expect(catalog.programs(for: channelID).first?.description == "Café <live>")
    }

    @Test("Malformed entries are ignored without discarding valid neighbours")
    func ignoresMalformedEntries() throws {
        let catalog = try parse("""
        <tv>
          <channel id=""></channel>
          <channel><display-name>Missing ID</display-name></channel>
          <programme channel="valid" start="invalid" stop="20240101110000 +0000"><title>Bad date</title></programme>
          <programme channel="valid" start="20240101120000 +0000" stop="20240101110000 +0000"><title>Bad range</title></programme>
          <programme channel="valid" start="20240101100000 +0000" stop="20240101110000 +0000"><desc>Missing title</desc></programme>
          <programme channel="valid" start="20240101110000 +0000" stop="20240101120000 +0000"><title>Valid</title></programme>
        </tv>
        """)

        #expect(catalog.channelsByID.isEmpty)
        #expect(catalog.programs(for: EPGChannelID(rawValue: "valid")).map(\.title) == ["Valid"])
    }

    @Test("InputStream entry point parses incrementally")
    func parsesInputStream() throws {
        let xml = """
        <tv><programme channel="stream" start="20240101100000 +0000" stop="20240101103000 +0000"><title>Live</title></programme></tv>
        """
        let stream = InputStream(data: Data(xml.utf8))
        let catalog = try XMLTVParser().parse(stream: stream)

        #expect(catalog.programs(for: EPGChannelID(rawValue: "stream")).count == 1)
    }

    private func parse(_ xml: String) throws -> EPGCatalog {
        try XMLTVParser().parse(data: Data(xml.utf8))
    }

    private func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
