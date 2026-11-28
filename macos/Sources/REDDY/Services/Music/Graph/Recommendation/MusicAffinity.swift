import Foundation

// Device-local listening affinity (section 5.5). Derived on demand from the play history, never stored as new copies of entities, never sent anywhere,
// and never part of a backup. A vector is a small value: counts per key with a recency decay applied when it is built.

/// One thing the person did with a song, already tied to the song's graph credits. Built by `MusicAffinityEventResolver` from the history.
struct MusicPlayEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case completed, partial, skipped, liked, unliked, repeated, addedToPlaylist }
    var kind: Kind
    var at: Date
    var recording: MusicEntityID?
    /// Composers and music directors of the song.
    var composers: [MusicEntityID] = []
    var singers: [MusicEntityID] = []
    var film: MusicEntityID?
    /// A lower-case language key (`hin`, `tel`, `hindi`): the same spelling the candidate side uses, see `MusicRecLanguage.key`.
    var language: String?
    var year: Int?

    /// Completed play +1, over 30 s or half +0.5, skipped within 20 s -0.5, like +3, unlike -3, repeat +1, added to a playlist +2.
    var weight: Double {
        switch kind {
        case .completed: 1
        case .partial: 0.5
        case .skipped: -0.5
        case .liked: 3
        case .unliked: -3
        case .repeated: 1
        case .addedToPlaylist: 2
        }
    }
}

/// Affinity per dimension, decayed to the moment it was built.
struct MusicAffinityVector: Sendable, Equatable {
    var recording: [MusicEntityID: Double] = [:]
    var composer: [MusicEntityID: Double] = [:]
    var singer: [MusicEntityID: Double] = [:]
    var film: [MusicEntityID: Double] = [:]
    /// Films whose songs the person SAVED (liked or added to a playlist). Plays, autoplay and radio never count here, so "saved" means saved.
    var savedFilm: [MusicEntityID: Double] = [:]
    var language: [String: Double] = [:]
    var decade: [Int: Double] = [:]
    var eventCount = 0
    /// Changes whenever the content does, for cache keys.
    var revision = 0

    static let empty = MusicAffinityVector()
    /// Nothing positive: a cold start.
    var isEmpty: Bool { recording.isEmpty && composer.isEmpty && singer.isEmpty && film.isEmpty && language.isEmpty && decade.isEmpty }

    /// Propagation weights from a played recording to what made it.
    enum Propagation { static let composer = 0.5, singer = 0.4, film = 0.3, language = 0.2, era = 0.2 }
    /// A raw affinity of this size counts as full (boost 1).
    static let saturation = 6.0

    /// 0...1 for a candidate described by its own id, credits, film, language keys and year. Pure sums of what the person played.
    func boost(recording id: MusicEntityID?, composers: [MusicEntityID], singers: [MusicEntityID], film films: [MusicEntityID],
               languages: Set<String>, year: Int?) -> Double {
        if isEmpty { return 0 }
        var a = id.flatMap { recording[$0] } ?? 0
        a += composers.compactMap { composer[$0] }.max() ?? 0
        a += singers.compactMap { singer[$0] }.max() ?? 0
        a += films.compactMap { film[$0] }.max() ?? 0
        a += languages.compactMap { language[$0] }.max() ?? 0
        if let y = year { a += decade[(y / 10) * 10] ?? 0 }
        return min(1, max(0, a / Self.saturation))
    }

    enum Dimension: Sendable { case composer, singer, film, savedFilm, recording }
    /// The strongest keys of one dimension, strongest first.
    func top(_ d: Dimension, count: Int) -> [(id: MusicEntityID, weight: Double)] {
        let src: [MusicEntityID: Double]
        switch d { case .composer: src = composer; case .singer: src = singer; case .film: src = film; case .savedFilm: src = savedFilm; case .recording: src = recording }
        return src.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(max(0, count)).map { (id: $0.key, weight: $0.value) }
    }
    func topLanguages(count: Int) -> [String] { language.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(max(0, count)).map(\.key) }
    func topDecades(count: Int) -> [Int] { decade.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(max(0, count)).map(\.key) }
}

enum MusicAffinityBuilder {
    static let halfLife: TimeInterval = 60 * 86_400

    static func build(events: [MusicPlayEvent], now: Date = Date(), halfLife: TimeInterval = halfLife, since floor: Date? = nil) -> MusicAffinityVector {
        var v = MusicAffinityVector()
        var counted = 0
        for e in events {
            if let floor, e.at < floor { continue }
            let age = max(0, now.timeIntervalSince(e.at))
            let w = e.weight * pow(0.5, age / max(1, halfLife))
            if w == 0 { continue }
            counted += 1
            if let r = e.recording { v.recording[r, default: 0] += w }
            for c in Set(e.composers) { v.composer[c, default: 0] += w * MusicAffinityVector.Propagation.composer }
            for s in Set(e.singers) { v.singer[s, default: 0] += w * MusicAffinityVector.Propagation.singer }
            if let f = e.film {
                v.film[f, default: 0] += w * MusicAffinityVector.Propagation.film
                if e.kind == .liked || e.kind == .unliked || e.kind == .addedToPlaylist { v.savedFilm[f, default: 0] += w * MusicAffinityVector.Propagation.film }
            }
            if let l = e.language, !l.isEmpty { v.language[l, default: 0] += w * MusicAffinityVector.Propagation.language }
            if let y = e.year { v.decade[(y / 10) * 10, default: 0] += w * MusicAffinityVector.Propagation.era }
        }
        // Dislikes can cancel likes but never go below zero.
        v.recording = v.recording.filter { $0.value > 0.0001 }
        v.composer = v.composer.filter { $0.value > 0.0001 }
        v.singer = v.singer.filter { $0.value > 0.0001 }
        v.film = v.film.filter { $0.value > 0.0001 }
        v.savedFilm = v.savedFilm.filter { $0.value > 0.0001 }
        v.language = v.language.filter { $0.value > 0.0001 }
        v.decade = v.decade.filter { $0.value > 0.0001 }
        v.eventCount = counted
        var h = Hasher()
        h.combine(v.recording.count); h.combine(v.composer.count); h.combine(v.singer.count); h.combine(v.film.count); h.combine(counted)
        h.combine(Int((v.recording.values.reduce(0, +) * 100).rounded()))
        v.revision = h.finalize()
        return v
    }
}

/// One finished or skipped play, as the history records it (no graph ids yet).
struct MusicHistoryPlay: Sendable, Equatable {
    var providerUID: String
    var at: Date
    var playedMs: Int64
    var durationMs: Int64

    /// Over 30 seconds or half the song counts as a play; 90 percent or more as a completed one; under 20 seconds as a skip.
    var eventKind: MusicPlayEvent.Kind? {
        let seconds = Double(playedMs) / 1000
        let share = durationMs > 0 ? Double(playedMs) / Double(durationMs) : 0
        if share >= 0.9 { return .completed }
        if seconds >= 30 || share >= 0.5 { return .partial }
        if seconds > 0 && seconds < 20 { return .skipped }
        return nil
    }
}

/// Ties history plays to graph credits by reading only: the index is asked for ids that already exist (nothing is minted) and the store for their
/// edges, so the history never gets copied into entities.
struct MusicAffinityEventResolver: Sendable {
    let store: any MusicGraphStoring
    let lookup: @Sendable (_ providerUID: String) async -> MusicEntityID?
    var maxPlays = 300
    var budget: Duration = .milliseconds(250)

    func events(from plays: [MusicHistoryPlay]) async -> [MusicPlayEvent] {
        let start = ContinuousClock.now
        var out: [MusicPlayEvent] = []
        var profile: [MusicEntityID: (composers: [MusicEntityID], singers: [MusicEntityID], film: MusicEntityID?, lang: String?, year: Int?)] = [:]
        for p in plays.sorted(by: { $0.at > $1.at }).prefix(maxPlays) {
            guard let kind = p.eventKind else { continue }
            guard ContinuousClock.now - start < budget, let id = await lookup(p.providerUID) else {
                // Past the budget (or unknown to the graph) the play still counts for the recording alone when it is known.
                continue
            }
            if profile[id] == nil { profile[id] = await Self.profile(of: id, store: store) }
            let pr = profile[id]!
            out.append(MusicPlayEvent(kind: kind, at: p.at, recording: id, composers: pr.composers, singers: pr.singers, film: pr.film, language: pr.lang, year: pr.year))
        }
        return out
    }

    static func profile(of id: MusicEntityID, store: any MusicGraphStoring) async -> (composers: [MusicEntityID], singers: [MusicEntityID], film: MusicEntityID?, lang: String?, year: Int?) {
        let edges = (try? await store.edges(of: id, predicate: nil, direction: .outgoing, limit: 60)) ?? []
        var composers: [MusicEntityID] = [], singers: [MusicEntityID] = [], film: MusicEntityID?
        var albums: [MusicEntityID] = []
        for e in edges {
            switch e.predicate {
            case .composedBy, .musicDirectedBy: composers.append(e.object)
            case .performedBy: singers.append(e.object)
            case .featuredIn: film = film ?? e.object
            case .trackOn: albums.append(e.object)
            default: break
            }
        }
        if film == nil || composers.isEmpty {
            for a in albums.prefix(2) {
                let ae = (try? await store.edges(of: a, predicate: nil, direction: .outgoing, limit: 40)) ?? []
                for e in ae {
                    if e.predicate == .soundtrackOf, film == nil { film = e.object }
                    if e.predicate == .musicDirectedBy || e.predicate == .composedBy { composers.append(e.object) }
                }
            }
        }
        let snap = try? await store.entity(id)
        return (Array(Set(composers)), Array(Set(singers)), film, snap?.lang.map { MusicRecLanguage.key($0) }, snap?.year)
    }
}

/// The app's device-local affinity: built on first use from the history, kept for a few minutes, rebuilt when the history changes. `reset()` is the
/// Music settings reset button; `wipe()` is part of "Delete all music data". Nothing here is persisted except the reset floor (the caller's closure).
actor MusicAffinityStore {
    private let source: @Sendable () async -> [MusicPlayEvent]
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private var cached: MusicAffinityVector?
    private var builtAt = Date.distantPast
    private var floor: Date?
    private let saveFloor: (@Sendable (Date?) -> Void)?

    init(ttl: TimeInterval = 300, clock: @escaping @Sendable () -> Date = { Date() }, floor: Date? = nil, saveFloor: (@Sendable (Date?) -> Void)? = nil,
         source: @escaping @Sendable () async -> [MusicPlayEvent]) {
        self.source = source; self.ttl = ttl; self.clock = clock; self.floor = floor; self.saveFloor = saveFloor
    }

    func vector() async -> MusicAffinityVector {
        let now = clock()
        if let v = cached, now.timeIntervalSince(builtAt) < ttl { return v }
        let events = await source()
        let v = MusicAffinityBuilder.build(events: events, now: now, since: floor)
        cached = v; builtAt = now
        return v
    }

    /// The history changed (a play finished, a like): the next read rebuilds.
    func invalidate() { cached = nil }

    /// Forget everything listened to so far; later plays count again.
    func reset() { floor = clock(); cached = nil; saveFloor?(floor) }

    /// The privacy wipe.
    func wipe() { floor = nil; cached = nil; saveFloor?(nil) }
}

/// Language keys written one way on both sides of the comparison (a snapshot says `hi`, `hin` or `Hindi`).
enum MusicRecLanguage {
    private static let table: [String: String] = [
        "hi": "hindi", "hin": "hindi", "hindi": "hindi", "te": "telugu", "tel": "telugu", "telugu": "telugu", "ta": "tamil", "tam": "tamil", "tamil": "tamil",
        "kn": "kannada", "kan": "kannada", "kannada": "kannada", "ml": "malayalam", "mal": "malayalam", "malayalam": "malayalam",
        "bn": "bengali", "ben": "bengali", "bengali": "bengali", "pa": "punjabi", "pan": "punjabi", "punjabi": "punjabi",
        "mr": "marathi", "mar": "marathi", "marathi": "marathi", "gu": "gujarati", "guj": "gujarati", "gujarati": "gujarati",
        "en": "english", "eng": "english", "english": "english", "ko": "korean", "kor": "korean", "korean": "korean",
        "ja": "japanese", "jpn": "japanese", "japanese": "japanese", "es": "spanish", "spa": "spanish", "spanish": "spanish",
        "ur": "urdu", "urd": "urdu", "urdu": "urdu"
    ]
    static func key(_ raw: String) -> String {
        let l = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let base = l.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? l
        return table[base] ?? base
    }
    static func display(_ key: String) -> String { key.prefix(1).uppercased() + key.dropFirst() }
}
