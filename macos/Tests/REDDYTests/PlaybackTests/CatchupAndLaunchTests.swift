import Testing
import Foundation
@testable import REDDY

@Suite("Catch-up, live rewind and launch") @MainActor struct CatchupAndLaunchTests {
    @Test func xtreamArchiveFlagsBecomeDays() {
        #expect(XtreamMapper.archiveDays(flag: 1, duration: 3) == 3)
        #expect(XtreamMapper.archiveDays(flag: 1, duration: nil) == 3, "flagged without a number: a short default")
        #expect(XtreamMapper.archiveDays(flag: 1, duration: 0) == 1)
        #expect(XtreamMapper.archiveDays(flag: 1, duration: 365) == 30, "capped")
        #expect(XtreamMapper.archiveDays(flag: 0, duration: 7) == 0 && XtreamMapper.archiveDays(flag: nil, duration: 7) == 0)
    }

    @Test func archiveFlagsSurviveTheDatabase() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-cu-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        var a = TestSupport.channel(src, "1", "Has Archive"); a.archiveDays = 4
        let b = TestSupport.channel(src, "2", "No Archive")
        try c.indexer.commitChannels(source: src, categories: [], channels: [a, b])
        let found = Dictionary(uniqueKeysWithValues: try c.catalog.channels(ChannelQuery(sourceID: src.id, collapseVariants: false)).map { ($0.name, $0.archiveDays) })
        #expect(found["Has Archive"] == 4 && found["No Archive"] == 0)
        a.archiveDays = 0
        try c.indexer.commitChannels(source: src, categories: [], channels: [a, b])
        #expect(try c.catalog.channels(ChannelQuery(sourceID: src.id, collapseVariants: false)).allSatisfy { $0.archiveDays == 0 }, "a provider dropping the archive is noticed on the next refresh")
    }

    @Test func archiveStampsUseTheProvidersClock() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)           // 2025-10-09 08:53:20 UTC
        #expect(XtreamProvider.catchupStamp(start, utcOffsetMinutes: 0) == "2025-10-09:08-53")
        #expect(XtreamProvider.catchupStamp(start, utcOffsetMinutes: 330) == "2025-10-09:14-23", "India: UTC+5:30")
        #expect(XtreamProvider.catchupStamp(start, utcOffsetMinutes: -300) == "2025-10-09:03-53")
        #expect(XtreamProvider.catchupStamp(start.addingTimeInterval(16 * 3600), utcOffsetMinutes: 600) == "2025-10-10:10-53", "crosses midnight into the next day")
    }

    @Test func catchupAddressesAndRequestsAreBuiltFromTheProvider() throws {
        let src = PlaylistSource(name: "X", type: .xtream, baseURL: "http://p.example:8080")
        let provider = XtreamProvider(source: src, account: XtreamAccount(base: "http://p.example:8080", user: "bob", pass: "p@ss"), http: HTTPClient())
        let url = try #require(try provider.catchupURL(ref: "123", start: Date(timeIntervalSince1970: 1_760_000_000), durationMinutes: 60, utcOffsetMinutes: 0))
        #expect(url.path.hasPrefix("/timeshift/bob/") && url.path.contains("/60/2025-10-09:08-53/123."))
        #expect(url.host == "p.example" && url.port == 8080)
        #expect(try provider.catchupURL(ref: "1", start: Date(), durationMinutes: 0, utcOffsetMinutes: 0)?.path.contains("/1/") == true, "never a zero-minute request")
    }

    @Test func catchupOffsetIsPerPlaylistAndBounded() {
        let s = AppSettings(defaults: UserDefaults(suiteName: "cu-\(UUID().uuidString)")!)
        let a = UUID(), b = UUID()
        #expect(s.catchupOffsetMinutes(for: a) == 0)
        s.setCatchupOffsetMinutes(330, for: a)
        #expect(s.catchupOffsetMinutes(for: a) == 330 && s.catchupOffsetMinutes(for: b) == 0)
        s.setCatchupOffsetMinutes(99999, for: a); #expect(s.catchupOffsetMinutes(for: a) == 840)
    }

    @Test func liveRewindSettingAndMPVBuffers() {
        let d = UserDefaults(suiteName: "lr-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        #expect(s.liveRewind, "on by default")
        s.liveRewind = false
        #expect(!AppSettings(defaults: d).liveRewind)
        var c = MPVConfiguration()
        func opts() -> [String: String] { Dictionary(c.options.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b }) }
        c.isLive = true; c.liveRewind = false
        #expect(opts()["demuxer-max-back-bytes"] == nil, "no back buffer unless asked")
        c.liveRewind = true
        #expect(opts()["demuxer-max-back-bytes"] == "192MiB" && opts()["cache-secs"] == "900")
        c.isLive = false
        #expect(opts()["demuxer-max-back-bytes"] == nil, "a movie never gets the live buffer")
    }
}
