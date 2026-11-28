import Foundation

// The recommendation engine's values (section 5 of the graph design). Pure and Sendable: no UI, no player, no network.

/// The owner's priority bands. A candidate's band is its strongest real signal; the bands are strictly ordered, so a candidate of band 2 always ranks
/// above a candidate of band 3 whatever the listening history says. Listening affinity only reorders items inside one band.
enum MusicRecBand: Int, CaseIterable, Comparable, Codable, Sendable {
    case verifiedDirect = 1, sharedCreators, sharedFilm, collaboration, sameArtist, languageEra, genre, affinity, broad

    /// The base of the score. Gaps are at least 100 and the in-band part stays below 100, so `score` alone orders bands too.
    var base: Double {
        switch self {
        case .verifiedDirect: 1000
        case .sharedCreators: 850
        case .sharedFilm: 750
        case .collaboration: 650
        case .sameArtist: 550
        case .languageEra: 400
        case .genre: 300
        case .affinity: 200
        case .broad: 100
        }
    }
    /// The largest in-band score (exclusive): keeps every band's range apart from the next.
    static let inBandCeiling = 99.0
    /// Bands that need listening history, or an explicit ask for broad shelves. Cold start serves bands 1 to 7 only.
    var needsHistory: Bool { self == .affinity || self == .broad }
    static func < (a: MusicRecBand, b: MusicRecBand) -> Bool { a.rawValue < b.rawValue }
}

/// A named thing in an explanation: an entity the person can open, or a plain label (a decade and language such as "1950s Hindi").
struct MusicRecSubject: Hashable, Sendable {
    var id: MusicEntityID?
    var name: String
    init(id: MusicEntityID? = nil, name: String) { self.id = id; self.name = name }
}

/// Why a candidate is shown. Each reason is read off real edges or real listening; none is ever invented.
enum MusicRecReason: String, Hashable, Sendable, CaseIterable {
    // band 1
    case sameAlbum, onAlbum, soundtrackOfFilm, versionOf, groupMember, creditedOn, inCastOf
    // band 2
    case sharedCreators
    // band 3
    case sameFilm, featuredInFilm, alsoStars, starring, sharedCast
    // band 4
    case collaboration
    // band 5
    case sameComposer, sameMusicDirector, sameSinger, sameLyricist, sameDirector, sameArtist
    // bands 6, 7
    case sameLanguageEra, sameGenre
    // band 8
    case affinityComposer, affinitySinger, affinityFilm, affinityLanguage, affinityLanguageFilm, affinityEra
    // band 9
    case broadLanguage
}

/// One short human line, built from a reason and the names it came from. `tentative` is set when the supporting edge is inferred below 0.75
/// confidence; the card then says "Possibly related".
struct MusicRecExplanation: Hashable, Sendable {
    var reason: MusicRecReason
    var subjects: [MusicRecSubject]
    var tentative: Bool
    init(_ reason: MusicRecReason, _ subjects: [MusicRecSubject] = [], tentative: Bool = false) {
        self.reason = reason; self.subjects = subjects; self.tentative = tentative
    }

    /// The line in English (or whatever `wording` says). Names are never translated; with no name the plain form is used.
    func text(_ wording: MusicRecWording = .english) -> String {
        let line = wording.render(reason, subjects.map(\.name))
        return tentative ? wording.possibly(line) : line
    }
}

/// The wording of every reason. English here; the app builds a localised one (`MusicRecWording+App.swift`) from the same keys.
struct MusicRecWording: Sendable {
    /// `(key, plain-key-when-no-name, names)`: looks the key up and fills `%@` with the joined names.
    var template: @Sendable (_ key: String) -> String
    var join: @Sendable (_ names: [String]) -> String
    var possiblyKey: String = "Possibly related: %@"

    /// A tentative reason reads exactly like a firm one: the app does not hedge in words on the card (the owner asked for no "Possibly related" or "Inferred" labels).
    func possibly(_ line: String) -> String { line }

    func render(_ reason: MusicRecReason, _ names: [String]) -> String {
        let (named, plain) = Self.keys(reason)
        let clean = names.filter { !$0.isEmpty }
        if clean.isEmpty { return template(plain ?? named) }
        let fmt = template(named)
        switch reason {
        case .collaboration:
            // "Worked with %1$@ on %2$@": two names; with one, the short form.
            if clean.count >= 2 { return String(format: fmt, clean[0], clean[1]) }
            return String(format: template("Worked with %@"), clean[0])
        default:
            return String(format: fmt, join(clean))
        }
    }

    /// The localisation key of a reason: the form with a name, and the form without one.
    static func keys(_ r: MusicRecReason) -> (named: String, plain: String?) {
        switch r {
        case .sameAlbum: ("From the same album: %@", "From the same album")
        case .onAlbum: ("From the album %@", "From the same album")
        case .soundtrackOfFilm: ("Soundtrack of %@", "Soundtrack of the same film")
        case .creditedOn: ("Credited on %@", "Credited on this work")
        case .inCastOf: ("In the cast of %@", "In the cast")
        case .versionOf: ("Another version of %@", "Another version of this song")
        case .groupMember: ("Member of %@", "Member of the same group")
        case .sharedCreators: ("Same creators: %@", "Same creators")
        case .sameFilm: ("From the film %@", "From the same film")
        case .featuredInFilm: ("From the film %@", "From the same film")
        case .alsoStars: ("Also stars %@", "Shares cast")
        case .starring: ("Stars %@", "Shares cast")
        case .sharedCast: ("Shares cast: %@", "Shares cast")
        case .collaboration: ("Worked with %1$@ on %2$@", "Worked with the same people")
        case .sameComposer: ("Same composer: %@", "Same composer")
        case .sameMusicDirector: ("Same music director: %@", "Same music director")
        case .sameSinger: ("Same singer: %@", "Same singer")
        case .sameLyricist: ("Same lyricist: %@", "Same lyricist")
        case .sameDirector: ("Same director: %@", "Same director")
        case .sameArtist: ("More from %@", "More from the same artist")
        case .sameLanguageEra: ("Same era and language: %@", "Same era and language")
        case .sameGenre: ("Same genre: %@", "Same genre")
        case .affinityComposer: ("Because you play music by %@", "Because of what you play")
        case .affinitySinger: ("Because you play %@", "Because of what you play")
        case .affinityFilm: ("Because you play songs from %@", "Because of what you play")
        case .affinityLanguage: ("Because you play %@ music", "Because of what you play")
        case .affinityLanguageFilm: ("Because you play %@ film music", "Because of what you play")
        case .affinityEra: ("Because you play %@ music", "Because of what you play")
        case .broadLanguage: ("Also in %@", "Also in your languages")
        }
    }

    static let english = MusicRecWording(template: { $0 }, join: { names in
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: names[0] + " and " + names[1]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    })
}

enum MusicRecFlag: String, Hashable, Sendable {
    /// Same title as the seed (or another candidate) but a different year: a remake. Kept separate.
    case remake
    /// Same film or title in another language: a dub or language edition. Kept separate.
    case dub
    /// The link behind the first reason is inferred, not verified.
    case inferredLink
}

struct MusicRecCandidate: Identifiable, Hashable, Sendable {
    var id: MusicEntityID
    var snapshot: MusicEntitySnapshot
    var band: MusicRecBand
    /// `band.base` plus the in-band part (0 up to but not including 100).
    var score: Double
    var explanation: MusicRecExplanation
    /// Up to two further reasons from weaker signals.
    var otherReasons: [MusicRecExplanation]
    var confidence: Float
    /// 0...1: how much the device-local affinity moved this item inside its band.
    var affinityBoost: Double
    /// How many near-identical items were folded into this one (1 = none).
    var versionCount: Int
    var flags: Set<MusicRecFlag>
    /// The first credited performer, for spacing a station's queue.
    var artist: MusicEntityID? = nil

    var kind: MusicEntityKind { id.kind }
    var name: String { snapshot.name }
}

struct MusicRecResult: Sendable {
    var seed: MusicEntityID
    var items: [MusicRecCandidate]
    /// A bound (depth, fan-out, nodes, time) cut the walk or the profile pass short.
    var truncated: Bool
    var visitedNodes: Int
    /// No listening history: bands 1 to 7 only.
    var coldStart: Bool
    var fromCache: Bool
    /// Served from an expired cache entry because the graph could not be read.
    var stale: Bool
    static func empty(_ seed: MusicEntityID, coldStart: Bool = true) -> MusicRecResult {
        MusicRecResult(seed: seed, items: [], truncated: false, visitedNodes: 0, coldStart: coldStart, fromCache: false, stale: false)
    }
}

/// How one request behaves. Defaults are the owner's bounds (depth 2, fan-out 40, 400 nodes, 40 ms).
struct MusicRecContext: Sendable {
    /// nil: read the device-local affinity from the recommender's store. `.empty`: act as a cold start.
    var affinity: MusicAffinityVector?
    var preferredLanguages: [String] = []
    var now: Date = Date()
    /// Allow band 9 (broader) items. Off for a cold start unless a page asks.
    var includeBroad = false
    /// The seed's own versions (remix, karaoke, dub) are normally left out; the song page's "versions" section asks for them.
    var includeSeedVersions = false
    var recentlyShown: Set<MusicEntityID> = []
    var exclude: Set<MusicEntityID> = []
    /// Bumped by the app when the graph changed; part of the cache key.
    var graphRevision = 0
    var depth = MusicTraversal.maxDepth
    var fanOut = MusicTraversal.maxFanOut
    /// Time allowed to read the edges and names of the walk's nodes after the walk itself.
    var profileBudget: Duration = .milliseconds(40)
    /// Albums and films of the walk's songs read one ring further out, at most this many.
    var maxRing = 120
    var useCache = true
    var minInferredConfidence: Float = 0.3
    /// Facts older than twice this are demoted (x0.8).
    var freshnessTTL: TimeInterval = 90 * 86_400

    init() {}
    init(affinity: MusicAffinityVector?) { self.affinity = affinity }
}

extension MusicRecContext {
    /// The part of the request that changes the answer, for the cache key.
    func configSignature(affinityRevision: Int, kinds: Set<MusicEntityKind>, limit: Int) -> String {
        let k = kinds.map { String($0.rawValue) }.sorted().joined(separator: ",")
        return "d\(depth)f\(fanOut)b\(includeBroad ? 1 : 0)v\(includeSeedVersions ? 1 : 0)a\(affinityRevision)g\(graphRevision)k\(k)l\(limit)x\(exclude.count)s\(recentlyShown.count)p\(preferredLanguages.joined(separator: "+"))"
    }
}
