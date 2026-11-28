import Foundation

// The shuffle engines. Pure value logic over queue rows: no audio, no I/O, no clock unless the caller passes one in, so every rule is
// testable with a seeded generator. The queue keeps its own bookkeeping (snapshot, history, Play next); an engine only decides ORDER.

/// How the shuffle button orders the queue.
enum MusicShuffleMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A constrained shuffle: songs of one language, artist or album are spread evenly, and the best of several orders is kept.
    case smart
    /// Fisher-Yates: every order equally likely, clumps and all.
    case random
    /// Smart order of the person's own songs, with a recommended song after every few of them, marked "Suggested".
    case smartSuggest

    var id: String { rawValue }
    static let defaultMode: MusicShuffleMode = .smart

    var title: String {
        switch self {
        case .smart: Localized.string("Smart shuffle order")
        case .random: Localized.string("True random")
        case .smartSuggest: Localized.string("Smart Shuffle with suggestions")
        }
    }
    var shortTitle: String {
        switch self {
        case .smart: Localized.string("Smart")
        case .random: Localized.string("Random")
        case .smartSuggest: Localized.string("Smart + suggestions")
        }
    }
    var detail: String {
        switch self {
        case .smart: Localized.string("Spreads songs of the same artist, album and language evenly, plays songs you have not heard lately first and leans a little towards your favourites.")
        case .random: Localized.string("Every order is equally likely, so an artist can come up several times in a row.")
        case .smartSuggest: Localized.string("Your own songs in a smart order, with a recommended song after every few of them. Suggestions are marked and you can remove each one.")
        }
    }
}

/// A small deterministic generator (SplitMix64), so tests and "reshuffle with the same seed" give the same order.
struct MusicSeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// What the scorer may know about each song. Everything is optional: with nothing known the score is spacing only.
struct MusicShuffleSignals: Sendable {
    /// Last time a song was played, by track uid.
    var lastPlayed: [String: Date] = [:]
    /// Liked songs, by uid.
    var favourites: Set<String> = []
    /// Listening affinity 0...1, by uid (play counts scaled by the caller).
    var affinity: [String: Double] = [:]
    /// Energy or loudness 0...1 from the Automix analysis cache, by uid. Read-only.
    var energy: [String: Double] = [:]
    /// The order of the previous shuffle (uids), so the same neighbours are not produced again.
    var previousOrder: [String] = []
    var now = Date()
    init() {}
}

enum MusicShuffleEngine {
    /// Candidate orders generated per shuffle.
    static let candidateCount = 8
    /// The share of a finished lap that may not open the next lap.
    static let lapAvoidFraction = 0.2
    /// Window inside which two songs of one artist or album count against an order.
    static let spacingWindow = 5

    enum Weight {
        static let spacing = 1.0, freshness = 0.6, affinity = 0.25, repeatPairs = 1.5, energy = 0.5
    }

    // MARK: keys

    static func artistKey(_ t: MusicTrack) -> String { MusicEndlessSource.artistKey(t) }
    static func albumKey(_ t: MusicTrack) -> String {
        guard let a = t.album else { return "" }
        return a.id.isEmpty ? MusicEndlessSource.normalise(a.title) : a.id
    }
    /// The script a song is written in; "" when unknown. Used as the top spreading level only when the queue holds more than one.
    static func languageKey(_ t: MusicTrack) -> String { MusicLanguageDetector.language(of: t)?.script.rawValue ?? "" }

    // MARK: balanced shuffle

    /// Fiedler-style balanced shuffle. Items are grouped by the first level key; each group is itself balanced by the remaining levels,
    /// then laid out at even intervals with one random offset per group and a little jitter per item, and the groups are merged by position.
    /// The result keeps a group's items about `count / groupSize` rows apart, whatever the group sizes.
    static func balanced<T, K: Hashable, G: RandomNumberGenerator>(_ items: [T], levels: ArraySlice<(T) -> K>, using rng: inout G) -> [T] {
        guard items.count > 1 else { return items }
        guard let key = levels.first else { return fisherYates(items, using: &rng) }
        var groups: [K: [T]] = [:]
        var order: [K] = []
        for it in items {
            let k = key(it)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(it)
        }
        if groups.count == 1 { return balanced(items, levels: levels.dropFirst(), using: &rng) }
        var placed: [(pos: Double, tie: Double, item: T)] = []
        placed.reserveCapacity(items.count)
        for k in order {
            let g = balanced(groups[k] ?? [], levels: levels.dropFirst(), using: &rng)
            let n = Double(g.count)
            let offset = Double.random(in: 0..<1, using: &rng)
            for (i, x) in g.enumerated() {
                let jitter = Double.random(in: -0.1...0.1, using: &rng)
                placed.append(((Double(i) + offset + jitter) / n, Double.random(in: 0..<1, using: &rng), x))
            }
        }
        placed.sort { $0.pos != $1.pos ? $0.pos < $1.pos : $0.tie < $1.tie }
        return placed.map(\.item)
    }

    static func fisherYates<T, G: RandomNumberGenerator>(_ items: [T], using rng: inout G) -> [T] {
        var a = items
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i, using: &rng)
            if i != j { a.swapAt(i, j) }
        }
        return a
    }

    // MARK: scoring

    /// Everything the scorer and the spreading levels need about each row, computed once per ordering call (keys, interned to small
    /// integers so comparing is cheap; staleness, affinity and energy per row; the previous order's neighbour pairs).
    struct Prepared {
        var artist: [Int] = [], album: [Int] = [], lang: [Int] = [], uidID: [Int] = []
        var stale: [Double] = [], aff: [Double] = []
        var energy: [Double?] = []
        var pairs = Set<UInt64>()
        var hasPrevious = false
        /// Rows that share the lead song's artist or album (empty when there is no lead).
        var leadFlag: [Bool] = []

        init(_ rows: [MusicQueue.Entry], signals: MusicShuffleSignals, lead: MusicTrack? = nil, wantLanguage: Bool = false) {
            let n = rows.count
            artist.reserveCapacity(n); album.reserveCapacity(n); uidID.reserveCapacity(n)
            var artists: [String: Int] = ["": 0], albums: [String: Int] = ["": 0], langs: [String: Int] = ["": 0], uids: [String: Int] = [:]
            func intern(_ k: String, _ table: inout [String: Int]) -> Int {
                if let v = table[k] { return v }
                let v = table.count; table[k] = v; return v
            }
            let leadArtist = lead.map(MusicShuffleEngine.artistKey) ?? "", leadAlbum = lead.map(MusicShuffleEngine.albumKey) ?? ""
            let hasLead = lead != nil && (!leadArtist.isEmpty || !leadAlbum.isEmpty)
            if hasLead { leadFlag.reserveCapacity(n) }
            for r in rows {
                let t = r.track
                let u = t.uid
                let ak = MusicShuffleEngine.artistKey(t), bk = MusicShuffleEngine.albumKey(t)
                artist.append(intern(ak, &artists))
                album.append(intern(bk, &albums))
                if wantLanguage { lang.append(intern(MusicShuffleEngine.languageKey(t), &langs)) }
                uidID.append(intern(u, &uids))
                if hasLead { leadFlag.append((!leadArtist.isEmpty && ak == leadArtist) || (!leadAlbum.isEmpty && bk == leadAlbum)) }
                let st: Double
                if let d = signals.lastPlayed[u] { st = min(1, max(0, signals.now.timeIntervalSince(d) / (30 * 86_400))) } else { st = 1 }
                stale.append(st)
                aff.append(signals.favourites.contains(u) ? 1 : min(1, max(0, signals.affinity[u] ?? 0)))
                energy.append(signals.energy[u])
            }
            hasPrevious = !signals.previousOrder.isEmpty
            if hasPrevious {
                var prev: Int?
                for u in signals.previousOrder {
                    let cur = uids[u]
                    if let a = prev, let b = cur { pairs.insert(UInt64(a) << 32 | UInt64(b)) }
                    prev = cur
                }
            }
        }
    }

    /// Higher is better, for a list of rows in the order given (prepares the rows first; the lap code works on indices and does not use this).
    static func score(_ rows: [MusicQueue.Entry], signals: MusicShuffleSignals) -> Double {
        score(Array(rows.indices), prepared: Prepared(rows, signals: signals), signals: signals)
    }

    /// Higher is better, over row indices into a `Prepared` set. Every part is normalised by the list length, so lists of different size compare fairly.
    static func score(_ order: [Int], prepared p: Prepared, signals: MusicShuffleSignals) -> Double {
        let n = order.count
        guard n > 1 else { return 0 }
        var penalty = 0.0
        for i in 0..<n {
            let a = p.artist[order[i]], b = p.album[order[i]]
            for d in 1...spacingWindow where i + d < n {
                let w = Double(spacingWindow + 1 - d)
                let j = order[i + d]
                if a != 0, a == p.artist[j] { penalty += w }
                if b != 0, b == p.album[j] { penalty += 0.5 * w }
            }
        }
        var total = -Weight.spacing * penalty / Double(n)

        var wSum = 0.0, fresh = 0.0, aff = 0.0
        for (i, r) in order.enumerated() {
            let w = 1 / (1 + Double(i) / 8)
            wSum += w
            fresh += w * p.stale[r]
            aff += w * p.aff[r]
        }
        total += Weight.freshness * fresh / wSum + Weight.affinity * aff / wSum

        if p.hasPrevious {
            var same = 0
            for k in 1..<n where p.pairs.contains(UInt64(p.uidID[order[k - 1]]) << 32 | UInt64(p.uidID[order[k]])) { same += 1 }
            total -= Weight.repeatPairs * Double(same) / Double(n - 1)
        }
        var jumps = 0.0, counted = 0
        for k in 1..<n {
            if let x = p.energy[order[k - 1]], let y = p.energy[order[k]] { jumps += abs(x - y); counted += 1 }
        }
        if counted > 0 { total -= Weight.energy * jumps / Double(counted) }
        return total
    }

    // MARK: ordering

    /// Which song opens a Shuffle Play of `tracks`. Random mode draws uniformly; the smart modes draw with weight (a liked song and one the person plays more are
    /// likelier, a song played in the last day is less likely), by the Efraimidis-Spirakis key `-ln(u) / w` (the smallest key wins), so the opener is a weighted
    /// draw without a fixed favourite. The rest of the order is the engine's `shuffler`; this is only the first song, so the shuffle is applied once.
    static func openingIndex(of tracks: [MusicTrack], mode: MusicShuffleMode, signals: MusicShuffleSignals = MusicShuffleSignals(), seed: UInt64, now: Date = Date()) -> Int {
        guard tracks.count > 1 else { return 0 }
        var rng = MusicSeededRNG(seed: seed)
        var best = 0, bestKey = Double.infinity
        for (i, t) in tracks.enumerated() {
            var w = 1.0
            if mode != .random {
                if signals.favourites.contains(t.uid) { w += 1 }
                w += min(1, max(0, signals.affinity[t.uid] ?? 0))
                if let at = signals.lastPlayed[t.uid], now.timeIntervalSince(at) < 86_400 { w *= 0.25 }
            }
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
            let key = -log(u) / w
            if key < bestKey { best = i; bestKey = key }
        }
        return best
    }

    /// How many of the first upcoming rows may not share the lead song's artist or album (when avoidable).
    static let leadAvoidCount = 2

    /// Orders `entries` for `mode`. `avoidFirst` rows may not sit in the first `avoidCount` places (the next lap's opening rule). With a
    /// `lead` (the song playing now), rows of its artist or album are kept out of the first places when that is possible; true random
    /// mode ignores it. Keys are computed once per call, so each candidate costs O(n).
    static func order(_ entries: [MusicQueue.Entry], mode: MusicShuffleMode, signals: MusicShuffleSignals = MusicShuffleSignals(), seed: UInt64,
                      avoidFirst: Set<MusicQueue.Entry.ID> = [], avoidCount: Int = 0, lead: MusicTrack? = nil) -> [MusicQueue.Entry] {
        guard entries.count > 1 else { return entries }
        var rng = MusicSeededRNG(seed: seed)
        if mode == .random {
            return enforce(fisherYates(entries, using: &rng), avoid: avoidFirst, count: avoidCount)
        }
        let n = entries.count
        let p = Prepared(entries, signals: signals, lead: lead, wantLanguage: true)
        var levels: [(Int) -> Int] = [{ p.artist[$0] }, { p.album[$0] }]
        let langCount = Set(p.lang.filter { $0 != 0 }).count
        if langCount > 1 { levels.insert({ p.lang[$0] }, at: 0) }
        let lapFlags: [Bool] = (avoidFirst.isEmpty || avoidCount <= 0) ? [] : entries.map { avoidFirst.contains($0.id) }
        let hasLap = lapFlags.contains(true)
        let hasLead = p.leadFlag.contains(true)
        let base = Array(0..<n)
        var bestOrder: [Int] = [], bestScore = -Double.infinity
        for _ in 0..<candidateCount {
            var idx = balanced(base, levels: levels[...], using: &rng)
            if hasLap { idx = enforce(idx, count: avoidCount) { lapFlags[$0] } }
            if hasLead { idx = keepLeadSharersOut(idx, flags: p.leadFlag, lapFlags: lapFlags, lapCount: hasLap ? avoidCount : 0) }
            // The lap rule is the hard one (a new lap never opens with what was just heard); the lead rule is only a preference, so the lap rule is applied last.
            if hasLap { idx = enforce(idx, count: avoidCount) { lapFlags[$0] } }
            let s = score(idx, prepared: p, signals: signals)
            if s > bestScore { bestScore = s; bestOrder = idx }
        }
        return bestOrder.map { entries[$0] }
    }

    /// Swaps any avoided row out of the first `count` places with the nearest later row that is not avoided.
    static func enforce(_ rows: [MusicQueue.Entry], avoid: Set<MusicQueue.Entry.ID>, count: Int) -> [MusicQueue.Entry] {
        guard count > 0, !avoid.isEmpty else { return rows }
        return enforce(rows, count: count) { avoid.contains($0.id) }
    }

    /// The same rule for any element type and any "avoided" test.
    static func enforce<T>(_ rows: [T], count: Int, avoid: (T) -> Bool) -> [T] {
        guard count > 0 else { return rows }
        var out = rows
        let head = min(count, out.count)
        var scan = head
        for i in 0..<head where avoid(out[i]) {
            while scan < out.count, avoid(out[scan]) { scan += 1 }
            guard scan < out.count else { break }
            out.swapAt(i, scan)
            scan += 1
        }
        return out
    }

    /// Moves rows that share the lead song's artist or album out of the first `leadAvoidCount` places, swapping in the nearest later row
    /// that does not share them and that the lap rule (`lapFlags`, the first `lapCount` places) allows. No row is lost; when every row
    /// shares them nothing moves.
    private static func keepLeadSharersOut(_ rows: [Int], flags: [Bool], lapFlags: [Bool], lapCount: Int) -> [Int] {
        var out = rows
        let head = min(leadAvoidCount, out.count)
        var scan = head
        for i in 0..<head where flags[out[i]] {
            let movedIsLapRow = !lapFlags.isEmpty && lapFlags[out[i]]
            while scan < out.count {
                let r = out[scan]
                let blocked = flags[r] || (!lapFlags.isEmpty && lapFlags[r] && scan < lapCount) || (movedIsLapRow && scan < lapCount)
                if !blocked { break }
                scan += 1
            }
            guard scan < out.count else { break }
            out.swapAt(i, scan)
            scan += 1
        }
        return out
    }

    /// A fresh order for the next lap under repeat-all: none of the last 20% of the finished lap opens it (by song, so a recording that
    /// sits in two rows is covered too), it never starts with the song that just ended, and in smart mode it does not open with that
    /// song's artist or album when avoidable.
    static func lap(_ finished: [MusicQueue.Entry], mode: MusicShuffleMode, signals: MusicShuffleSignals = MusicShuffleSignals(), seed: UInt64) -> [MusicQueue.Entry] {
        let n = finished.count
        guard n > 1 else { return finished }
        let count = max(1, min(Int((Double(n) * lapAvoidFraction).rounded(.up)), n / 2))
        var sig = signals
        sig.previousOrder = finished.map(\.track.uid)
        let recent = Set(finished.suffix(count).map(\.track.uid))
        let avoid = Set(finished.filter { recent.contains($0.track.uid) }.map(\.id))
        return order(finished, mode: mode, signals: sig, seed: seed, avoidFirst: avoid, avoidCount: count, lead: finished.last?.track)
    }

    /// The closure the queue's `setShuffle` takes. It seeds from the rows themselves, so two calls on different row lists differ while the
    /// same call twice gives the same order.
    /// With a `lead` (the playing song) the first rows it orders avoid the lead's artist and album when possible.
    static func shuffler(mode: MusicShuffleMode, signals: MusicShuffleSignals = MusicShuffleSignals(), seed: UInt64, lead: MusicTrack? = nil) -> MusicQueue.Shuffler {
        return { rows in
            var h = seed ^ 0xcbf29ce484222325
            for r in rows.prefix(16) { for b in r.track.uid.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 } }
            rows = MusicShuffleEngine.order(rows, mode: mode, signals: signals, seed: h, lead: lead)
        }
    }

    /// The closure for `MusicQueue.lapShuffler`.
    static func lapShuffler(mode: MusicShuffleMode, signals: MusicShuffleSignals = MusicShuffleSignals(), seed: UInt64) -> @Sendable ([MusicQueue.Entry]) -> [MusicQueue.Entry] {
        return { rows in
            var h = seed
            for r in rows.suffix(8) { for b in r.track.uid.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 } }
            return MusicShuffleEngine.lap(rows, mode: mode, signals: signals, seed: h)
        }
    }
}

// MARK: Smart Shuffle (recommended songs between the person's own)

enum MusicSmartSuggest {
    /// A suggestion follows every 3 to 5 of the person's own songs.
    static let every = 3...5

    /// How many suggestions the upcoming own songs have room for. `ownAfterLastSuggestion` is the stretch a new one can go into; too short a stretch has no room at all
    /// (`interleave` needs more own songs than its smallest gap), whatever the totals say.
    static func needed(ownUpcoming: Int, suggestedUpcoming: Int, ownAfterLastSuggestion: Int = .max, every: ClosedRange<Int> = every) -> Int {
        guard ownAfterLastSuggestion > every.lowerBound else { return 0 }
        return max(0, ownUpcoming / ((every.lowerBound + every.upperBound) / 2) - suggestedUpcoming)
    }

    /// Puts one suggestion after every N own rows (N drawn from `every` each time), only between own rows, never first and never last.
    /// Suggestions are marked `suggested` and carry their reason. Unused suggestions are dropped.
    static func interleave<G: RandomNumberGenerator>(own: [MusicQueue.Entry], suggestions: [MusicQueue.Entry], every: ClosedRange<Int> = every,
                                                      using rng: inout G) -> [MusicQueue.Entry] {
        guard !suggestions.isEmpty, own.count > every.lowerBound else { return own }
        var out: [MusicQueue.Entry] = [], pool = suggestions[...]
        var gap = Int.random(in: every, using: &rng)
        var since = 0
        for (i, e) in own.enumerated() {
            out.append(e); since += 1
            if since >= gap, i < own.count - 1, let s = pool.popFirst() {
                var m = s; m.suggested = true; m.auto = false
                out.append(m); since = 0
                gap = Int.random(in: every, using: &rng)
            }
        }
        return out
    }
}
