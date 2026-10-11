import Testing
import Foundation
@testable import REDDY

@Suite("EPG") struct EPGTests {
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository
    let indexer: CatalogIndexer
    let epgRepo: SQLiteEPGRepository
    let service: EPGSyncService

    init() throws {
        db = try TestSupport.makeDB()
        catalog = SQLiteCatalogRepository(db: db)
        indexer = CatalogIndexer(db: db)
        epgRepo = SQLiteEPGRepository(db: db)
        service = EPGSyncService(db: db, catalog: catalog, http: HTTPClient())
    }

    static func stamp(_ d: Date, offset: String = "+0000") -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d) + " " + offset
    }

    static func xmltv(now: Date, channels: [(String, String)], programmes: [(String, Double, Double, String)]) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><tv>"
        for (id, name) in channels { x += "<channel id=\"\(id)\"><display-name>\(name)</display-name><icon src=\"http://i/\(id).png\"/></channel>" }
        for (ch, s, e, t) in programmes {
            x += "<programme start=\"\(stamp(now.addingTimeInterval(s)))\" stop=\"\(stamp(now.addingTimeInterval(e)))\" channel=\"\(ch)\"><title lang=\"en\">\(t)</title><desc>About \(t)</desc><category>News</category></programme>"
        }
        return x + "</tv>"
    }

    func write(_ xml: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        try xml.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @Test func timeParsingHandlesZonesAndLeapDays() {
        #expect(XMLTVMapper.parseTime("20260101120000 +0100")?.timeIntervalSince1970 == 1767265200)
        #expect(XMLTVMapper.parseTime("20240229235959 -0500")?.timeIntervalSince1970 == 1709269199)
        #expect(XMLTVMapper.parseTime("202601011200")?.timeIntervalSince1970 == 1767268800)      // no seconds, no zone = UTC
        #expect(XMLTVMapper.parseTime("garbage") == nil)
        #expect(XMLTVMapper.parseTime("20261301120000") == nil)                                  // month 13
    }

    @Test func importsMapsAndServesNowNext() throws {
        let s = try TestSupport.makeSource(db)
        let now = Date()
        try indexer.commitChannels(source: s, categories: [], channels: [
            TestSupport.channel(s, "1", "BBC One", epg: "bbc1.uk"),        // exact id
            TestSupport.channel(s, "2", "ITV", epg: nil),                  // unique-name match
            TestSupport.channel(s, "3", "Mystery"),                        // nothing to match
        ])
        let xml = Self.xmltv(now: now, channels: [("bbc1.uk", "BBC One"), ("itv.uk", "ITV")], programmes: [
            ("bbc1.uk", -1800, 1800, "Now Show"), ("bbc1.uk", 1800, 5400, "Next Show"), ("bbc1.uk", 5400, 9000, "Later Show"),
            ("itv.uk", -600, 600, "ITV News"), ("bbc1.uk", -90000, -80000, "Ancient"),
        ])
        let r = try service.importFile(try write(xml), sourceID: s.id)
        #expect(r.channels == 2 && r.mapped == 2)
        let ids = try catalog.channels(ChannelQuery()).map(\.id)
        let nn = try epgRepo.nowNext(channelIDs: ids, at: now)
        let bbc = try #require(try catalog.channels(ChannelQuery(search: "bbc")).first)
        #expect(nn[bbc.id]?.map(\.title) == ["Now Show", "Next Show"])
        #expect(nn[bbc.id]?.first?.isLive(at: now) == true)
        let itv = try #require(try catalog.channels(ChannelQuery(search: "itv")).first)
        #expect(nn[itv.id]?.first?.title == "ITV News")
        let mystery = try #require(try catalog.channels(ChannelQuery(search: "mystery")).first)
        #expect(nn[mystery.id] == nil, "an unmatched channel must show nothing, not a guess")
    }

    @Test func aPlaylistsGuideCanBeShiftedByHours() throws {
        let s = try TestSupport.makeSource(db)
        let now = Date()
        try indexer.commitChannels(source: s, categories: [], channels: [TestSupport.channel(s, "1", "BBC One", epg: "bbc1.uk")])
        let xml = Self.xmltv(now: now, channels: [("bbc1.uk", "BBC One")], programmes: [("bbc1.uk", -1800, 1800, "Now Show"), ("bbc1.uk", 1800, 5400, "Next Show")])
        // the provider's guide runs 2 hours early: shifting it +2h puts "Now Show" two hours from now
        let shifted = EPGSyncService(db: db, catalog: catalog, http: HTTPClient(), shiftMinutes: { _ in 120 })
        _ = try shifted.importFile(try write(xml), sourceID: s.id)
        let id = try #require(try catalog.channels(ChannelQuery()).first?.id)
        let programmes = try epgRepo.programs(channelIDs: [id], from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(4 * 3600))[id] ?? []
        let nowShow = try #require(programmes.first { $0.title == "Now Show" })
        #expect(abs(nowShow.start.timeIntervalSince(now) - (-1800 + 7200)) < 2, "start moved by +2 hours")
        #expect(abs(nowShow.end.timeIntervalSince(nowShow.start) - 3600) < 1, "length unchanged")
        let nn = try epgRepo.nowNext(channelIDs: [id], at: now)
        #expect(nn[id]?.first?.isLive(at: now) != true, "nothing is on right now after the shift")
        // and the other way: -3h reads the guide's later programmes
        let earlier = EPGSyncService(db: db, catalog: catalog, http: HTTPClient(), shiftMinutes: { _ in -180 })
        _ = try earlier.importFile(try write(xml), sourceID: s.id)
        let after = try epgRepo.programs(channelIDs: [id], from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(2 * 3600))[id] ?? []
        #expect(try #require(after.first { $0.title == "Now Show" }).start.timeIntervalSince(now) < -3 * 3600 + 1800 + 2)
    }

    @Test func ambiguousNamesAreNotGuessed() throws {
        let s = try TestSupport.makeSource(db)
        try indexer.commitChannels(source: s, categories: [], channels: [
            TestSupport.channel(s, "1", "Sport", cat: "A"), TestSupport.channel(s, "2", "Sport", cat: "B"),
        ])
        let xml = Self.xmltv(now: Date(), channels: [("sport.1", "Sport")], programmes: [("sport.1", -10, 100, "Match")])
        let r = try service.importFile(try write(xml), sourceID: s.id)
        #expect(r.mapped == 0)
    }

    @Test func userMappingsSurviveGuideRefresh() throws {
        let s = try TestSupport.makeSource(db)
        try indexer.commitChannels(source: s, categories: [], channels: [TestSupport.channel(s, "1", "My Channel")])
        let ch = try #require(try catalog.channels(ChannelQuery()).first)
        let xml = Self.xmltv(now: Date(), channels: [("x.custom", "Totally Different")], programmes: [("x.custom", -10, 100, "Custom Show")])
        _ = try service.importFile(try write(xml), sourceID: s.id)
        try XMLTVChannelMatcher(db: db).setUserMapping(channelID: ch.id, sourceID: s.id, xmltvID: "x.custom")
        _ = try service.importFile(try write(xml), sourceID: s.id)         // refresh rebuilds automatic mappings only
        #expect(try epgRepo.nowNext(channelIDs: [ch.id], at: Date())[ch.id]?.first?.title == "Custom Show")
    }

    @Test func programsOutsideTheWindowAreNeverStored() throws {
        let s = try TestSupport.makeSource(db)
        let now = Date()
        let xml = Self.xmltv(now: now, channels: [("a", "A")], programmes: [
            ("a", -86400 * 3, -86400 * 2, "Old"), ("a", 0, 3600, "Current"), ("a", 86400 * 30, 86400 * 30 + 3600, "Far future"),
        ])
        _ = try service.importFile(try write(xml), sourceID: s.id)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM epg_programs") } == 1)
    }

    @Test func failedImportKeepsPreviousGuide() throws {
        let s = try TestSupport.makeSource(db)
        try indexer.commitChannels(source: s, categories: [], channels: [TestSupport.channel(s, "1", "One", epg: "one")])
        let now = Date()
        _ = try service.importFile(try write(Self.xmltv(now: now, channels: [("one", "One")], programmes: [("one", -10, 100, "Good")])), sourceID: s.id)
        let broken = "<tv><channel id=\"one\"><display-name>One</display-name></channel><programme start=\"\(Self.stamp(now))\" stop=\"\(Self.stamp(now.addingTimeInterval(60)))\" channel=\"one\"><title>New</title></programme><programme start="
        #expect(throws: (any Error).self) { try service.importFile(try write(broken), sourceID: s.id) }
        let id = try #require(try catalog.channels(ChannelQuery()).first).id
        #expect(try epgRepo.nowNext(channelIDs: [id], at: now)[id]?.first?.title == "Good")
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM epg_programs WHERE title='New'") } == 0, "failed import is cleaned up")
    }

    @Test func gzipRoundTripStreaming() throws {
        let body = String(repeating: "<programme>line of guide data 0123456789</programme>\n", count: 80_000)   // ~4 MB
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: plain, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-kf", plain.path]
        try p.run(); p.waitUntilExit()
        let gz = URL(fileURLWithPath: plain.path + ".gz")
        #expect(GzipInflater.isGzip(gz) && !GzipInflater.isGzip(plain))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try GzipInflater.inflate(from: gz, to: out)
        #expect(try Data(contentsOf: out) == Data(body.utf8))
        #expect(throws: (any Error).self) { try GzipInflater.inflate(from: plain, to: out) }     // not gzip
    }

    @Test func xmlWithEntitiesAndCDATAParses() throws {
        let s = try TestSupport.makeSource(db)
        try indexer.commitChannels(source: s, categories: [], channels: [TestSupport.channel(s, "1", "A", epg: "a")])
        let now = Date()
        let xml = "<tv><channel id=\"a\"><display-name>A &amp; B</display-name></channel><programme start=\"\(Self.stamp(now.addingTimeInterval(-60)))\" stop=\"\(Self.stamp(now.addingTimeInterval(600)))\" channel=\"a\"><title><![CDATA[News & Weather]]></title><desc>Tom &amp; Jerry</desc></programme></tv>"
        _ = try service.importFile(try write(xml), sourceID: s.id)
        let id = try #require(try catalog.channels(ChannelQuery()).first).id
        let p = try #require(try epgRepo.nowNext(channelIDs: [id], at: now)[id]?.first)
        #expect(p.title == "News & Weather" && p.description == "Tom & Jerry")
    }
}
