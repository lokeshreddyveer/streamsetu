import Testing
import Foundation
@testable import REDDY

/// Fixes from the independent review: hidden-folder rebuilds, TMDB privacy and the 180-day cap, twin restriction while identity is incomplete, folder-row polish.
@Suite("Review fixes", .serialized) @MainActor struct ReviewFixTests {
    private func cat(_ s: PlaylistSource, _ id: String, _ name: String, _ kind: ContentKind = .movie) -> CatalogCategory {
        CatalogCategory(id: id, sourceID: s.id, kind: kind, providerID: id, name: name, sortOrder: 0)
    }
    private func film(_ s: PlaylistSource, _ pid: String, _ title: String, folder: CatalogCategory, poster: String? = nil, year: Int = 2020) -> Movie {
        var m = TestSupport.movie(s, pid, title, year: year)
        m.categoryID = folder.id; m.categoryName = folder.name; m.posterURL = poster; m.addedAt = Date()
        return m
    }

    // MARK: H1

    @Test func hidingAFolderRebuildsEverythingKeyedByTheRestriction() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-h1-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "H")
        let f = cat(s, "hf", "Hide Me")
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [f], movies: [film(s, "a", "Alpha", folder: f)])
        let before = c.parental.restrictionRevision
        var observed = 0, changed = 0
        c.parental.observeRestriction { observed += 1 }
        c.parental.onChange = { changed += 1 }
        try c.favoritesRepo.hide("hf", kind: "category")
        for _ in 0..<50 where c.parental.restrictionRevision == before { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(c.parental.restrictionRevision == before + 1, "featured, Home and the folder rows are keyed by this revision")
        #expect(observed == 1 && changed == 1, "the featured cache purge, the widget and the catalog version are all driven from here")
    }

    // MARK: H2 / M5

    private func tmdbService(_ db: DatabaseManager, calls: LockedBox<[String]>, reply: String = #"{"results":[]}"#) throws -> MetadataMatchService {
        let creds = InMemoryCredentialStore()
        let svc = MetadataMatchService(db: db, credentials: creds, pause: 0) { req in calls.value.append(req.url?.path ?? ""); return Data(reply.utf8) }
        try svc.saveKey("k")
        return svc
    }

    private func tmdbLibrary() throws -> (DatabaseManager, [String: String], MetadataMatchService, LockedBox<[String]>) {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let open = cat(a, "A-open", "Open"), secret = cat(a, "A-secret", "Secret"), hid = cat(a, "A-hid", "Hid"), bopen = cat(b, "B-open", "Open")
        let idx = CatalogIndexer(db: db)
        let mA = [film(a, "1", "Plain Film", folder: open), film(a, "2", "Secret Film", folder: secret), film(a, "3", "Hidden Film", folder: hid), film(a, "4", "Cross Film", folder: secret)]
        _ = try idx.commitMovies(source: a, categories: [open, secret, hid], movies: mA)
        _ = try idx.commitMovies(source: b, categories: [bopen], movies: [film(b, "5", "Cross Film", folder: bopen)])
        let repo = SQLiteCatalogRepository(db: db)
        _ = try repo.setCategoryLocked("A-secret", true)
        try SQLiteFavoritesRepository(db: db).hide("A-hid", kind: "category")
        let calls = LockedBox<[String]>([])
        let ids = Dictionary(uniqueKeysWithValues: (mA + [film(b, "5", "Cross Film", folder: bopen)]).map { ($0.title + ($0.sourceID == b.id ? "-B" : ""), $0.id) })
        return (db, ids, try tmdbService(db, calls: calls), calls)
    }

    @Test func artworkMatchingNeverListsOrSendsARestrictedTitle() async throws {
        let (db, ids, svc, calls) = try tmdbLibrary()
        _ = try IdentityStore(db: db).backfill()
        let p = try svc.pending(limit: 50)
        #expect(p.items.map(\.id) == [ids["Plain Film"]!], "locked, hidden and twin-of-locked titles are left out, and so are they from the count: \(p.total)")
        #expect(p.total >= 1 && p.total <= 2)
        _ = try await svc.run()
        #expect((1...4).contains(calls.value.count), "only the one open title is looked up (a title that is not found is tried up to four ways)")
    }

    @Test func detailsOfARestrictedTitleAreNeverSentOrKept() async throws {
        let (db, ids, svc, calls) = try tmdbLibrary()
        _ = try IdentityStore(db: db).backfill()
        for name in ["Secret Film", "Hidden Film", "Cross Film-B"] {
            let cand = MetadataMatchService.Candidate(id: ids[name]!, isSeries: false, title: "x", year: 2020)
            #expect(await svc.details(for: cand) == nil)
        }
        #expect(calls.value.isEmpty, "nothing reached TMDB")
    }

    @Test func lockingOrHidingPurgesSavedDetailsOfTheFolderAndOfItsTwins() throws {
        let (db, ids, svc, _) = try tmdbLibrary()
        _ = try IdentityStore(db: db).backfill()
        try db.write { c in for n in ["Secret Film", "Cross Film-B", "Plain Film"] { try c.execute("INSERT INTO title_details(item_id, json, fetched_at) VALUES(?,?,?)", [ids[n]!, "{\"cast\":[]}", Date().timeIntervalSince1970]) } }
        svc.purgeStored(inFolders: ["A-secret"])
        let left = try db.read { try $0.query("SELECT item_id FROM title_details") { $0.string(0) } }
        #expect(left == [ids["Plain Film"]!], "the locked folder's rows and the twin copy under another playlist are gone")
    }

    @Test func tmdbFilledFieldsExpireAfter180DaysAndThePlaylistsOwnDataIsNeverTouched() async throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        let f = cat(a, "f", "F")
        var own = film(a, "o", "Own Film", folder: f, poster: "https://provider.example/own.jpg"); own.overview = "Provider summary"
        let bare = film(a, "b", "Plain Film", folder: f)
        _ = try CatalogIndexer(db: db).commitMovies(source: a, categories: [f], movies: [own, bare])
        let reply = #"{"results":[{"id":7,"title":"Plain Film","overview":"From TMDB","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"2020-05-01","vote_average":7.5}]}"#
        let svc = try tmdbService(db, calls: LockedBox([]), reply: reply)
        _ = try await svc.run()
        func row(_ id: String) throws -> (String?, String?) { try db.read { try $0.queryOne("SELECT poster_url, overview FROM movies WHERE id=?", [id]) { ($0.optString(0), $0.optString(1)) } }! }
        #expect(try row(bare.id).0?.contains("image.tmdb.org") == true && (try row(bare.id).1) == "From TMDB")
        #expect(svc.purgeExpired(now: Date().addingTimeInterval(100 * 86400)) == 0, "not yet")
        #expect(svc.purgeExpired(now: Date().addingTimeInterval(181 * 86400)) > 0)
        let after = try row(bare.id)
        #expect((after.0 ?? "").isEmpty && (after.1 ?? "").isEmpty, "everything TMDB wrote into the row is taken back")
        #expect(try row(own.id).0 == "https://provider.example/own.jpg" && (try row(own.id).1) == "Provider summary")
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM metadata_matches") } == 0)
    }

    @Test func thePrivacyTextDescribesWhatTheCodeDoes() {
        let t = TMDBAttribution.privacy
        #expect(t.contains("180 days") && t.contains("never sent") && t.contains("name and year"))
        #expect(MetadataMatchService.maxKeepDays == 180)
    }

    @Test func oneRuleDecidesWhichTMDBKeysAreSentAsAToken() {
        #expect(MetadataMatchService.isBearerToken("eyJabc") && MetadataMatchService.isBearerToken(String(repeating: "a", count: 41)) && !MetadataMatchService.isBearerToken("0123456789abcdef"))
    }

    // MARK: H3

    @Test func aRestrictedCopyWithNoIdentityRowStillRestrictsItsTwin() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let secret = cat(a, "A-secret", "Adult"), open = cat(b, "B-open", "General")
        let idx = CatalogIndexer(db: db)
        let hidden = film(a, "1", "Zed Story (2020)", folder: secret), visible = film(b, "1", "Zed Story (2020)", folder: open)
        _ = try idx.commitMovies(source: a, categories: [secret], movies: [hidden])
        _ = try idx.commitMovies(source: b, categories: [open], movies: [visible])
        let repo = SQLiteCatalogRepository(db: db)
        _ = try repo.setCategoryLocked("A-secret", true)
        try db.write { try $0.execute("DELETE FROM content_identity WHERE item_id=?", [hidden.id]) }          // the locked copy has not been backfilled yet
        #expect(try repo.recommendableIDs([visible.id]).isEmpty, "the title rule fails closed even though the visible copy has an identity row")
        let cands = try db.read { try SQLiteSmartMixCandidateSource.read($0, profile: "main", scope: .home, pool: 100, source: nil, lang: nil, trend: [], now: Date()) }
        #expect(cands.count == 1 && cands[0].restricted, "Smart Mix marks it restricted too")
    }

    // MARK: M6 / M7

    @Test func coverageIsCountedOnceNotOncePerFolderRow() throws {
        let db = try TestSupport.makeDB()
        let src = SQLiteSmartMixCandidateSource(db: db)
        for _ in 0..<20 { _ = src.coverageOK() }
        #expect(src.coverageScans == 1)
        src.bump(\.catalog)
        _ = src.coverageOK()
        #expect(src.coverageScans == 2)
    }

    @Test func backfillBatchesDoNotReadTheWholePlaylistAndStillFinish() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        let f = cat(a, "f", "F")
        _ = try CatalogIndexer(db: db).commitMovies(source: a, categories: [f], movies: (0..<50).map { film(a, "m\($0)", "Film Number \($0)", folder: f) })
        try db.write { try $0.execute("DELETE FROM content_identity") }
        let store = IdentityStore(db: db)
        #expect(try store.backfill(batch: 20) == 20 && store.backfill(batch: 20) == 20 && store.backfill(batch: 20) == 10 && store.backfill(batch: 20) == 0)
        #expect(try store.coverage().done == 50)
        #expect(try store.refreshTwins().isEmpty)
    }

    // MARK: folder rows

    @Test func acronymsAreUppercasedWithoutTouchingRealWords() {
        #expect(FolderNaming.clean("ENGLISH | FHD 2026") == "English · FHD 2026")
        #expect(FolderNaming.clean("English | 4k") == "English · 4K")
        #expect(FolderNaming.clean("English Fhd") == "English FHD")
        #expect(FolderNaming.clean("Movies | Hd Uk") == "Movies · HD UK")
        #expect(FolderNaming.clean("Shdow Hdr10 Tvs") == "Shdow HDR10 Tvs", "only whole words")
        #expect(FolderNaming.clean("Cam Releases") == "Cam Releases", "CAM is a quality rank, not an acronym to restyle")
        #expect(FolderNaming.clean("Sdn Movies") == "Sdn Movies")
    }

    @Test func theQuietLineIsAShortGenreOrTheYearAndNeverTheFolder() {
        func movie(_ genre: String?, title: String = "Some Film", year: Int? = 2022, category: String = "ENGLISH | 4K") -> LibraryItem {
            let s = try! TestSupport.makeSource(TestSupport.makeDB())
            var m = TestSupport.movie(s, "1", title, year: year); m.genre = genre; m.categoryName = category
            return .movie(m)
        }
        #expect(FolderTileLine.line(for: movie("Comedy"), folder: "ENGLISH | 4K") == "Comedy")
        #expect(FolderTileLine.line(for: movie("ENGLISH | FHD 2026"), folder: "ENGLISH | 4K") == "2022")
        #expect(FolderTileLine.line(for: movie("English"), folder: "English · 4K") == "2022", "repeats the folder")
        #expect(FolderTileLine.line(for: movie("4K"), folder: "Hindi") == "2022")
        #expect(FolderTileLine.line(for: movie(nil, title: "Some Film (2022)"), folder: "Hindi") == nil)
        #expect(movie(nil).quietLine == "2022", "the folder name never stands in for a genre")
    }

    @Test func titlesWithPostersLeadAndOthersFollowOnlyWhenNeeded() {
        let s = try! TestSupport.makeSource(TestSupport.makeDB())
        func m(_ i: Int, poster: Bool) -> LibraryItem { var x = TestSupport.movie(s, "\(i)", "T\(i)"); x.posterURL = poster ? "https://i.example/\(i).jpg" : nil; return .movie(x) }
        let few = [m(0, poster: false), m(1, poster: true), m(2, poster: false), m(3, poster: true)]
        #expect(FolderTileOrder.preferPosters(few).map(\.id) == few.filter { $0.posterURL != nil }.map(\.id) + few.filter { $0.posterURL == nil }.map(\.id))
        let many = (0..<10).map { m($0, poster: $0 % 3 != 0) }
        #expect(FolderTileOrder.preferPosters(many).allSatisfy { $0.posterURL != nil })
    }

    @Test func aSavedScrollRowPastThePageIsRevealed() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-m2-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "S")
        var cats: [CatalogCategory] = [], movies: [Movie] = []
        for i in 0..<40 { let f = cat(s, "f\(i)", "Folder \(i)"); cats.append(f); movies.append(film(s, "m\(i)", "Film \(i)", folder: f)) }
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: cats, movies: movies)
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        let target = m.rows[25].id
        #expect(!m.visible.contains { $0.id == target })
        #expect(m.reveal(target) && m.visible.contains { $0.id == target })
        #expect(!m.reveal("nope"))
        await m.reload(c, sourceID: nil, profile: "main")
        #expect(m.visible.count >= 26, "a rebuild keeps what was already scrolled into view")
    }

    @Test func recentlyWatchedChannelsOfALockedFolderAreNeitherShownNorCounted() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-m3-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "S")
        var ch = TestSupport.channel(s, "c1", "Secret One", cat: nil); ch.categoryID = "lock-ch"; ch.categoryName = "Locked"
        _ = try CatalogIndexer(db: c.db).commitChannels(source: s, categories: [cat(s, "lock-ch", "Locked", .channel)], channels: [ch])
        try c.historyRepo.recordPlay(itemID: ch.id, kind: .channel, title: ch.name)
        _ = try c.catalog.setCategoryLocked("lock-ch", true)
        c.catalog.restriction.isActive = true
        let m = FolderRowsModel(kind: .channel)
        await m.reload(c, sourceID: nil, profile: "main")
        #expect(!m.rows.contains { $0.special == "recent" }, "no \"Recently Watched · 1\" row that gives away a locked channel")
    }

    @Test func foldersNamedOnlyWithSymbolsStaySeparateRows() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-l3-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "S")
        let names = ["🎬", "⭐️⭐️", "★"]
        var cats: [CatalogCategory] = [], movies: [Movie] = []
        for (i, n) in names.enumerated() { let f = cat(s, "e\(i)", n); cats.append(f); movies.append(film(s, "m\(i)", "Film \(i)", folder: f)) }
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: cats, movies: movies)
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        #expect(m.rows.count == 3)
    }

    @Test func headerTextReadsNaturally() {
        let r = FolderRowsModel.Row(id: "1", name: "ENGLISH | 4K", display: "English · 4K", count: 1058, locked: false, sourceID: UUID())
        #expect(r.countText == "(1,058)" && r.accessibilityTitle(.title) == "English 4K, 1,058 titles" && r.accessibilityTitle(.channel) == "English 4K, 1,058 channels")
        let l = FolderRowsModel.Row(id: "2", name: "X", display: "Adult", count: 0, locked: true, sourceID: UUID())
        #expect(l.accessibilityTitle(.channel) == "Adult, locked folder")
    }

    @Test func homeShelvesCarryNoCategoryCaption() throws {
        let db = try TestSupport.makeDB()
        let s = try TestSupport.makeSource(db, name: "S")
        let f = cat(s, "n", "NETFLIX | ENGLISH MOVIES")
        _ = try CatalogIndexer(db: db).commitMovies(source: s, categories: [f], movies: (0..<8).map { film(s, "m\($0)", "Film \($0)", folder: f, poster: "https://i.example/\($0).jpg") })
        let content = try DiscoverService(catalog: SQLiteCatalogRepository(db: db), history: SQLiteHistoryRepository(db: db)).build(sourceID: nil)
        let shelf = try #require(content.shelves.first { $0.id == "Netflix" })
        #expect(shelf.caption.isEmpty)
    }

    // MARK: round 2

    @Test func theTwinTitleFallbackOnlyCatchesRealTwinsWithoutIdentity() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let secret = cat(a, "A-secret", "Adult"), open = cat(b, "B-open", "General")
        let idx = CatalogIndexer(db: db)
        let locked = film(a, "1", "Crash", folder: secret, year: 1996)
        let sameYear = film(b, "1", "Crash", folder: open, year: 1996), otherFilm = film(b, "2", "Crash", folder: open, year: 2004)
        _ = try idx.commitMovies(source: a, categories: [secret], movies: [locked])
        _ = try idx.commitMovies(source: b, categories: [open], movies: [sameYear, otherFilm])
        let repo = SQLiteCatalogRepository(db: db)
        _ = try repo.setCategoryLocked("A-secret", true)
        // identity present everywhere: the identity rule decides, so the unrelated 2004 film stays recommendable
        #expect(try repo.recommendableIDs([sameYear.id, otherFilm.id]) == [otherFilm.id])
        // the locked copy not yet backfilled: still only the same-year copy is caught
        try db.write { try $0.execute("DELETE FROM content_identity WHERE item_id=?", [locked.id]) }
        #expect(try repo.recommendableIDs([sameYear.id, otherFilm.id]) == [otherFilm.id])
        let cands = try db.read { try SQLiteSmartMixCandidateSource.read($0, profile: "main", scope: .home, pool: 100, source: nil, lang: nil, trend: [], now: Date()) }
        #expect(cands.first { $0.id == sameYear.id }?.restricted == true && cands.first { $0.id == otherFilm.id }?.restricted == false)
        let svc = try tmdbService(db, calls: LockedBox([]))
        #expect(svc.isSendable(otherFilm.id) && !svc.isSendable(sameYear.id))
    }

    @Test func aHiddenSingleTitleRestrictsItsTwinCopyInTheCatalogView() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let fa = cat(a, "A-f", "Movies"), fb = cat(b, "B-f", "Movies")
        let idx = CatalogIndexer(db: db)
        let one = film(a, "1", "Twin Pair", folder: fa, year: 2015), two = film(b, "1", "Twin Pair", folder: fb, year: 2015), other = film(b, "2", "Another", folder: fb, year: 2016)
        _ = try idx.commitMovies(source: a, categories: [fa], movies: [one])
        _ = try idx.commitMovies(source: b, categories: [fb], movies: [two, other])
        try SQLiteFavoritesRepository(db: db).hide(one.id, kind: "movie")
        let repo = SQLiteCatalogRepository(db: db)
        #expect(try repo.recommendableIDs([one.id, two.id, other.id]) == [other.id])
        #expect(try repo.recommendationView.movies(VODQuery(sort: .recentlyAdded, limit: 10)).map(\.id) == [other.id])
    }

    @Test func unhidingAndHidingASingleTitleAlsoRefreshWhatIsKeyedByTheRestriction() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-m2-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "H")
        let f = cat(s, "hf", "F")
        let m = film(s, "a", "Alpha", folder: f)
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [f], movies: [m])
        func waitForRevision(after r: Int) async throws { for _ in 0..<50 where c.parental.restrictionRevision == r { try await Task.sleep(nanoseconds: 20_000_000) } }
        var r = c.parental.restrictionRevision
        try c.favoritesRepo.hide(m.id, kind: "movie")
        try await waitForRevision(after: r)
        #expect(c.parental.restrictionRevision == r + 1, "hiding one title")
        r = c.parental.restrictionRevision
        try c.favoritesRepo.unhide(m.id)
        try await waitForRevision(after: r)
        #expect(c.parental.restrictionRevision == r + 1, "showing it again")
    }

    @Test func rowsOnScreenAreAskedAgainAfterEveryReload() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-h1b-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "S")
        let f = cat(s, "f1", "Folder One")
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [f], movies: [film(s, "m", "Film", folder: f, poster: "https://i.example/1.jpg")])
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        let e0 = m.epoch
        await m.ensureTiles(m.rows[0], c, sourceID: nil, profile: "main")
        #expect(m.tiles["f1"] != nil)
        await m.reload(c, sourceID: nil, profile: "main")
        #expect(m.epoch == e0 + 1 && m.tiles["f1"] == nil, "tiles are cleared and the row's task key (which holds the epoch) changed, so it asks again")
        await m.ensureTiles(m.rows[0], c, sourceID: nil, profile: "main")
        #expect(m.tiles["f1"] != nil)
    }

    @Test func aFolderOpenedWithThePINListsItsOwnTitles() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-l2-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "S")
        let f = cat(s, "lk", "Locked One")
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [f], movies: [film(s, "m", "Film", folder: f, poster: "https://i.example/1.jpg")])
        _ = try c.catalog.setCategoryLocked("lk", true)
        c.catalog.restriction.isActive = false          // unlocked session
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        let row = try #require(m.rows.first { $0.id == "lk" })
        #expect(!row.locked && row.sessionUnlocked)
        await m.ensureTiles(row, c, sourceID: nil, profile: "main")
        #expect(m.tiles["lk"]?.count == 1)
    }

    // MARK: round 3

    @Test func aVisibleTwinWithNoIdentityRowIsStillRestrictedWhenTheLockedCopyHasOne() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let secret = cat(a, "A-secret", "Adult"), open = cat(b, "B-open", "General")
        let idx = CatalogIndexer(db: db)
        let locked = film(a, "1", "Zed Story", folder: secret, year: 2020)
        let visible = film(b, "1", "Zed Story", folder: open, year: 2020), unrelated = film(b, "2", "Zed Story", folder: open, year: 1990)
        _ = try idx.commitMovies(source: a, categories: [secret], movies: [locked])
        _ = try idx.commitMovies(source: b, categories: [open], movies: [visible, unrelated])
        let repo = SQLiteCatalogRepository(db: db)
        _ = try repo.setCategoryLocked("A-secret", true)
        try db.write { try $0.execute("DELETE FROM content_identity WHERE item_id IN (?,?)", [visible.id, unrelated.id]) }          // not backfilled yet
        #expect(try repo.recommendableIDs([visible.id, unrelated.id]) == [unrelated.id])
        #expect(try repo.recommendationView.movies(VODQuery(sort: .recentlyAdded, limit: 10)).map(\.id) == [unrelated.id])
    }

    @Test func aReloadThatOnlyMeansSomethingChangedKeepsTheRowsAndTheirTiles() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-m1-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "S")
        let f = cat(s, "f1", "Folder One")
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [f], movies: [film(s, "m", "Film", folder: f, poster: "https://i.example/1.jpg")])
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main", restrictionKey: "1-main")
        await m.ensureTiles(m.rows[0], c, sourceID: nil, profile: "main")
        let e = m.epoch
        await m.reload(c, sourceID: nil, profile: "main", restrictionKey: "1-main")          // a sync, a removed Continue Watching entry
        #expect(m.epoch == e && m.tiles["f1"] != nil, "no placeholders, no reset scroll, no refetch")
        await m.reload(c, sourceID: nil, profile: "main", restrictionKey: "2-main")          // a lock or hide
        #expect(m.epoch == e + 1 && m.tiles["f1"] == nil)
        await m.reload(c, sourceID: nil, profile: "kid", restrictionKey: "2-kid")          // another profile
        #expect(m.epoch == e + 2)
    }

    @Test func aPersonsPageMatchesTheWholeNameNotAPrefix() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        let f = cat(a, "f", "F")
        let one = film(a, "1", "One", folder: f), two = film(a, "2", "Two", folder: f)
        _ = try CatalogIndexer(db: db).commitMovies(source: a, categories: [f], movies: [one, two])
        let people = PeopleIndex(db: db)
        try people.save(itemID: one.id, kind: .movie, sourceID: a.id, names: ["Ram Charan"])
        try people.save(itemID: two.id, kind: .movie, sourceID: a.id, names: ["Ramesh Babu"])
        #expect(Set(people.hits(term: "Ram", kinds: [.movie], sourceID: nil, limit: 10).map(\.itemID)) == [one.id, two.id], "search keeps word-start matching")
        #expect(people.hits(term: "Ram Charan", kinds: [.movie], sourceID: nil, limit: 10, exact: true).map(\.itemID) == [one.id])
        #expect(people.hits(term: "Ram", kinds: [.movie], sourceID: nil, limit: 10, exact: true).isEmpty)
    }
}
