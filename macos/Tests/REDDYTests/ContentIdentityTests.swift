import Testing
import Foundation
@testable import REDDY

/// The canonical content-identity layer: derived data beside the catalog, never a change to it.
@Suite("Content identity") struct ContentIdentityTests {
    // MARK: helpers

    func movie(_ s: PlaylistSource, _ pid: String, _ title: String, year: Int?, folder: String = "General", cat: String? = nil, added: Double = 1_700_000_000,
               duration: Double? = nil, rating: String? = nil) -> Movie {
        var m = TestSupport.movie(s, pid, title, year: year)
        m.categoryName = folder; m.categoryID = cat ?? "cat-\(s.id.uuidString.prefix(4))-\(folder)"
        m.addedAt = Date(timeIntervalSince1970: added); m.durationSeconds = duration; m.rating = rating
        return m
    }
    func categories(_ s: PlaylistSource, _ items: [Movie]) -> [CatalogCategory] {
        var seen = Set<String>(); var out: [CatalogCategory] = []
        for m in items { if let id = m.categoryID, seen.insert(id).inserted { out.append(CatalogCategory(id: id, sourceID: s.id, kind: .movie, providerID: id, name: m.categoryName ?? "x", sortOrder: out.count)) } }
        return out
    }
    func commit(_ db: DatabaseManager, _ s: PlaylistSource, _ items: [Movie]) throws -> IndexResult {
        try CatalogIndexer(db: db).commitMovies(source: s, categories: categories(s, items), movies: items)
    }
    /// A checksum of every column of every row of the tables identity must never change.
    func checksum(_ db: DatabaseManager) throws -> [String: String] {
        try db.read { c in
            var out: [String: String] = [:]
            for t in ["movies", "series", "channels", "episodes", "categories", "sources"] {
                let cols = try c.query("PRAGMA table_info(\(t))") { $0.string(1) }
                let rows = try c.query("SELECT \(cols.map { "quote(\($0))" }.joined(separator: " || '|' || ")) FROM \(t) ORDER BY 1") { $0.string(0) }
                var h: UInt64 = 0xcbf29ce484222325
                for r in rows { for b in r.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }; h = (h ^ 10) &* 0x100000001b3 }
                out[t] = "\(rows.count):\(h)"
            }
            return out
        }
    }

    // MARK: the key

    @Test func theKeyMatchesTheRuleOtherLanguagesAlreadyUses() {
        for t in ["Leo (2023) (Tamil) FHD", "Leo 2023 Hindi", "The Dark Knight (2008) 4K", "A Quiet Place [Telugu]", "Dune: Part Two (2024) HD", "Tom & Jerry (2021)", "Fast and Furious 7 Hindi Dubbed",
                  "L'Auberge Espagnole (2002)", "Amélie (2001)", "Spider-Man: No Way Home (2021) CAM", "The 100"] {
            #expect(IdentityKey.make(t) == OtherLanguages.matchKey(t), "\(t): \(IdentityKey.make(t)) vs \(OtherLanguages.matchKey(t))")
        }
    }

    @Test func theKeyIgnoresYearQualityLanguageAndAccents() {
        #expect(IdentityKey.make("Leo (2023) (Tamil) FHD") == "leo")
        #expect(IdentityKey.make("LEO 2023 Hindi") == "leo")
        #expect(IdentityKey.make("Amélie (2001)") == IdentityKey.make("Amelie 2001 HD"))
        #expect(IdentityKey.make("The Matrix") == IdentityKey.make("Matrix (1999)"))
        #expect(IdentityKey.make("Dune (1984)") == IdentityKey.make("Dune (2021)"), "the key alone does not tell remakes apart; the year does")
        #expect(IdentityKey.make("HD English") == "hd english", "a title made only of tags keeps its words")
        #expect(IdentityKey.make("தமிழ் படம் (2020)") == "தமிழ் படம்", "non-Latin scripts are kept")
    }

    @Test func deriveReadsLanguageQualityAndFolderFamily() {
        let a = IdentityDerive.derive(title: "Leo (2023) FHD", categoryName: "TELUGU | GENERAL", year: nil, kind: .movie)
        #expect(a.key == "leo" && a.year == 2023 && a.language == "Telugu" && a.qualityRank == 4 && !a.isCam && a.folderKey == "movie|telugu general")
        #expect(IdentityDerive.derive(title: "Leo (2023) (Hindi) 4K", categoryName: "General", year: 2023, kind: .movie).qualityRank == 5)
        #expect(IdentityDerive.derive(title: "Leo", categoryName: "General", year: 2023, kind: .movie).qualityRank == 2, "unmarked sits between HD and SD")
        #expect(IdentityDerive.derive(title: "Leo SD", categoryName: nil, year: nil, kind: .movie).qualityRank == 1)
        let cam = IdentityDerive.derive(title: "Leo HDCAM", categoryName: nil, year: nil, kind: .movie)
        #expect(cam.isCam && cam.qualityRank == 0)
        #expect(IdentityDerive.derive(title: "Leo", categoryName: "ENGLISH | ARABIC SUBTITLES", year: nil, kind: .movie).language == "English")
        #expect(IdentityDerive.derive(title: "Leo", categoryName: "HINDI DUBBED", year: nil, kind: .movie).language == "Hindi")
    }

    // MARK: choosing the copy

    private func member(_ id: String, source: UUID, lang: String? = nil, q: Int = 2, added: Double = 0) -> IdentityMember {
        IdentityMember(itemID: id, sourceID: source, language: lang, qualityRank: q, isCam: q == 0, year: 2020, addedAt: added)
    }

    @Test func theCanonicalCopyFollowsLanguageThenQualityThenSourceThenNewestThenId() {
        let s1 = UUID(), s2 = UUID()
        let ctx = CanonicalPick.Context(preferredLanguage: "Telugu", sourceRank: [s1: 0, s2: 1])
        let hindi4k = member("a", source: s1, lang: "Hindi", q: 5), telugu = member("b", source: s2, lang: "Telugu", q: 2), teluguHD = member("c", source: s2, lang: "Telugu", q: 3)
        #expect(CanonicalPick.pick([hindi4k, telugu, teluguHD], context: ctx)?.itemID == "c", "preferred language first, then the better picture")
        let x = member("x", source: s1, q: 4, added: 10), y = member("y", source: s2, q: 4, added: 99)
        #expect(CanonicalPick.pick([y, x], context: .init(sourceRank: [s1: 0, s2: 1]))?.itemID == "x", "same picture: the preferred playlist, not the newer one")
        #expect(CanonicalPick.pick([y, x], context: .init(sourceRank: [s1: 1, s2: 0]))?.itemID == "y")
        let n1 = member("n1", source: s1, q: 4, added: 10), n2 = member("n2", source: s1, q: 4, added: 20)
        #expect(CanonicalPick.pick([n1, n2], context: .init())?.itemID == "n2", "then the newest")
        #expect(CanonicalPick.pick([member("b2", source: s1), member("b1", source: s1)], context: .init())?.itemID == "b1", "last, the id bytewise")
        let cam = member("cam", source: s1, q: 0), sd = member("sd", source: s2, q: 1)
        #expect(CanonicalPick.pick([cam, sd], context: .init())?.itemID == "sd", "a cinema recording is last")
        // The order never depends on the order the copies arrive in.
        let all = [hindi4k, telugu, teluguHD, x, y, n1, n2, cam, sd]
        let expected = CanonicalPick.ordered(all, context: ctx).map(\.itemID)
        for _ in 0..<20 { #expect(CanonicalPick.ordered(all.shuffled(), context: ctx).map(\.itemID) == expected) }
    }

    @Test func thePreferredSourceIsEnabledHealthyThenChosenThenOrdered() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func s(_ n: Int, enabled: Bool = true, status: String = "completed", ageDays: Double = 1, order: Int = 0) -> SourceHealth {
            SourceHealth(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!, enabled: enabled, syncStatus: status, lastSync: now.addingTimeInterval(-ageDays * 86400), sortOrder: order)
        }
        let ok = s(1, order: 1), failed = s(2, status: "failed", order: 0), stale = s(3, ageDays: 20, order: 0), off = s(4, enabled: false, order: 0), second = s(5, order: 2)
        let r = PreferredSource.ranking([failed, stale, off, second, ok], now: now)
        #expect(r[ok.id]! < r[second.id]! && r[second.id]! < r[failed.id]! && r[second.id]! < r[stale.id]! && r[failed.id]! < r[off.id]! && r[stale.id]! < r[off.id]!)
        #expect(PreferredSource.ranking([ok, second], userPreferred: second.id, now: now)[second.id] == 0, "the person's own choice beats the playlist order")
        #expect(PreferredSource.ranking([failed], now: now)[failed.id] == 0)
        let alone = s(6, ageDays: 40)
        #expect(PreferredSource.ranking([alone, off], now: now)[alone.id] == 0, "the only enabled playlist is healthy however old")
        let a = s(7), b = s(8)
        #expect(PreferredSource.ranking([b, a], now: now) == PreferredSource.ranking([a, b], now: now), "ties break on the id, not on arrival order")
    }

    // MARK: schema

    @Test func theMigrationIsAdditiveAndKeepsEveryOldRow() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-v18-\(UUID().uuidString).sqlite").path
        let conn = try Connection(path: path, readOnly: false)
        try conn.exec("PRAGMA foreign_keys=ON")
        for m in DatabaseMigrator.migrations where m.version <= 18 { try conn.exec(m.sql); try conn.exec("PRAGMA user_version = \(m.version)") }
        try conn.exec("""
            INSERT INTO sources(id, name, type, base_url, created_at) VALUES('s1','Old','m3uRemote','http://x',1);
            INSERT INTO movies(id, source_id, provider_id, title, normalized_title, stream_ref, created_at, updated_at, last_seen_at, category_id, category_name, release_year)
                VALUES('s1|movie|1','s1','1','Old Film (2001)','old film 2001','1.mp4',1,1,1,'c1','Old',2001);
            INSERT INTO locked_categories(category_id) VALUES('c1');
            """)
        let before = try conn.query("SELECT quote(id), quote(title), quote(stream_ref), quote(category_id) FROM movies") { "\($0.string(0))\($0.string(1))\($0.string(2))\($0.string(3))" }
        try DatabaseMigrator.migrate(conn)
        #expect(try conn.scalarInt("PRAGMA user_version") == DatabaseMigrator.latestVersion && DatabaseMigrator.latestVersion >= 20)
        let after = try conn.query("SELECT quote(id), quote(title), quote(stream_ref), quote(category_id) FROM movies") { "\($0.string(0))\($0.string(1))\($0.string(2))\($0.string(3))" }
        #expect(before == after)
        #expect(try conn.scalarInt("SELECT COUNT(*) FROM locked_categories") == 1)
        let tables = Set(try conn.query("SELECT name FROM sqlite_master WHERE type='table'") { $0.string(0) })
        #expect(tables.isSuperset(of: ["content_identity", "source_twin", "rec_dismissed", "smartmix_shown", "smartmix_state", "folder_recent"]))
        let indexes = Set(try conn.query("SELECT name FROM sqlite_master WHERE type='index'") { $0.string(0) })
        #expect(indexes.isSuperset(of: ["idx_ci_key", "idx_ci_source", "idx_ci_folder", "idx_dismissed_key", "idx_shown_load"]))
        #expect(!indexes.contains("idx_movies_src_added"), "the big-table indexes are built in the background, not in the launch migration")
        for stmt in SchemaV19.lazyIndexSQL.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !stmt.isEmpty { try conn.exec(stmt) }
        let built = Set(try conn.query("SELECT name FROM sqlite_master WHERE type='index'") { $0.string(0) })
        #expect(built.isSuperset(of: ["idx_movies_src_added", "idx_movies_src_cat_add", "idx_series_src_cat_fs", "idx_categories_family", "idx_movies_recent2", "idx_series_rating2"]))
        try DatabaseMigrator.migrate(conn)          // running it again changes nothing
        #expect(try conn.scalarInt("PRAGMA user_version") == DatabaseMigrator.latestVersion)
    }

    @Test func identityNeverChangesAPlaylistRow() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        for s in [a, b] { _ = try commit(db, s, (0..<60).map { movie(s, "\($0)", "Film \($0 % 40) (\(2000 + $0 % 5))", year: 2000 + $0 % 5, folder: $0 % 3 == 0 ? "HINDI" : "TELUGU") }) }
        let before = try checksum(db)
        try db.write { try $0.execute("DELETE FROM content_identity") }
        let store = IdentityStore(db: db)
        store.backfillAll(batch: 25, pause: 0)
        _ = try store.refreshTwins()
        #expect(try checksum(db) == before, "backfill and twin detection wrote nothing to the catalog")
        let cov = try store.coverage()
        #expect(cov.done == cov.total && cov.total == 120)
    }

    // MARK: grouping, twins, alternatives, restriction

    @Test func twinPlaylistsShareAGroupAndEveryCopyStaysReachable() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let ia = movie(a, "1", "Leo (2023) FHD", year: 2023, folder: "TAMIL"), ib = movie(b, "9", "Leo 2023 4K", year: 2023, folder: "TAMIL")
        let hindi = movie(a, "2", "Leo (2023) (Hindi)", year: 2023, folder: "HINDI DUBBED")
        _ = try commit(db, a, [ia, hindi]); _ = try commit(db, b, [ib])
        let res = IdentityResolver(db: db)
        let g = try #require(try res.group(of: ia.id))
        #expect(Set(g.members.map(\.itemID)) == [ia.id, ib.id, hindi.id])
        #expect(g.canonical?.itemID == ib.id, "the 4K copy of the second playlist beats the FHD copy of the first")
        #expect(Set(g.alternatives.map(\.itemID)) == [ia.id, hindi.id], "both other copies stay reachable")
        #expect(!g.restricted)
        let tel = try #require(try res.group(of: ia.id, preferredLanguage: "Hindi"))
        #expect(tel.canonical?.itemID == hindi.id, "the preferred audio language leads")
        // Row-by-row: nothing about the playlists changed (ids, urls, metadata).
        #expect(try SQLiteCatalogRepository(db: db).movie(id: ib.id)?.streamRef == ib.streamRef)
    }

    @Test func aRestrictedCopyIsNeverAnAlternativeAndRestrictsTheGroup() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let locked = movie(a, "1", "Secret Thing (2020)", year: 2020, folder: "Locked Shelf", cat: "A-locked")
        let open = movie(b, "1", "Secret Thing (2020)", year: 2020, folder: "Open Shelf", cat: "B-open")
        _ = try commit(db, a, [locked]); _ = try commit(db, b, [open])
        let repo = SQLiteCatalogRepository(db: db)
        try repo.setCategoryLocked("A-locked", true)
        let g = try #require(try IdentityResolver(db: db).group(of: open.id))
        #expect(g.restricted, "any copy in a locked folder restricts the title")
        #expect(g.canonical?.itemID == open.id && g.alternatives.isEmpty, "the locked copy is not offered")
        #expect(Set(g.members.map(\.itemID)) == [locked.id, open.id])
    }

    @Test func remakesApartAndShortTitlesAreNotMerged() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        let items = [movie(a, "1", "Dune (1984)", year: 1984), movie(a, "2", "Dune (2021)", year: 2021),
                     movie(a, "3", "Stolen (2014)", year: 2014, duration: 6000, rating: "6.1"), movie(a, "4", "Stolen (2015)", year: 2015, duration: 6200, rating: "7.0"),
                     movie(a, "5", "Heat (1995)", year: 1995, duration: 10000, rating: "8.3"), movie(a, "6", "Heat (1996)", year: 1996, duration: 5000, rating: "5.0"),
                     movie(a, "7", "Moon Walker (2010)", year: 2010, duration: 6000, rating: "7.0"), movie(a, "8", "Moon Walker (2011)", year: 2011, duration: 6000, rating: "7.0"),
                     movie(a, "9", "Moon Walker 2012 Hindi", year: nil, folder: "HINDI")]
        _ = try commit(db, a, items)
        let r = IdentityResolver(db: db)
        #expect(try r.group(of: items[0].id)?.members.map(\.itemID) == [items[0].id], "37 years apart: not the same film")
        #expect(Set(try r.group(of: items[2].id)?.members.map(\.itemID) ?? []) == [items[2].id], "one-word title, a year apart, only one fact agrees: not merged")
        #expect(Set(try r.group(of: items[4].id)?.members.map(\.itemID) ?? []) == [items[4].id], "a year apart, nothing agrees: not merged")
        #expect(Set(try r.group(of: items[6].id)?.members.map(\.itemID) ?? []) == [items[6].id, items[7].id], "a year apart, two facts agree: the same film")
    }

    @Test func twinsAreRecognisedByOverlap() throws {
        func overlap(_ shared: Int, of total: Int) throws -> IdentityStore.Twin {
            let db = try TestSupport.makeDB()
            let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
            _ = try commit(db, a, (0..<total).map { movie(a, "\($0)", "Title \($0)", year: 2000 + $0 % 20) })
            _ = try commit(db, b, (0..<total).map { movie(b, "\($0)", $0 < shared ? "Title \($0)" : "Other \($0)", year: 2000 + $0 % 20) })
            let t = try #require(try IdentityStore(db: db).refreshTwins().first { $0.kind == .movie })
            return t
        }
        #expect(try overlap(100, of: 100).isTwin)
        #expect(try overlap(92, of: 100).isTwin)
        #expect(try !overlap(60, of: 100).isTwin)
    }

    // MARK: sync

    @Test func anUnchangedSyncWritesNothingToIdentityAndAChangedOneIsPatched() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        var items = (0..<500).map { movie(a, "\($0)", "Film Number \($0) (\(1990 + $0 % 30))", year: 1990 + $0 % 30, folder: "F\($0 % 5)") }
        let first = try commit(db, a, items)
        #expect(first.identity?.addedCount == 500 && first.identity?.bulk == false)
        let hashes = try db.read { try $0.query("SELECT item_id, in_hash FROM content_identity ORDER BY item_id") { "\($0.string(0))\($0.int(1))" } }
        let same = try commit(db, a, items)
        #expect(same.identity == nil, "the fingerprint matched: nothing was written")
        // +30 added, -20 removed, 25 whose title changed.
        items.removeFirst(20)
        for i in 0..<25 { items[i].title = items[i].title + " Extended"; items[i].normalizedTitle = MetadataNormalizer.normalize(items[i].title) }
        items += (1000..<1030).map { movie(a, "\($0)", "Brand New \($0)", year: 2024) }
        let r = try commit(db, a, items)
        let ch = try #require(r.identity)
        #expect(ch.addedCount == 30 && ch.removedCount == 20 && ch.changedCount == 25 && !ch.bulk)
        // Patched == a fresh rebuild from the same final catalog.
        let patched = try db.read { try $0.query("SELECT item_id, identity_key, year, lang, quality_rank, is_cam, folder_key, in_hash, ident_ver FROM content_identity ORDER BY item_id") { r in (0..<9).map { r.string($0) }.joined(separator: "|") } }
        let fresh = try TestSupport.makeDB()
        let a2 = PlaylistSource(id: a.id, name: "A", type: .m3uRemote, baseURL: "http://example.com/p.m3u"); try SQLiteCatalogRepository(db: fresh).save(source: a2)
        _ = try commit(fresh, a2, items)
        let rebuilt = try fresh.read { try $0.query("SELECT item_id, identity_key, year, lang, quality_rank, is_cam, folder_key, in_hash, ident_ver FROM content_identity ORDER BY item_id") { r in (0..<9).map { r.string($0) }.joined(separator: "|") } }
        #expect(patched == rebuilt)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM content_identity ci LEFT JOIN movies m ON m.id=ci.item_id WHERE m.id IS NULL") } == 0, "no identity row outlives its title")
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM movies m LEFT JOIN content_identity ci ON ci.item_id=m.id WHERE ci.item_id IS NULL") } == 0)
        _ = hashes
    }

    @Test func aFailedSyncLeavesIdentityAndCatalogAsTheyWere() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        let items = (0..<100).map { movie(a, "\($0)", "Film \($0)", year: 2000, folder: "F") }
        _ = try commit(db, a, items)
        let before = try db.read { try $0.query("SELECT item_id, in_hash FROM content_identity ORDER BY item_id") { "\($0.string(0))\($0.int(1))" } }
        #expect(throws: IndexError.self) { _ = try commit(db, a, []) }          // an empty answer is refused before anything is written
        #expect(throws: IndexError.self) { _ = try commit(db, a, Array(items.prefix(3))) }          // so is a far smaller one
        let after = try db.read { try $0.query("SELECT item_id, in_hash FROM content_identity ORDER BY item_id") { "\($0.string(0))\($0.int(1))" } }
        #expect(before == after)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM movies") } == 100)
    }

    @Test func removingAPlaylistRemovesItsIdentityAndKeepsTheTwinsGroup() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let ia = movie(a, "1", "Leo (2023)", year: 2023), ib = movie(b, "1", "Leo (2023)", year: 2023)
        _ = try commit(db, a, [ia]); _ = try commit(db, b, [ib])
        try SQLiteCatalogRepository(db: db).deleteSource(id: a.id)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM content_identity WHERE source_id=?", [a.id]) } == 0)
        #expect(try IdentityResolver(db: db).group(of: ib.id)?.members.map(\.itemID) == [ib.id])
    }

    @Test func backfillResumesAfterAnInterruptionAtAnyBatch() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        _ = try commit(db, a, (0..<230).map { movie(a, "\($0)", "Film \($0)", year: 2000 + $0 % 10) })
        let expected = try db.read { try $0.query("SELECT item_id, identity_key, in_hash FROM content_identity ORDER BY item_id") { "\($0.string(0))|\($0.string(1))|\($0.int(2))" } }
        for stopAfter in [0, 1, 2, 3] {
            try db.write { try $0.execute("DELETE FROM content_identity") }
            let store = IdentityStore(db: db)
            for _ in 0..<stopAfter { try store.backfill(batch: 60) }          // the app was quit here
            let mid = try store.coverage()
            #expect(mid.done == min(230, stopAfter * 60))
            while try store.backfill(batch: 60) > 0 {}                         // and started again
            let now = try db.read { try $0.query("SELECT item_id, identity_key, in_hash FROM content_identity ORDER BY item_id") { "\($0.string(0))|\($0.string(1))|\($0.int(2))" } }
            #expect(now == expected, "stop after \(stopAfter)")
        }
    }

    @Test func aNewIdentityVersionIsRederivedInTheBackground() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A")
        _ = try commit(db, a, (0..<50).map { movie(a, "\($0)", "Film \($0)", year: 2000) })
        try db.write { try $0.execute("UPDATE content_identity SET ident_ver = 0, identity_key = 'stale'") }
        let store = IdentityStore(db: db)
        #expect(try store.coverage().done == 0, "rows of an old version count as missing")
        store.backfillAll(batch: 20, pause: 0)
        #expect(try store.coverage().done == 50)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM content_identity WHERE identity_key='stale'") } == 0)
    }
}
