import Testing
import Foundation
@testable import REDDY

@Suite("Guide hub: enrichment, sources, settings model") struct GuideWiringTests {
    func library(_ db: DatabaseManager) throws -> (PlaylistSource, [Channel]) {
        let s = try TestSupport.makeSource(db)
        var list = [TestSupport.channel(s, "1", "BBC One HD"), TestSupport.channel(s, "2", "BBC Two"), TestSupport.channel(s, "3", "CNN"), TestSupport.channel(s, "4", "Adult Example", cat: "Adult"), TestSupport.channel(s, "5", "Blocked News"),
                    TestSupport.channel(s, "6", "Comedy Central", cat: "Kids")]
        list[0].country = "uk"; list[1].country = "uk"; list[2].country = "us"; list[3].country = "us"; list[4].country = "uk"; list[1].logoURL = "https://provider.test/bbc2.png"
        try CatalogIndexer(db: db).commitChannels(source: s, categories: [], channels: list)
        return (s, list)
    }

    @Test func enrichmentOverlaysOnlyAllowedChannelsAndNeverTouchesTheirData() throws {
        let db = try GuideFixtures.tempDB()
        let (_, list) = try library(db)
        let svc = ChannelEnrichmentService(db: db)
        let r = try svc.apply(index: try GuideMappingTests.index())
        #expect(r.matched == 3 && r.logosGained == 2, "BBC One and CNN gain a logo; BBC Two keeps the playlist's")
        let ov = try svc.overlays(for: list.map(\.id))
        #expect(ov[list[0].id]?.logo == "https://example.test/logos/bbcone.png" && ov[list[0].id]?.genre == "general")
        #expect(ov[list[2].id]?.genre == "news" && ov[list[2].id]?.language == "eng")
        #expect(ov[list[3].id] == nil, "adult is never matched")
        #expect(ov[list[4].id] == nil, "blocklisted is never matched")
        #expect(ov[list[5].id] == nil, "kids category is never matched")
        #expect(r.skippedRestricted == 2)
        // channels table untouched
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM channels WHERE logo_url IS NOT NULL") } == 1)
        // provenance
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM field_provenance WHERE source='iptvorg' AND field='logo'") } == 2)
        try svc.undoAll()
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM channel_enrichment") } == 0)
    }

    @Test func aChannelLockedLaterLosesItsEnrichment() throws {
        let db = try GuideFixtures.tempDB()
        let (_, list) = try library(db)
        let svc = ChannelEnrichmentService(db: db)
        try svc.apply(index: try GuideMappingTests.index())
        try db.write { try $0.execute("INSERT INTO locked_categories(category_id) SELECT category_id FROM channels WHERE id=?", [list[0].id]) }
        try svc.apply(index: try GuideMappingTests.index())
        #expect(try svc.overlays(for: [list[0].id])[list[0].id] == nil)
    }

    @Test func logoFallbackOrderAndCategoryMapping() {
        #expect(GuideLogoResolver.resolve(.init(userChoice: "u", provider: "p", guideIcon: "https://g", enrichment: "https://e")).source == "user")
        #expect(GuideLogoResolver.resolve(.init(provider: "http://p", guideIcon: "https://g", enrichment: "https://e")).source == "provider")
        #expect(GuideLogoResolver.resolve(.init(provider: "http://p", providerFailed: true, guideIcon: "https://g", enrichment: "https://e")).source == "guide")
        #expect(GuideLogoResolver.resolve(.init(provider: nil, guideIcon: "http://insecure", enrichment: "https://e")).source == "iptvorg")
        #expect(GuideLogoResolver.resolve(.init()).source == "generated")
        #expect(GuideCategoryMapper.genre(["animation"]) == "kids" && GuideCategoryMapper.genre(["xxx"]) == nil && GuideCategoryMapper.genre(["weather", "news"]) == "news")
    }

    @Test func availabilityAndShift() {
        let fresh = GuideFreshness(level: .fresh, key: "guide.fresh", amount: 5), old = GuideFreshness(level: .warning, key: "guide.updatedLongAgo", amount: 3)
        #expect(GuideAvailability.evaluate(mapped: false, programmesNext3h: 4, freshness: fresh) == .none)
        #expect(GuideAvailability.evaluate(mapped: true, programmesNext3h: 0, freshness: fresh) == .mappedEmpty)
        #expect(GuideAvailability.evaluate(mapped: true, programmesNext3h: 2, freshness: fresh) == .nowNext)
        #expect(GuideAvailability.evaluate(mapped: true, programmesNext3h: 2, freshness: old) == .stale)
        #expect(GuideTimeShift.seconds(sourceMinutes: 60, channelMinutes: nil) == 3600 && GuideTimeShift.seconds(sourceMinutes: 60, channelMinutes: -30) == -1800)
        #expect(GuideTimeShift.suggestedHourShift(median: 7230) == 2 && GuideTimeShift.suggestedHourShift(median: 1800) == nil)
    }

    @Test func userGuideAddressIsStoredInTheCredentialStoreNotTheDatabase() async throws {
        let db = try GuideFixtures.tempDB()
        let creds = InMemoryCredentialStore()
        let mgr = GuideSourceManager(db: db, credentials: creds, fetcher: FixtureFetcher(files: ["g.xml": GuideFixtures.url("xmltv/basic.xml")]))
        #expect(throws: GuideSourceManager.AddError.badAddress) { try mgr.add(name: "x", address: "ftp://nope") }
        let t = await mgr.test("https://example.test/g.xml?token=SECRET9")
        #expect(t.valid && t.channels == 2 && t.programmes == 3 && !t.message.contains("SECRET9"))
        let bad = await mgr.test("https://example.test/missing.xml")
        #expect(!bad.valid)
        let id = try mgr.add(name: "", address: "https://example.test/g.xml?token=SECRET9")
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM guide_sources WHERE url IS NOT NULL OR url_ref NOT LIKE 'guide.%'") } == 0)
        #expect(try db.read { c in try c.queryOne("SELECT name FROM guide_sources WHERE id=?", [id]) { $0.string(0) } } == "example.test")
        // real refresh through the runner and the same adapter
        let res = try await mgr.refresh(force: true, now: GuideFixtures.iso("2026-11-22T17:00:00Z"))
        #expect(res[id]?.outcome == "ok" && res[id]?.stats.programmesKept == 3)
        let model = try GuideSettingsModel.load(db: db, defaults: UserDefaults(suiteName: "guide-test-\(UUID().uuidString)")!, now: GuideFixtures.iso("2026-11-22T17:00:00Z"))
        #expect(model.rows.count == 1 && model.rows[0].freshness.level != .error && model.enrichmentEnabled, "enrichment defaults on")
        try mgr.remove(id)
        #expect(try creds.load(ref: "guide." + id) == nil)
    }

    @Test func providerGuideGoesThroughTheSameAdapterAndAnEmptyOneIsExplained() async throws {
        let db = try GuideFixtures.tempDB()
        let s = try TestSupport.makeSource(db)
        try db.write { try $0.execute("UPDATE sources SET epg_url='https://example.test/old.xml' WHERE id=?", [s.id]) }
        try SQLiteGuideRepository(db: db).ensureProviderRow(sourceID: s.id)
        let mgr = GuideSourceManager(db: db, credentials: InMemoryCredentialStore(), fetcher: FixtureFetcher(files: ["old.xml": GuideFixtures.url("xmltv/all-past.xml")]))
        let now = GuideFixtures.iso("2026-11-22T12:00:00Z")
        let res = try await mgr.refresh(force: true, now: now)
        let key = "provider:" + s.id.uuidString.lowercased()
        #expect(res[key]?.outcome == "empty")
        let model = try GuideSettingsModel.load(db: db, now: now)
        let row = try #require(model.rows.first { $0.id == key })
        #expect(row.findings.first?.key == "diag.allPast" && model.worst == .error)
    }
}

@Suite("Guide hub: banner data") struct GuideBannerDataTests {
    @Test func aStaleAddedGuideProducesAWarningRow() throws {
        let db = try GuideFixtures.tempDB()
        let now = Date().timeIntervalSince1970
        try db.write { x in
            try x.execute("INSERT INTO guide_sources(id, kind, name, priority, enabled, refresh_hours, created_at) VALUES('user:b','userXMLTV','Extra guide',20,1,6,?)", [now])
            try x.execute("INSERT INTO guide_diagnostics(guide_source_id, last_attempt, last_success, outcome, programmes_kept) VALUES('user:b', ?, ?, 'ok', 100)", [now - 84 * 3600, now - 84 * 3600])
            try x.execute("INSERT INTO guide_import_state(guide_source_id, import_id, updated_at) VALUES('user:b', 1, ?)", [now - 84 * 3600])
            try x.execute("INSERT INTO guide_programmes(guide_source_id, xmltv_id, start_time, end_time, title, import_id) VALUES('user:b','a', ?, ?, 'Evening', 1)", [now - 3600, now + 30 * 3600])
        }
        let m = try GuideSettingsModel.load(db: db)
        let row = try #require(m.rows.first { $0.id == "user:b" })
        #expect(row.freshness.key == "guide.updatedLongAgo" && row.freshness.level == .warning, "got \(row.freshness.key) \(row.freshness.level)")
    }
}
