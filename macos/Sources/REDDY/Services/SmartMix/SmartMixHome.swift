import Foundation

// Home v2 (docs/SMART-MIX.md section 10): moods, franchises, row names, row-level exclusion, re-rank, exploration, placement by context and the
// default view of a ranked row. Pure and integer-only, like the rest of the engine: no I/O, no clock, no locale. Fixture: smartmix/fixtures/home-layout.json.

// MARK: - Moods

struct SMMood: Sendable {
    let key: String
    let title: String                 // English; the UI looks it up
    let subtitle: String
    let genreKeys: [String]           // SMGenres keys the mood draws from
    let kidsOK: Bool                  // shown (with kid-safe genres only) on a Kids profile
}

enum SMMoods {
    static let table: [SMMood] = [
        SMMood(key: "withKids", title: "With the Kids", subtitle: "Safe, bright and made to share", genreKeys: ["family", "animation", "kids", "adventure"], kidsOK: true),
        SMMood(key: "edge", title: "Edge of Your Seat", subtitle: "Tense stories you cannot pause", genreKeys: ["thriller", "crime", "mystery"], kidsOK: false),
        SMMood(key: "feelGood", title: "Feel-Good Picks", subtitle: "Light, warm and easy to enjoy", genreKeys: ["comedy", "romance", "family", "music"], kidsOK: true),
    ]
    static let byKey: [String: SMMood] = Dictionary(uniqueKeysWithValues: table.map { ($0.key, $0) })

    /// A Kids profile only draws from kid-safe genres of the mood.
    static func genreKeys(_ m: SMMood, kids: Bool) -> [String] { kids ? m.genreKeys.filter { SMGenres.byKey[$0]?.kidsSafe ?? false } : m.genreKeys }

    static func matches(_ m: SMMood, genres: [String], kind: SMKind, kids: Bool) -> Bool {
        if kids && !m.kidsOK { return false }
        for k in genreKeys(m, kids: kids) { if let g = SMGenres.byKey[k], SMGenres.matches(g, genres: genres, kind: kind) { return true } }
        return false
    }
}

// MARK: - Eligibility of the context rows

enum SMHomeRules {
    /// Quality floor shared by the new rows: a rating that exists must be credible (6.5 and up for Movie Night and Binge, 5.5 for Fresh Additions); no rating at all is allowed
    /// (a library without ratings still gets the rows; the draw then uses the neutral rating feature).
    static func eligible(_ shelf: String, _ c: SMCandidate) -> Bool {
        let t = SmartMixScoring.ratingTenths(c.rating)
        switch shelf {
        case SMShelf.fresh: return (c.added ?? Int.max) <= 14 && (t ?? 99) >= 55
        case SMShelf.movieNight: return c.kind == .movie && c.q >= 2 && (t ?? 99) >= 65
        case SMShelf.binge: return c.kind == .series && (t ?? 99) >= 65
        default: return true
        }
    }
}

// MARK: - Franchises and the Collections row

enum SMFranchise {
    private static let small: Set<String> = ["its", "a", "an", "the", "i", "my", "me", "in", "on", "of", "to", "is", "are", "one", "all", "no", "you", "we", "our", "your", "this", "that", "with", "from", "for", "not", "too", "his", "her", "how", "what", "when", "who", "love", "man", "day", "night", "life"]
    private static let roman: Set<String> = ["ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
    private static let markers: Set<String> = ["part", "chapter", "vol", "volume", "episode"]

    private static let function: Set<String> = ["of", "the", "in", "on", "to", "a", "an", "for", "with", "and", "is", "at", "by"]
    private static func isMarker(_ w: String) -> Bool { (w.count <= 2 && w.allSatisfy(\.isNumber)) || roman.contains(w) || markers.contains(w) }

    /// The franchise of a title from its identity key (lower-case words, no year, no article): the first two words once a trailing sequel number is removed. Needs two words, one of
    /// them at least 4 letters and not a small word. nil = no franchise guess ("Crash", "Heat" are one word: two unrelated films may share it).
    static func key(identityKey: String) -> String? {
        var w = identityKey.split(separator: " ").map(String.init)
        while w.count > 1, let l = w.last, isMarker(l) { w.removeLast() }
        guard w.count >= 2 else { return nil }
        let a = w[0], b = w[1]
        guard !function.contains(b) else { return nil }          // "lord of ..." names no franchise
        guard !(a.allSatisfy(\.isNumber) && b.allSatisfy(\.isNumber)) else { return nil }
        guard [a, b].contains(where: { $0.count >= 4 && !small.contains($0) }) else { return nil }
        return a + " " + b
    }

    /// Display name from the members' own titles: their common leading words, minus trailing small words ("Harry Potter and the" -> "Harry Potter"); the key, title-cased, when nothing is common.
    static func name(titles: [String], key: String) -> String {
        let split = titles.map { $0.split(separator: " ").map(String.init) }
        guard var common = split.first else { return key.capitalized }
        for s in split.dropFirst() {
            var n = 0
            while n < common.count, n < s.count, common[n].lowercased() == s[n].lowercased() { n += 1 }
            common = Array(common.prefix(n))
        }
        while let l = common.last, small.contains(l.lowercased()) || ["and", "&", "-", ":"].contains(l.lowercased()) || l.allSatisfy(\.isNumber) { common.removeLast() }
        return common.count >= 2 ? common.joined(separator: " ") : key.capitalized
    }
}

enum SMCollections {
    static let minTitles = 3, maxTiles = 12, minTiles = 3

    /// Franchise tiles: a franchise needs at least 3 distinct titles that may be shown (not restricted, not dismissed, not CAM-only, with a poster). Strength = titles * 100 + average rating
    /// (tenths); strongest first, with positions in blocks of 4 shuffled by the day-seeded stream so the row changes from day to day. Hidden with fewer than 3 franchises.
    static func build(prepared: SmartMixEngine.Prepared, ctx: SMContext) -> SMShelfResult {
        var diag = SMDiagnostics()
        diag.inCount = prepared.inCount; diag.groups = prepared.groups.count
        var byKey: [String: [SMCandidate]] = [:]
        for g in prepared.groups where !g.restricted && !g.dismissed && !g.camOnly && g.poster { if let f = g.franchise { byKey[f, default: []].append(g) } }
        struct Entry { let key: String; let members: [SMCandidate]; let lead: SMCandidate; let strength: Int }
        var entries: [Entry] = []
        for (k, ms) in byKey where ms.count >= minTitles {
            let ordered = ms.sorted { a, b in
                if a.year != b.year { guard let x = a.year else { return false }; guard let y = b.year else { return true }; return x < y }
                return SmartMixEngine.idLess(a.id, b.id)
            }
            let tenths = ms.map { SmartMixScoring.ratingTenths($0.rating) ?? 60 }
            let lead = ms.sorted { a, b in
                let x = SmartMixScoring.ratingTenths(a.rating) ?? 0, y = SmartMixScoring.ratingTenths(b.rating) ?? 0
                return x != y ? x > y : SmartMixEngine.idLess(a.id, b.id)
            }[0]
            entries.append(Entry(key: k, members: ordered, lead: lead, strength: ms.count * 100 + tenths.reduce(0, +) / tenths.count))
        }
        entries.sort { $0.strength != $1.strength ? $0.strength > $1.strength : SmartMixEngine.idLess($0.key, $1.key) }
        var rng = SplitMix64(seed: SmartMixPRNG.seed(profile: ctx.profile, shelf: SMShelf.collections, day: ctx.dayKey, counter: ctx.refreshCounter))
        var keyed: [(block: Int, draw: UInt64, e: Entry)] = []
        for (i, e) in entries.prefix(maxTiles * 2).enumerated() { keyed.append((i / 4, rng.next(), e)) }
        keyed.sort { $0.block != $1.block ? $0.block < $1.block : ($0.draw != $1.draw ? $0.draw < $1.draw : SmartMixEngine.idLess($0.e.key, $1.e.key)) }
        let chosen = keyed.prefix(maxTiles).map(\.e)
        diag.pool = entries.count; diag.drawn = chosen.count
        if chosen.count < minTiles { diag.hidden = true; return SMShelfResult(shelfId: SMShelf.collections, picks: [], diag: diag) }
        var r = SMShelfResult(shelfId: SMShelf.collections, picks: chosen.map { SMPick(id: $0.lead.id, key: $0.lead.key, year: $0.lead.year, kind: $0.lead.kind, hasBackdrop: $0.lead.backdrop, franchise: $0.key) }, diag: diag)
        r.collections = chosen.map { SMCollection(key: $0.key, memberIds: $0.members.map(\.id)) }
        return r
    }
}

// MARK: - Names

/// Row titles and subtitles (English; every string is looked up in the Hindi and Telugu tables by its English text). No two rows share a title.
enum SMNaming {
    struct Row { let title: String; let subtitle: String }

    static let continueWatching = Row(title: "Pick Up Where You Left Off", subtitle: "Movies and episodes you started")
    static let topWeek = Row(title: "This Week's Top Picks", subtitle: "Popular right now")
    static let topWeekLocal = Row(title: "This Week's Top Picks", subtitle: "Most watched and best rated here")
    static let trending = Row(title: "Popular in Your Library", subtitle: "")        // subtitle is the view caption (viewCaption)
    static let forYou = Row(title: "Picked for You", subtitle: "Based on what you watch most")
    static let rediscover = Row(title: "Hidden Gems", subtitle: "Well rated and waiting for you")
    static let fresh = Row(title: "Fresh Additions", subtitle: "Added in the last two weeks")
    static let movieNight = Row(title: "Movie Night", subtitle: "Well-rated films for tonight")
    static let binge = Row(title: "Binge-Worthy Series", subtitle: "Well-rated shows to settle into")
    static let collections = Row(title: "Collections", subtitle: "Film series in your library")
    static let browseByGenre = "Browse by Genre"
    /// "Because You Watched %@" is formatted by the UI from this key.
    static let becauseYouWatched = "Because You Watched %@"
    static let languageRow = "%@ Picks"
    static let quietWeek = "Quiet week: all time"

    /// Friendly genre row titles by genre key (English). Distinct from every other row title.
    static let genreTitles: [String: String] = [
        "action": "Action Packed", "comedy": "Laugh Out Loud", "drama": "Drama Worth Your Time", "thriller": "Thrillers Worth Watching", "scifi": "Sci-Fi Picks",
        "horror": "Horror After Dark", "romance": "Love Stories", "crime": "Crime Stories", "animation": "Animated Favourites", "documentary": "Real-World Docs",
        "family": "Family Time", "fantasy": "Fantasy Worlds", "mystery": "Mysteries to Solve", "adventure": "Adventure Awaits", "war": "War Stories",
        "western": "Westerns", "history": "History Comes Alive", "music": "Music and Musicals", "biography": "True Life Stories", "kids": "Kids' Corner",
        "anime": "Anime Picks", "reality": "Reality Favourites",
    ]

    static func genreTitle(_ key: String) -> String { genreTitles[key] ?? (SMGenres.byKey[key]?.title ?? key) }
    static func moodRow(_ key: String) -> Row { SMMoods.byKey[key].map { Row(title: $0.title, subtitle: $0.subtitle) } ?? Row(title: key, subtitle: "") }

    /// Every title the Home can show, for the uniqueness test and the localisation check.
    static var allTitles: [String] {
        [continueWatching.title, topWeek.title, trending.title, forYou.title, rediscover.title, fresh.title, movieNight.title, binge.title, collections.title, browseByGenre]
            + SMMoods.table.map(\.title) + SMGenres.table.map { genreTitle($0.key) }
    }
}

// MARK: - Context and placement

/// Weekday (1 = Monday ... 7 = Sunday) and hour (0...23) on the device, local time. Only these two numbers leave the clock.
struct SMDayContext: Sendable, Equatable {
    var weekday: Int
    var hour: Int
    init(weekday: Int, hour: Int) { self.weekday = weekday; self.hour = hour }
    init(date: Date, calendar: Calendar = .current) {
        let wd = calendar.component(.weekday, from: date)      // 1 = Sunday
        weekday = wd == 1 ? 7 : wd - 1
        hour = calendar.component(.hour, from: date)
    }
    /// Friday and Saturday from 17:00, and the small hours after them.
    var movieNight: Bool { ((weekday == 5 || weekday == 6) && hour >= 17) || ((weekday == 6 || weekday == 7) && hour < 4) }
    var weekend: Bool { weekday >= 6 }
    var morning: Bool { hour >= 5 && hour < 11 }
}

enum SMRowKind: String, Sendable { case ranking, personal, context, collection, mood, genre }

extension SMPlacement {
    static func kind(_ id: String) -> SMRowKind {
        switch id {
        case SMShelf.topWeek, "trending": return .ranking
        case SMShelf.forYou, SMShelf.rediscover, SMShelf.langPref: return .personal
        case SMShelf.fresh, SMShelf.movieNight, SMShelf.binge: return .context
        case SMShelf.collections: return .collection
        default: return SMShelf.isMood(id) ? .mood : .genre
        }
    }

    static let maxRows = 12
    static let minRows = 6
    static let lookahead = 3

    /// The v2 order. `present`: ids of the non-genre, non-mood rows that have titles (the trending row is "trending" here). `genres` / `moods`: shelf ids in the order chosen.
    /// Template, then "never two rows of the same kind next to each other": the next row of a different kind among the next 3 is taken; when none, the row is dropped. At most 12 rows.
    /// Above the fold (after the hero and Continue Watching): one ranking row, then a personal row. A Kids profile starts with its mood row.
    static func layout(present: Set<String>, genres: [String], moods: [String], context: SMDayContext, kids: Bool) -> [String] {
        var g = genres[...], m = moods[...]
        func nextG() -> String? { let v = g.first; g = g.dropFirst(); return v }
        func nextM() -> String? { let v = m.first; m = m.dropFirst(); return v }
        var tokens: [String]
        if kids {
            tokens = ["M", "top-week", "G", "for-you", "G", "fresh", "collections", "G", "M", "rediscover", "lang-pref", "G", "trending", "G"]
        } else if context.morning {
            tokens = ["top-week", "fresh", "for-you", "G", "trending", "M", "G", "lang-pref", "collections", "G", "movie-night", "binge", "M", "rediscover", "G", "G"]
        } else {
            tokens = ["top-week", "for-you", "movie-night", "G", "trending", "M", "G", "lang-pref", "binge", "collections", "G", "rediscover", "M", "G", "fresh", "G", "G"]
        }
        var queue: [String] = []
        for t in tokens {
            switch t {
            case "G": if let x = nextG() { queue.append(x) }
            case "M": if let x = nextM() { queue.append(x) }
            case "movie-night": if present.contains(t), context.movieNight { queue.append(t) }
            case "binge": if present.contains(t), context.weekend { queue.append(t) }
            default: if present.contains(t) { queue.append(t) }
            }
        }
        queue += Array(g) + Array(m)
        var out: [String] = [], dropped: [String] = []
        while !queue.isEmpty && out.count < maxRows {
            let last = out.last.map(kind)
            if let i = queue.prefix(lookahead).firstIndex(where: { kind($0) != last }) { out.append(queue.remove(at: i)) } else { dropped.append(queue.removeFirst()) }
        }
        // A thin page (fewer than 6 rows) beats a strict one: rows that were set aside for sitting next to their own kind come back, in order.
        while out.count < minRows, !dropped.isEmpty { out.append(dropped.removeFirst()) }
        return out
    }
}

// MARK: - Default view of a ranked row

enum SMModeDefault {
    /// The person's own choice wins. Otherwise a row opens on "This week", unless this week's list found fewer than 6 matching titles in the library while the all-time list found enough:
    /// then it opens on "All time" and says so. Without a list at all (no TMDB access) both views are local rankings and "This week" stays.
    static func choose(chosen: SMShelfMode?, weeklyOrdered: Bool, allTimeOrdered: Bool) -> (mode: SMShelfMode, auto: Bool) {
        if let chosen { return (chosen, false) }
        if !weeklyOrdered && allTimeOrdered { return (.allTime, true) }
        return (.weekly, false)
    }
}

extension SMShelfModes {
    static func chosenKey(profile: String, shelf: String) -> String { "smartmix.modeChosen.\(profile).\(shelf)" }
    /// The person's own choice: set when they tap a segment (even "This week"), or an all-time choice stored by an older version.
    static func chosen(_ d: UserDefaults, profile: String, shelf: String) -> SMShelfMode? {
        let stored = d.string(forKey: key(profile: profile, shelf: shelf)).flatMap(SMShelfMode.init(rawValue:))
        if d.bool(forKey: chosenKey(profile: profile, shelf: shelf)) { return stored ?? .weekly }
        return stored
    }
    static func markChosen(_ d: UserDefaults, profile: String, shelf: String) { d.set(true, forKey: chosenKey(profile: profile, shelf: shelf)) }
}

// MARK: - Composition: one title per screen, MMR-style re-rank, exploration

struct SMComposedRow: Sendable, Equatable {
    var shelfId: String
    var picks: [SMPick]
}

enum SMCompose {
    static let explorationEvery = 6
    static let rerankWindow = 8

    /// Rows whose order is a ranking (TMDB order) and must not be re-ranked.
    static func isOrdered(_ r: SMShelfResult) -> Bool {
        r.diag.caption == .trendingTMDB && (r.shelfId == SMShelf.topWeek || r.shelfId == SMShelf.trendingLibrary || SMShelf.isGenre(r.shelfId))
    }

    static func minimum(_ shelfId: String) -> Int {
        if shelfId == SMShelf.trendingLibrary { return 3 }
        if SMShelf.isGenre(shelfId) { return SMGenres.minTitles }
        return 6
    }

    static func size(_ shelfId: String) -> Int { SMShelf.isGenre(shelfId) ? SMGenres.shelfSize : 14 }

    /// Greedy re-rank (MMR in integer form) of the draw order: relevance = 1000 - 30 * draw position; penalty against the last 3 chosen: same franchise 300, same decade 60,
    /// same primary genre 80 (last 2), same language and kind 40 (last 2). Candidates come from the first 8 not yet chosen; ties go to the earlier draw position.
    static func rerank(_ picks: [SMPick], take n: Int) -> [SMPick] {
        var rest = Array(picks.enumerated()).map { (pos: $0.offset, p: $0.element) }
        var out: [SMPick] = []
        while out.count < n, !rest.isEmpty {
            var best = 0, bestScore = Int.min
            for i in 0..<min(rest.count, rerankWindow) {
                let c = rest[i].p
                var s = 1000 - 30 * rest[i].pos
                for (back, o) in out.suffix(3).reversed().enumerated() {
                    if let f = c.franchise, f == o.franchise { s -= 300 }
                    if let y = c.year, let oy = o.year, y / 10 == oy / 10 { s -= 60 }
                    if back < 2 {
                        if let g = c.genre, g == o.genre { s -= 80 }
                        if let l = c.lang, l == o.lang, c.kind == o.kind { s -= 40 }
                    }
                }
                if s > bestScore { bestScore = s; best = i }
            }
            out.append(rest.remove(at: best).p)
        }
        return out
    }

    /// True when the pick lies outside what the person watches: none of its genre keys is among their top genres and its language is not their first language.
    static func isExploration(_ p: SMPick, affinity: SMAffinity) -> Bool {
        let keys = SMGenres.keys(genres: p.genres, kind: p.kind)
        if !keys.isEmpty, keys.contains(where: { affinity.genreKeys.contains($0) }) { return false }
        if let l = p.lang, affinity.topLangs.first == l { return false }
        return true
    }

    /// Every sixth position (6, 12) is an exploration slot: when the pick there is inside the person's taste, the first leftover candidate outside it takes the place. Nothing happens
    /// when the person has no history yet (everything is new to them) or when no leftover qualifies.
    static func explore(_ main: [SMPick], leftovers: [SMPick], affinity: SMAffinity) -> [SMPick] {
        guard !(affinity.genreKeys.isEmpty && affinity.topLangs.isEmpty) else { return main }
        var out = main, pool = leftovers.filter { isExploration($0, affinity: affinity) }[...]
        var slot = explorationEvery - 1
        while slot < out.count {
            if !isExploration(out[slot], affinity: affinity), let x = pool.first { out[slot] = x; pool = pool.dropFirst() }
            slot += explorationEvery
        }
        return out
    }

    /// At most 2 mood rows a day: a Kids profile keeps the order of the table; others rotate by a day-seeded offset.
    static func limitMoods(_ results: [SMShelfResult], seed: SMContext?) -> [SMShelfResult] {
        let moods = results.filter { SMShelf.isMood($0.shelfId) && !$0.diag.hidden && !$0.picks.isEmpty }
        guard moods.count > 2 else { return results }
        var keep = moods.map(\.shelfId)
        if let seed, !seed.kids {
            var rng = SplitMix64(seed: SmartMixPRNG.seed(profile: seed.profile, shelf: "moods:auto", day: seed.dayKey, counter: seed.refreshCounter))
            let off = Int(rng.uniform(UInt64(keep.count)))
            keep = Array(keep[off...] + keep[..<off])
        }
        let allowed = Set(keep.prefix(2))
        return results.filter { !SMShelf.isMood($0.shelfId) || allowed.contains($0.shelfId) }
    }

    /// One row built alone (the view switch of a ranked row): titles shown on the other rows are skipped when enough remain.
    static func single(_ r: SMShelfResult, avoid: Set<String>, affinity: SMAffinity) -> [SMPick] {
        let free = r.picks.filter { !avoid.contains($0.id) }
        let n = size(r.shelfId)
        var picks = isOrdered(r) ? Array(free.prefix(n)) : rerank(free, take: n)
        if picks.count < minimum(r.shelfId) { picks = Array(r.picks.prefix(n)) }
        return picks
    }

    /// The whole composition. `results`: engine output (oversampled). Returns the rows in display order with at most one appearance of a title on the screen; `collections` rows pass
    /// through untouched (a tile is a franchise, not a title).
    static func compose(results rawResults: [SMShelfResult], affinity: SMAffinity, context: SMDayContext, kids: Bool, seed: SMContext? = nil) -> [SMComposedRow] {
        let results = limitMoods(rawResults, seed: seed)
        let byId = Dictionary(results.map { ($0.shelfId, $0) }, uniquingKeysWith: { a, _ in a })
        func shown(_ r: SMShelfResult) -> Bool { !r.diag.hidden && !r.picks.isEmpty }
        let genreIds = results.filter { SMShelf.isGenre($0.shelfId) && shown($0) }.map(\.shelfId)
        let moodIds = results.filter { SMShelf.isMood($0.shelfId) && shown($0) }.map(\.shelfId)
        func presentSet(_ ids: Set<String>) -> Set<String> {
            var s = Set<String>()
            for r in results where shown(r) && ids.contains(r.shelfId) && !SMShelf.isGenre(r.shelfId) && !SMShelf.isMood(r.shelfId) && r.shelfId != SMShelf.hero {
                s.insert(r.shelfId == SMShelf.trendingLibrary ? "trending" : r.shelfId)
            }
            return s
        }
        func rowId(_ layoutId: String) -> String { layoutId == "trending" ? SMShelf.trendingLibrary : layoutId }
        let all = Set(results.map(\.shelfId))
        // Pass 1: order by the template with every row present; this is the priority order of the exclusion.
        let first = SMPlacement.layout(present: presentSet(all), genres: genreIds, moods: moodIds, context: context, kids: kids).map(rowId)
        var used = Set<String>()
        var rows: [String: SMComposedRow] = [:]
        for id in first {
            guard let r = byId[id] else { continue }
            if id == SMShelf.collections { rows[id] = SMComposedRow(shelfId: id, picks: r.picks); continue }
            let free = r.picks.filter { !used.contains($0.id) }
            let n = size(id)
            var picks: [SMPick]
            if isOrdered(r) { picks = Array(free.prefix(n)) }
            else {
                picks = rerank(free, take: n)
                if id == SMShelf.forYou {
                    let left = free.filter { f in !picks.contains { $0.id == f.id } }
                    picks = explore(picks, leftovers: left, affinity: affinity)
                }
            }
            guard picks.count >= minimum(id) else { continue }
            for p in picks { used.insert(p.id) }
            rows[id] = SMComposedRow(shelfId: id, picks: picks)
        }
        // Pass 2: the same template over the rows that survived.
        let surviving = Set(rows.keys)
        let order = SMPlacement.layout(present: presentSet(surviving), genres: genreIds.filter { surviving.contains($0) }, moods: moodIds.filter { surviving.contains($0) }, context: context, kids: kids).map(rowId)
        return order.compactMap { rows[$0] }
    }
}
