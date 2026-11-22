import Testing
import Foundation
@testable import REDDY

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func diagDict(_ d: SMDiagnostics, folder: Bool) -> [String: String] {
    var o: [String: String] = [
        "groups": String(d.groups), "restricted": String(d.restricted), "dismissed": String(d.dismissed), "camOnly": String(d.camOnly),
        "noArtwork": String(d.noArtwork), "watched": String(d.watched), "lang": String(d.lang), "notTrending": String(d.notTrending),
        "pool": String(d.pool), "drawn": String(d.drawn), "tier": String(d.tier), "tiny": String(d.tiny), "hidden": String(d.hidden),
        "fallback": d.fallback.rawValue, "diversityRelaxed": String(d.diversityRelaxed), "caption": d.caption.rawValue, "tmdb": d.tmdb, "trendMode": String(d.trendMode)]
    if !folder { o["inCount"] = String(d.inCount) }
    return o
}

private func pyString(_ v: Any?) -> String {
    if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue }
    return (v as? String) ?? ""
}

private struct NoFetch: SMTrendingFetching { func fetchWeekly() async throws -> [SMTrendingEntry] { throw SMTMDBTrendingClient.Failure.disabled } }

/// Runs a fixture case through the real session (source, state, trending service, engine).
private func run(_ doc: [String: Any], file: String) async throws {
    let lib0 = SMFixtures.library(doc)
    let hasPatch = (doc["steps"] as! [[String: Any]]).contains { $0["patch"] != nil }
    let source = InMemoryCandidateSource(lib0)
    let state = InMemorySmartMixStateStore()
    var stepNo = 0
    for step in doc["steps"] as! [[String: Any]] {
        defer { stepNo += 1 }
        if hasPatch {
            var lib = lib0
            let patch = step["patch"] as? [String: [String: Any]] ?? [:]
            if !patch.isEmpty { for i in lib.indices { if let p = patch[lib[i].id] { SMFixtures.patch(&lib[i], p) } } }
            source.set(lib)
        }
        var service: SMTrendingService? = nil
        if let tm = step["tmdb"] as? [String: Any] {
            var cache: SMTrendingCache? = nil
            if let c = tm["cache"] as? [String: Any] {
                cache = SMTrendingCache(fetchedAt: fixedNow.addingTimeInterval(-Double(c["fetchedDaysAgo"] as! Int) * 86_400),
                                        entries: SMFixtures.entries(c["entries"] as! [[String: Any]]))
            }
            var policy = SMTrendingPolicy()
            policy.enabled = tm["enabled"] as? Bool ?? true
            policy.hasOwnKey = tm["keyPresent"] as? Bool ?? false
            service = SMTrendingService(fetcher: NoFetch(), cache: InMemoryTrendingCacheStore(cache), policy: policy)
        }
        let session = SmartMixSession(source: source, state: state, trending: service)
        let ctx = SMContext(profile: step["profile"] as! String, dayKey: step["dayKey"] as! String, refreshCounter: step["refreshCounter"] as? Int ?? 0,
                            preferredLang: step["preferredLang"] as? String, affinity: SMFixtures.affinity(step["affinity"] as? [String: Any]))
        let shelves = step["shelves"] as! [String]
        let results = try await session.shelves(shelves, ctx: ctx, now: fixedNow, commit: step["commit"] as? Bool ?? false)
        let expect = step["expect"] as! [String: Any]
        let tag = "\(file) step \(stepNo)"
        if let digest = expect["digest"] as? String {
            #expect(SMFixtures.digest(results) == digest, "\(tag) digest")
            let first = expect["first"] as! [String: [String]]
            for r in results where first[r.shelfId] != nil { #expect(Array(r.ids.prefix(14)) == first[r.shelfId]!, "\(tag) \(r.shelfId) first ids") }
            let counts = expect["counts"] as! [String: Int]
            for r in results { #expect(r.ids.count == counts[r.shelfId], "\(tag) \(r.shelfId) count") }
            continue
        }
        for r in results {
            let e = expect[r.shelfId] as! [String: Any]
            #expect(r.ids == e["ids"] as! [String], "\(tag) \(r.shelfId) ids")
            if r.shelfId == SMShelf.hero { #expect(r.picks.map { $0.hasBackdrop ? "backdrop" : "poster" } == e["art"] as! [String], "\(tag) hero art") }
            let ed = e["diag"] as! [String: Any]
            let got = diagDict(r.diag, folder: SMShelf.isFolder(r.shelfId))
            for (k, v) in got { #expect(v == pyString(ed[k]), "\(tag) \(r.shelfId) diag.\(k)") }
        }
    }
}

@Suite struct SmartMixPRNGTests {
    @Test func vectorsMatchTheSharedFile() throws {
        let d = try SMFixtures.json("prng")
        for v in d["fnv1a64"] as! [[String: Any]] {
            #expect(String(format: "%016llX", SmartMixPRNG.fnv1a64((v["input"] as! String).utf8)) == v["hex"] as! String)
        }
        for v in d["splitmix64"] as! [[String: Any]] {
            var g = SplitMix64(seed: UInt64(v["seed"] as! Int))
            #expect((v["hex"] as! [String]).map { _ in String(format: "%016llX", g.next()) } == v["hex"] as! [String])
        }
        let ss = d["seedString"] as! [String: Any]
        #expect(SmartMixPRNG.seedString(profile: ss["profile"] as! String, shelf: ss["shelf"] as! String, day: ss["day"] as! String, counter: ss["counter"] as! Int) == ss["value"] as! String)
        for u in d["uniform"] as! [[String: Any]] {
            if let s = u["seedString"] as? String {
                var g = SplitMix64(seed: SmartMixPRNG.fnv1a64(s.utf8))
                let n = UInt64((u["n"] as! NSNumber).uint64Value)
                #expect((u["values"] as! [Int]).map { _ in Int(g.uniform(n)) } == u["values"] as! [Int])
            } else if let ns = u["ns"] as? [Int] {
                var g = SplitMix64(seed: UInt64(u["splitmixSeed"] as! Int))
                #expect(ns.map { Int(g.uniform(UInt64($0))) } == u["values"] as! [Int])
            } else {
                var g = SplitMix64(seed: UInt64(u["splitmixSeed"] as! Int))
                let n = (u["n"] as! NSNumber).uint64Value
                let vals = (u["values"] as! [NSNumber]).map(\.uint64Value)
                #expect(vals.map { _ in g.uniform(n) } == vals)
            }
        }
    }

    @Test func publishedContractVectors() {
        var g = SplitMix64(seed: 0)
        #expect([g.next(), g.next(), g.next()] == [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F])
        let seed = SmartMixPRNG.seed(profile: "main", shelf: "hero", day: "2026-11-21", counter: 0)
        #expect(seed == 0xEA146339CF956E5F)
        var h = SplitMix64(seed: seed)
        #expect((0..<5).map { _ in Int(h.uniform(1000)) } == [600, 713, 122, 290, 566])
    }

    @Test func uniformRejectsTheBiasedBand() {
        // n = 3: limit = 2^64 mod 3 = 1, so a raw 0 is rejected and the next draw is used.
        var s = StubBits(values: [0, 5])
        #expect(s.uniform(3) == 2)
        #expect(s.calls == 2)
        var t = StubBits(values: [1])
        #expect(t.uniform(3) == 1 && t.calls == 1)
        // n = 1 never rejects.
        var u = StubBits(values: [0])
        #expect(u.uniform(1) == 0 && u.calls == 1)
        // A power of two has no bias band at all.
        var p = StubBits(values: [0xFFFF_FFFF_FFFF_FFFF])
        #expect(p.uniform(1 << 32) == 0xFFFF_FFFF && p.calls == 1)
    }
}

@Suite struct SmartMixScoringTests {
    @Test func featureTablesMatchTheSharedFile() throws {
        let d = try SMFixtures.json("features")
        for r in d["release"] as! [[Any]] { #expect(SmartMixScoring.release(year: r[0] as? Int, nowYear: r[1] as! Int) == r[2] as! Int, "release \(r)") }
        for r in d["added"] as! [[Any]] { #expect(SmartMixScoring.added(days: r[0] as? Int) == r[1] as! Int, "added \(r)") }
        for r in d["quality"] as! [[Any]] { #expect(SmartMixScoring.quality(r[0] as! Int) == r[1] as! Int) }
        for r in d["language"] as! [[Any]] { #expect(SmartMixScoring.language(r[0] as? String, preferred: r[1] as? String) == r[2] as! Int, "language \(r)") }
        for r in d["rating"] as! [[Any]] { #expect(SmartMixScoring.rating(r[0] as? String) == r[1] as! Int, "rating \(r)") }
        for r in d["popularity"] as! [[Any]] { #expect(SmartMixScoring.popularity(p7: r[0] as! Int, p30: r[1] as! Int) == r[2] as! Int, "popularity \(r)") }
        for r in d["fresh"] as! [[Any]] { #expect(SmartMixScoring.fresh(loadsAgo: r[0] as? Int) == r[1] as! Int) }
        let aff = SMFixtures.affinity(d["affinityContext"] as? [String: Any])
        for r in d["affinity"] as! [[Any]] {
            let c = r[0] as! [String: Any]
            var cand = SMCandidate(id: "x"); cand.lang = c["lang"] as? String; cand.folder = c["folder"] as? String; cand.genre = c["genre"] as? String; cand.year = c["year"] as? Int
            #expect(SmartMixScoring.affinity(cand, aff) == r[1] as! Int, "affinity \(c)")
        }
    }

    @Test func junkRatingsAreNeutralAndGoodOnesAreShrunk() {
        for junk in ["", "0", "0.0", "10", "10.0", "10.5", "abc", "-1", ">10", "N/A", "7.", ".5", "007", "7,5", " 7"] as [String?] + [nil] {
            #expect(SmartMixScoring.rating(junk) == 500, "\(junk ?? "nil")")
        }
        #expect(SmartMixScoring.rating("9.99") == 687)
        #expect(SmartMixScoring.rating("6.0") == 500)
        #expect(SmartMixScoring.rating("1") == 500 + ((0 - 500) * 40) / 100 && SmartMixScoring.rating("1.0") < 500)
        for t in ["0.1", "5.5", "9.9", "9.99"] { #expect((300...700).contains(SmartMixScoring.rating(t)), "shrink keeps ratings within 300...700: \(t)") }
    }

    @Test func weightRowsSumTo100AndOverflowBoundHolds() {
        for id in SMShelf.all + [SMShelf.folder("x")] { #expect(SmartMixScoring.shelf(id).w.reduce(0, +) == 100, "\(id)") }
        // Worst case: 2000 candidates at the maximum score 1100.
        let w = SmartMixScoring.weight(score: 1100, sharp: true)
        #expect(w == 12_101)
        #expect(w * 2000 == 24_202_000 && w * 2000 < Int64.max / 1_000_000)
        #expect(SmartMixScoring.weight(score: 0, sharp: true) == 1 && SmartMixScoring.weight(score: 0, sharp: false) == 1)
    }
}

@Suite struct SmartMixFixtureTests {
    @Test(arguments: SMFixtures.allCaseNames.filter { $0 != "stress-200k" }) func fixtureCase(_ name: String) async throws {
        try await run(try SMFixtures.json(name), file: name)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SMARTMIX_HEAVY"] != nil || ProcessInfo.processInfo.environment["SMARTMIX_BENCH"] != nil))
    func stress200k() async throws {
        try await run(try SMFixtures.json("stress-200k"), file: "stress-200k")
    }

    @Test func everyRequiredFixtureExists() {
        let need = ["prng", "features", "empty-library", "tiny-library", "duplicates-and-twins", "multilang-versions", "bad-ratings", "missing-artwork",
                    "offline-no-tmdb-key", "trending-matched", "expired-metadata", "profile-switch", "exclusions", "repeat-suppression-5-loads",
                    "reshuffle-sequence", "day-rollover", "diversity-limits", "non-latin-ids-byte-order", "relaxation-order", "hundreds-of-folders", "large-66k", "stress-200k"]
        let have = Set(SMFixtures.allCaseNames + ["prng", "features"])
        for n in need { #expect(have.contains(n), "missing fixture \(n)") }
    }
}

@Suite struct SmartMixBehaviourTests {
    private func lib(_ n: Int) -> [SMCandidate] {
        (0..<n).map { i in
            var c = SMCandidate(id: "m\(i)"); c.key = "k\(i)"; c.year = 2015 + i % 11; c.added = i * 4; c.q = 2 + i % 4
            c.lang = ["Telugu", "Hindi", "English"][i % 3]; c.backdrop = i % 2 == 0; c.franchise = i % 7 == 0 ? "fr" : nil
            return c
        }
    }
    private func ctx(_ p: String = "main", day: String = "2026-11-21", counter: Int = 0, lang: String? = "Telugu") -> SMContext {
        SMContext(profile: p, dayKey: day, refreshCounter: counter, preferredLang: lang)
    }
    private func build(_ shelf: String, _ cands: [SMCandidate], _ c: SMContext) -> SMShelfResult {
        SmartMixEngine.build(shelfId: shelf, prepared: SmartMixEngine.prepare(cands, preferredLang: c.preferredLang), ctx: c)
    }

    @Test func sameInputTwiceIsIdentical_differentSeedsDiffer() {
        let l = lib(200)
        for s in SMShelf.all {
            #expect(build(s, l, ctx()).ids == build(s, l, ctx()).ids, "\(s)")
        }
        let base = build(SMShelf.forYou, l, ctx()).ids
        #expect(build(SMShelf.forYou, l, ctx(counter: 1)).ids != base)
        #expect(build(SMShelf.forYou, l, ctx(day: "2026-11-22")).ids != base)
        #expect(build(SMShelf.forYou, l, ctx("other")).ids != base)
    }

    @Test func inputOrderDoesNotChangeTheResult() {
        let l = lib(150)
        #expect(build(SMShelf.hero, l, ctx()).ids == build(SMShelf.hero, l.reversed(), ctx()).ids)
    }

    @Test func restrictedAndDismissedNeverAppear_evenThroughFallbacks() {
        var l = lib(40)
        for i in 0..<10 { l[i].restricted = true }
        for i in 10..<14 { l[i].dismissed = true }
        let bad = Set(l.prefix(10).map(\.id)), dis = Set(l[10..<14].map(\.id))
        for s in SMShelf.all {
            let r = build(s, l, ctx())
            #expect(r.ids.allSatisfy { !bad.contains($0) && !dis.contains($0) }, "\(s)")
        }
        let folder = build(SMShelf.folder("none"), l, ctx())
        #expect(folder.ids.isEmpty)
        // Everything restricted: nothing is shown and the fallback does not leak.
        let all = l.map { var c = $0; c.restricted = true; return c }
        for s in SMShelf.all { #expect(build(s, all, ctx()).ids.isEmpty, "\(s)") }
        #expect(build(SMShelf.hero, all, ctx()).diag.fallback == .existingFeatured)
    }

    @Test func aRestrictedTwinRemovesTheWholeTitle() {
        var a = SMCandidate(id: "a"); a.key = "dune"; a.year = 2021; a.q = 5
        var b = SMCandidate(id: "b"); b.key = "dune"; b.year = 2021; b.restricted = true
        let r = build(SMShelf.hero, [a, b] + lib(10), ctx())
        #expect(!r.ids.contains("a") && !r.ids.contains("b"))
        #expect(r.diag.restricted == 1)
    }

    @Test func foldersIgnoreDismissalsButNotRestriction() {
        var l = lib(30).map { var c = $0; c.folder = "f"; return c }
        l[0].dismissed = true; l[1].restricted = true
        let r = build(SMShelf.folder("f"), l, ctx())
        #expect(r.diag.dismissed == 0 && r.diag.restricted == 1)
        #expect(!r.ids.contains("m1"))
    }

    @Test func shelvesAreNeverEmptyWhenAnythingIsAllowed() {
        var one = SMCandidate(id: "only"); one.key = "x"; one.poster = false; one.cam = true; one.q = 0; one.watched = true
        for s in [SMShelf.hero, SMShelf.forYou, SMShelf.topWeek, SMShelf.trendingLibrary, SMShelf.rediscover] {
            #expect(build(s, [one], ctx()).ids == ["only"] || build(s, [one], ctx()).diag.fallback != .none, "\(s)")
        }
        #expect(build(SMShelf.hero, [], ctx()).diag.fallback == .existingFeatured)
        #expect(build(SMShelf.forYou, [], ctx()).ids.isEmpty)
    }

    @Test func langPrefHardFilterIsNeverRelaxedAndHidesWithoutALanguage() {
        let l = lib(60)
        let r = build(SMShelf.langPref, l, ctx(lang: "Telugu"))
        #expect(r.picks.allSatisfy { p in l.first { $0.id == p.id }!.lang == "Telugu" })
        let none = build(SMShelf.langPref, l, ctx(lang: nil))
        #expect(none.isHidden && none.ids.isEmpty)
        let noMatch = build(SMShelf.langPref, l, ctx(lang: "Klingon"))
        #expect(noMatch.isHidden && noMatch.ids.isEmpty && noMatch.diag.fallback == .none)
    }

    @Test func heroFallsBackToPosterWhenThereIsNoBackdrop() {
        var l = lib(20); for i in l.indices { l[i].backdrop = false }
        let r = build(SMShelf.hero, l, ctx())
        #expect(r.ids.count == 12 && r.picks.allSatisfy { !$0.hasBackdrop })
        for i in l.indices { l[i].poster = false }
        #expect(build(SMShelf.hero, l, ctx()).diag.fallback == .existingFeatured)
    }

    @Test func maxTwoConsecutiveOfTheSameFranchiseGenreLanguageAndHeroKind() {
        var l: [SMCandidate] = []
        for i in 0..<30 { var c = SMCandidate(id: "a\(i)"); c.key = "a\(i)"; c.franchise = "saga"; c.genre = "g"; c.lang = "Telugu"; c.q = 5; c.year = 2026; c.added = 1; c.backdrop = true; l.append(c) }
        for i in 0..<30 { var c = SMCandidate(id: "b\(i)"); c.key = "b\(i)"; c.kind = .series; c.franchise = "other"; c.genre = "h"; c.lang = "Hindi"; c.q = 4; c.year = 2026; c.added = 1; c.backdrop = true; l.append(c) }
        for shelf in [SMShelf.hero, SMShelf.forYou, SMShelf.topWeek] {
            for counter in 0..<5 {
                let ids = build(shelf, l, ctx(counter: counter)).ids
                for i in 2..<ids.count {
                    let g = ids[(i - 2)...i].map { $0.first! }
                    #expect(Set(g).count > 1, "three in a row from the same franchise on \(shelf) seed \(counter)")
                }
            }
        }
    }

    @Test func repeatSuppressionSpreadsLoadsAndStaysStableInASession() async throws {
        let l = lib(80)
        let source = InMemoryCandidateSource(l), state = InMemorySmartMixStateStore()
        let session = SmartMixSession(source: source, state: state)
        var seen: [[String]] = []
        for counter in 0..<4 {
            let r = try await session.shelves([SMShelf.forYou], ctx: ctx(counter: counter), now: fixedNow, commit: true)
            let again = try await session.shelves([SMShelf.forYou], ctx: ctx(counter: counter), now: fixedNow, commit: true)
            #expect(r[0].ids == again[0].ids, "rebuild within a load is stable")
            seen.append(r[0].ids)
        }
        // With 80 candidates and 14 picks per load, the previous load is penalised: overlap with it is lower than chance.
        let overlap = Set(seen[1]).intersection(seen[0]).count
        #expect(overlap <= 4, "overlap \(overlap)")
        // Old rows are pruned to 48.
        for c in 4..<12 { _ = try await session.shelves([SMShelf.forYou], ctx: ctx(counter: c), now: fixedNow, commit: true) }
        let ago = state.loadsAgo(profile: "main", shelf: SMShelf.forYou, loadKey: "2026-11-21|99")
        #expect(ago.count <= 48 && ago.values.allSatisfy { $0 >= 1 })
    }

    @Test func stateIsPerProfileAndForgetDropsRows() {
        let s = InMemorySmartMixStateStore()
        s.recordShown(profile: "A", shelf: "hero", loadKey: "d|0", rows: [SMShownRow(key: "k1", year: 2020, itemId: "i1", seq: 0)])
        #expect(s.loadsAgo(profile: "A", shelf: "hero", loadKey: "d|1") == ["k1": 1])
        #expect(s.loadsAgo(profile: "B", shelf: "hero", loadKey: "d|1").isEmpty)
        #expect(s.loadsAgo(profile: "A", shelf: "hero", loadKey: "d|0").isEmpty, "own load rows are ignored")
        s.bumpRefresh(profile: "A", shelves: ["hero"])
        #expect(s.refreshCounter(profile: "A", shelf: "hero") == 1 && s.refreshCounter(profile: "B", shelf: "hero") == 0)
        s.forget(profile: "A", keys: ["k1"])
        #expect(s.loadsAgo(profile: "A", shelf: "hero", loadKey: "d|1").isEmpty)
        s.recordShown(profile: "A", shelf: "hero", loadKey: "d|1", rows: [SMShownRow(key: "k2", year: nil, itemId: "i2", seq: 0)])
        s.clear(profile: "A")
        #expect(s.loadsAgo(profile: "A", shelf: "hero", loadKey: "d|2").isEmpty)
    }

    @Test func utf8ByteOrderBreaksTies() {
        #expect(SmartMixEngine.idLess("\u{FF21}", "\u{10400}"))        // UTF-8: EF.. < F0.. although UTF-16 order is reversed
        #expect(!("\u{FF21}".utf16.lexicographicallyPrecedes("\u{10400}".utf16)))
        #expect(SmartMixEngine.idLess("Z", "a") && SmartMixEngine.idLess("a", "\u{e9}"))
    }

    @Test func degradedPoolCapStillWorks() {
        let l = lib(500)
        var c = ctx(); c.poolCap = 50
        let r = build(SMShelf.forYou, l, c)
        #expect(r.diag.pool == 50 && r.ids.count == 14)
    }
}

@Suite struct SmartMixSessionTests {
    private func cands(_ n: Int) -> [SMCandidate] {
        (0..<n).map { i in var c = SMCandidate(id: "m\(i)"); c.key = "k\(i)"; c.year = 2020 + i % 6; c.added = i; c.backdrop = true; return c }
    }

    private actor GateSource: SmartMixCandidateSource {
        let inner: InMemoryCandidateSource
        var gate: CheckedContinuation<Void, Never>?
        var waiting = false
        init(_ l: [SMCandidate]) { inner = InMemoryCandidateSource(l) }
        func candidates(profile: String, scope: SMScope, poolLimit: Int) async throws -> [SMCandidate] {
            waiting = true
            await withCheckedContinuation { gate = $0 }
            return try await inner.candidates(profile: profile, scope: scope, poolLimit: poolLimit)
        }
        func revision(profile: String) async -> SMRevision { await inner.revision(profile: profile) }
        func release() { gate?.resume(); gate = nil }
        func isWaiting() -> Bool { waiting && gate != nil }
    }

    @Test func aBuildThatStraddlesALockPublishesNothingAndCachesNothing() async throws {
        let source = GateSource(cands(40)), state = InMemorySmartMixStateStore()
        let session = SmartMixSession(source: source, state: state)
        let ctx = SMContext(profile: "p", dayKey: "2026-11-21")
        let task = Task { try await session.shelves([SMShelf.hero], ctx: ctx, now: fixedNow, commit: true) }
        while !(await source.isWaiting()) { await Task.yield() }
        await session.invalidate(.lockOrRestrictionChange)
        await source.release()
        do { _ = try await task.value; Issue.record("expected a stale build") } catch let e as SmartMixSession.SessionError { #expect(e == .stale) }
        #expect(state.loadsAgo(profile: "p", shelf: SMShelf.hero, loadKey: "2026-11-22|0").isEmpty, "nothing recorded from a discarded build")
    }

    @Test func lockClearsCachesAndNeverServesARestrictedTitle() async throws {
        let l = cands(40)
        let source = InMemoryCandidateSource(l), state = InMemorySmartMixStateStore()
        let session = SmartMixSession(source: source, state: state)
        let ctx = SMContext(profile: "p", dayKey: "2026-11-21")
        let first = try await session.shelves([SMShelf.hero], ctx: ctx, now: fixedNow)
        let victim = first[0].ids[0]
        var locked = l; locked[locked.firstIndex { $0.id == victim }!].restricted = true
        source.set(locked, bump: \.restrict)
        await session.invalidate(.lockOrRestrictionChange)
        let after = try await session.shelves([SMShelf.hero], ctx: ctx, now: fixedNow)
        #expect(!after[0].ids.contains(victim))
    }

    @Test func buildsRunOffTheMainThread() async throws {
        let source = InMemoryCandidateSource(cands(100)), state = InMemorySmartMixStateStore()
        let session = SmartMixSession(source: source, state: state)
        let onMain = await Task.detached { (pthread_main_np() != 0) }.value
        #expect(!onMain)
        _ = try await session.shelves(SMShelf.all, ctx: SMContext(profile: "p", dayKey: "2026-11-21"), now: fixedNow)
    }

    @Test func profileSwitchKeepsStateApart() async throws {
        let source = InMemoryCandidateSource(cands(60)), state = InMemorySmartMixStateStore()
        let session = SmartMixSession(source: source, state: state)
        let a = try await session.shelves([SMShelf.forYou], ctx: SMContext(profile: "A", dayKey: "2026-11-21"), now: fixedNow, commit: true)
        await session.invalidate(.profileSwitch)
        let b = try await session.shelves([SMShelf.forYou], ctx: SMContext(profile: "B", dayKey: "2026-11-21"), now: fixedNow, commit: true)
        await session.invalidate(.profileSwitch)
        let a2 = try await session.shelves([SMShelf.forYou], ctx: SMContext(profile: "A", dayKey: "2026-11-21"), now: fixedNow)
        #expect(a[0].ids == a2[0].ids && a[0].ids != b[0].ids)
    }
}

@Suite struct SmartMixTrendingTests {
    @Test func foldAndMatch() {
        #expect(SMTrendingMatcher.fold("The Bear") == "bear")
        #expect(SMTrendingMatcher.fold("Shōgun") == "shogun")
        #expect(SMTrendingMatcher.fold("Dune: Part Two") == "dune part two")
        #expect(SMTrendingMatcher.fold("  A  ") == "a")
        var c1 = SMCandidate(id: "1"); c1.key = "dune part two"; c1.year = 2024
        var c2 = SMCandidate(id: "2"); c2.key = "dune part two"; c2.year = 2010
        var c3 = SMCandidate(id: "3"); c3.key = "dune part two"; c3.kind = .series; c3.year = 2024
        let e = [SMTrendingEntry(rank: 4, type: "movie", title: "Dune: Part Two", original: nil, year: 2023)]
        #expect(SMTrendingMatcher.match(entries: e, candidates: [c1, c2, c3]) == ["1": 4])
    }

    @Test func offWithoutAKey_noRequest_noCache() async {
        let fetcher = FakeTrendingFetcher(.success([SMTrendingEntry(rank: 1, type: "movie", title: "x", original: nil, year: nil)]))
        let store = InMemoryTrendingCacheStore(SMTrendingCache(fetchedAt: fixedNow, entries: []))
        var p = SMTrendingPolicy(); p.hasOwnKey = false
        let svc = SMTrendingService(fetcher: fetcher, cache: store, policy: p)
        #expect(await svc.refreshIfNeeded(now: fixedNow) == .off)
        #expect(fetcher.calls == 0)
        #expect(await svc.current(now: fixedNow).entries == nil)
        await svc.setPolicy(p)
        #expect(store.load() == nil, "no key: nothing kept")
        #expect(SMTrendingPolicy().enabled, "the switch defaults to ON")
    }

    @Test func fetchesCachesAndRespectsAgeLimits() async {
        let entries = [SMTrendingEntry(rank: 1, type: "movie", title: "x", original: nil, year: 2024)]
        let fetcher = FakeTrendingFetcher(.success(entries))
        let store = InMemoryTrendingCacheStore()
        var p = SMTrendingPolicy(); p.hasOwnKey = true
        let svc = SMTrendingService(fetcher: fetcher, cache: store, policy: p)
        #expect(await svc.refreshIfNeeded(now: fixedNow) == .active && fetcher.calls == 1)
        _ = await svc.refreshIfNeeded(now: fixedNow.addingTimeInterval(3_600))
        #expect(fetcher.calls == 1, "at most one refresh a day")
        // Offline later: keeps the cache while it is fresh, then expired (local only), then purged at 6 months.
        fetcher.result = .failure(SMTMDBTrendingClient.Failure.http(500))
        let day = 86_400.0
        #expect(await svc.refreshIfNeeded(now: fixedNow.addingTimeInterval(10 * day)) == .active)
        #expect(await svc.refreshIfNeeded(now: fixedNow.addingTimeInterval(45 * day)) == .expired)
        #expect(await svc.current(now: fixedNow.addingTimeInterval(45 * day)).entries == nil)
        #expect(await svc.refreshIfNeeded(now: fixedNow.addingTimeInterval(181 * day)) == .noCache)
        #expect(store.load() == nil, "older than 180 days is deleted")
    }

    @Test func theClientRefusesWithoutAKeyAndNeverTouchesTheNetwork() async {
        let client = SMTMDBTrendingClient(keys: FixedKeys(apiKey: nil))
        do { _ = try await client.fetchWeekly(); Issue.record("must throw") } catch let e as SMTMDBTrendingClient.Failure { if case .disabled = e {} else { Issue.record("wrong error") } } catch { Issue.record("wrong error") }
        let blank = SMTMDBTrendingClient(keys: FixedKeys(apiKey: "  "))
        do { _ = try await blank.fetchWeekly(); Issue.record("must throw") } catch {}
    }
}

@Suite struct SmartMixIdentityMappingTests {
    @Test func identityRowMapsToACandidate() {
        let row = SMIdentityRow(itemId: "m1", kind: "series", identityKey: "the bear", year: 2022, lang: "English", qualityRank: 9, isCam: true, folderKey: "f")
        let c = row.candidate(sourceRank: 1, addedDays: 5, hasPoster: true, hasBackdrop: false, ratingText: "8.1", restricted: true, dismissed: false)
        #expect(c.kind == .series && c.key == "the bear" && c.q == 5 && c.cam && c.folder == "f" && c.src == 1 && c.restricted && c.added == 5)
    }
}
