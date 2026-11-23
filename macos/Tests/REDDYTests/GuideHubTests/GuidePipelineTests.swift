import Testing
import Foundation
@testable import REDDY

/// Serves fixture files without a network.
struct FixtureFetcher: GuideFileFetching {
    var files: [String: URL]            // by last path component
    var etags: [String: String] = [:]
    func get(_ url: URL, etag: String?, lastModified: String?, maxBytes: Int64) async throws -> GuideFetched {
        let name = url.lastPathComponent
        guard let src = files[name] else { throw NetworkError.unreadable }
        if let e = etags[name], e == etag { return GuideFetched(file: nil, validators: GuideValidators(etag: etag, lastModified: nil), status: 304, bytes: 0) }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("fx-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: copy)
        return GuideFetched(file: copy, validators: GuideValidators(etag: etags[name], lastModified: nil), status: 200, bytes: 100)
    }
}

@Suite("Guide hub: storage, pipeline, diagnostics") struct GuidePipelineTests {
    @Test func migrationV25CreatesTablesAndBackfillsProviders() throws {
        #expect(DatabaseMigrator.latestVersion >= 25)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("guide-mig-\(UUID().uuidString).sqlite").path
        let c = try Connection(path: path, readOnly: false)
        try c.exec("PRAGMA foreign_keys=ON")
        for m in DatabaseMigrator.migrations where m.version <= 24 { try c.exec(m.sql); try c.exec("PRAGMA user_version = \(m.version)") }
        try c.exec("""
        INSERT INTO sources(id,name,type,base_url,epg_url,created_at) VALUES('s1','Main','m3uRemote','http://x/p.m3u','http://x/guide.xml',1),('s2','No guide','m3uRemote','http://x/q.m3u',NULL,1);
        INSERT INTO channels(id, source_id, provider_id, name, normalized_name, stream_ref, last_seen_at) VALUES('c1','s1','1','One','one','r',0);
        INSERT INTO epg_channels(source_id,xmltv_id,display_name,normalized_name) VALUES('s1','one','One','one');
        INSERT INTO epg_channel_mappings(channel_id,source_id,xmltv_channel_id,method,confidence) VALUES('c1','s1','one','user',1);
        """)
        try DatabaseMigrator.migrate(c)
        #expect(try c.scalarInt("PRAGMA user_version") == DatabaseMigrator.latestVersion)
        #expect(try c.scalarInt("SELECT COUNT(*) FROM guide_sources WHERE id='provider:s1' AND kind='provider'") == 1)
        #expect(try c.scalarInt("SELECT COUNT(*) FROM guide_sources WHERE id='provider:s2'") == 0)
        #expect(try c.scalarInt("SELECT COUNT(*) FROM guide_channels WHERE guide_source_id='provider:s1'") == 1)
        #expect(try c.scalarInt("SELECT COUNT(*) FROM channel_guide_map WHERE channel_id='c1' AND locked=1 AND method='user'") == 1)
        // the provider's address is never copied
        #expect(try c.scalarInt("SELECT COUNT(*) FROM guide_sources WHERE url IS NOT NULL") == 0)
        #expect(try c.scalarInt("SELECT COUNT(*) FROM epg_channels") == 1, "old tables stay")
    }

    @Test func importThenNotModifiedThenEmptyKeepsTheWorkingGuide() async throws {
        let db = try GuideFixtures.tempDB()
        let repo = SQLiteGuideRepository(db: db)
        try repo.add(.init(id: "user:u1", kind: .userXMLTV, name: "Mine", urlRef: nil, url: "https://example.test/guide.xml", enabled: true, priority: 20, refreshHours: 6, tz: .automatic, offsetMinutes: 0,
                           lastAttempt: nil, lastSuccess: nil, etag: nil, lastModified: nil, status: "idle", error: nil, channelsCount: 0, programmesCount: 0, windowEnd: nil))
        let now = GuideFixtures.iso("2026-11-22T17:00:00Z")
        var fetcher = FixtureFetcher(files: ["guide.xml": GuideFixtures.url("xmltv/basic.xml")], etags: ["guide.xml": "v1"])
        func source() -> XMLTVURLSource { XMLTVURLSource(id: "user:u1", kind: .userXMLTV, name: "Mine", url: URL(string: "https://example.test/guide.xml")!, priority: 20, fetcher: fetcher) }
        let pipe = GuideImportPipeline(db: db)

        let r1 = await pipe.run(source(), row: try repo.source("user:u1"), now: now)
        #expect(r1.outcome == "ok" && r1.stats.programmesKept == 3)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM guide_programmes") } == 3)
        var d = try #require(try repo.diagnostics(now: now).first { $0.sourceID == "user:u1" })
        #expect(d.outcome == "ok" && d.storedProgrammes == 3 && d.channelsInFile == 2 && d.host == "example.test")

        let r2 = await pipe.run(source(), row: try repo.source("user:u1"), now: now.addingTimeInterval(3600))
        #expect(r2.outcome == "notModified")
        d = try #require(try repo.diagnostics(now: now).first { $0.sourceID == "user:u1" })
        #expect(d.programmesKept == 3 && d.storedProgrammes == 3, "a 304 keeps what the last fetch found")

        fetcher = FixtureFetcher(files: ["guide.xml": GuideFixtures.url("xmltv/all-past.xml")])
        let r3 = await pipe.run(source(), row: try repo.source("user:u1"), now: now.addingTimeInterval(7200))
        #expect(r3.outcome == "empty" && r3.stats.droppedPast == 3)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM guide_programmes") } == 3, "the working guide stays")
        d = try #require(try repo.diagnostics(now: now).first { $0.sourceID == "user:u1" })
        let findings = GuideDiagnosisAdvisor.findings(d, now: now.addingTimeInterval(7200))
        #expect(findings.first?.key == "diag.allPast" && findings.first?.level == .error)
        #expect(findings.first?.text.contains("out of date") == true)
    }

    @Test func aFailedFetchIsRecordedWithoutTheAddress() async throws {
        let db = try GuideFixtures.tempDB()
        let repo = SQLiteGuideRepository(db: db)
        try repo.add(.init(id: "user:u2", kind: .userXMLTV, name: "Broken", urlRef: nil, url: nil, enabled: true, priority: 20, refreshHours: 6, tz: .automatic, offsetMinutes: 0,
                           lastAttempt: nil, lastSuccess: nil, etag: nil, lastModified: nil, status: "idle", error: nil, channelsCount: 0, programmesCount: 0, windowEnd: nil))
        let src = XMLTVURLSource(id: "user:u2", kind: .userXMLTV, name: "Broken", url: URL(string: "https://example.test/missing.xml?token=SECRET123")!, priority: 20, fetcher: FixtureFetcher(files: [:]))
        let r = await GuideImportPipeline(db: db).run(src, row: nil)
        #expect(r.outcome == "failed")
        let d = try #require(try repo.diagnostics().first { $0.sourceID == "user:u2" })
        #expect(d.outcome == "failed" && d.lastSuccess == nil && !(d.error ?? "").contains("SECRET123"))
        #expect(GuideDiagnosisAdvisor.findings(d, now: Date()).first?.key == "diag.fetchFailed")
    }

    @Test func providerImportExplainsAnEmptyGuideAndKeepsTheOldOne() throws {
        let db = try GuideFixtures.tempDB()
        let catalog = SQLiteCatalogRepository(db: db)
        let s = PlaylistSource(name: "Prov", type: .m3uRemote, baseURL: "http://example.test/p.m3u")
        try catalog.save(source: s)
        try db.write { try $0.execute("UPDATE sources SET epg_url='http://example.test/g.xml' WHERE id=?", [s.id]) }
        let svc = EPGSyncService(db: db, catalog: catalog, http: HTTPClient(), windowDays: 7)
        let now = Date()
        func stamp(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d) + " +0000" }
        func doc(_ start: Date, _ end: Date) throws -> URL {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString).xml")
            try "<tv><channel id=\"a\"><display-name>A</display-name></channel><programme start=\"\(stamp(start))\" stop=\"\(stamp(end))\" channel=\"a\"><title>T</title></programme></tv>".write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        _ = try svc.importFile(try doc(now, now.addingTimeInterval(3600)), sourceID: s.id)
        let old = now.addingTimeInterval(-86400 * 4)
        #expect(throws: (any Error).self) { try svc.importFile(try doc(old, old.addingTimeInterval(3600)), sourceID: s.id) }
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM epg_programs") } == 1, "the previous guide is not wiped by an import that kept nothing")
        let d = try #require(try SQLiteGuideRepository(db: db).diagnostics().first { $0.sourceID == "provider:" + s.id.uuidString.lowercased() })
        #expect(d.outcome == "empty" && d.droppedPast == 1 && d.programmesSeen == 1 && d.storedProgrammes == 1)
        let f = GuideDiagnosisAdvisor.findings(d, now: now)
        #expect(f.first?.key == "diag.allPast" && f.first?.text.contains("4 days") == true)
    }

    @Test func diagnosticsOfALibraryWhoseGuideIsEmptyAndOld() throws {
        // The owner's situation in numbers only: a guide row exists, 3.5 days old, zero programmes held.
        var d = GuideSourceDiagnostics(sourceID: "provider:x", name: "Playlist", lastAttempt: GuideFixtures.iso("2026-11-19T00:00:00Z"), lastSuccess: GuideFixtures.iso("2026-11-19T00:00:00Z"), outcome: "ok")
        d.channelsInFile = 448; d.programmesSeen = 0; d.storedProgrammes = 0
        let now = GuideFixtures.iso("2026-11-22T12:00:00Z")
        let f = GuideDiagnosisAdvisor.findings(d, now: now)
        #expect(f.first?.key == "diag.emptyFile" && f.first?.level == .error)
        #expect(GuideDiagnosisAdvisor.freshness(d, now: now).key == "guide.empty")
    }

    @Test func manualMappingsSurviveAnAutomaticRebuild() throws {
        let db = try GuideFixtures.tempDB()
        let catalog = SQLiteCatalogRepository(db: db)
        let s = try TestSupport.makeSource(db)
        try SQLiteCatalogRepository(db: db).save(source: s)
        let ch = TestSupport.channel(s, "1", "One")
        try CatalogIndexer(db: db).commitChannels(source: s, categories: [], channels: [ch])
        _ = catalog
        let repo = SQLiteGuideRepository(db: db)
        try repo.setUserMapping(channelID: ch.id, guideSourceID: "user:u1", xmltvID: "mine")
        try repo.saveMappings(guideSourceID: "user:u1", channelIDs: [ch.id], matches: [(ch.id, GuideMatch(guideSourceID: "user:u1", xmltvID: "auto", method: .name, confidence: 0.7, reason: "same name"))])
        let rows = try db.read { try $0.query("SELECT xmltv_id, locked FROM channel_guide_map WHERE channel_id=?", [ch.id]) { ($0.string(0), $0.bool(1)) } }
        #expect(rows.count == 1 && rows[0].0 == "mine" && rows[0].1)
        #expect(try repo.userMappings()[ch.id]?.xmltvID == "mine")
        try repo.setUserMapping(channelID: ch.id, guideSourceID: "user:u1", xmltvID: nil)
        #expect(try repo.userMappings().isEmpty)
    }

    // MARK: public database fetcher

    @Test func publicDatabaseCachesWithEtagAndRateLimitsAndFailsClosed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iptvorg-\(UUID().uuidString)")
        let mini = GuideFixtures.url("iptvorg-mini")
        final class Counter: @unchecked Sendable { var gets = 0; var etagsSeen: [String?] = [] }
        struct Counting: GuideFileFetching {
            let inner: FixtureFetcher; let c: Counter
            func get(_ url: URL, etag: String?, lastModified: String?, maxBytes: Int64) async throws -> GuideFetched { c.gets += 1; c.etagsSeen.append(etag); return try await inner.get(url, etag: etag, lastModified: lastModified, maxBytes: maxBytes) }
        }
        let counter = Counter()
        let fetcher = Counting(inner: FixtureFetcher(files: ["blocklist.json": mini.appendingPathComponent("blocklist.json"), "channels.json": mini.appendingPathComponent("channels.json"),
                                                            "feeds.json": mini.appendingPathComponent("feeds.json"), "logos.json": mini.appendingPathComponent("logos.json")],
                                                     etags: ["blocklist.json": "b1", "channels.json": "c1", "feeds.json": "f1", "logos.json": "l1"]), c: counter)
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let db = IPTVOrgDatabase(directory: dir, fetcher: fetcher, clock: { clock.now })
        await #expect(throws: IPTVOrgError.blocklistUnavailable) { try await db.loadIndex() }
        try await db.refresh()
        #expect(counter.gets == 4)
        let index = try await db.loadIndex()
        #expect(index.count == 8 && index.blocked.count == 1)
        try await db.refresh()
        #expect(counter.gets == 4, "once a day: nothing is asked again within 24 h")
        clock.now.addTimeInterval(25 * 3600)
        try await db.refresh()
        #expect(counter.gets == 8 && counter.etagsSeen.suffix(4).allSatisfy { $0 != nil }, "conditional requests after a day")
        _ = try await db.loadIndex()
        // A block list older than 30 days is not trusted.
        clock.now.addTimeInterval(31 * 86400)
        await #expect(throws: IPTVOrgError.blocklistUnavailable) { try await db.loadIndex() }
    }

    @Test func publicDatabaseDownloadWithoutBlocklistNeverEnriches() async throws {
        let mini = GuideFixtures.url("iptvorg-mini")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iptvorg-\(UUID().uuidString)")
        let db = IPTVOrgDatabase(directory: dir, fetcher: FixtureFetcher(files: ["channels.json": mini.appendingPathComponent("channels.json")]))
        await #expect(throws: (any Error).self) { try await db.refresh() }
        await #expect(throws: IPTVOrgError.blocklistUnavailable) { try await db.loadIndex() }
    }

    // MARK: planner

    @Test func plannerRespectsIntervalsFailuresAndSwitches() {
        let now = GuideFixtures.iso("2026-11-22T12:00:00Z")
        func st(_ id: String, _ kind: GuideSourceKind, hours: Int, ago: Double?, fails: Int = 0, enabled: Bool = true) -> GuideRefreshPlanner.SourceState {
            GuideRefreshPlanner.SourceState(id: id, kind: kind, enabled: enabled, priority: kind.defaultPriority, refreshHours: hours, lastAttempt: ago.map { now.addingTimeInterval(-$0 * 3600) }, lastSuccess: ago.map { now.addingTimeInterval(-$0 * 3600) }, consecutiveFailures: fails)
        }
        let states = [st("p", .provider, hours: 6, ago: 7), st("u", .userXMLTV, hours: 1, ago: 0.5), st("pub", .publicIndex, hours: 1, ago: 10), st("off", .provider, hours: 6, ago: 99, enabled: false), st("new", .userXMLTV, hours: 6, ago: nil),
                      st("failed", .userXMLTV, hours: 6, ago: 0.001, fails: 1)]
        let due = GuideRefreshPlanner.due(states, .init(now: now))
        #expect(due.map(\.id) == ["p", "new"], "public database waits 24 h even if configured lower; failures back off")
        #expect(GuideRefreshPlanner.due(states, .init(now: now, onUnmeteredNetwork: false, wifiOnly: true)).isEmpty)
        #expect(Set(GuideRefreshPlanner.due(states, .init(now: now, force: true)).map(\.id)) == ["p", "u", "pub", "new", "failed"])
    }
}
