import Testing
import Foundation
@testable import REDDY

/// Opt-in benchmark on a synthetic library (no real data is read): STREAMSETU_BENCH=1 [STREAMSETU_BENCH_SCALE=owner|stress|both] swift test --filter SmartMixBench
/// Library shape: Zipf folder sizes, ~25% of titles repeated in 2-3 languages or qualities, ~8% CAM, ~12% without artwork, ~5% junk ratings; the owner scale is two twin playlists.
private struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

private struct SynthLibrary {
    var movieCats: [CatalogCategory] = [], seriesCats: [CatalogCategory] = [], channelCats: [CatalogCategory] = []
    var movies: [Movie] = [], series: [Series] = [], channels: [Channel] = []
}

private enum Synth {
    static let langs = ["Hindi", "Telugu", "Tamil", "English", "Malayalam", "Kannada", "Arabic", "Spanish"]
    static let a = ["Silent", "Last", "Iron", "Midnight", "Paper", "Neon", "Glass", "Northern", "Second", "Hidden", "Broken", "Golden", "Crimson", "Lost", "Final", "Burning"]
    static let b = ["Harbor", "Voyage", "Echoes", "Mountain", "Rain", "Moons", "Orchard", "Tide", "Garden", "Empire", "Letters", "Horizon", "Kingdom", "Signal", "River", "Shadow"]

    static func folderIndex(_ rng: inout Rng, count: Int) -> Int { min(count - 1, Int(Double(count) * pow(rng.unit(), 2.6))) }          // Zipf-like: a few big folders, many small

    static func build(source: PlaylistSource, tag: String, movies nm: Int, series ns: Int, channels nc: Int, movieFolders: Int, seriesFolders: Int, channelFolders: Int, seed: UInt64) -> SynthLibrary {
        var rng = Rng(s: seed)
        var lib = SynthLibrary()
        func cats(_ kind: ContentKind, _ n: Int) -> [CatalogCategory] {
            (0..<n).map { i in CatalogCategory(id: "\(tag)-\(kind.rawValue)-\(i)", sourceID: source.id, kind: kind, providerID: "\(kind.rawValue)\(i)", name: "\(langs[i % langs.count].uppercased()) | \(kind.rawValue.uppercased()) \(i)", sortOrder: i) }
        }
        lib.movieCats = cats(.movie, movieFolders); lib.seriesCats = cats(.series, seriesFolders); lib.channelCats = cats(.channel, channelFolders)
        func title(_ base: Int, year: Int, variant: Int) -> String {
            var t = "\(a[base % a.count]) \(b[(base / a.count) % b.count]) \(base)"
            t += " (\(year))"
            if variant > 0 { t += " (\(langs[(base + variant) % langs.count]))" }
            switch rng.int(20) { case 0: t += " 4K"; case 1, 2: t += " FHD"; case 3, 4, 5: t += " HD"; case 6: t += " SD"; default: break }
            if rng.int(100) < 8 { t += " CAM" }
            return t
        }
        var bases: [(base: Int, year: Int)] = []
        let now = Date().timeIntervalSince1970
        for i in 0..<nm {
            let repeatIt = !bases.isEmpty && rng.int(100) < 25
            let (base, year) = repeatIt ? bases[rng.int(bases.count)] : (bases.count + 1000, 1980 + Int(44 * pow(rng.unit(), 0.45)))
            if !repeatIt { bases.append((base, year)) }
            var m = TestSupport.movie(source, "\(i)", title(base, year: year, variant: repeatIt ? 1 + rng.int(3) : 0), year: year)
            let f = folderIndex(&rng, count: movieFolders)
            m.categoryID = lib.movieCats[f].id; m.categoryName = lib.movieCats[f].name
            m.rating = rng.int(100) < 5 ? ["", "0", "10", "10.0"][rng.int(4)] : String(format: "%.1f", 4 + rng.unit() * 5)
            if rng.int(100) < 88 { m.posterURL = "https://img.example/\(tag)/p\(i).jpg"; m.backdropURL = rng.int(2) == 0 ? "https://img.example/\(tag)/b\(i).jpg" : nil }
            m.addedAt = Date(timeIntervalSince1970: now - Double(i / 400) * 86400 - Double(rng.int(3600)))          // clustered by sync batch
            m.durationSeconds = 4800 + Double(rng.int(6000)); m.genre = ["Drama", "Action", "Comedy", "Thriller", "Family", "Horror"][rng.int(6)]
            lib.movies.append(m)
        }
        for i in 0..<ns {
            var s = TestSupport.series(source, "\(i)", "\(a[i % a.count]) \(b[(i / 7) % b.count]) Show \(i % (ns * 8 / 10 + 1)) (\(2000 + i % 25))")
            let f = folderIndex(&rng, count: seriesFolders)
            s.categoryID = lib.seriesCats[f].id; s.categoryName = lib.seriesCats[f].name; s.releaseYear = 2000 + i % 25
            s.rating = String(format: "%.1f", 4 + rng.unit() * 5); s.posterURL = rng.int(100) < 88 ? "https://img.example/\(tag)/s\(i).jpg" : nil
            s.addedAt = Date(timeIntervalSince1970: now - Double(i / 150) * 86400)
            lib.series.append(s)
        }
        for i in 0..<nc {
            var c = TestSupport.channel(source, "\(i)", "Channel \(i % 9000) \(["HD", "FHD", "SD", ""][i % 4])", cat: nil, order: i)
            let f = folderIndex(&rng, count: channelFolders)
            c.categoryID = lib.channelCats[f].id; c.categoryName = lib.channelCats[f].name
            lib.channels.append(c)
        }
        return lib
    }
}

private func ms(_ f: () throws -> Void) rethrows -> Double { let t = ContinuousClock.now; try f(); let d = ContinuousClock.now - t; return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

private func stats(_ samples: [Double]) -> String {
    let s = samples.sorted(); let p95 = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
    return String(format: "p50 %.1f  p95 %.1f  max %.1f ms (n=%d)", s[s.count / 2], p95, s.last!, s.count)
}
private func sample(warmups: Int = 2, runs: Int = 8, _ f: () throws -> Void) rethrows -> String { for _ in 0..<warmups { try f() }; return stats(try (0..<runs).map { _ in try ms(f) }) }

@Suite("Smart Mix benchmark (opt-in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["STREAMSETU_BENCH"] != nil))
struct SmartMixBenchTests {
    func log(_ s: String) { print("BENCH", s) }

    func run(name: String, sources: Int, movies: Int, series: Int, channels: Int, mf: Int, sf: Int, cf: Int) throws {
        log("=== \(name): \(sources) playlist(s), \(movies) movies / \(series) series / \(channels) channels per playlist, \(mf + sf + cf) folders per playlist")
        let db = try TestSupport.makeDB()
        let keep = ProcessInfo.processInfo.environment["STREAMSETU_BENCH_KEEP"]
        defer { if keep == nil { try? FileManager.default.removeItem(atPath: db.path); for x in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + x) } } }
        let repo = SQLiteCatalogRepository(db: db), indexer = CatalogIndexer(db: db)
        var srcs: [PlaylistSource] = [], libs: [SynthLibrary] = []
        for k in 0..<sources {
            let s = try TestSupport.makeSource(db, name: "Bench\(k)"); srcs.append(s)
            var l = Synth.build(source: s, tag: "T\(k)", movies: movies, series: series, channels: channels, movieFolders: mf, seriesFolders: sf, channelFolders: cf, seed: 42)
            if k == 1 { l.movies = l.movies.map { var m = $0; m.addedAt = m.addedAt?.addingTimeInterval(-5); return m } }          // the twin lists the same titles a moment apart
            libs.append(l)
        }
        // Sync through the real indexing path.
        var commit = 0.0
        for (s, l) in zip(srcs, libs) {
            commit += try ms { _ = try indexer.commitChannels(source: s, categories: l.channelCats, channels: l.channels) }
            commit += try ms { _ = try indexer.commitMovies(source: s, categories: l.movieCats, movies: l.movies) }
            commit += try ms { _ = try indexer.commitSeries(source: s, categories: l.seriesCats, series: l.series) }
        }
        log(String(format: "first sync, all playlists, with identity written in the same transaction: %.0f ms", commit))
        let idRows = try db.read { try $0.scalarInt("SELECT COUNT(*) FROM content_identity") }
        log("content_identity rows: \(idRows)")
        let size = { (try? FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int) ?? 0 }
        _ = try db.maintenance { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        let withIdentity = size()
        // Identity cost: derive + write throughput, measured by clearing and re-applying in one transaction per playlist.
        var derive = 0.0, derived = 0
        for (s, l) in zip(srcs, libs) {
            try db.write { try $0.execute("DELETE FROM content_identity WHERE source_id=?", [s.id]) }
            derive += try ms { try db.write { c in
                try IdentityStore.apply(rows: l.movies.map { .init(id: $0.id, title: $0.title, category: $0.categoryName, year: $0.releaseYear) }, removedIDs: [], source: s.id, kind: .movie, in: c)
                try IdentityStore.apply(rows: l.series.map { .init(id: $0.id, title: $0.title, category: $0.categoryName, year: $0.releaseYear) }, removedIDs: [], source: s.id, kind: .series, in: c) } }
            derived += l.movies.count + l.series.count
        }
        log(String(format: "identity derive+write: %.0f ms for %d rows = %.1f us/row (%.0f rows/s)", derive, derived, derive * 1000 / Double(derived), Double(derived) / (derive / 1000)))
        _ = try db.maintenance { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        // Size of the identity table and its indexes.
        let dbstat = (try? db.read { c in try c.query("SELECT name, SUM(pgsize) FROM dbstat WHERE name IN ('content_identity','idx_ci_key','idx_ci_source','idx_ci_folder','sqlite_autoindex_content_identity_1') GROUP BY name") { "\($0.string(0))=\($0.int(1) / 1024)KB" } }) ?? []
        log("DB file with identity \(withIdentity / 1_048_576) MB; identity table+indexes: \(dbstat.isEmpty ? "(dbstat unavailable)" : dbstat.joined(separator: " "))")

        // Re-sync, no change (fingerprint hit): fingerprinting every row is the cost.
        let l0 = libs[0], s0 = srcs[0]
        log("identical re-sync (fingerprint hit, nothing written), movies: " + String(format: "%.0f ms", try ms { _ = try indexer.commitMovies(source: s0, categories: l0.movieCats, movies: l0.movies) }))
        // +300 / -300 / +300 changed.
        var changed = l0.movies
        changed.removeFirst(300)
        for i in 0..<300 { changed[i].title += " Extended Cut"; changed[i].normalizedTitle = MetadataNormalizer.normalize(changed[i].title) }
        let extra = (0..<300).map { i -> Movie in var m = TestSupport.movie(s0, "new\(i)", "Fresh Arrival \(i) (2025)", year: 2025); m.categoryID = l0.movieCats[0].id; m.categoryName = l0.movieCats[0].name; return m }
        var delta: IndexResult?
        let dms = try ms { delta = try indexer.commitMovies(source: s0, categories: l0.movieCats, movies: changed + extra) }
        log(String(format: "+300/-300/300 changed sync (whole commit incl. today's full upsert): %.0f ms; identity patch saw added %d removed %d changed %d", dms,
                   delta?.identity?.addedCount ?? -1, delta?.identity?.removedCount ?? -1, delta?.identity?.changedCount ?? -1))
        let store = IdentityStore(db: db)
        let patchOnly = try ms { try db.write { c in
            try IdentityStore.apply(rows: (changed + extra).map { .init(id: $0.id, title: $0.title, category: $0.categoryName, year: $0.releaseYear) }, removedIDs: [], source: s0.id, kind: .movie, in: c) } }
        log(String(format: "identity step alone on that sync, nothing changed vs stored (hash compare of %d rows): %.0f ms", changed.count + extra.count, patchOnly))

        // Backfill from scratch, in batches of 2000.
        try db.write { try $0.execute("DELETE FROM content_identity") }
        var batches = 0, bf = 0.0
        bf = try ms { while try store.backfill(batch: 2000) > 0 { batches += 1 } }
        let cov = try store.coverage()
        log(String(format: "backfill from empty: %.0f ms in %d batches of 2000 (%.1f ms/batch), coverage %d/%d", bf, batches, bf / Double(max(1, batches)), cov.done, cov.total))
        let tw = try ms { _ = try store.refreshTwins() }
        log(String(format: "twin detection (refreshTwins, all pairs/kinds): %.0f ms", tw))

        // Queries: the pool and folder reads.
        let sid = s0.id.uuidString.lowercased()
        var probe = db          // a reader opened after each schema change, so its plans and timings are for the schema that is in the file
        func plan(_ sql: String) -> String { ((try? probe.read { try $0.query("EXPLAIN QUERY PLAN " + sql) { $0.string(3) } }) ?? []).joined(separator: " | ") }
        let recentSQL = "SELECT id FROM movies WHERE source_id='\(sid)' ORDER BY added_at DESC LIMIT 2000"
        let folderQ = "SELECT id FROM movies WHERE source_id='\(sid)' AND category_id='\(l0.movieCats[0].id)' ORDER BY added_at DESC LIMIT 12"
        log("movies(recentlyAdded, 14), series(rating, 14) with the indexes, unrestricted: " + (try sample { _ = try repo.movies(VODQuery(sort: .recentlyAdded, limit: 14)); _ = try repo.series(VODQuery(sort: .rating, limit: 14)) }))
        // Before V19: the same two reads without the new indexes, then the cost of building them.
        try db.maintenance { for i in ["idx_movies_src_added", "idx_movies_src_cat_add", "idx_series_src_cat_fs", "idx_movies_recent2", "idx_series_recent2", "idx_movies_rating2", "idx_series_rating2"] { try $0.exec("DROP INDEX IF EXISTS \(i)") } }
        probe = try DatabaseManager(path: db.path)
        let repoNoIdx = SQLiteCatalogRepository(db: probe)
        log("movies(recentlyAdded, 14), series(rating, 14) WITHOUT the new indexes, unrestricted: " + (try sample { _ = try repoNoIdx.movies(VODQuery(sort: .recentlyAdded, limit: 14)); _ = try repoNoIdx.series(VODQuery(sort: .rating, limit: 14)) }))
        log("WITHOUT the V19 indexes, recent pool plan: " + plan(recentSQL))
        log("WITHOUT the V19 indexes, recent pool (2000 newest of one playlist): " + (try sample { _ = try probe.read { try $0.query(recentSQL) { $0.string(0) } } }))
        log("WITHOUT the V19 indexes, first-12 of the biggest folder plan: " + plan(folderQ))
        log("WITHOUT the V19 indexes, first-12 of the biggest folder: " + (try sample { _ = try probe.read { try $0.query(folderQ) { $0.string(0) } } }))
        log(String(format: "SchemaV19 launch migration script (plain indexes only) on this library: %.0f ms", try ms { try db.maintenance { try $0.exec(SchemaV19.sql) } }))
        log(String(format: "background build of the four expression indexes (one write turn each): %.0f ms", try ms { SchemaV19.ensureQueryIndexes(db: db) }))
        probe = try DatabaseManager(path: db.path)
        log("recent pool plan: " + plan(recentSQL))
        log("recent pool (2000 newest of one playlist): " + (try sample { _ = try probe.read { try $0.query(recentSQL) { $0.string(0) } } }))
        let folderSQL = folderQ
        log("first-12 of the biggest folder plan: " + plan(folderSQL))
        log("first-12 of the biggest folder: " + (try sample { _ = try probe.read { try $0.query(folderSQL) { $0.string(0) } } }))
        let small = l0.movieCats[l0.movieCats.count - 1].id
        log("first-12 of a small folder: " + (try sample { _ = try repo.movies(VODQuery(sourceID: s0.id, categoryID: small, sort: .recentlyAdded, limit: 12)) }))
        log("movies(sort recentlyAdded, limit 14), normal view: " + (try sample { _ = try repo.movies(VODQuery(sourceID: nil, sort: .recentlyAdded, limit: 14)) }))
        log("categories(movie) with \(l0.movieCats.count) folders x \(sources) playlists: " + (try sample { _ = try repo.categories(sourceID: nil, kind: .movie, includeHidden: false) }))
        log("categories(series) with \(l0.seriesCats.count) folders: " + (try sample { _ = try repo.categories(sourceID: nil, kind: .series, includeHidden: false) }))

        // Restriction: 50 locked folders, 5k hidden items, 3 hidden folders.
        let fav = SQLiteFavoritesRepository(db: db)
        for i in 0..<min(50, l0.movieCats.count) { try repo.setCategoryLocked(l0.movieCats[l0.movieCats.count - 1 - i].id, true, family: true) }
        try db.write { c in for i in 0..<5000 { try c.execute("INSERT OR IGNORE INTO hidden_items(item_id, kind, hidden_at) VALUES(?,?,?)", [l0.movies[(i * 7) % l0.movies.count].id, "movie", Date()]) } }
        for i in 0..<3 { try fav.hide(l0.movieCats[10 + i].id, kind: "category") }
        repo.restriction.isActive = true
        if let keep { _ = try db.maintenance { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") }; try? FileManager.default.removeItem(atPath: keep); try FileManager.default.copyItem(atPath: db.path, toPath: keep); log("kept a copy of the seeded library for query experiments"); return }
        log("with 50 locked folders (+family), 5k hidden items, 3 hidden folders:")
        log("  normal view movies(recentlyAdded, 14): " + (try sample { _ = try repo.movies(VODQuery(sort: .recentlyAdded, limit: 14)) }))
        log("  baseline view movies(recentlyAdded, 14): " + (try sample { _ = try repo.baseline.movies(VODQuery(sort: .recentlyAdded, limit: 14)) }))
        log("  baseline view movies(rating, 400) [hero pool]: " + (try sample { _ = try repo.baseline.movies(VODQuery(sort: .rating, limit: 400)) }))
        log("  normal view movies(rating, 400): " + (try sample { _ = try repo.movies(VODQuery(sort: .rating, limit: 400)) }))
        log("  visibleCounts: " + (try sample { _ = try repo.visibleCounts(sourceID: nil) }))
        log("  counts (raw, before): " + (try sample { _ = try repo.counts(sourceID: nil) }))
        log("  genres(movie): " + (try sample { _ = try repo.genres(kind: .movie) }))
        log("  years(movie): " + (try sample { _ = try repo.years(kind: .movie) }))
        let search = SQLiteSearchRepository(db: db, restriction: repo.restriction)
        log("  search \"silent\" (restricted, FTS + folder guard): " + (try sample { _ = try search.search(term: "silent", filters: SearchFilters()) }))
        let discover = DiscoverService(catalog: repo, history: SQLiteHistoryRepository(db: db), people: PeopleIndex(db: db))
        log("  DiscoverService.build (baseline view): " + (try sample(warmups: 1, runs: 5) { _ = try discover.build(sourceID: nil) }))
        let res = IdentityResolver(db: db)
        let ids = Array(l0.movies.prefix(2000)).map(\.id)
        log("  identity group + canonical pick for 2000 candidates (groups(of:), twins + restricted check): " + (try sample(warmups: 1, runs: 5) { _ = try res.groups(of: ids) }))
        log("  the same, one group(of:) call per candidate: " + (try sample(warmups: 0, runs: 2) { for id in ids.prefix(500) { _ = try res.group(of: id) } }) + " for 500")
        log("  lock one folder (family, writes) : " + String(format: "%.1f ms", try ms { _ = try repo.setCategoryLocked(l0.movieCats[100 % l0.movieCats.count].id, true, family: true) }))
        let mem = RecommendationMemory(db: db, catalog: repo)
        log("  purgeRestricted on an empty shown table: " + String(format: "%.1f ms", try ms { _ = try mem.purgeRestricted() }))
        log("  1000 shown rows recorded: " + String(format: "%.0f ms", try ms { _ = try mem.recordShown(profileID: "main", shelfID: "recent", itemIDs: Array(l0.movies.prefix(1000)).map(\.id), loadSeq: 1) }))
        log("  purgeRestricted with 1000 shown rows: " + String(format: "%.0f ms", try ms { _ = try mem.purgeRestricted() }))
    }

    /// What the seven new indexes cost the first sync of one playlist (66,540 movies), measured alternately with and without them.
    @Test func syncCostOfTheNewIndexes() throws {
        let which = ProcessInfo.processInfo.environment["STREAMSETU_BENCH_SCALE"] ?? "both"
        guard which == "owner" || which == "both" else { return }
        let names = ["idx_movies_src_added", "idx_movies_src_cat_add", "idx_series_src_cat_fs", "idx_movies_recent2", "idx_series_recent2", "idx_movies_rating2", "idx_series_rating2", "idx_categories_family"]
        func once(dropIndexes: Bool) throws -> (sync: Double, size: Int) {
            let db = try TestSupport.makeDB()
            defer { try? FileManager.default.removeItem(atPath: db.path); for x in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + x) } }
            if dropIndexes { try db.maintenance { for n in names { try $0.exec("DROP INDEX IF EXISTS \(n)") } } }
            let s = try TestSupport.makeSource(db, name: "Cost")
            let l = Synth.build(source: s, tag: "C", movies: 66_540, series: 0, channels: 0, movieFolders: 172, seriesFolders: 1, channelFolders: 1, seed: 7)
            let t = try ms { _ = try CatalogIndexer(db: db).commitMovies(source: s, categories: l.movieCats, movies: l.movies) }
            _ = try db.maintenance { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
            return (t, (try? FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int) ?? 0)
        }
        var with: [Double] = [], without: [Double] = [], sizeWith = 0, sizeWithout = 0
        for _ in 0..<3 { let a = try once(dropIndexes: false); with.append(a.sync); sizeWith = a.size; let b = try once(dropIndexes: true); without.append(b.sync); sizeWithout = b.size }
        log(String(format: "first sync of 66,540 movies (identity included in both): WITH the new indexes %@ ms, WITHOUT %@ ms; file %d MB vs %d MB",
                   with.map { String(format: "%.0f", $0) }.joined(separator: "/"), without.map { String(format: "%.0f", $0) }.joined(separator: "/"), sizeWith / 1_048_576, sizeWithout / 1_048_576))
    }

    @Test func ownerScale() throws {
        let which = ProcessInfo.processInfo.environment["STREAMSETU_BENCH_SCALE"] ?? "both"
        guard which == "owner" || which == "both" else { return }
        try run(name: "owner scale, twin playlists", sources: 2, movies: 66_540, series: 18_011, channels: 14_879, mf: 172, sf: 302, cf: 158)
    }

    @Test func stress200k() throws {
        let which = ProcessInfo.processInfo.environment["STREAMSETU_BENCH_SCALE"] ?? "both"
        guard which == "stress" || which == "both" else { return }
        try run(name: "stress", sources: 1, movies: 140_000, series: 45_000, channels: 40_000, mf: 500, sf: 700, cf: 300)
    }
}

// MARK: Home pipeline (opt-in): STREAMSETU_BENCH=1 swift test --filter SmartMixHomePipeline
private func residentMB() -> Double {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

@Suite("Smart Mix home pipeline (opt-in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["STREAMSETU_BENCH"] != nil))
struct SmartMixHomePipelineBench {
    func log(_ s: String) { print("BENCH", s) }
    func wall(_ f: () async throws -> Void) async rethrows -> Double { let t = ContinuousClock.now; try await f(); let d = ContinuousClock.now - t; return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    func run(name: String, sources: Int, movies: Int, series: Int, channels: Int, mf: Int, sf: Int, cf: Int) async throws {
        log("=== home pipeline \(name): \(sources) playlist(s), \(movies)/\(series)/\(channels) per playlist")
        let db = try TestSupport.makeDB()
        defer { try? FileManager.default.removeItem(atPath: db.path); for x in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + x) } }
        let repo = SQLiteCatalogRepository(db: db), indexer = CatalogIndexer(db: db)
        var srcs: [PlaylistSource] = [], libs: [SynthLibrary] = []
        for k in 0..<sources {
            let s = try TestSupport.makeSource(db, name: "P\(k)"); srcs.append(s)
            var l = Synth.build(source: s, tag: "T\(k)", movies: movies, series: series, channels: channels, movieFolders: mf, seriesFolders: sf, channelFolders: cf, seed: 42)
            if k == 1 { l.movies = l.movies.map { var m = $0; m.addedAt = m.addedAt?.addingTimeInterval(-5); return m } }
            libs.append(l)
        }
        for (s, l) in zip(srcs, libs) {
            _ = try indexer.commitChannels(source: s, categories: l.channelCats, channels: l.channels)
            _ = try indexer.commitMovies(source: s, categories: l.movieCats, movies: l.movies)
            _ = try indexer.commitSeries(source: s, categories: l.seriesCats, series: l.series)
        }
        // Some history so affinity, rediscover and because-you-watched have something to work with.
        let hist = SQLiteHistoryRepository(db: db)
        for m in libs[0].movies.prefix(60) { try hist.recordPlay(itemID: m.id, kind: .movie, title: m.title) }
        let memory = RecommendationMemory(db: db, catalog: repo)
        let defaults = UserDefaults(suiteName: "bench-\(UUID().uuidString)")!
        let before = residentMB()
        let coord = SmartMixCoordinator(db: db, catalog: repo, memory: memory, credentials: InMemoryCredentialStore(), defaults: defaults)
        log("identity coverage ok: \(coord.source.coverageOK())")
        var result: SmartMixHomeResult?
        let cold = try await wall { result = await coord.home(profile: "main", sourceID: nil, preferredLanguage: "Hindi") }
        let shelves = result?.shelves.map { "\($0.title)=\($0.items.count)" }.joined(separator: ", ") ?? "nil"
        log(String(format: "FIRST HOME DATA READY (cold: SQL pool + identity grouping + 6 shelves + item rows): %.0f ms; hero %d; %@", cold, result?.heroOrder.count ?? 0, shelves))
        log(String(format: "  of which the SQL candidate read: %d ms (last)", coord.source.lastReadMillis))
        let after = residentMB()
        log(String(format: "  resident memory %.0f MB before, %.0f MB after the first Home (+%.0f MB)", before, after, after - before))
        let warm = try await wall { _ = await coord.home(profile: "main", sourceID: nil, preferredLanguage: "Hindi") }
        log(String(format: "  repeat Home, nothing changed (cache hit, no SQL pool): %.0f ms", warm))
        coord.invalidate(.syncChanged)
        let full = try await wall { _ = await coord.home(profile: "main", sourceID: nil, preferredLanguage: "Hindi") }
        log(String(format: "  full rebuild after a sync that changed titles: %.0f ms", full))
        coord.reshuffle(profile: "main")
        let shuffle = try await wall { _ = await coord.home(profile: "main", sourceID: nil, preferredLanguage: "Hindi") }
        log(String(format: "  after Shuffle recommendations (new draw; reads the pool again): %.0f ms", shuffle))
        let id = libs[0].movies[5].id
        coord.dismiss(profile: "main", itemID: id)
        let dis = try await wall { _ = await coord.home(profile: "main", sourceID: nil, preferredLanguage: "Hindi") }
        log(String(format: "  after one Don't Recommend This: %.0f ms", dis))
        // Folder rows: the first 20 movie folders' tiles, one after another as rows appear.
        let cats = try repo.categories(sourceID: nil, kind: .movie, includeHidden: false)
        let catMs = try await wall { _ = try repo.categories(sourceID: nil, kind: .movie, includeHidden: false) }
        log(String(format: "  folder list (categories, %d folders x %d playlists): %.0f ms", mf, sources, catMs))
        var per: [Double] = []
        for c in cats.prefix(20) { per.append(try await wall { _ = await coord.folderItems(profile: "main", sourceID: nil, kind: .movie, folderName: c.name, preferredLanguage: "Hindi") }) }
        let sorted = per.sorted()
        log(String(format: "  folder row tiles (engine folder shelf), first 20 folders: p50 %.1f  p95 %.1f  max %.1f ms; total %.0f ms", sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!, per.reduce(0, +)))
        // Restrictions: 50 locked folders, 5k hidden titles, 3 hidden folders.
        for i in 0..<min(50, libs[0].movieCats.count) { try repo.setCategoryLocked(libs[0].movieCats[libs[0].movieCats.count - 1 - i].id, true, family: true) }
        try db.write { c in for i in 0..<5000 { try c.execute("INSERT OR IGNORE INTO hidden_items(item_id, kind, hidden_at) VALUES(?,?,?)", [libs[0].movies[(i * 7) % libs[0].movies.count].id, "movie", Date()]) } }
        coord.invalidate(.lockOrRestrictionChange)
        SQLiteSmartMixCandidateSource.trace = { log("    stage \($0): \($1) ms") }
        defer { SQLiteSmartMixCandidateSource.trace = nil }
        let locked = try await wall { result = await coord.home(profile: "main", sourceID: nil, preferredLanguage: "Hindi") }
        log(String(format: "  cold Home with 50 locked folders (+family), 5k hidden titles: %.0f ms; shelves %d", locked, result?.shelves.count ?? 0))
        log(String(format: "  resident memory at the end: %.0f MB", residentMB()))
        _ = repo
    }

    @Test func ownerScale() async throws {
        try await run(name: "owner scale (twin playlists)", sources: 2, movies: 66_540, series: 18_011, channels: 14_879, mf: 172, sf: 302, cf: 158)
    }
    @Test func stress200k() async throws {
        try await run(name: "200k stress", sources: 1, movies: 140_000, series: 45_000, channels: 40_000, mf: 500, sf: 700, cf: 300)
    }
}
