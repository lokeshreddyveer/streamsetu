import Testing
import Foundation
@testable import REDDY

private let genreNow = Date(timeIntervalSince1970: 1_800_000_000)

/// The library every genre fixture step runs on (also written into the fixture files).
private func genreLibrary() -> [[String: Any]] {
    var out: [[String: Any]] = []
    let ratings = ["8.5", "8.1", "7.9", "7.4", "7.0", "6.6", "6.2", "5.8", "5.1", "4.7", "8.8", "7.7", "6.9", "6.0"]
    for i in 0..<14 {                                   // thrillers: 10 movies, 4 series
        var d: [String: Any] = ["id": String(format: "t%02d", i), "kind": i < 10 ? "movie" : "series", "key": "thr\(i)", "year": 2026 - i % 8, "added": 10 + i * 20,
                                "rating": ratings[i], "q": 2 + i % 3, "genres": i % 2 == 0 ? "Thriller, Drama" : "Action / Thriller", "lang": "English"]
        if i == 3 { d["cam"] = true; d["q"] = 0 }
        if i == 5 { d["restricted"] = true }
        if i == 7 { d["poster"] = false }
        if i == 9 { d["dismissed"] = true }
        if i == 12 { d["watched"] = true; d["lastWatched"] = 2; d["p7"] = 2 }
        out.append(d)
    }
    for i in 0..<10 {                                   // science fiction: 6 movies, 4 series ("Sci-Fi & Fantasy" is the TMDB TV name)
        out.append(["id": String(format: "f%02d", i), "kind": i < 6 ? "movie" : "series", "key": "sf\(i)", "year": 2024 - i, "added": 30 + i * 10,
                    "rating": "\(6 + i % 4).\(i)", "genres": i < 6 ? "Science Fiction" : "Sci-Fi & Fantasy"])
    }
    for i in 0..<6 { out.append(["id": "c0\(i)", "kind": "movie", "key": "com\(i)", "year": 2020 + i, "added": 5 + i, "rating": "7.\(i)", "genres": "Comedy"]) }   // too few for a shelf
    out.append(["id": "r00", "kind": "movie", "key": "real0", "year": 2025, "rating": "7.0", "genres": "Reality TV"])                                     // reality is series-only
    for i in 0..<8 { out.append(["id": "r1\(i)", "kind": "series", "key": "real1\(i)", "year": 2025 - i, "added": 4 * i, "rating": "6.\(i)", "genres": "Reality"]) }
    return out
}

private let weeklyRanks: [String: Int] = ["t00": 3, "t01": 1, "t02": 2, "t04": 4, "t06": 5, "t08": 6, "t10": 7, "t11": 8]

private func diagJSON(_ d: SMDiagnostics) -> [String: Any] {
    ["groups": d.groups, "restricted": d.restricted, "dismissed": d.dismissed, "camOnly": d.camOnly, "noArtwork": d.noArtwork, "watched": d.watched,
     "pool": d.pool, "drawn": d.drawn, "tier": d.tier, "hidden": d.hidden, "trendMode": d.trendMode, "caption": d.caption.rawValue]
}

private func context(_ s: [String: Any]) -> SMContext {
    var c = SMContext(profile: s["profile"] as! String, dayKey: s["dayKey"] as! String, refreshCounter: s["refreshCounter"] as? Int ?? 0)
    c.kids = s["kids"] as? Bool ?? false
    c.affinity = SMAffinity(genreKeys: s["affinityGenreKeys"] as? [String] ?? [])
    if let m = s["mode"] as? String, let shelf = s["shelf"] as? String { c.modes[shelf] = SMShelfMode(rawValue: m)! }
    return c
}

private func prepared(_ lib: [[String: Any]]) -> SmartMixEngine.Prepared { SmartMixEngine.prepare(lib.map(SMFixtures.candidate), preferredLang: nil) }

private func buildShelf(_ lib: [[String: Any]], _ step: [String: Any]) -> SMShelfResult {
    let ranks = (step["ranks"] as? [String: Int])
    return SmartMixEngine.build(shelfId: step["shelf"] as! String, prepared: prepared(lib), ctx: context(step), ranks: ranks)
}

private func jsonData(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) }
private let writing = ProcessInfo.processInfo.environment["SMARTMIX_WRITE_GENRE_FIXTURES"] != nil

private func same(_ a: Any, _ b: Any) -> Bool { (try? jsonData(["v": a])) == (try? jsonData(["v": b])) }

@Suite("Genre shelves") struct GenreShelfTests {
    @Test func tableIsConsistent() {
        let keys = SMGenres.table.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(SMGenres.table.allSatisfy { $0.title == "Top " + $0.name && !$0.aliases.isEmpty })
        #expect(SMGenres.byKey["scifi"]?.title == "Top Science Fiction" && SMGenres.byKey["thriller"]?.title == "Top Thriller")
        #expect(SMGenres.byKey["thriller"]?.tmdbMovie == [53] && SMGenres.byKey["scifi"]?.tmdbMovie == [878] && SMGenres.byKey["scifi"]?.tmdbTV == [10765])
        #expect(SMGenres.byKey["reality"]?.scope == .series)
        #expect(Set(SMGenres.table.filter(\.kidsSafe).map(\.key)) == ["comedy", "animation", "family", "fantasy", "adventure", "music", "kids"])
        #expect(SMGenres.table.allSatisfy { g in g.aliases.allSatisfy { SMGenres.norm($0) == $0 } })
    }

    @Test func textRules() {
        #expect(SMGenres.norm("Sci-Fi & Fantasy") == "sci fi fantasy")
        #expect(SMGenres.tokens("Action, Thriller / Sci-Fi | Drama;  ") == ["action", "thriller", "sci fi", "drama"])
        #expect(SMGenres.keys(genres: ["sci fi fantasy"], kind: .series).sorted() == ["fantasy", "scifi"])
        #expect(SMGenres.keys(genres: ["action adventure"], kind: .series).sorted() == ["action", "adventure"])
        #expect(SMGenres.keys(genres: ["docudrama"], kind: .movie).isEmpty)           // whole words only
        #expect(SMGenres.keys(genres: ["reality tv"], kind: .movie).isEmpty && SMGenres.keys(genres: ["reality tv"], kind: .series) == ["reality"])
    }

    @Test func selectionRules() {
        let all = Dictionary(uniqueKeysWithValues: SMGenres.table.map { ($0.key, 20) })
        var seen = Set<[String]>()
        for day in 1...12 {
            let ctx = SMContext(profile: "p", dayKey: String(format: "2026-11-%02d", day))
            let pick = SMGenres.select(counts: all, ctx: ctx)
            #expect(pick.count == 6 && Set(pick).count == 6)
            seen.insert(pick)
        }
        #expect(seen.count >= 6, "the choice differs from day to day")
        var a = SMContext(profile: "p", dayKey: "2026-11-02"); a.affinity = SMAffinity(genreKeys: ["horror", "western", "nope", "crime", "comedy"])
        #expect(Array(SMGenres.select(counts: all, ctx: a).prefix(3)) == ["horror", "western", "crime"])
        var thin = all; thin["horror"] = 7
        #expect(!SMGenres.select(counts: thin, ctx: a).contains("horror"))
        var kids = SMContext(profile: "k", dayKey: "2026-11-02"); kids.kids = true
        #expect(Set(SMGenres.select(counts: all, ctx: kids)).isSubset(of: ["comedy", "animation", "family", "fantasy", "adventure", "music", "kids"]))
        #expect(SMGenres.select(counts: [:], ctx: a).isEmpty)
        #expect(SMGenres.select(counts: all, ctx: a) == SMGenres.select(counts: all, ctx: a))
    }

    @Test func placementNeverStacksMoreThanTwo() {
        let g = (1...6).map { "g\($0)" }
        let full = SMPlacement.order(present: ["top-week", "trending", "for-you", "lang-pref", "rediscover"], genres: g)
        #expect(full == ["top-week", "trending", "g1", "for-you", "g2", "g3", "lang-pref", "g4", "rediscover", "g5", "g6"])
        for present in [Set<String>(), ["top-week"], ["top-week", "trending"], ["trending", "rediscover"]] as [Set<String>] {
            let o = SMPlacement.order(present: present, genres: g)
            var run = 0
            for id in o { run = id.hasPrefix("g") ? run + 1 : 0; #expect(run <= 2) }
        }
        #expect(SMPlacement.order(present: [], genres: g) == ["g1", "g2"])
    }

    @Test func engineShelfRules() {
        let lib = genreLibrary()
        let r = buildShelf(lib, ["profile": "p", "dayKey": "2026-11-02", "shelf": "genre:thriller"])
        #expect(!r.diag.hidden && r.ids.count >= 8)
        #expect(!r.ids.contains("t05") && !r.ids.contains("t03") && !r.ids.contains("t09"))      // restricted, CAM-only, dismissed never show
        #expect(r.ids.allSatisfy { $0.hasPrefix("t") })
        #expect(buildShelf(lib, ["profile": "p", "dayKey": "2026-11-02", "shelf": "genre:comedy"]).diag.hidden)    // 6 titles: no shelf
        let sf = buildShelf(lib, ["profile": "p", "dayKey": "2026-11-02", "shelf": "genre:scifi"])
        #expect(Set(sf.ids) == Set((0..<10).map { String(format: "f%02d", $0) }))                  // "Science Fiction" and "Sci-Fi & Fantasy" both count
        let re = buildShelf(lib, ["profile": "p", "dayKey": "2026-11-02", "shelf": "genre:reality"])
        #expect(!re.ids.contains("r00") && re.ids.count == 8)                                      // series-only
        let counts = SmartMixEngine.genreCounts(prepared(lib))
        #expect(counts["thriller"] == 10 && counts["scifi"] == 10 && counts["comedy"] == 6 && counts["reality"] == 8)
        // TMDB order: the first ranks come first, shuffled only inside a bucket of 3 ranks.
        var step: [String: Any] = ["profile": "p", "dayKey": "2026-11-02", "shelf": "genre:thriller", "ranks": weeklyRanks]
        let o = buildShelf(lib, step)
        #expect(o.diag.trendMode && o.diag.caption == .trendingTMDB)
        #expect(Set(o.ids.prefix(3)) == ["t01", "t02", "t00"] && Set(o.ids.dropFirst(3).prefix(3)) == ["t04", "t06", "t08"])
        step["ranks"] = ["t00": 1, "t01": 2]                                                       // fewer than 6 matches: local ranking
        #expect(!buildShelf(lib, step).diag.trendMode)
        // The all-time view is rating first and differs from the weekly view.
        step["ranks"] = nil; step["mode"] = "allTime"
        let top = buildShelf(lib, step)
        #expect(top.ids != buildShelf(lib, ["profile": "p", "dayKey": "2026-11-02", "shelf": "genre:thriller"]).ids)
        #expect(!top.diag.hidden && top.diag.drawn >= 8)
    }

    @Test func sessionChoosesTodaysShelves() async throws {
        let lib = genreLibrary().map(SMFixtures.candidate)
        var big = lib
        for g in SMGenres.table where g.scope == .both {                                           // enough titles in every both-kind genre
            for i in 0..<9 { var c = SMCandidate(id: "x-\(g.key)-\(i)"); c.key = "x\(g.key)\(i)"; c.year = 2020; c.rating = "7.5"; c.genres = [g.aliases[0]]; big.append(c) }
        }
        let session = SmartMixSession(source: InMemoryCandidateSource(big), state: InMemorySmartMixStateStore())
        let res = try await session.shelves([SMShelf.genresAuto], ctx: SMContext(profile: "p", dayKey: "2026-11-02"), now: genreNow, commit: true)
        let shown = res.filter { SMShelf.isGenre($0.shelfId) }
        #expect(shown.count == 6 && shown.allSatisfy { !$0.diag.hidden && $0.ids.count >= 8 })
        let index = try #require(res.first { $0.shelfId == SMShelf.genresIndex })
        #expect(index.genreSelected == shown.map { String($0.shelfId.dropFirst(6)) } && index.genreCounts["thriller"] == 19)
        var kids = SMContext(profile: "k", dayKey: "2026-11-02"); kids.kids = true
        let kr = try await session.shelves([SMShelf.genresAuto], ctx: kids, now: genreNow)
        #expect(kr.filter { SMShelf.isGenre($0.shelfId) }.allSatisfy { SMGenres.byKey[String($0.shelfId.dropFirst(6))]!.kidsSafe })
    }

    @Test func switchingOneShelfsViewLeavesTheOthersAndReadsTheLibraryOnce() async throws {
        var lib = genreLibrary().map(SMFixtures.candidate)
        for g in SMGenres.table where g.scope == .both { for i in 0..<9 { var c = SMCandidate(id: "x-\(g.key)-\(i)"); c.key = "x\(g.key)\(i)"; c.year = 2020; c.rating = "7.5"; c.genres = [g.aliases[0]]; lib.append(c) } }
        let source = InMemoryCandidateSource(lib)
        let session = SmartMixSession(source: source, state: InMemorySmartMixStateStore())
        let base = SMContext(profile: "p", dayKey: "2026-11-02")
        let all = SMShelf.all + [SMShelf.genresAuto]
        let first = try await session.shelves(all, ctx: base, now: genreNow, commit: true)
        let genre = try #require(first.first { SMShelf.isGenre($0.shelfId) }).shelfId
        var top = base; top.modes = [genre: .allTime, SMShelf.trendingLibrary: .allTime]
        let readsBefore = source.requests
        let sw = try await session.shelves([genre, SMShelf.trendingLibrary], ctx: top, now: genreNow, commit: false)
        #expect(source.requests == readsBefore + 1)                              // one pool read for both switched shelves
        #expect(sw.first { $0.shelfId == genre }?.ids != first.first { $0.shelfId == genre }?.ids)
        let again = try await session.shelves([genre, SMShelf.trendingLibrary], ctx: top, now: genreNow, commit: false)
        let back = try await session.shelves([genre, SMShelf.trendingLibrary], ctx: base, now: genreNow, commit: false)
        #expect(source.requests == readsBefore + 1, "switching back and forth is served from the per-view cache")
        #expect(again.map(\.ids) == sw.map(\.ids) && back.first { $0.shelfId == genre }?.ids == first.first { $0.shelfId == genre }?.ids)
        let rebuilt = try await session.shelves(all, ctx: base, now: genreNow, commit: false)
        for r in first where r.shelfId != SMShelf.genresIndex { #expect(rebuilt.first { $0.shelfId == r.shelfId }?.ids == r.ids, "\(r.shelfId) is unchanged by the switch") }
        #expect(source.requests == readsBefore + 1)
    }

    @Test func replacingAShelfTouchesOnlyThatShelf() {
        func shelf(_ id: String, _ items: Int) -> DiscoverShelf { DiscoverShelf(id: id, title: id, caption: "", items: []) }
        var a = shelf("a", 0), b = shelf("b", 0), c = shelf("c", 0)
        a.caption = "A"; b.caption = "B"; c.caption = "C"
        let content = DiscoverContent(hero: nil, shelves: [a, b, c])
        var nb = b; nb.caption = "B2"; nb.mode = .allTime
        let out = content.replacingShelf(nb)
        #expect(out.shelves.map(\.id) == ["a", "b", "c"] && out.shelves.map(\.caption) == ["A", "B2", "C"] && out.shelves[1].mode == .allTime)
        #expect(content.replacingShelf(shelf("zzz", 0)).shelves.map(\.caption) == ["A", "B", "C"])
    }

    @Test func subtitlesAreShortEnoughToStayOnOneLine() {
        for mode in SMShelfMode.allCases { for tmdb in [true, false] { #expect(SmartMixCoordinator.viewCaption(mode: mode, tmdb: tmdb).count <= 20) } }
    }

    @Test func modesAreRememberedPerProfileAndShelf() {
        let d = UserDefaults(suiteName: "genre-modes-test-\(UUID().uuidString)")!
        #expect(SMShelfModes.get(d, profile: "a", shelf: "genre:thriller") == .weekly)
        SMShelfModes.set(d, .allTime, profile: "a", shelf: "genre:thriller")
        #expect(SMShelfModes.get(d, profile: "a", shelf: "genre:thriller") == .allTime)
        #expect(SMShelfModes.get(d, profile: "b", shelf: "genre:thriller") == .weekly && SMShelfModes.get(d, profile: "a", shelf: "genre:action") == .weekly)
        SMShelfModes.set(d, .weekly, profile: "a", shelf: "genre:thriller")
        #expect(d.string(forKey: SMShelfModes.key(profile: "a", shelf: "genre:thriller")) == nil)
    }

    @Test func listKeysAndCap() async {
        #expect(SMListKey.forShelf("genre:thriller", mode: .weekly) == (own: "week:thriller", general: "week"))
        #expect(SMListKey.forShelf("genre:thriller", mode: .allTime) == (own: "top:thriller", general: "top"))
        #expect(SMListKey.forShelf(SMShelf.trendingLibrary, mode: .allTime) == (own: nil, general: "top"))
        #expect(SMListKey.refetchHours("week:x") == 24 && SMListKey.refetchHours("top:x") == 168 && SMListKey.refetchHours("top") == 168)
        struct F: SMListFetching { func fetch(_ key: String) async throws -> [SMTrendingEntry] { [SMTrendingEntry(rank: 1, type: "movie", title: key, original: nil, year: nil)] } }
        var p = SMTrendingPolicy(); p.hasOwnKey = true
        let old = SMTrendingCache(fetchedAt: genreNow.addingTimeInterval(-200 * 86_400), entries: [SMTrendingEntry(rank: 1, type: "movie", title: "old", original: nil, year: nil)])
        let store = InMemoryListsCache(["top": old])
        let svc = SMListsService(fetcher: F(), cache: store, policy: p)
        #expect(await svc.current(now: genreNow).isEmpty)                     // past the 180-day cap: not used
        await svc.refresh(["top", "week:action"], now: genreNow)
        #expect(Set(await svc.current(now: genreNow).keys) == ["top", "week:action"])
        p.hasOwnKey = false
        await svc.setPolicy(p)
        let after = await svc.current(now: genreNow)
        #expect(store.load().isEmpty && after.isEmpty)   // no key: nothing kept, nothing requested
    }

    // MARK: shared fixtures (smartmix/fixtures/genre-shelves.json, shelf-modes.json)

    private static func shelfSteps() -> [[String: Any]] {
        let base: [String: Any] = ["profile": "p", "dayKey": "2026-11-02"]
        func s(_ shelf: String, _ extra: [String: Any] = [:]) -> [String: Any] { base.merging(["shelf": shelf], uniquingKeysWith: { $1 }).merging(extra, uniquingKeysWith: { $1 }) }
        return [s("genre:thriller"), s("genre:thriller", ["dayKey": "2026-11-03"]), s("genre:thriller", ["refreshCounter": 1]), s("genre:thriller", ["ranks": weeklyRanks]),
                s("genre:scifi"), s("genre:comedy"), s("genre:reality"), s("genre:thriller", ["profile": "q"])]
    }

    private static func modeSteps() -> [[String: Any]] {
        func s(_ shelf: String, _ mode: String, _ extra: [String: Any] = [:]) -> [String: Any] { ["profile": "p", "dayKey": "2026-11-02", "shelf": shelf, "mode": mode].merging(extra, uniquingKeysWith: { $1 }) }
        return [s("genre:thriller", "weekly"), s("genre:thriller", "allTime"), s("genre:thriller", "allTime", ["ranks": weeklyRanks]), s("genre:thriller", "weekly", ["ranks": weeklyRanks]),
                s("genre:scifi", "weekly"), s("genre:scifi", "allTime"), s("trending-library", "weekly"), s("trending-library", "allTime"),
                s("trending-library", "allTime", ["ranks": ["f00": 2, "f01": 1, "f02": 3, "t00": 4]])]
    }

    private func result(_ lib: [[String: Any]], _ step: [String: Any]) -> [String: Any] {
        let r = buildShelf(lib, step)
        return ["ids": r.ids, "diag": diagJSON(r.diag)]
    }

    @Test func genreShelvesFixture() throws {
        let lib = genreLibrary()
        let url = SMFixtures.directory.appendingPathComponent("genre-shelves.json")
        let all = Dictionary(uniqueKeysWithValues: SMGenres.table.map { ($0.key, 20) })
        let counts = SmartMixEngine.genreCounts(prepared(lib))
        let selects: [[String: Any]] = [
            ["profile": "p", "dayKey": "2026-11-02", "counts": all], ["profile": "p", "dayKey": "2026-11-03", "counts": all], ["profile": "p", "dayKey": "2026-11-02", "refreshCounter": 1, "counts": all],
            ["profile": "p", "dayKey": "2026-11-02", "counts": all, "affinityGenreKeys": ["horror", "western", "crime", "comedy"]],
            ["profile": "k", "dayKey": "2026-11-02", "counts": all, "kids": true], ["profile": "p", "dayKey": "2026-11-02", "counts": counts],
            ["profile": "p", "dayKey": "2026-11-02", "counts": [String: Int]()]].map { c in
            var c = c; let sel = SMGenres.select(counts: c["counts"] as! [String: Int], ctx: context(c)); c["expect"] = sel; return c }
        let placements: [[String: Any]] = [
            ["present": ["top-week", "trending", "for-you", "lang-pref", "rediscover"], "genres": (1...6).map { "g\($0)" }],
            ["present": ["top-week", "trending"], "genres": (1...6).map { "g\($0)" }], ["present": [String](), "genres": (1...6).map { "g\($0)" }],
            ["present": ["trending", "rediscover", "lang-pref"], "genres": ["g1", "g2", "g3"]]].map { c in
            var c = c; c["expect"] = SMPlacement.order(present: Set(c["present"] as! [String]), genres: c["genres"] as! [String]); return c }
        let tokenCases: [[String: Any]] = ["Action, Thriller", "Sci-Fi & Fantasy", "Science Fiction | Drama", "Action & Adventure", "Reality TV", "", "War & Politics; Western"].map { ["raw": $0, "tokens": SMGenres.tokens($0)] }
        let matchCases: [[String: Any]] = [["sci fi fantasy", "series"], ["sci fi fantasy", "movie"], ["action adventure", "series"], ["reality tv", "movie"], ["reality tv", "series"], ["war politics", "series"], ["docudrama", "movie"], ["anime", "movie"]]
            .map { ["tokens": [$0[0]], "kind": $0[1], "keys": SMGenres.keys(genres: [$0[0]], kind: $0[1] == "movie" ? .movie : .series)] }
        let table: [[String: Any]] = SMGenres.table.map { ["key": $0.key, "title": $0.title, "scope": $0.scope.rawValue, "aliases": $0.aliases, "kids": $0.kidsSafe, "tmdbMovie": $0.tmdbMovie, "tmdbTV": $0.tmdbTV, "tmdbLang": $0.tmdbLang ?? ""] }
        var doc: [String: Any] = [
            "name": "genre-shelves",
            "description": "Genre shelf contract (docs/SMART-MIX.md, Genre shelves). Expected values were produced by the Swift reference and checked by hand against the rules; Kotlin and C# must reproduce them exactly. Candidate field `genres` is the raw provider text; tokenise it with `tokens` first.",
            "constants": ["minTitles": SMGenres.minTitles, "maxShown": SMGenres.maxShown, "maxFromAffinity": SMGenres.maxFromAffinity, "shelfSize": SMGenres.shelfSize, "rankBucket": SMGenres.rankBucket],
            "table": table, "tokens": tokenCases, "matching": matchCases, "counts": counts, "select": selects, "placement": placements, "library": lib]
        var steps = Self.shelfSteps()
        for i in steps.indices { steps[i]["expect"] = result(lib, steps[i]) }
        doc["steps"] = steps
        if writing { try jsonData(doc).write(to: url) }
        let on = try SMFixtures.json("genre-shelves")
        #expect(same(on["table"]!, doc["table"]!) && same(on["tokens"]!, tokenCases) && same(on["matching"]!, matchCases) && same(on["select"]!, selects)
                && same(on["placement"]!, placements) && same(on["counts"]!, counts) && same(on["steps"]!, steps), "genre-shelves.json is out of date (run with SMARTMIX_WRITE_GENRE_FIXTURES=1)")
    }

    @Test func shelfModesFixture() throws {
        let lib = genreLibrary()
        var steps = Self.modeSteps()
        for i in steps.indices { steps[i]["expect"] = result(lib, steps[i]) }
        let storage: [[String: Any]] = [["op": "get", "profile": "a", "shelf": "genre:thriller", "expect": "weekly"], ["op": "set", "profile": "a", "shelf": "genre:thriller", "mode": "allTime"],
                                        ["op": "get", "profile": "a", "shelf": "genre:thriller", "expect": "allTime"], ["op": "get", "profile": "b", "shelf": "genre:thriller", "expect": "weekly"],
                                        ["op": "get", "profile": "a", "shelf": "genre:action", "expect": "weekly"], ["op": "set", "profile": "a", "shelf": "genre:thriller", "mode": "weekly"],
                                        ["op": "get", "profile": "a", "shelf": "genre:thriller", "expect": "weekly"]]
        let lists: [[String: Any]] = [["shelf": "genre:thriller", "mode": "weekly"], ["shelf": "genre:thriller", "mode": "allTime"], ["shelf": "trending-library", "mode": "weekly"], ["shelf": "trending-library", "mode": "allTime"]]
            .map { c in var c = c; let k = SMListKey.forShelf(c["shelf"] as! String, mode: SMShelfMode(rawValue: c["mode"] as! String)!); c["own"] = k.own ?? ""; c["general"] = k.general ?? ""; return c }
        let doc: [String: Any] = [
            "name": "shelf-modes",
            "description": "All time top / Trending this week on Trending in Your Library and genre shelves: ranking per mode (steps), remembered choice per profile and shelf (storage), TMDB list names per shelf and mode (lists, refetchHours: week* 24, others 168, 180-day cap). `ranks` = TMDB rank by item id for the shelf's own list; absent = no list cached (local ranking). Library: genre-shelves.json.",
            "storage": storage, "lists": lists, "refetchHours": ["week:x": 24, "top:x": 168, "top": 168], "library": lib, "steps": steps]
        let url = SMFixtures.directory.appendingPathComponent("shelf-modes.json")
        if writing { try jsonData(doc).write(to: url) }
        let on = try SMFixtures.json("shelf-modes")
        #expect(same(on["steps"]!, steps) && same(on["storage"]!, storage) && same(on["lists"]!, lists), "shelf-modes.json is out of date (run with SMARTMIX_WRITE_GENRE_FIXTURES=1)")
        // The storage script replays against the real helper.
        let d = UserDefaults(suiteName: "genre-fixture-\(UUID().uuidString)")!
        for op in storage {
            let p = op["profile"] as! String, sh = op["shelf"] as! String
            if op["op"] as! String == "set" { SMShelfModes.set(d, SMShelfMode(rawValue: op["mode"] as! String)!, profile: p, shelf: sh) }
            else { #expect(SMShelfModes.get(d, profile: p, shelf: sh).rawValue == op["expect"] as! String) }
        }
    }
}
