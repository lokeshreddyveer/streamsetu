import Foundation

/// Pure Smart Mix engine: no I/O, no clock, no globals. Same input and seed give the same output on every platform.
/// Pipeline: `prepare` (restricted flags, identity grouping, representative) once per context, then `build` per shelf.
enum SmartMixEngine {
    struct Prepared: Sendable {
        var inCount: Int
        var groups: [SMCandidate]
        /// folderKey -> indexes into `groups` (representative's folder). Built once; folder rows use it.
        var byFolder: [String: [Int]]
    }

    struct TrendingMode: Sendable {
        /// Matched titles are placed first in TMDB order on the top-week shelf (>= 6 matches and cache valid).
        var ordered = false
        var status = ""             // "off", "noCache", "active", "expired", "purged"
        init(ordered: Bool = false, status: String = "") { self.ordered = ordered; self.status = status }
    }

    // MARK: byte order (never String `<`, which is Unicode-canonical, and never UTF-16)
    @inline(__always) static func idLess(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    // MARK: prepare
    private struct GroupKey: Hashable { let kind: SMKind; let key: String }

    static func prepare(_ cands: [SMCandidate], preferredLang: String?) -> Prepared {
        var buckets: [GroupKey: [Int]] = [:]
        buckets.reserveCapacity(cands.count)
        for (i, c) in cands.enumerated() { buckets[GroupKey(kind: c.kind, key: c.key), default: []].append(i) }
        var reps: [SMCandidate] = []
        reps.reserveCapacity(buckets.count)
        for (_, idxs) in buckets {
            for cluster in clusters(idxs, cands) { reps.append(merge(cluster.map { cands[$0] }, preferredLang)) }
        }
        // Dictionary order is not stable: fix the array order (the pool sorts again by score; this keeps everything else deterministic).
        reps.sort { idLess($0.id, $1.id) }
        var byFolder: [String: [Int]] = [:]
        for (i, g) in reps.enumerated() { if let f = g.folder { byFolder[f, default: []].append(i) } }
        return Prepared(inCount: cands.count, groups: reps, byFolder: byFolder)
    }

    /// Splits one (kind, key) bucket into titles: members sorted by (year nil last, year, id bytes); a member more than 1 year above the
    /// first year of the current cluster starts a new cluster; nil-year members join the first cluster.
    private static func clusters(_ idxs: [Int], _ cands: [SMCandidate]) -> [[Int]] {
        if idxs.count == 1 { return [idxs] }
        let sorted = idxs.sorted { a, b in
            let ya = cands[a].year, yb = cands[b].year
            if ya != yb {
                guard let ya else { return false }
                guard let yb else { return true }
                return ya < yb
            }
            return idLess(cands[a].id, cands[b].id)
        }
        var out: [[Int]] = [], firstYear: [Int] = [], nily: [Int] = []
        for i in sorted {
            guard let y = cands[i].year else { nily.append(i); continue }
            if let fy = firstYear.last, y - fy <= 1 { out[out.count - 1].append(i) } else { out.append([i]); firstYear.append(y) }
        }
        if !nily.isEmpty { if out.isEmpty { out.append(nily) } else { out[0].append(contentsOf: nily) } }
        return out
    }

    private static func merge(_ members: [SMCandidate], _ pref: String?) -> SMCandidate {
        let nonCam = members.filter { !$0.cam }
        let pool = nonCam.isEmpty ? members : nonCam
        var best = pool[0]
        for m in pool.dropFirst() where better(m, best, pref) { best = m }
        var r = best
        r.restricted = members.contains { $0.restricted }
        r.dismissed = members.contains { $0.dismissed }
        r.camOnly = !members.contains { !$0.cam }
        r.watched = members.contains { $0.watched }
        r.completed = members.contains { $0.completed }
        r.lastWatched = members.compactMap(\.lastWatched).min()
        r.p7 = members.reduce(0) { $0 + $1.p7 }
        r.p30 = members.reduce(0) { $0 + $1.p30 }
        r.trend = members.compactMap(\.trend).min()
        return r
    }

    /// Representative order: preferred language, quality, preferred source, newest (added asc, nil last), id bytes.
    private static func better(_ a: SMCandidate, _ b: SMCandidate, _ pref: String?) -> Bool {
        let la = pref != nil && a.lang == pref, lb = pref != nil && b.lang == pref
        if la != lb { return la }
        if a.q != b.q { return a.q > b.q }
        if a.src != b.src { return a.src < b.src }
        if a.added != b.added {
            guard let x = a.added else { return false }
            guard let y = b.added else { return true }
            return x < y
        }
        return idLess(a.id, b.id)
    }

    // MARK: build one shelf
    static func build(shelfId: String, prepared: Prepared, ctx: SMContext, loadsAgo: [String: Int] = [:], trending: TrendingMode = TrendingMode(), ranks: [String: Int]? = nil) -> SMShelfResult {
        var prepared = prepared
        if shelfId == SMShelf.collections { return SMCollections.build(prepared: prepared, ctx: ctx) }
        let mode = ctx.mode(shelfId)
        let moodDef = SMShelf.isMood(shelfId) ? SMMoods.byKey[String(shelfId.dropFirst(SMShelf.moodPrefix.count))] : nil
        let isContextual = moodDef != nil || shelfId == SMShelf.fresh || shelfId == SMShelf.movieNight || shelfId == SMShelf.binge
        let isGenre = SMShelf.isGenre(shelfId)
        let genreDef = isGenre ? SMGenres.byKey[String(shelfId.dropFirst(SMGenres.shelfPrefix.count))] : nil
        // TMDB ranks for this shelf's own list (genre shelves, and Trending in Your Library in its all-time view); nil = no list, the local ranking stands.
        let usesRanks = isGenre || (shelfId == SMShelf.trendingLibrary && mode == .allTime)
        if usesRanks { for i in prepared.groups.indices { prepared.groups[i].trend = ranks?[prepared.groups[i].id] } }
        let seedShelf = (mode == .allTime && (isGenre || shelfId == SMShelf.trendingLibrary)) ? shelfId + "|top" : shelfId
        let def = SmartMixScoring.shelf(shelfId, mode: mode)
        let isFolder = SMShelf.isFolder(shelfId)
        var diag = SMDiagnostics()
        diag.inCount = prepared.inCount
        diag.tmdb = (shelfId == SMShelf.topWeek || shelfId == SMShelf.trendingLibrary || shelfId == SMShelf.hero) ? trending.status : ""

        if (isGenre && genreDef == nil) || (SMShelf.isMood(shelfId) && moodDef == nil) { diag.hidden = true; return SMShelfResult(shelfId: shelfId, picks: [], diag: diag) }
        var source: [Int] = isFolder ? (prepared.byFolder[String(shelfId.dropFirst(7))] ?? []) : Array(prepared.groups.indices)
        if let gd = genreDef { source = source.filter { SMGenres.matches(gd, genres: prepared.groups[$0].genres, kind: prepared.groups[$0].kind) } }
        if moodDef != nil {          // adaptive floor: a mood needs 1.5 % of the library's showable titles (at least 8)
            let total = prepared.groups.reduce(0) { $0 + (!$1.restricted && !$1.dismissed && !$1.camOnly && $1.poster ? 1 : 0) }
            let hits = source.reduce(0) { n, i in let g = prepared.groups[i]; return n + (!g.restricted && !g.dismissed && !g.camOnly && g.poster && SMMoods.matches(moodDef!, genres: g.genres, kind: g.kind, kids: ctx.kids) ? 1 : 0) }
            if hits < max(8, total * 15 / 1000) { diag.hidden = true; return SMShelfResult(shelfId: shelfId, picks: [], diag: diag) }
        }
        if let md = moodDef { source = source.filter { SMMoods.matches(md, genres: prepared.groups[$0].genres, kind: prepared.groups[$0].kind, kids: ctx.kids) } }
        if isContextual && moodDef == nil { source = source.filter { SMHomeRules.eligible(shelfId, prepared.groups[$0]) } }
        diag.groups = source.count
        var base: [Int] = []
        base.reserveCapacity(source.count)
        for i in source {
            let g = prepared.groups[i]
            if g.restricted { diag.restricted += 1; continue }
            if !isFolder && g.dismissed { diag.dismissed += 1; continue }
            base.append(i)
        }
        if shelfId == SMShelf.langPref && (ctx.preferredLang ?? "").isEmpty { diag.hidden = true; return SMShelfResult(shelfId: shelfId, picks: [], diag: diag) }
        let need = min(def.minCount, base.count)
        let trendMode = shelfId == SMShelf.trendingLibrary && base.reduce(0, { $0 + (prepared.groups[$1].trend != nil ? 1 : 0) }) >= 3
        let genreOrdered = isGenre && base.reduce(0, { $0 + (prepared.groups[$1].trend != nil ? 1 : 0) }) >= SMTrendingPolicy.minMatchesForTopWeek
        diag.trendMode = trendMode || genreOrdered
        let cap = min(def.pool, ctx.poolCap ?? Int.max)

        var final: (tier: Int, counts: SMDiagnostics, tiny: Bool, items: [SMCandidate], picks: [Int], relaxed: Bool)? = nil
        for tier in 0...5 {
            var counts = SMDiagnostics()
            var elig: [Int] = []
            elig.reserveCapacity(base.count)
            for i in base {
                let c = prepared.groups[i]
                if c.camOnly && tier < 5 { counts.camOnly += 1; continue }
                if shelfId == SMShelf.hero { if !(c.backdrop || c.poster) { counts.noArtwork += 1; continue } }
                else if !c.poster && tier < 4 { counts.noArtwork += 1; continue }
                if shelfId == SMShelf.langPref && c.lang != ctx.preferredLang { counts.lang += 1; continue }
                if trendMode && c.trend == nil { counts.notTrending += 1; continue }
                if !isFolder {
                    if shelfId == SMShelf.rediscover {
                        if c.watched && (!c.completed || (c.lastWatched.map { $0 <= 30 } ?? false)) { counts.watched += 1; continue }
                    } else if c.watched && tier < 3 { counts.watched += 1; continue }
                }
                elig.append(i)
            }
            let tiny = elig.count <= def.size
            let eff = tiny ? max(tier, 1) : tier
            let pool = selectPool(elig, prepared.groups, cap: cap) { SmartMixScoring.score($0, loadsAgo: loadsAgo[$0.key], shelfId: shelfId, shelf: def, ctx: ctx, tier: eff) }
            let items = pool.map { prepared.groups[$0.index] }
            let ws = pool.map { SmartMixScoring.weight(score: $0.score, sharp: def.sharp) }
            var forced: [Int] = []
            var rng = SplitMix64(seed: SmartMixPRNG.seed(profile: ctx.profile, shelf: seedShelf, day: ctx.dayKey, counter: ctx.refreshCounter))
            if genreOrdered {
                // TMDB order, with titles in the same rank bucket (3 ranks) shuffled by the day-seeded stream: one draw per ranked title, in (rank, id) order.
                let ranked = items.indices.filter { items[$0].trend != nil }.sorted { a, b in
                    items[a].trend! != items[b].trend! ? items[a].trend! < items[b].trend! : idLess(items[a].id, items[b].id)
                }
                var keyed: [(bucket: Int, key: UInt64, index: Int)] = []
                for i in ranked { keyed.append(((items[i].trend! - 1) / SMGenres.rankBucket, rng.next(), i)) }
                keyed.sort { a, b in a.bucket != b.bucket ? a.bucket < b.bucket : (a.key != b.key ? a.key < b.key : idLess(items[a.index].id, items[b.index].id)) }
                forced = keyed.prefix(def.size).map(\.index)
            }
            if trending.ordered && shelfId == SMShelf.topWeek {
                let ranked = items.indices.filter { items[$0].trend != nil }.sorted { a, b in
                    items[a].trend! != items[b].trend! ? items[a].trend! < items[b].trend! : idLess(items[a].id, items[b].id)
                }
                forced = Array(ranked.prefix(def.size))
            }
            let k = min(def.size, items.count)
            var picks: [Int] = [], relaxed = false
            let kk = min(def.size + max(0, ctx.oversample), items.count)
            if kk > 0 { (picks, relaxed) = draw(items: items, weights: ws, k: kk, rng: &rng, def: def, diversity: eff < 2, langRule: shelfId != SMShelf.langPref, genreRule: !(isGenre || moodDef != nil), forced: forced) }
            _ = k
            final = (tier, counts, tiny, items, picks, relaxed)
            if picks.count >= need { break }
        }
        let f = final!
        diag.camOnly = f.counts.camOnly; diag.noArtwork = f.counts.noArtwork; diag.watched = f.counts.watched
        diag.lang = f.counts.lang; diag.notTrending = f.counts.notTrending
        diag.tier = f.tier; diag.tiny = f.tiny; diag.pool = f.items.count; diag.drawn = f.picks.count; diag.diversityRelaxed = f.relaxed
        if isGenre && f.picks.count < SMGenres.minTitles {          // a genre shelf with too few titles is not shown (no fallback)
            diag.hidden = true
            return SMShelfResult(shelfId: shelfId, picks: [], diag: diag)
        }
        // Home v2 rows: no fallback, and never below the quality tiers (no CAM-only, no artwork-less titles).
        if isContextual && (f.picks.count < def.minCount || f.tier >= 4) {
            diag.hidden = true
            return SMShelfResult(shelfId: shelfId, picks: [], diag: diag)
        }
        var out = f.picks.map { f.items[$0] }
        if out.isEmpty && shelfId != SMShelf.langPref {
            // Never empty: recently added from what survived restricted/dismissed, then the plain library.
            let g = base.map { prepared.groups[$0] }
            var rec = g.filter { $0.poster || $0.backdrop }.sorted(by: recentlyAddedLess)
            diag.fallback = .recentlyAdded
            if rec.isEmpty && shelfId != SMShelf.hero { rec = g.sorted { idLess($0.id, $1.id) }; diag.fallback = .plainLibrary }
            out = Array(rec.prefix(def.size))
            if out.isEmpty { diag.fallback = shelfId == SMShelf.hero ? .existingFeatured : .none }
        } else if out.isEmpty { diag.hidden = true }
        switch shelfId {
        case SMShelf.topWeek: diag.caption = trending.ordered ? .trendingTMDB : .mostWatchedHere
        case SMShelf.trendingLibrary: diag.caption = trendMode ? .trendingTMDB : .mostWatchedHere
        default: if isGenre { diag.caption = genreOrdered ? .trendingTMDB : .mostWatchedHere }
        }
        let picks = out.map { SMPick(id: $0.id, key: $0.key, year: $0.year, kind: $0.kind, hasBackdrop: $0.backdrop, genre: $0.genre, genres: $0.genres, lang: $0.lang, franchise: $0.franchise) }
        let result = SMShelfResult(shelfId: shelfId, picks: picks, diag: diag)
        assertNoRestricted(result, in: prepared)
        return result
    }

    /// Eligible titles per genre key: not restricted, not dismissed, not CAM-only, with a poster, of a kind the genre covers, and matching it.
    static func genreCounts(_ prepared: Prepared) -> [String: Int] {
        var counts: [String: Int] = [:]
        for g in prepared.groups where !g.restricted && !g.dismissed && !g.camOnly && g.poster {
            for k in SMGenres.keys(genres: g.genres, kind: g.kind) { counts[k, default: 0] += 1 }
        }
        return counts
    }

    private static func recentlyAddedLess(_ a: SMCandidate, _ b: SMCandidate) -> Bool {
        if a.added != b.added {
            guard let x = a.added else { return false }
            guard let y = b.added else { return true }
            return x < y
        }
        return idLess(a.id, b.id)
    }

    // MARK: pool selection: top `cap` by (score desc, id bytes asc) without sorting everything
    private struct Scored { let index: Int; let score: Int }

    private static func selectPool(_ elig: [Int], _ groups: [SMCandidate], cap: Int, score: (SMCandidate) -> Int) -> [Scored] {
        var scored = elig.map { Scored(index: $0, score: score(groups[$0])) }
        if scored.count > cap {
            var hist = [Int](repeating: 0, count: 1101)
            for s in scored { hist[s.score] += 1 }
            var acc = 0, threshold = 0
            for v in stride(from: 1100, through: 0, by: -1) { acc += hist[v]; if acc >= cap { threshold = v; break } }
            scored = scored.filter { $0.score >= threshold }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : idLess(groups[$0.index].id, groups[$1.index].id) }
        return scored.count > cap ? Array(scored.prefix(cap)) : scored
    }

    // MARK: weighted sampling without replacement + MMR-style penalties + max 2 consecutive
    static func draw(items: [SMCandidate], weights: [Int64], k: Int, rng: inout some SmartMixBitSource, def: SmartMixScoring.Shelf,
                     diversity: Bool, langRule: Bool, genreRule: Bool = true, forced: [Int]) -> (picks: [Int], relaxed: Bool) {
        let n = items.count
        var w = weights
        var picks: [Int] = []
        var table: [String: Int32] = [:]
        func intern(_ s: String?) -> Int32 {          // -1 = nil
            guard let s else { return -1 }
            if let v = table[s] { return v }
            let v = Int32(table.count); table[s] = v; return v
        }
        let fr = items.map { intern($0.franchise) }, ge = items.map { genreRule ? intern($0.genre) : -1 }, la = items.map { intern($0.lang) }
        let kd: [Int32] = items.map { $0.kind == .movie ? 0 : 1 }
        for i in forced { w[i] = 0; picks.append(i) }
        var relaxed = false
        var elig: [Int] = []
        elig.reserveCapacity(n)
        while picks.count < k {
            elig.removeAll(keepingCapacity: true)
            var anyPositive = false
            let blockedActive = diversity && picks.count >= 2
            let a = blockedActive ? picks[picks.count - 1] : 0, b = blockedActive ? picks[picks.count - 2] : 0
            for i in 0..<n where w[i] > 0 {
                anyPositive = true
                if blockedActive {
                    if fr[i] >= 0 && fr[a] == fr[i] && fr[b] == fr[i] { continue }
                    if ge[i] >= 0 && ge[a] == ge[i] && ge[b] == ge[i] { continue }
                    if def.mixesKinds && kd[a] == kd[i] && kd[b] == kd[i] { continue }
                    if langRule && la[i] >= 0 && la[a] == la[i] && la[b] == la[i] { continue }
                }
                elig.append(i)
            }
            if elig.isEmpty {
                if !anyPositive { break }
                for i in 0..<n where w[i] > 0 { elig.append(i) }
                relaxed = true
            }
            var total: Int64 = 0
            for i in elig { total += w[i] }
            if total == 0 { break }
            let r = Int64(rng.uniform(UInt64(total)))
            var acc: Int64 = 0, p = elig[elig.count - 1]
            for i in elig { acc += w[i]; if r < acc { p = i; break } }
            w[p] = 0
            picks.append(p)
            if diversity {
                for j in 0..<n where w[j] > 0 {
                    if fr[p] >= 0 && fr[j] == fr[p] { w[j] = w[j] / 4 }
                    if langRule && la[p] >= 0 && la[j] == la[p] && kd[j] == kd[p] { w[j] = (w[j] * 3) / 4 }
                }
            }
        }
        return (picks, relaxed)
    }

    // MARK: restricted assertion
    /// Belt and braces: the adapter removes restricted items; the engine drops them again and a debug build asserts none is shown.
    static func assertNoRestricted(_ result: SMShelfResult, in prepared: Prepared) {
        #if DEBUG
        let bad = Set(prepared.groups.filter(\.restricted).map(\.id))
        assert(result.picks.allSatisfy { !bad.contains($0.id) }, "restricted title reached a Smart Mix shelf")
        #endif
    }
}
