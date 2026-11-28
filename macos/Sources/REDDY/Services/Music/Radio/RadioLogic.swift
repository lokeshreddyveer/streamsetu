import Foundation

// The rules of a station as pure functions: which songs are allowed, how they are ranked, how familiar and new songs are mixed, how artists are
// spaced, when to fetch more and when to give up on a source. Nothing here touches the player, the network or the disk, so every rule is tested.

// MARK: bans

enum RadioBans {
    /// "Not for a while" lasts this long, on every station.
    static let tiredDays = 30

    static func tiredUntil(_ at: Date) -> Date { at.addingTimeInterval(TimeInterval(tiredDays) * 86_400) }

    static func isTired(_ uid: String, tired: [String: Date], now: Date) -> Bool {
        guard let at = tired[uid] else { return false }
        return tiredUntil(at) > now
    }

    /// True when the song may not play on this station: the station's own thumbs-down, a "not for a while" still running, or the person's Never play list.
    static func isBanned(_ t: MusicTrack, station: RadioStation, tired: [String: Date], blocked: Set<String>, now: Date) -> Bool {
        station.bannedUIDs.contains(t.uid) || isTired(t.uid, tired: tired, now: now) || MusicAutoplaySelector.isBlocked(t, blocked)
    }

    /// The same list without the bans that have run out.
    static func pruned(_ tired: [String: Date], now: Date) -> [String: Date] { tired.filter { tiredUntil($0.value) > now } }
}

// MARK: taste

/// What the person's thumbs taught one station: a weight for each artist and each language. Up is worth more than down costs, and old
/// thumbs fade, so a station follows the person's present taste.
struct RadioAffinity: Equatable, Sendable {
    var artists: [String: Double] = [:]
    var languages: [String: Double] = [:]

    static let upWeight = 1.0, downWeight = -0.6, tiredWeight = -0.8
    /// A thumb is worth half after this many days.
    static let halfLifeDays = 60.0

    static func build(from feedback: [RadioFeedback], now: Date) -> RadioAffinity {
        var a = RadioAffinity()
        for f in feedback {
            let base: Double
            switch f.kind { case .up: base = upWeight; case .down: base = downWeight; case .tired: base = tiredWeight }
            let days = max(0, now.timeIntervalSince(f.at) / 86_400)
            let w = base * pow(0.5, days / halfLifeDays)
            for k in f.artistKeys where !k.isEmpty { a.artists[k, default: 0] += w }
            if let l = f.language { a.languages[l, default: 0] += w * 0.5 }
        }
        return a
    }

    func weight(for t: MusicTrack) -> Double {
        let a = MusicAutoplaySelector.artistKeys(t).map { artists[$0] ?? 0 }.max() ?? 0
        let l = MusicLanguageDetector.language(of: t).map { languages[$0.rawValue] ?? 0 } ?? 0
        return min(3, max(-2, a)) + min(1, max(-1, l))
    }
}

// MARK: candidates

enum RadioSource: String, Codable, Sendable, CaseIterable { case provider, graph, local }

struct RadioCandidate: Sendable {
    var track: MusicTrack
    var source: RadioSource
    /// Lower is better, within one source.
    var rank: Int
    var reason: MusicAutoplayReason
    /// True when it came from one of the station's own seeds (a seed artist's songs), not from a similar one.
    var fromSeed = false
    init(track: MusicTrack, source: RadioSource, rank: Int, reason: MusicAutoplayReason = MusicAutoplayReason(.radio), fromSeed: Bool = false) {
        self.track = track; self.source = source; self.rank = rank; self.reason = reason; self.fromSeed = fromSeed
    }
}

struct RadioPick: Sendable, Equatable {
    var track: MusicTrack
    var reason: MusicAutoplayReason
    var source: RadioSource
}

/// Everything a pick depends on besides the pool.
struct RadioPickContext: Sendable {
    var station: RadioStation
    var tired: [String: Date] = [:]
    /// The Never play list and anything the player asks to keep out.
    var blocked: Set<String> = []
    /// Songs that failed to play on this run (kept out until the station is started again).
    var failedUIDs: Set<String> = []
    var queuedUIDs: Set<String> = []
    /// `MusicAutoplaySelector.versionKey` of what is queued.
    var queuedKeys: Set<String> = []
    /// Artist keys of the last rows before the new ones, oldest first, the playing song last.
    var tailArtists: [[String]] = []
    var familiarUIDs: Set<String> = []
    var familiarArtists: Set<String> = []
    var allow: (@Sendable (MusicTrack) -> Bool)? = nil
    var now = Date()
    init(station: RadioStation) { self.station = station }
}

// MARK: spacing and mixing

enum RadioSpacing {
    /// The longest run of one artist in a row.
    static let maxRun = 2
    /// Most songs of one artist in a single batch.
    static let batchCap = 4

    /// True when adding a song by these artists would make a run longer than `maxRun`.
    static func breaksRun(_ keys: [String], tail: [[String]], maxRun: Int = RadioSpacing.maxRun) -> Bool {
        guard tail.count >= maxRun else { return false }
        let last = tail.suffix(maxRun)
        return keys.contains { k in !k.isEmpty && last.allSatisfy { $0.contains(k) } }
    }
}

enum RadioMixing {
    /// Whether the next pick should be a familiar song: keeps the familiar share of the picks so far as close to `share` as whole songs allow.
    static func wantsFamiliar(picked: Int, familiarPicked: Int, share: Double) -> Bool {
        Double(familiarPicked) < (share * Double(picked + 1)).rounded()
    }
}

// MARK: refill and recovery

enum RadioRefill {
    /// A refill starts when fewer than this many songs are queued after the playing one.
    static let lowWater = 5
    static let minBatch = 10
    static let maxBatch = 20

    static func needsRefill(upcoming: Int, inFlight: Bool) -> Bool { !inFlight && upcoming < lowWater }
    static func batchSize(upcoming: Int) -> Int { min(maxBatch, max(minBatch, maxBatch - max(0, upcoming))) }
}

/// Counts songs and batches that came to nothing, and says what to do next: skip quietly, try another source, or stop trying and say so calmly.
struct RadioRecovery: Equatable, Sendable {
    static let switchAfter = 3
    static let troubleAfter = 8

    enum Step: Equatable, Sendable { case skip, switchSource, trouble }

    private(set) var failures = 0
    /// How many times the source order was turned; the pool starts from the next source each time.
    private(set) var rotation = 0
    private(set) var troubled = false

    mutating func failed() -> Step {
        failures += 1
        if failures >= Self.troubleAfter { troubled = true; return .trouble }
        if failures % Self.switchAfter == 0 { rotation += 1; return .switchSource }
        return .skip
    }

    mutating func succeeded() { failures = 0; troubled = false }
    mutating func reset() { self = RadioRecovery() }

    /// The sources in the order to ask them, turned by `rotation`.
    func sourceOrder(_ all: [RadioSource]) -> [RadioSource] {
        guard !all.isEmpty else { return [] }
        let r = rotation % all.count
        return Array(all[r...] + all[..<r])
    }

    /// The seeds to ask: those not known to have vanished; when every seed vanished, all of them again (a provider may have come back).
    static func liveSeeds(_ seeds: [RadioSeed], gone: Set<String>) -> [RadioSeed] {
        let live = seeds.filter { !gone.contains($0.id) }
        return live.isEmpty ? seeds : live
    }
}

// MARK: scoring and selection

enum RadioScorer {
    /// Higher is better. A source's own order counts most; thumbs add or take away; a seed's own songs get a little extra; the station's mode then leans on release date or popularity.
    static func score(_ c: RadioCandidate, affinity: RadioAffinity, mode: RadioMode = .mixed, now: Date = Date()) -> Double {
        var s = 1.0 / (1.0 + Double(c.rank) / 8.0)
        s += affinity.weight(for: c.track) * 0.5
        if c.fromSeed { s += 0.15 }
        s += RadioModeRules.bonus(for: c.track, mode: mode, now: now)
        return s
    }
}

/// What the Pandora-style modes change: a score bonus for the mode's kind of song, and (artist only) a filter to the station's own artists.
enum RadioModeRules {
    /// Songs from the last year count as new; the bonus fades over two years.
    static func bonus(for t: MusicTrack, mode: RadioMode, now: Date) -> Double {
        switch mode {
        case .newlyReleased:
            guard let days = ageDays(of: t, now: now) else { return 0 }
            return days <= 90 ? 1.0 : days <= 365 ? 0.6 : days <= 730 ? 0.25 : 0
        case .crowdFaves:
            return Double(max(0, min(100, t.popularity ?? 0))) / 100 * 0.8
        case .deepCuts:
            // A song without a popularity figure is not penalised; a well-known one is.
            guard let p = t.popularity else { return 0.1 }
            return (1 - Double(max(0, min(100, p))) / 100) * 0.8
        case .familiar, .mixed, .discover, .artistOnly:
            return 0
        }
    }

    /// Age in days from the album's release date ("2026", "2026-03" or "2026-03-14"), nil when it says nothing usable.
    static func ageDays(of t: MusicTrack, now: Date) -> Double? {
        guard let raw = t.album?.releaseDate?.trimmingCharacters(in: .whitespaces), raw.count >= 4, let year = Int(raw.prefix(4)), year > 1900 else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents(); c.year = year; c.month = parts.count > 1 ? parts[1] : 7; c.day = parts.count > 2 ? parts[2] : 1
        guard let d = Calendar(identifier: .gregorian).date(from: c) else { return nil }
        return max(0, now.timeIntervalSince(d) / 86_400)
    }

    /// The artist keys of the station's own artists: the artist seeds, and the artists of song seeds.
    static func seedArtistKeys(_ station: RadioStation) -> Set<String> {
        var keys = Set<String>()
        for seed in station.seeds {
            if let a = seed.artist { keys.formUnion(MusicAutoplaySelector.artistKeys(MusicTrack(id: "seed", providerID: a.providerID, title: "", durationMs: 0, artists: [MusicArtistRef(id: a.id, name: a.name)]))) }
            if let t = seed.track { keys.formUnion(MusicAutoplaySelector.artistKeys(t)) }
        }
        return keys
    }

    /// Artist only: the pool narrowed to songs by the station's own artists. When that leaves too few (a genre station has no artists, a source knew little),
    /// the seeds' own songs are used, and failing that the pool is left alone rather than going quiet.
    static func shape(_ pool: [RadioCandidate], station: RadioStation) -> [RadioCandidate] {
        guard station.mode == .artistOnly else { return pool }
        let keys = seedArtistKeys(station)
        guard !keys.isEmpty else { return pool }
        let own = pool.filter { c in MusicAutoplaySelector.artistKeys(c.track).contains { keys.contains($0) } }
        if own.count >= 3 { return own }
        let seeded = pool.filter(\.fromSeed)
        return seeded.isEmpty ? pool : seeded
    }
}

enum RadioSelector {
    /// The pool without anything that may not play now: banned, failed, already played in the window, queued, not allowed, or the same song twice.
    static func eligible(_ pool: [RadioCandidate], context ctx: RadioPickContext) -> [RadioCandidate] {
        let played = ctx.station.playedSet
        var seenUIDs = ctx.queuedUIDs
        var seenKeys = ctx.queuedKeys
        var out: [RadioCandidate] = []
        for c in pool {
            let t = c.track
            if t.isPodcast == true { continue }
            if RadioBans.isBanned(t, station: ctx.station, tired: ctx.tired, blocked: ctx.blocked, now: ctx.now) { continue }
            if ctx.failedUIDs.contains(t.uid) || played.contains(t.uid) { continue }
            if let allow = ctx.allow, !allow(t) { continue }
            let key = MusicAutoplaySelector.versionKey(t)
            guard !seenUIDs.contains(t.uid), !seenKeys.contains(key) else { continue }
            seenUIDs.insert(t.uid); seenKeys.insert(key)
            out.append(c)
        }
        return out
    }

    /// Picks up to `want` songs: best first, familiar and new songs mixed by the station's mode, no artist more than twice in a row and no more than
    /// `batchCap` in one batch. When that alone would leave the batch very short, spacing is relaxed rather than going quiet (a one-artist listener).
    static func select(_ pool: [RadioCandidate], context ctx: RadioPickContext, want: Int) -> [RadioPick] {
        guard want > 0 else { return [] }
        let affinity = RadioAffinity.build(from: ctx.station.feedback, now: ctx.now)
        let ranked = eligible(RadioModeRules.shape(pool, station: ctx.station), context: ctx)
            .map { (c: $0, s: RadioScorer.score($0, affinity: affinity, mode: ctx.station.mode, now: ctx.now)) }
            .sorted { $0.s != $1.s ? $0.s > $1.s : $0.c.rank < $1.c.rank }
            .map(\.c)

        func familiar(_ c: RadioCandidate) -> Bool {
            ctx.familiarUIDs.contains(c.track.uid) || MusicAutoplaySelector.artistKeys(c.track).contains { ctx.familiarArtists.contains($0) }
        }
        var known = ranked.filter(familiar), fresh = ranked.filter { !familiar($0) }
        var picks: [RadioPick] = []
        var tail = ctx.tailArtists
        var perArtist: [String: Int] = [:]
        var familiarPicked = 0

        func allowed(_ c: RadioCandidate, strict: Bool) -> Bool {
            guard strict else { return true }
            let keys = MusicAutoplaySelector.artistKeys(c.track)
            return !RadioSpacing.breaksRun(keys, tail: tail) && keys.allSatisfy { k in k.isEmpty || perArtist[k, default: 0] < RadioSpacing.batchCap }
        }
        func take(_ c: RadioCandidate, wasFamiliar: Bool) {
            picks.append(RadioPick(track: c.track, reason: c.reason, source: c.source))
            let keys = MusicAutoplaySelector.artistKeys(c.track)
            tail.append(keys)
            for k in keys { perArtist[k, default: 0] += 1 }
            if wasFamiliar { familiarPicked += 1 }
        }
        func run(strict: Bool, limit: Int) {
            while picks.count < limit, !(known.isEmpty && fresh.isEmpty) {
                let wantKnown = RadioMixing.wantsFamiliar(picked: picks.count, familiarPicked: familiarPicked, share: ctx.station.mode.familiarShare)
                var done = false
                for useKnown in (wantKnown ? [true, false] : [false, true]) {
                    let list = useKnown ? known : fresh
                    if let i = list.firstIndex(where: { allowed($0, strict: strict) }) {
                        if useKnown { take(known.remove(at: i), wasFamiliar: true) } else { take(fresh.remove(at: i), wasFamiliar: false) }
                        done = true; break
                    }
                }
                if !done { return }
            }
        }
        run(strict: true, limit: want)
        if picks.count < min(want, 5) { run(strict: false, limit: min(want, 5)) }
        return picks
    }
}

/// Builds the kind of pool every adapter's answer ends up in: duplicates (the same uid from two sources) keep the best-ranked copy.
enum RadioPool {
    static func merge(_ lists: [[RadioCandidate]]) -> [RadioCandidate] {
        var best: [String: RadioCandidate] = [:]
        var order: [String] = []
        for (n, list) in lists.enumerated() {
            for var c in list {
                c.rank += n * 1000
                if let old = best[c.track.uid] {
                    if c.rank < old.rank { best[c.track.uid] = c }
                } else { best[c.track.uid] = c; order.append(c.track.uid) }
            }
        }
        return order.compactMap { best[$0] }
    }
}
