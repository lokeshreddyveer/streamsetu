import Foundation

// Smart playlists made locally from the plays table: Recently added, Never played, Forgotten favourites and On Repeat. Pure: a list of songs with their
// dates and play times in, ordered song ids out. Nothing is stored; the lists are rebuilt on open, so they never go stale and never evict anything.

struct MusicSmartSong: Hashable, Sendable {
    var uid: String
    var addedAt: Date?
    /// Every recorded play (a play counts after the minimum listen the stats rules set).
    var plays: [Date]
    var liked: Bool
    /// A file from this Mac's own folders: left out of On Repeat (the reference behaviour) and offered everywhere else.
    var isLocal: Bool
    /// Position in a newest-first list when the library stores no date (liked songs are kept newest first): the stand-in for `addedAt`.
    var order: Int?
    init(uid: String, addedAt: Date? = nil, plays: [Date] = [], liked: Bool = false, isLocal: Bool = false, order: Int? = nil) {
        self.uid = uid; self.addedAt = addedAt; self.plays = plays; self.liked = liked; self.isLocal = isLocal; self.order = order
    }
    var lastPlayed: Date? { plays.max() }
}

enum MusicSmartKind: String, CaseIterable, Sendable, Hashable {
    case onRepeat, recentlyAdded, neverPlayed, forgottenFavourites
    /// Added for the Library checklist: the all-time top plays, and what was played last.
    case mostPlayed, recentlyPlayed

    var title: String {
        switch self {
        case .onRepeat: "On Repeat"
        case .recentlyAdded: "Recently added"
        case .neverPlayed: "Never played"
        case .forgottenFavourites: "Forgotten favourites"
        case .mostPlayed: "Most played"
        case .recentlyPlayed: "Recently played"
        }
    }
    /// One honest line for the list's header.
    var reason: String {
        switch self {
        case .onRepeat: "The songs you played most in the last 30 days"
        case .recentlyAdded: "What you added to your library lately, newest first"
        case .neverPlayed: "Saved songs you have not played yet"
        case .forgottenFavourites: "Songs you liked or played often, not played for 90 days"
        case .mostPlayed: "The songs you played most, over all your history"
        case .recentlyPlayed: "What you played last, newest first"
        }
    }
}

struct MusicSmartList: Hashable, Sendable, Identifiable {
    var kind: MusicSmartKind
    var songs: [String]
    var id: String { kind.rawValue }
}

enum MusicSmartPlaylists {
    /// A list is offered only with at least this many songs (On Repeat as a shortcut at 5 or more).
    static let minimum = 5
    static let onRepeatLimit = 20
    static let onRepeatDays = 30
    static let recentDays = 30
    static let forgottenDays = 90
    static let listLimit = 200
    static let undatedRecent = 30
    /// Most played: up to this many songs, each played at least `mostPlayedMinPlays` times (one play is not a favourite).
    static let mostPlayedLimit = 50
    static let mostPlayedMinPlays = 2
    static let recentlyPlayedLimit = 500

    /// The top songs by plays over the whole history, ties broken by the later last play, then by id so the order never shuffles.
    static func mostPlayed(_ songs: [MusicSmartSong]) -> [String] {
        songs.filter { $0.plays.count >= mostPlayedMinPlays }.sorted { a, b in
            if a.plays.count != b.plays.count { return a.plays.count > b.plays.count }
            let x = a.lastPlayed ?? .distantPast, y = b.lastPlayed ?? .distantPast
            return x != y ? x > y : a.uid < b.uid
        }.prefix(mostPlayedLimit).map(\.uid)
    }

    /// Songs played at least once, the most recently played first.
    static func recentlyPlayed(_ songs: [MusicSmartSong]) -> [String] {
        songs.compactMap { s -> (String, Date)? in s.lastPlayed.map { (s.uid, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(recentlyPlayedLimit).map(\.0)
    }

    static func onRepeat(_ songs: [MusicSmartSong], now: Date = Date()) -> [String] {
        let since = now.addingTimeInterval(-Double(onRepeatDays) * 86_400)
        let counted: [(uid: String, n: Int, last: Date)] = songs.filter { !$0.isLocal }.compactMap { s in
            let recent = s.plays.filter { $0 >= since && $0 <= now }
            guard let last = recent.max() else { return nil }
            return (s.uid, recent.count, last)
        }
        return counted.sorted { a, b in a.n != b.n ? a.n > b.n : (a.last != b.last ? a.last > b.last : a.uid < b.uid) }.prefix(onRepeatLimit).map(\.uid)
    }

    static func recentlyAdded(_ songs: [MusicSmartSong], now: Date = Date()) -> [String] {
        let since = now.addingTimeInterval(-Double(recentDays) * 86_400)
        let dated = songs.compactMap { s -> (String, Date)? in guard let a = s.addedAt, a >= since, a <= now else { return nil }; return (s.uid, a) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
        // no stored date: the newest 30 of a newest-first list stand in
        let undated = songs.filter { $0.addedAt == nil && ($0.order ?? Int.max) < undatedRecent }.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.uid)
        return Array((dated + undated).prefix(listLimit))
    }

    static func neverPlayed(_ songs: [MusicSmartSong]) -> [String] {
        songs.filter { $0.plays.isEmpty }.sorted { ($0.addedAt ?? .distantPast) != ($1.addedAt ?? .distantPast) ? ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) : $0.uid < $1.uid }
            .prefix(listLimit).map(\.uid)
    }

    /// Liked, or played at least three times ever, but not played in the last `forgottenDays` (and played at least once, so it differs from Never played).
    static func forgottenFavourites(_ songs: [MusicSmartSong], now: Date = Date()) -> [String] {
        let before = now.addingTimeInterval(-Double(forgottenDays) * 86_400)
        return songs.compactMap { s -> (String, Int, Date)? in
            guard let last = s.lastPlayed, last < before, s.liked || s.plays.count >= 3 else { return nil }
            return (s.uid, s.plays.count, last)
        }.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : (a.2 != b.2 ? a.2 < b.2 : a.0 < b.0) }.prefix(listLimit).map(\.0)
    }

    static func lists(_ songs: [MusicSmartSong], now: Date = Date(), dismissed: Set<MusicSmartKind> = []) -> [MusicSmartList] {
        MusicSmartKind.allCases.compactMap { k in
            guard !dismissed.contains(k) else { return nil }
            let ids: [String]
            switch k {
            case .onRepeat: ids = onRepeat(songs, now: now)
            case .recentlyAdded: ids = recentlyAdded(songs, now: now)
            case .neverPlayed: ids = neverPlayed(songs)
            case .forgottenFavourites: ids = forgottenFavourites(songs, now: now)
            case .mostPlayed: ids = mostPlayed(songs)
            case .recentlyPlayed: ids = recentlyPlayed(songs)
            }
            return ids.count >= minimum ? MusicSmartList(kind: k, songs: ids) : nil
        }
    }
}
