import Testing
import Foundation
@testable import REDDY

@Suite struct CredentialRedactorWideTests {
    @Test func otherSecretNamesAreHiddenToo() {
        let s = "http://h/epg.xml?access_token=AAA111&refresh_token=BBB222&api_key=CCC333&X-Plex-Token=DDD444&client_secret=EEE555&sig=FFF666&sessionid=GGG777&passwd=HHH888&x=1"
        let r = CredentialRedactor.redact(s)
        for secret in ["AAA111", "BBB222", "CCC333", "DDD444", "EEE555", "FFF666", "GGG777", "HHH888"] { #expect(!r.contains(secret), "leaked \(secret)") }
        #expect(r.contains("x=1"), "an ordinary parameter must stay")
        #expect(r.hasPrefix("http://h/epg.xml?"))
    }
    @Test func aSecretInThePathIsHidden() {
        let r = CredentialRedactor.redact("http://h/guide/token/SECRET99/epg.xml and https://h/api/key/K12345?x=1")
        #expect(!r.contains("SECRET99") && !r.contains("K12345"))
        #expect(r.contains("/epg.xml"))
    }
    @Test func anAddressWithNoSecretIsUntouched() {
        let s = "http://host:8080/xmltv.php?lang=en&day=3"
        #expect(CredentialRedactor.redact(s) == s)
    }
    @Test func aGuideAddressWithATokenIsNotKeptWhole() throws {
        let db = try TestSupport.makeDB()
        let creds = InMemoryCredentialStore()
        let mgr = SourceManager(catalog: SQLiteCatalogRepository(db: db), credentials: creds, http: HTTPClient())
        let s = try mgr.addM3U(name: "G", url: "http://host/list.m3u")
        try mgr.setGuideURL(s.id, url: "http://host/epg.xml?access_token=TOPSECRET")
        let stored = try SQLiteCatalogRepository(db: db).source(id: s.id)?.epgURL ?? ""
        #expect(!stored.contains("TOPSECRET"), "the database must hold only the redacted guide address")
        #expect(mgr.withFullGuide(try #require(try SQLiteCatalogRepository(db: db).source(id: s.id))).epgURL?.contains("TOPSECRET") == true, "the providers still get the real address")
        try mgr.setGuideURL(s.id, url: "local-guide://guide.xml")
        #expect(mgr.withFullGuide(try #require(try SQLiteCatalogRepository(db: db).source(id: s.id))).epgURL == "local-guide://guide.xml", "a local guide file replaces the remote one")
    }
}

@Suite struct GzipLimitTests {
    @Test func aFileThatUnpacksFarTooBigIsRefusedAndRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-gz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("g.xml")
        try Data(repeating: 0x41, count: 2_000_000).write(to: plain)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-kf", plain.path]
        try p.run(); p.waitUntilExit()
        let gz = dir.appendingPathComponent("g.xml.gz"), out = dir.appendingPathComponent("out.xml")
        #expect(throws: GzipError.tooLarge) { try GzipInflater.inflate(from: gz, to: out, maxOutput: 500_000) }
        #expect(!FileManager.default.fileExists(atPath: out.path), "the partly written file must not be left behind")
        try GzipInflater.inflate(from: gz, to: out)
        #expect((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) == 2_000_000)
    }
}

@Suite struct HLSPlaylistTests {
    private let base = URL(string: "http://host/live/index.m3u8")!

    @Test func aMasterPlaylistOffersItsBestStream() {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=3000000\nhigh/index.m3u8\n"
        let p = HLSPlaylist.parse(text, base: base)
        #expect(p.isMaster && p.variants.count == 2)
        #expect(p.bestVariant?.url.absoluteString == "http://host/live/high/index.m3u8")
    }

    @Test func aMediaPlaylistListsSegmentsInOrderWithTheirNumbers() {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:6.0,\nseg100.ts\n#EXTINF:5.5,\nhttp://cdn/seg101.ts\n"
        let p = HLSPlaylist.parse(text, base: base)
        #expect(!p.isMaster && p.targetDuration == 6 && !p.ended)
        #expect(p.segments.map(\.sequence) == [100, 101])
        #expect(p.segments[0].url.absoluteString == "http://host/live/seg100.ts")
        #expect(p.segments[1].url.absoluteString == "http://cdn/seg101.ts")
        #expect(p.segments[1].duration == 5.5)
    }

    @Test func anEndedPlaylistAndEncryptedOrFragmentedOnesAreRecognised() {
        #expect(HLSPlaylist.parse("#EXTM3U\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n", base: base).ended)
        #expect(HLSPlaylist.parse("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:4,\na.ts\n", base: base).encrypted)
        #expect(!HLSPlaylist.parse("#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\na.ts\n", base: base).encrypted)
        #expect(HLSPlaylist.parse("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\na.m4s\n", base: base).fragmentedMP4)
        #expect(HLSPlaylist.parse("#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:1000@0\nall.ts\n", base: base).byteRanged)
        #expect(!HLSPlaylist.parse("#EXTM3U\n#EXTINF:4,\na.ts\n", base: base).byteRanged)
    }

    @Test func playlistTextIsToldApartFromVideo() {
        #expect(HLSPlaylist.looksLikePlaylist("  #EXTM3U\n#EXTINF:1,\na.ts"))
        #expect(!HLSPlaylist.looksLikePlaylist("\u{47}\u{40}\u{11}"))
    }
}

@Suite struct RecordingShortfallTests {
    @Test func aRecordingThatRanToTheEndIsFine() {
        #expect(ScheduledRecordingService.shortfall(wanted: 3600, got: 3590) == nil)
        #expect(ScheduledRecordingService.shortfall(wanted: 3600, got: 3600 - 80) == nil)
    }
    @Test func aRecordingThatStoppedEarlyIsReportedWithHowMuchWasKept() {
        let note = ScheduledRecordingService.shortfall(wanted: 3600, got: 600, error: "The network connection was lost.")
        #expect(note?.contains("10 of 60 minutes") == true)
        #expect(note?.contains("network connection was lost") == true)
    }
}

@Suite struct PINThrottleTests {
    private func throttle(_ clock: @escaping () -> Date) -> PINThrottle {
        PINThrottle(name: "t-\(UUID().uuidString)", defaults: UserDefaults(suiteName: "pin-\(UUID().uuidString)")!, now: clock)
    }

    @Test func fiveWrongTriesLockItAndEvenTheRightPinIsRefusedUntilItPasses() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = throttle { now }
        for left in stride(from: 4, through: 1, by: -1) { #expect(t.attempt { false } == .wrong(attemptsLeft: left)) }
        #expect(t.attempt { false } == .wrong(attemptsLeft: 0))
        var asked = false
        if case .locked = t.attempt({ asked = true; return true }) {} else { Issue.record("a try should have been refused") }
        #expect(!asked, "the PIN must not even be compared while locked")
        now = now.addingTimeInterval(PINThrottle.lockoutSeconds + 1)
        #expect(t.attempt { true } == .right)
    }

    @Test func aRightPinResetsTheCount() {
        let t = throttle { Date() }
        _ = t.attempt { false }; _ = t.attempt { false }
        #expect(t.attempt { true } == .right)
        #expect(t.attempt { false } == .wrong(attemptsLeft: 4))
    }

    @MainActor @Test func changingOrRemovingTheFolderPinIsThrottledLikeUnlocking() throws {
        let defaults = UserDefaults(suiteName: "pc-\(UUID().uuidString)")!
        let p = ParentalControls(catalog: SQLiteCatalogRepository(db: try DatabaseManager(path: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pin2-\(UUID().uuidString).sqlite").path)), defaults: defaults)
        #expect(p.setPIN("1234"))
        for _ in 0..<5 { #expect(!p.removePIN(current: "0000")) }
        #expect(!p.removePIN(current: "1234"), "after five wrong tries the right PIN is refused for a while")
        #expect(p.hasPIN)
    }
}

@MainActor @Suite struct SettingsRestoreTests {
    @Test func highContrastComesBackFromABackup() {
        let d = UserDefaults(suiteName: "hc-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.highContrast = false
        #expect(s.apply(snapshot: ["settings.highcontrast": "true"]) == 1)
        #expect(s.highContrast)
    }
}

@MainActor @Suite struct LockedHistoryTests {
    @Test func aLockedFoldersTitleLeavesTheWatchLogUntilUnlocked() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-lh-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let sid = UUID().uuidString.lowercased()
        let movieID = "\(sid)|movie|1", otherID = "\(sid)|movie|2"
        try c.db.write { db in
            try db.execute("INSERT INTO sources(id, name, type, base_url, enabled, created_at, sort_order) VALUES(?, 'S', 'm3uRemote', 'x', 1, 0, 0)", [sid])
            for (id, cat) in [(movieID, "locked-cat"), (otherID, "open-cat")] {
                try db.execute("INSERT INTO movies(id, source_id, provider_id, title, normalized_title, category_id, category_name, stream_ref, created_at, updated_at, last_seen_at) VALUES(?, ?, ?, 'T', 't', ?, 'C', 'r', 0, 0, 0)", [id, sid, id, cat])
            }
            try db.execute("INSERT INTO locked_categories(category_id) VALUES('locked-cat')", [])
        }
        c.catalog.restriction.isActive = true
        #expect(try c.catalog.hiddenByLock([movieID, otherID]) == [movieID])
        c.catalog.restriction.isActive = false
        #expect(try c.catalog.hiddenByLock([movieID, otherID]).isEmpty)
    }
}
