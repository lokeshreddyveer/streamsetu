import Foundation

// Smart Autoplay: when the queue would end, keep an AUTO tail of related songs going. This file is the single entry point
// (`MusicAutoplayEngine`) plus the pure selection rules. Candidates come from injectable sources (graph recommender, provider radio, the
// local library), so tests use fakes. Nothing here touches the player, the network or the disk.

// MARK: reasons and candidates

enum MusicAutoplayReasonKind: String, Sendable, Equatable {
    case artist, singer, film, cast, musicDirector, composer, lyricist, language, era, genre, affinity, history, radio, local
}

/// Why a song was added: a kind and the name it came from. `text` is the short line the queue shows.
struct MusicAutoplayReason: Sendable, Equatable {
    var kind: MusicAutoplayReasonKind
    var subject: String?

    init(_ kind: MusicAutoplayReasonKind, _ subject: String? = nil) {
        self.kind = kind
        self.subject = (subject?.isEmpty ?? true) ? nil : subject
    }

    var text: String {
        if let s = subject {
            switch kind {
            case .artist: return Localized.string("Autoplay: more from %@", s)
            case .singer: return Localized.string("Same singer: %@", s)
            case .film: return Localized.string("Same film: %@", s)
            case .cast: return Localized.string("Shares cast: %@", s)
            case .musicDirector: return Localized.string("Same music director: %@", s)
            case .composer: return Localized.string("Same composer: %@", s)
            case .lyricist: return Localized.string("Same lyricist: %@", s)
            case .language: return Localized.string("More %@ songs", s)
            case .era: return Localized.string("Same era and language: %@", s)
            case .genre: return Localized.string("Similar genre: %@", s)
            case .affinity: return Localized.string("Because you play %@", s)
            case .radio: return Localized.string("Autoplay: similar to %@", s)
            case .history, .local: break
            }
        }
        switch kind {
        case .history: return Localized.string("From your history")
        case .local: return Localized.string("From your library")
        default: return Localized.string("Autoplay: similar music")
        }
    }

    /// Strong links (same artist, film, creators) may carry a song whose language the title alone cannot show.
    var isStrong: Bool {
        switch kind {
        case .artist, .singer, .film, .cast, .musicDirector, .composer, .lyricist: true
        default: false
        }
    }
}

struct MusicAutoplayCandidate: Sendable {
    var track: MusicTrack
    var reason: MusicAutoplayReason
    /// Lower is better, within one source.
    var rank: Int
    /// The language the source itself knows the song is in (the graph knows; a title only suggests).
    var language: MusicLanguage?
    init(track: MusicTrack, reason: MusicAutoplayReason, rank: Int = 0, language: MusicLanguage? = nil) {
        self.track = track; self.reason = reason; self.rank = rank; self.language = language
    }
}

struct MusicAutoplayPick: Sendable, Equatable {
    var track: MusicTrack
    var reason: MusicAutoplayReason
    var text: String { reason.text }
}

struct MusicAutoplayRequest: Sendable {
    /// The song autoplay follows: the last song the person chose, not an autoplay row, so the mix does not drift.
    var seed: MusicTrack
    /// The playing song and the latest plays, newest first, as further seeds.
    var recentSeeds: [MusicTrack] = []
    var want: Int = MusicAutoplayEngine.fillTo
    var offline = false
    /// Drives every random choice; tests fix it.
    var randomSeed: UInt64 = UInt64.random(in: .min ... .max)
    init(seed: MusicTrack) { self.seed = seed }
}

/// Where candidates come from. A source never throws: a failure is an empty answer.
protocol MusicAutoplayCandidateSource: Sendable {
    var name: String { get }
    /// True when it answers without the network (the local library, cached graph edges).
    var worksOffline: Bool { get }
    func candidates(for request: MusicAutoplayRequest) async -> [MusicAutoplayCandidate]
}

/// A source made from a closure, for the provider's own radio and for tests.
struct MusicClosureAutoplaySource: MusicAutoplayCandidateSource {
    let name: String
    let worksOffline: Bool
    let fetch: @Sendable (MusicAutoplayRequest) async -> [MusicAutoplayCandidate]
    init(name: String, worksOffline: Bool = false, fetch: @escaping @Sendable (MusicAutoplayRequest) async -> [MusicAutoplayCandidate]) {
        self.name = name; self.worksOffline = worksOffline; self.fetch = fetch
    }
    func candidates(for request: MusicAutoplayRequest) async -> [MusicAutoplayCandidate] { await fetch(request) }
}

// MARK: filters

/// What a candidate must pass. Built by the player from the library, the queue and the settings.
struct MusicAutoplayContext: Sendable {
    /// Blocked song uids and artist ids ("Never play").
    var blocked: Set<String> = []
    /// The last 100 plays.
    var recentUIDs: Set<String> = []
    var queuedUIDs: Set<String> = []
    /// `MusicAutoplaySelector.versionKey` of everything queued.
    var queuedKeys: Set<String> = []
    /// Artist keys of the last rows before the new ones, oldest first (the playing song included).
    var tailArtists: [[String]] = []
    var familiarUIDs: Set<String> = []
    var familiarArtists: Set<String> = []
    var profile = MusicLanguageProfile()
    /// Languages the person said they like; they are allowed next to the seed's own.
    var preferredLanguages: Set<MusicLanguage> = []
    /// Kids mode and the lock: false drops the song.
    var allow: (@Sendable (MusicTrack) -> Bool)? = nil
    /// Offline: true when the song can play without the network (downloaded, cached, local).
    var playableOffline: (@Sendable (MusicTrack) -> Bool)? = nil
    var seedArtistKeys: Set<String> = []
    init() {}
}

/// Which languages autoplay may use: the seed's own script, plus every language the person's history shows they mix.
struct MusicAutoplayLanguagePolicy: Sendable, Equatable {
    var seedScript: MusicLanguage?
    var allowed: Set<MusicLanguage>
    /// Share of the non-Latin plays a language needs to count as part of the person's mix.
    static let mixShare = 0.2
    static let mixMinPlays = 3

    static func make(seed: MusicTrack, profile: MusicLanguageProfile, preferred: Set<MusicLanguage> = []) -> MusicAutoplayLanguagePolicy {
        let s = MusicLanguageDetector.language(of: seed)?.script
        let nonLatin = profile.counts.filter { $0.key != .latin }
        let total = nonLatin.values.reduce(0, +)
        var mixed = Set<MusicLanguage>()
        if total > 0 {
            for (l, c) in nonLatin where c >= mixMinPlays && Double(c) / Double(total) >= mixShare { mixed.insert(l.script) }
        }
        // One language in the history is no mix: the seed decides. Two or more is a mixed listener.
        var allowed: Set<MusicLanguage> = mixed.count >= 2 ? mixed : []
        if let s, s != .latin { allowed.insert(s) }
        if s != nil, s != .latin { allowed.formUnion(preferred.map(\.script).filter { $0 != .latin }) }
        return MusicAutoplayLanguagePolicy(seedScript: s, allowed: allowed)
    }

    enum Verdict { case fits, neutral, rejects }

    func verdict(for c: MusicAutoplayCandidate) -> Verdict {
        let seedIsNonLatin = seedScript.map { $0 != .latin } ?? false
        let lang = (c.language ?? MusicLanguageDetector.language(of: c.track))?.script
        guard let lang else { return seedIsNonLatin ? .neutral : .fits }
        if lang == .latin {
            // A song written in Latin letters says nothing about its language. After a non-Latin seed it passes only on a strong link.
            if !seedIsNonLatin { return .fits }
            return (c.language != nil || c.reason.isStrong) ? .fits : .neutral
        }
        if allowed.contains(lang) { return .fits }
        return .rejects
    }
}

// MARK: selection

enum MusicAutoplaySelector {
    static let familiarShare = 0.7
    static let artistWindow = 6          // no artist more than `maxInWindow` times in any 6 songs
    static let maxInWindow = 2
    static let batchArtistCap = 3
    static let batchSeedArtistCap = 5

    /// The same song in another version (remix, karaoke, "from the film ...", live) shares this key.
    static func versionKey(_ t: MusicTrack) -> String {
        var title = "", depth = 0
        var previous: Character = " "
        for ch in t.title {
            if ch == "(" || ch == "[" { depth += 1; continue }
            if ch == ")" || ch == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 {
                if ch == "-", previous == " " { break }
                title.append(ch)
            }
            previous = ch
        }
        let base = MusicEndlessSource.normalise(title.isEmpty ? t.title : title)
        return base + "|" + MusicEndlessSource.artistKey(t)
    }

    static func artistKeys(_ t: MusicTrack) -> [String] {
        let keys = t.artists.map { $0.id.isEmpty ? MusicEndlessSource.normalise($0.name) : $0.id }.filter { !$0.isEmpty }
        return keys.isEmpty ? [""] : keys
    }

    static func isBlocked(_ t: MusicTrack, _ blocked: Set<String>) -> Bool {
        blocked.contains(t.uid) || t.artists.contains { blocked.contains($0.id) }
    }

    /// Picks up to `want` songs. Pass 1 uses only songs that fit the language policy; pass 2 adds language-neutral ones when pass 1 came up
    /// short, so autoplay never goes quiet because every title was in Latin letters.
    static func select<G: RandomNumberGenerator>(_ pool: [MusicAutoplayCandidate], context: MusicAutoplayContext, policy: MusicAutoplayLanguagePolicy,
                                                  want: Int, offline: Bool, using rng: inout G) -> [MusicAutoplayPick] {
        guard want > 0 else { return [] }
        var seenUIDs = context.queuedUIDs.union(context.recentUIDs)
        var seenKeys = context.queuedKeys
        var fits: [MusicAutoplayCandidate] = [], neutral: [MusicAutoplayCandidate] = []
        for c in pool.sorted(by: { $0.rank < $1.rank }) {
            let t = c.track
            if isBlocked(t, context.blocked) { continue }
            if let allow = context.allow, !allow(t) { continue }
            if offline, let ok = context.playableOffline, !ok(t) { continue }
            if seenUIDs.contains(t.uid) { continue }
            let key = versionKey(t)
            if seenKeys.contains(key) { continue }
            switch policy.verdict(for: c) {
            case .rejects: continue
            case .fits: fits.append(c)
            case .neutral: neutral.append(c)
            }
            seenUIDs.insert(t.uid); seenKeys.insert(key)
        }
        var window = context.tailArtists
        var picks: [MusicAutoplayPick] = []
        var perArtist: [String: Int] = [:]

        func familiar(_ c: MusicAutoplayCandidate) -> Bool {
            context.familiarUIDs.contains(c.track.uid) || artistKeys(c.track).contains { context.familiarArtists.contains($0) }
        }
        func spaced(_ c: MusicAutoplayCandidate) -> Bool {
            let recent = window.suffix(artistWindow - 1)
            return artistKeys(c.track).allSatisfy { k in k.isEmpty || recent.filter { $0.contains(k) }.count < maxInWindow }
        }
        func capped(_ c: MusicAutoplayCandidate) -> Bool {
            artistKeys(c.track).allSatisfy { k in
                k.isEmpty || perArtist[k, default: 0] < (context.seedArtistKeys.contains(k) ? batchSeedArtistCap : batchArtistCap)
            }
        }
        func take(_ c: MusicAutoplayCandidate) {
            picks.append(MusicAutoplayPick(track: c.track, reason: c.reason))
            window.append(artistKeys(c.track))
            for k in artistKeys(c.track) { perArtist[k, default: 0] += 1 }
        }
        func fill(_ source: [MusicAutoplayCandidate], enforce: Bool) {
            var familiarPool = source.filter(familiar), freshPool = source.filter { !familiar($0) }
            while picks.count < want, !(familiarPool.isEmpty && freshPool.isEmpty) {
                let wantFamiliar = Double.random(in: 0..<1, using: &rng) < familiarShare
                var chosen: (pool: Int, index: Int)?
                for first in (wantFamiliar ? [0, 1] : [1, 0]) {
                    let p = first == 0 ? familiarPool : freshPool
                    if let i = p.firstIndex(where: { !enforce || (spaced($0) && capped($0)) }) { chosen = (first, i); break }
                }
                guard let ch = chosen else { return }
                if ch.pool == 0 { take(familiarPool.remove(at: ch.index)) } else { take(freshPool.remove(at: ch.index)) }
            }
        }
        fill(fits, enforce: true)
        if picks.count < want { fill(neutral, enforce: true) }
        // Spacing is a preference: when it alone would leave the queue short, relax it rather than stop.
        if picks.count < min(want, 3) {
            let used = Set(picks.map(\.track.uid))
            fill((fits + neutral).filter { !used.contains($0.track.uid) }, enforce: false)
        }
        return picks
    }
}

// MARK: the engine

final class MusicAutoplayEngine: Sendable {
    /// Autoplay keeps at least this many upcoming auto songs, tops up to `fillTo`, and refills when fewer than `lowWater` remain.
    static let floorUpcoming = 10
    static let lowWater = 5
    static let fillTo = 15
    /// Autoplay starts when this many rows or fewer of the person's own context remain.
    static let contextTrigger = 2
    /// Retries per queue tail after an empty answer, and the waits between them.
    static let retryDelays: [TimeInterval] = [3, 10, 30]

    let sources: [any MusicAutoplayCandidateSource]

    init(sources: [any MusicAutoplayCandidateSource]) { self.sources = sources }

    static func needsRefill(upcomingAuto: Int, contextRemaining: Int) -> Bool {
        contextRemaining <= contextTrigger && upcomingAuto < lowWater
    }

    /// How many songs to ask for so the tail reaches `fillTo`.
    static func wantCount(upcomingAuto: Int) -> Int { max(0, fillTo - upcomingAuto) }

    /// Asks the sources in order, stopping as soon as enough songs pass the filters. Offline asks only sources that work offline.
    func fetch(_ request: MusicAutoplayRequest, context: MusicAutoplayContext) async -> [MusicAutoplayPick] {
        var rng = MusicSeededRNG(seed: request.randomSeed)
        let policy = MusicAutoplayLanguagePolicy.make(seed: request.seed, profile: context.profile, preferred: context.preferredLanguages)
        var ctx = context
        if ctx.seedArtistKeys.isEmpty { ctx.seedArtistKeys = Set(MusicAutoplaySelector.artistKeys(request.seed)) }
        var pool: [MusicAutoplayCandidate] = []
        var seen = Set<String>()
        var best: [MusicAutoplayPick] = []
        for (n, source) in sources.enumerated() {
            if Task.isCancelled { break }
            if request.offline, !source.worksOffline { continue }
            for var c in await source.candidates(for: request) where seen.insert(c.track.uid).inserted {
                c.rank += n * 1_000_000
                pool.append(c)
            }
            var local = rng
            best = MusicAutoplaySelector.select(pool, context: ctx, policy: policy, want: request.want, offline: request.offline, using: &local)
            if best.count >= request.want { rng = local; break }
        }
        return best
    }
}

// MARK: sources

/// The local library as a source: same artist, then the same language, then anything the person has played. Works offline.
struct MusicLocalAffinitySource: MusicAutoplayCandidateSource {
    let name = "local"
    let worksOffline = true
    let library: @Sendable () -> [MusicTrack]
    init(library: @escaping @Sendable () -> [MusicTrack]) { self.library = library }

    func candidates(for request: MusicAutoplayRequest) async -> [MusicAutoplayCandidate] {
        let seedKeys = Set(MusicAutoplaySelector.artistKeys(request.seed))
        let seedLang = MusicLanguageDetector.language(of: request.seed)?.script
        var out: [MusicAutoplayCandidate] = []
        for (i, t) in library().enumerated() where t.uid != request.seed.uid {
            if !seedKeys.isDisjoint(with: MusicAutoplaySelector.artistKeys(t)) {
                out.append(MusicAutoplayCandidate(track: t, reason: MusicAutoplayReason(.artist, request.seed.artists.first?.name), rank: i))
            } else if let l = seedLang, l != .latin, MusicLanguageDetector.language(of: t)?.script == l {
                out.append(MusicAutoplayCandidate(track: t, reason: MusicAutoplayReason(.language, l.displayName), rank: 10_000 + i, language: l))
            } else {
                out.append(MusicAutoplayCandidate(track: t, reason: MusicAutoplayReason(.local), rank: 20_000 + i))
            }
        }
        return out
    }
}

/// The graph recommender as a source: same artist or singer, same film (cast, music director, composer, lyricist), same language and era,
/// genre, then listening affinity, in the recommender's own band order. The two closures bridge the graph to playable tracks and are
/// supplied by the app (an entity with no playable match returns nil and is skipped).
struct MusicGraphAutoplaySource: MusicAutoplayCandidateSource {
    let name = "graph"
    let worksOffline = true
    let recommender: MusicRecommender
    let seedEntity: @Sendable (MusicTrack) async -> MusicEntityID?
    let playable: @Sendable (MusicRecCandidate) async -> MusicTrack?
    /// Names the recommender may bias towards (the person's languages).
    var preferredLanguages: [String] = []

    func candidates(for request: MusicAutoplayRequest) async -> [MusicAutoplayCandidate] {
        var out: [MusicAutoplayCandidate] = []
        var seeds = [request.seed]
        seeds += request.recentSeeds.prefix(2)
        for (n, seed) in seeds.enumerated() {
            guard let id = await seedEntity(seed) else { continue }
            var ctx = MusicRecContext()
            ctx.preferredLanguages = preferredLanguages
            let result = await recommender.radioCandidates(seed: id, limit: max(request.want * 2, 20), maxRun: 2, context: ctx)
            for (i, c) in result.items.enumerated() {
                guard let t = await playable(c) else { continue }
                out.append(MusicAutoplayCandidate(track: t, reason: Self.reason(c.explanation), rank: n * 500 + Int(c.band.rawValue) * 40 + i,
                                                  language: nil))
            }
            if out.count >= request.want * 2 { break }
        }
        return out
    }

    static func reason(_ e: MusicRecExplanation) -> MusicAutoplayReason {
        let name = e.subjects.first?.name
        switch e.reason {
        case .sameFilm, .featuredInFilm, .soundtrackOfFilm, .sameAlbum, .onAlbum, .affinityFilm: return MusicAutoplayReason(.film, name)
        case .sharedCast, .alsoStars, .starring, .inCastOf: return MusicAutoplayReason(.cast, name)
        case .sameMusicDirector: return MusicAutoplayReason(.musicDirector, name)
        case .sameComposer, .affinityComposer, .sharedCreators, .creditedOn: return MusicAutoplayReason(.composer, name)
        case .sameLyricist: return MusicAutoplayReason(.lyricist, name)
        case .sameSinger, .affinitySinger, .collaboration: return MusicAutoplayReason(.singer, name)
        case .sameArtist, .groupMember, .versionOf, .sameDirector: return MusicAutoplayReason(.artist, name)
        case .sameLanguageEra, .affinityEra: return MusicAutoplayReason(.era, name)
        case .sameGenre: return MusicAutoplayReason(.genre, name)
        case .affinityLanguage, .affinityLanguageFilm, .broadLanguage: return MusicAutoplayReason(.language, name)
        }
    }
}

/// A retry schedule per queue tail, so one empty answer (offline for a moment, a rate limit) never ends autoplay for good.
struct MusicAutoplayRetryGate: Sendable, Equatable {
    private(set) var tail: UUID?
    private(set) var failures = 0
    private(set) var nextAt = Date.distantPast
    private(set) var inFlight = false

    func shouldFetch(tail key: UUID?, now: Date) -> Bool {
        guard let key, !inFlight else { return false }
        if key != tail { return true }
        return failures > 0 && failures <= MusicAutoplayEngine.retryDelays.count && now >= nextAt
    }
    mutating func begin(tail key: UUID?) {
        if key != tail { tail = key; failures = 0; nextAt = .distantPast }
        inFlight = true
    }
    mutating func succeeded() { inFlight = false; failures = 0 }
    mutating func failed(now: Date) {
        inFlight = false
        failures += 1
        nextAt = now.addingTimeInterval(MusicAutoplayEngine.retryDelays[min(failures, MusicAutoplayEngine.retryDelays.count) - 1])
    }
    mutating func reset() { self = MusicAutoplayRetryGate() }
}
