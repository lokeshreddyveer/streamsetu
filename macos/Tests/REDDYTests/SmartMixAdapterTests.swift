import Testing
import Foundation
@testable import REDDY

/// The SQL adapter, the stores and the coordinator, on a small real database.
@Suite("Smart Mix adapter", .serialized) struct SmartMixAdapterTests {
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository
    let s1: PlaylistSource, s2: PlaylistSource
    let hindi: String, general: String, adult: String

    private static func cat(_ id: String, _ s: PlaylistSource, _ name: String) -> CatalogCategory { CatalogCategory(id: id, sourceID: s.id, kind: .movie, providerID: id, name: name, sortOrder: 0) }
    private static func movie(_ s: PlaylistSource, _ pid: String, _ title: String, year: Int, cat: CatalogCategory, added: Double, poster: Bool = true) -> Movie {
        var m = TestSupport.movie(s, pid, title, year: year)
        m.categoryID = cat.id; m.categoryName = cat.name; m.addedAt = Date(timeIntervalSince1970: added); m.rating = "7.5"
        if poster { m.posterURL = "https://img.example/\(pid).jpg" }
        return m
    }

    init() throws {
        db = try TestSupport.makeDB()
        catalog = SQLiteCatalogRepository(db: db)
        s1 = try TestSupport.makeSource(db, name: "One"); s2 = try TestSupport.makeSource(db, name: "Two")
        let c1 = Self.cat("c-hindi", s1, "HINDI | MOVIES"), c2 = Self.cat("c-adult", s1, "ADULT | 18+"), c3 = Self.cat("c-gen", s2, "GENERAL")
        let now = Date().timeIntervalSince1970
        var a: [Movie] = []
        for i in 0..<30 { a.append(Self.movie(s1, "h\(i)", "Hindi Title \(i) (2021)", year: 2021, cat: c1, added: now - Double(i) * 86400)) }
        a.append(Self.movie(s1, "beta1", "Beta (2022)", year: 2022, cat: c1, added: now - 100))
        a.append(Self.movie(s1, "beta2", "Beta (2022) 4K", year: 2022, cat: c2, added: now - 100))
        a.append(Self.movie(s1, "alpha1", "Alpha (2020)", year: 2020, cat: c1, added: now - 50))
        a.append(Self.movie(s1, "adult1", "Hidden Thing (2020)", year: 2020, cat: c2, added: now - 10))
        let indexer = CatalogIndexer(db: db)
        _ = try indexer.commitMovies(source: s1, categories: [c1, c2], movies: a)
        _ = try indexer.commitMovies(source: s2, categories: [c3], movies: [Self.movie(s2, "alpha2", "Alpha (2020) HD", year: 2020, cat: c3, added: now - 40)])
        hindi = c1.id; general = c3.id; adult = c2.id
        try catalog.setCategoryLocked(adult, true, family: false)
    }

    private func read(profile: String = "main", scope: SMScope = .home, source: UUID? = nil) throws -> [SMCandidate] {
        try db.read { try SQLiteSmartMixCandidateSource.read($0, profile: profile, scope: scope, pool: 2000, source: source, lang: nil, trend: [], now: Date()) }
    }

    @Test func aTitleWithACopyInALockedFolderIsRestrictedOnEveryCopy() throws {
        let cs = try read()
        let beta = cs.filter { $0.key == "beta" }
        #expect(beta.count == 2 && beta.allSatisfy { $0.restricted }, "both copies of Beta are restricted because one sits in a locked folder")
        #expect(cs.filter { $0.key == "hidden thing" }.allSatisfy { $0.restricted })
        #expect(cs.filter { $0.key == "alpha" }.count == 2 && cs.filter { $0.key == "alpha" }.allSatisfy { !$0.restricted }, "twins in two playlists are both read and neither is restricted")
        #expect(Set(cs.filter { $0.key == "alpha" }.map(\.key)).count == 1)
    }

    @Test func theEngineNeverShowsARestrictedTitleFromTheRealPool() throws {
        let prepared = SmartMixEngine.prepare(try read(), preferredLang: nil)
        let ctx = SMContext(profile: "main", dayKey: "2026-11-20")
        for shelf in SMShelf.all {
            let r = SmartMixEngine.build(shelfId: shelf, prepared: prepared, ctx: ctx)
            #expect(!r.picks.contains { $0.key == "beta" || $0.key == "hidden thing" }, "\(shelf)")
        }
    }

    @Test func dismissedMarksEveryCopyAndOnlyForThatProfile() throws {
        let mem = RecommendationMemory(db: db, catalog: catalog)
        let alpha1 = ItemID.make(source: s1.id, kind: .movie, provider: "alpha1")
        #expect(try mem.dismiss(profileID: "main", itemID: alpha1))
        #expect(try read(profile: "main").filter { $0.key == "alpha" }.allSatisfy { $0.dismissed }, "the twin copy counts as dismissed too")
        #expect(try read(profile: "kid").filter { $0.key == "alpha" }.allSatisfy { !$0.dismissed })
        try mem.undismiss(profileID: "main", itemID: alpha1)
        #expect(try read(profile: "main").filter { $0.key == "alpha" }.allSatisfy { !$0.dismissed })
    }

    @Test func dismissingWritesOnlyTheMarkerAndNeverContinueWatching() throws {
        let hist = SQLiteHistoryRepository(db: db)
        let id = ItemID.make(source: s1.id, kind: .movie, provider: "h1")
        try hist.recordPlay(itemID: id, kind: .movie, title: "Hindi Title 1")
        try hist.saveProgress(WatchProgress(itemID: id, kind: .movie, seriesID: nil, positionSeconds: 100, durationSeconds: 6000, updatedAt: Date(), completed: false))
        func snapshot() throws -> [String] {
            try db.read { c in
                try ["watch_progress", "watch_history", "recently_watched"].flatMap { t in try c.query("SELECT quote(item_id)||quote(kind) FROM \(t)") { $0.string(0) } }
            }
        }
        let before = try snapshot()
        #expect(try RecommendationMemory(db: db, catalog: catalog).dismiss(profileID: "main", itemID: id))
        #expect(try snapshot() == before)
        #expect(try hist.continueWatching(limit: 10).contains { $0.itemID == id })
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM rec_dismissed") } == 1)
    }

    @Test func aRestrictedTitleCannotBeDismissedOrRemembered() throws {
        let beta2 = ItemID.make(source: s1.id, kind: .movie, provider: "beta2")
        #expect(try RecommendationMemory(db: db, catalog: catalog).dismiss(profileID: "main", itemID: beta2) == false)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM rec_dismissed") } == 0)
    }

    @Test func folderScopeReadsTheFolderAndEveryCopyOfItsTitles() throws {
        let folder = try db.read { try $0.queryOne("SELECT folder_key FROM content_identity WHERE item_id=?", [ItemID.make(source: s2.id, kind: .movie, provider: "alpha2")]) { $0.string(0) } } ?? ""
        let cs = try read(scope: .folder(folder))
        #expect(cs.contains { $0.key == "alpha" }, "the folder's own title is there")
        #expect(cs.count <= 2000)
    }

    @Test func theSourceFilterLimitsThePoolToOnePlaylist() throws {
        let only2 = try read(source: s2.id)
        #expect(only2.filter { !$0.id.hasPrefix(s2.id.uuidString.lowercased()) }.allSatisfy { $0.key == "alpha" }, "other playlists only appear as copies of titles in the pool")
        #expect(only2.contains { $0.key == "alpha" })
        #expect(!only2.contains { $0.key == "hindi title 3" })
    }

    // MARK: state store parity

    @Test func theSQLStateStoreBehavesLikeTheInMemoryOne() throws {
        let sql = SQLiteSmartMixStateStore(db: db), mem = InMemorySmartMixStateStore()
        let stores: [SmartMixStateStore] = [sql, mem]
        for s in stores {
            #expect(s.refreshCounter(profile: "p", shelf: "x") == 0)
            s.bumpRefresh(profile: "p", shelves: ["x", "y"]); s.bumpRefresh(profile: "p", shelves: ["x"])
            for load in 1...3 { s.recordShown(profile: "p", shelf: "x", loadKey: "d\(load)|0", rows: (0..<30).map { SMShownRow(key: "k\(load)-\($0)", year: 2020, itemId: "i\($0)", seq: 0) }) }
            s.recordShown(profile: "p", shelf: "x", loadKey: "d3|0", rows: [SMShownRow(key: "again", year: nil, itemId: "z", seq: 0)])
        }
        #expect(sql.refreshCounter(profile: "p", shelf: "x") == mem.refreshCounter(profile: "p", shelf: "x"))
        #expect(sql.refreshCounter(profile: "p", shelf: "y") == 1)
        #expect(sql.loadsAgo(profile: "p", shelf: "x", loadKey: "d4|0") == mem.loadsAgo(profile: "p", shelf: "x", loadKey: "d4|0"))
        #expect(sql.loadsAgo(profile: "p", shelf: "x", loadKey: "d3|0") == mem.loadsAgo(profile: "p", shelf: "x", loadKey: "d3|0"))
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM smartmix_shown WHERE profile_id='p' AND shelf_id='x'") } == 48, "bounded to 48 remembered rows")
        sql.forget(profile: "p", keys: ["k3-1"]); mem.forget(profile: "p", keys: ["k3-1"])
        #expect(sql.loadsAgo(profile: "p", shelf: "x", loadKey: "d4|0") == mem.loadsAgo(profile: "p", shelf: "x", loadKey: "d4|0"))
        #expect(sql.loadsAgo(profile: "other", shelf: "x", loadKey: "d4|0").isEmpty, "profile keyed")
        sql.clear(profile: "p")
        #expect(sql.loadsAgo(profile: "p", shelf: "x", loadKey: "d9").isEmpty && sql.refreshCounter(profile: "p", shelf: "x") == 0)
    }

    // MARK: coordinator

    @MainActor private func coordinator(key: String? = nil) throws -> (SmartMixCoordinator, UserDefaults) {
        let d = UserDefaults(suiteName: "smartmix-test-\(UUID().uuidString)")!
        let creds = InMemoryCredentialStore()
        if let key { try creds.save(Credentials(username: "tmdb", password: key), ref: MetadataMatchService.keyRef) }
        return (SmartMixCoordinator(db: db, catalog: catalog, memory: RecommendationMemory(db: db, catalog: catalog), credentials: creds, defaults: d), d)
    }

    @MainActor @Test func homeBuildsShelvesWithoutRestrictedTitlesAndWithoutANetworkRequest() async throws {
        let (c, _) = try coordinator()
        _ = try IdentityStore(db: db).backfill()
        let r = try #require(await c.home(profile: "main", sourceID: nil, preferredLanguage: ""))
        let all = r.shelves.flatMap(\.items) + r.heroOrder
        #expect(!all.isEmpty)
        #expect(!all.contains { $0.title.contains("Beta") || $0.title.contains("Hidden Thing") })
        #expect(c.hasOwnKey == false && c.policy().isActive == false, "ON by default but not active without the person's own key")
        #expect(r.diagnostics[SMShelf.topWeek]?.tmdb == "off")
    }

    @MainActor @Test func theTrendingSwitchIsOnByDefaultAndActiveOnlyWithAKey() throws {
        let (c, d) = try coordinator(key: "k")
        #expect(c.trendingEnabled && c.policy().isActive)
        c.trendingEnabled = false
        #expect(!c.policy().isActive && d.object(forKey: SmartMixCoordinator.enabledKey) as? Bool == false)
    }

    @MainActor @Test func reshuffleChangesTheCounterAndNeverTouchesTheLibrary() async throws {
        let (c, _) = try coordinator()
        let before = try db.read { try $0.scalarInt("SELECT COUNT(*) FROM sync_jobs") }
        c.reshuffle(profile: "main"); c.reshuffle(profile: "main")
        #expect(c.state.refreshCounter(profile: "main", shelf: SmartMixCoordinator.homeShelf) == 2)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM sync_jobs") } == before)
    }

    @MainActor @Test func invalidationBumpsTheRevisionSoCachedShelvesAreNotReused() async throws {
        let (c, _) = try coordinator()
        _ = try IdentityStore(db: db).backfill()
        _ = await c.home(profile: "main", sourceID: nil, preferredLanguage: "")
        let r0 = await c.source.revision(profile: "main")
        let builds0 = await c.session.buildCount
        _ = await c.home(profile: "main", sourceID: nil, preferredLanguage: "")
        let cacheHit = await c.session.buildCount - builds0
        c.invalidate(.lockOrRestrictionChange); c.invalidate(.profileSwitch); c.invalidate(.syncChanged); c.invalidate(.dismissChange)
        let r1 = await c.source.revision(profile: "main")
        #expect(r1.restrict == r0.restrict + 1 && r1.profileEpoch == r0.profileEpoch + 1 && r1.catalog == r0.catalog + 1 && r1.dismiss == r0.dismiss + 1)
        #expect(cacheHit == 1)
    }
}

@Suite("TMDB expiry", .serialized) struct TMDBExpiryTests {
    @Test func savedDetailsOlderThan180DaysAreDeletedAndTheWeeklyListHasTheSameCap() throws {
        let db = try TestSupport.makeDB()
        let svc = MetadataMatchService(db: db, credentials: InMemoryCredentialStore()) { _ in throw CancellationError() }
        let now = Date()
        try db.write { c in
            try c.execute("INSERT INTO title_details(item_id, json, fetched_at) VALUES('old','{}',?)", [now.timeIntervalSince1970 - 181 * 86400])
            try c.execute("INSERT INTO title_details(item_id, json, fetched_at) VALUES('new','{}',?)", [now.timeIntervalSince1970 - 10 * 86400])
        }
        #expect(svc.purgeExpired(now: now) == 1)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM title_details") } == 1)
        var p = SMTrendingPolicy(); p.hasOwnKey = true
        let cache = SMTrendingCache(fetchedAt: now.addingTimeInterval(-181 * 86400), entries: [])
        #expect(p.status(cache: cache, now: now) == .purged)
        p.enabled = false
        #expect(p.status(cache: cache, now: now) == .off && !p.needsRefetch(cache: nil, now: now), "switched off: nothing is requested")
    }
}
