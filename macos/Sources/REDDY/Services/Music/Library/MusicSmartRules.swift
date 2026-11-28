import Foundation
import Observation

// Rule-based smart playlists: the person writes rules ("language is Telugu, played at least 3 times, added in the last 90 days"), and the playlist is whatever
// in the library matches them now. Nothing is stored but the rules, so the list is always current. The matching is a pure function over the library's songs
// and a few facts about them (plays, when they were added, which are liked).

enum MusicSmartField: String, Codable, CaseIterable, Identifiable, Sendable {
    case title, artist, album, genre, language, year, plays, lastPlayedDays, liked, minutes
    var id: String { rawValue }

    /// Text fields take "contains" and "is"; number fields take "at least" and "at most"; liked takes yes or no.
    enum Kind: Sendable { case text, number, flag }
    var kind: Kind {
        switch self {
        case .title, .artist, .album, .genre, .language: .text
        case .year, .plays, .lastPlayedDays, .minutes: .number
        case .liked: .flag
        }
    }
    var title: String {
        switch self {
        case .title: Localized.string("Title")
        case .artist: Localized.string("Artist")
        case .album: Localized.string("Album")
        case .genre: Localized.string("Genre")
        case .language: Localized.string("Language")
        case .year: Localized.string("Release year")
        case .plays: Localized.string("Times played")
        case .lastPlayedDays: Localized.string("Last played within (days)")
        case .liked: Localized.string("Liked")
        case .minutes: Localized.string("Length (minutes)")
        }
    }
    var operators: [MusicSmartOperator] {
        switch kind {
        case .text: [.contains, .notContains, .equals]
        case .number: [.atLeast, .atMost, .equals]
        case .flag: [.isTrue, .isFalse]
        }
    }
}

enum MusicSmartOperator: String, Codable, CaseIterable, Identifiable, Sendable {
    case contains, notContains, equals, atLeast, atMost, isTrue, isFalse
    var id: String { rawValue }
    var title: String {
        switch self {
        case .contains: Localized.string("contains")
        case .notContains: Localized.string("does not contain")
        case .equals: Localized.string("is")
        case .atLeast: Localized.string("at least")
        case .atMost: Localized.string("at most")
        case .isTrue: Localized.string("yes")
        case .isFalse: Localized.string("no")
        }
    }
}

struct MusicSmartCondition: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var field: MusicSmartField
    var op: MusicSmartOperator
    var value: String = ""
}

enum MusicSmartMatch: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, any
    var id: String { rawValue }
    var title: String { self == .all ? Localized.string("all of these rules") : Localized.string("any of these rules") }
}

enum MusicSmartSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case recentlyAdded, mostPlayed, leastPlayed, title, artist, random
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recentlyAdded: Localized.string("Recently added")
        case .mostPlayed: Localized.string("Most played")
        case .leastPlayed: Localized.string("Least played")
        case .title: Localized.string("A to Z")
        case .artist: Localized.string("Artist")
        case .random: Localized.string("Random")
        }
    }
}

struct MusicSmartPlaylist: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var match: MusicSmartMatch
    var conditions: [MusicSmartCondition]
    var sort: MusicSmartSort
    /// Most songs shown; 0 means no limit.
    var limit: Int
    var created: Date

    init(id: UUID = UUID(), name: String, match: MusicSmartMatch = .all, conditions: [MusicSmartCondition] = [], sort: MusicSmartSort = .recentlyAdded, limit: Int = 100, created: Date = Date()) {
        self.id = id; self.name = name; self.match = match; self.conditions = conditions; self.sort = sort; self.limit = max(0, limit); self.created = created
    }

    private enum CodingKeys: String, CodingKey { case id, name, match, conditions, sort, limit, created }

    /// Lenient, like the other library files: a field a newer or older version did not write gets a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        match = (try? c.decodeIfPresent(MusicSmartMatch.self, forKey: .match)) ?? .all
        conditions = (try? c.decodeIfPresent([MusicSmartCondition].self, forKey: .conditions)) ?? []
        sort = (try? c.decodeIfPresent(MusicSmartSort.self, forKey: .sort)) ?? .recentlyAdded
        limit = max(0, try c.decodeIfPresent(Int.self, forKey: .limit) ?? 100)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

/// What the matcher needs to know about the library besides the songs themselves.
struct MusicSmartSignals: Sendable {
    var plays: [String: Int] = [:]
    var lastPlayed: [String: Date] = [:]
    /// Place in the liked list, newest first (0 is the song liked last). The library keeps no date for when a song was added, so this is the order it has.
    var likedOrder: [String: Int] = [:]
    var liked: Set<String> = []
    var now = Date()

    /// From the play history and the liked list (newest first).
    static func build(history: [PlayRecord], liked: [MusicTrack], now: Date = Date()) -> MusicSmartSignals {
        var s = MusicSmartSignals(now: now)
        for r in history {
            s.plays[r.track.uid, default: 0] += 1
            if s.lastPlayed[r.track.uid].map({ r.at > $0 }) ?? true { s.lastPlayed[r.track.uid] = r.at }
        }
        s.liked = Set(liked.map(\.uid))
        for (i, t) in liked.enumerated() where s.likedOrder[t.uid] == nil { s.likedOrder[t.uid] = i }
        return s
    }
}

enum MusicSmartEvaluator {
    /// A rule with no value (or a number that is not a number) cannot be judged, so it is left out rather than matching everything or nothing.
    static func isComplete(_ c: MusicSmartCondition) -> Bool {
        switch c.field.kind {
        case .flag: return true
        case .text: return !c.value.trimmingCharacters(in: .whitespaces).isEmpty
        case .number: return Double(c.value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) != nil
        }
    }

    static func matches(_ t: MusicTrack, _ c: MusicSmartCondition, signals: MusicSmartSignals) -> Bool {
        switch c.field.kind {
        case .text:
            let want = MusicText.normalize(c.value)
            let haves: [String]
            switch c.field {
            case .title: haves = [t.title]
            case .artist: haves = t.artists.map(\.name)
            case .album: haves = [t.album?.title ?? ""]
            case .genre: haves = [t.hints?.genre ?? ""]
            case .language: haves = [MusicLanguageDetector.language(of: t).map { $0.rawValue } ?? "", MusicLanguageDetector.language(of: t)?.displayName ?? "", t.hints?.language ?? ""]
            default: haves = []
            }
            let norm = haves.map { MusicText.normalize($0) }.filter { !$0.isEmpty }
            switch c.op {
            case .contains: return norm.contains { $0.contains(want) }
            case .notContains: return !norm.contains { $0.contains(want) }
            case .equals: return norm.contains { $0 == want }
            default: return false
            }
        case .number:
            guard let n = Double(c.value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) else { return false }
            let have: Double?
            switch c.field {
            case .year: have = t.hints?.year.map(Double.init) ?? year(of: t).map(Double.init)
            case .plays: have = Double(signals.plays[t.uid] ?? 0)
            case .lastPlayedDays: have = signals.lastPlayed[t.uid].map { signals.now.timeIntervalSince($0) / 86_400 }
            case .minutes: have = t.durationMs > 0 ? Double(t.durationMs) / 60_000 : nil
            default: have = nil
            }
            // "Last played within" is at most that many days ago ("at most"); a song never played is not "within" anything.
            guard let have else { return false }
            switch c.op {
            case .atLeast: return have >= n
            case .atMost: return have <= n
            case .equals: return Int(have) == Int(n)
            default: return false
            }
        case .flag:
            let liked = signals.liked.contains(t.uid)
            return c.op == .isFalse ? !liked : liked
        }
    }

    /// Release year from the album's date ("2026-03-14", "2026").
    static func year(of t: MusicTrack) -> Int? {
        guard let raw = t.album?.releaseDate, raw.count >= 4, let y = Int(raw.prefix(4)), y > 1900 else { return nil }
        return y
    }

    /// The songs of `pool` (the library) that match, sorted and limited. A playlist with no complete rule matches nothing (a blank rule list is not "everything").
    static func tracks(for list: MusicSmartPlaylist, in pool: [MusicTrack], signals: MusicSmartSignals, seed: UInt64 = 1) -> [MusicTrack] {
        let rules = list.conditions.filter(isComplete)
        guard !rules.isEmpty else { return [] }
        var seen = Set<String>()
        var hits = pool.filter { t in
            guard seen.insert(t.uid).inserted else { return false }
            let results = rules.map { matches(t, $0, signals: signals) }
            return list.match == .all ? results.allSatisfy { $0 } : results.contains(true)
        }
        switch list.sort {
        case .recentlyAdded:
            hits.sort { (signals.likedOrder[$0.uid] ?? Int.max) < (signals.likedOrder[$1.uid] ?? Int.max) }
        case .mostPlayed:
            hits.sort { (signals.plays[$0.uid] ?? 0) != (signals.plays[$1.uid] ?? 0) ? (signals.plays[$0.uid] ?? 0) > (signals.plays[$1.uid] ?? 0) : $0.title < $1.title }
        case .leastPlayed:
            hits.sort { (signals.plays[$0.uid] ?? 0) != (signals.plays[$1.uid] ?? 0) ? (signals.plays[$0.uid] ?? 0) < (signals.plays[$1.uid] ?? 0) : $0.title < $1.title }
        case .title:
            hits.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            hits.sort { $0.artistLine.localizedCaseInsensitiveCompare($1.artistLine) == .orderedAscending }
        case .random:
            var g = HomeSeededGenerator(seed: seed)
            hits.shuffle(using: &g)
        }
        return list.limit > 0 ? Array(hits.prefix(list.limit)) : hits
    }

    /// A plain sentence for the list's rules, for a subtitle ("Language contains Telugu and Times played at least 3").
    static func summary(_ list: MusicSmartPlaylist) -> String {
        let parts = list.conditions.filter(isComplete).map { c -> String in
            c.field.kind == .flag ? "\(c.field.title): \(c.op.title)" : "\(c.field.title) \(c.op.title) \(c.value)"
        }
        return parts.joined(separator: list.match == .all ? " · " : " / ")
    }
}

/// The smart playlists on disk (`smartRules.json`). Observable so the Playlists tab redraws.
@MainActor @Observable
final class MusicSmartRuleBook {
    private(set) var lists: [MusicSmartPlaylist] { didSet { store.save(lists); revision &+= 1 } }
    private(set) var revision = 0
    @ObservationIgnored private let store: MusicJSONStore<[MusicSmartPlaylist]>

    init(directory: URL, debounce: Duration = .seconds(1)) {
        let s = MusicJSONStore<[MusicSmartPlaylist]>(url: directory.appendingPathComponent("smartRules.json"), debounce: debounce)
        let loaded = s.load() ?? []
        store = s
        lists = loaded
        MusicDebugLog.log("library", "smart playlists loaded: \(loaded.count)")
    }

    func list(id: UUID) -> MusicSmartPlaylist? { lists.first { $0.id == id } }

    /// Adds a new list or replaces the one with the same id.
    func save(_ list: MusicSmartPlaylist) {
        var l = list
        l.name = l.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if l.name.isEmpty { l.name = Localized.string("Smart playlist") }
        if let i = lists.firstIndex(where: { $0.id == l.id }) { lists[i] = l } else { lists.append(l) }
    }

    func duplicate(_ id: UUID) {
        guard let src = list(id: id) else { return }
        var copy = src
        copy.id = UUID(); copy.created = Date(); copy.name = Localized.string("%@ copy", src.name)
        copy.conditions = src.conditions.map { var c = $0; c.id = UUID(); return c }
        lists.append(copy)
    }

    func delete(_ id: UUID) { lists.removeAll { $0.id == id } }
    func flush() { store.flush() }
}
