import Foundation

/// The two views of a ranked shelf (Trending in Your Library and every genre shelf): this week's TMDB trending, or the best of all time.
enum SMShelfMode: String, Sendable, CaseIterable { case weekly, allTime }

enum SMKind: String, Sendable { case movie, series }

/// Shelf ids. `folder:<folderKey>` is built with `SMShelf.folder(_:)`.
enum SMShelf {
    static let hero = "hero"
    static let forYou = "for-you"                   // Because You Watched
    static let rediscover = "rediscover"
    static let langPref = "lang-pref"
    static let topWeek = "top-week"                 // Top This Week
    static let trendingLibrary = "trending-library" // Trending in Your Library
    static let all = [hero, topWeek, trendingLibrary, forYou, rediscover, langPref]
    // Home v2 rows (docs/SMART-MIX.md section 10). Not part of `all`: the coordinator asks for them next to it.
    static let fresh = "fresh"                      // Fresh Additions
    static let movieNight = "movie-night"           // Movie Night (Fri/Sat evenings)
    static let binge = "binge"                      // Binge-Worthy Series (weekends)
    static let collections = "collections"          // franchise tiles
    static let moodPrefix = "mood:"
    static func mood(_ key: String) -> String { moodPrefix + key }
    static func isMood(_ id: String) -> Bool { id.hasPrefix(moodPrefix) }
    static let contextual = [fresh, movieNight, binge, collections] + SMMoods.table.map { mood($0.key) }
    static func folder(_ key: String) -> String { "folder:" + key }
    static func isFolder(_ id: String) -> Bool { id.hasPrefix("folder:") }
    /// Asks the session for today's genre shelves (`genre:<key>`, see SmartMixGenres.swift); the result also carries `genres:index`.
    static let genresAuto = "genres:auto"
    static let genresIndex = "genres:index"
    static func isGenre(_ id: String) -> Bool { id.hasPrefix(SMGenres.shelfPrefix) }
}

/// One library item as the platform adapter hands it to the engine (no titles, no URLs: ids and keys only).
struct SMCandidate: Sendable {
    var id: String
    var kind: SMKind = .movie
    var key: String = ""            // identity key (canonical identity layer)
    var year: Int? = nil
    var added: Int? = nil           // days before today; nil = unknown / list position only
    var rating: String? = nil       // provider text, never trusted
    var q: Int = 2                  // quality rank 0...5
    var cam: Bool = false
    var lang: String? = nil
    var folder: String? = nil       // folderKey
    var franchise: String? = nil
    var genre: String? = nil
    /// Every genre token of the title, normalised (`SMGenres.tokens`); `genre` stays the first one.
    var genres: [String] = []
    var poster = true
    var backdrop = false
    var watched = false
    var completed = false
    var lastWatched: Int? = nil     // days ago
    var p7 = 0
    var p30 = 0
    var trend: Int? = nil           // TMDB rank, set by the matcher only
    var restricted = false          // locked / hidden / adult-Kids restricted (any twin copy makes the whole title restricted)
    var dismissed = false           // rec_dismissed marker (never Continue Watching)
    var src = 0                     // preferred-source rank, lower is better
    // Filled by SmartMixEngine.prepare:
    var camOnly = false

    init(id: String) { self.id = id }
}

struct SMAffinity: Sendable, Equatable {
    var topLangs: [String] = []
    var topFolders: [String] = []
    var topGenres: [String] = []
    var topDecades: [Int] = []
    /// Genre-shelf keys (`SMGenres.table`) of what was watched most lately, most watched first.
    var genreKeys: [String] = []
    init(topLangs: [String] = [], topFolders: [String] = [], topGenres: [String] = [], topDecades: [Int] = [], genreKeys: [String] = []) {
        self.topLangs = topLangs; self.topFolders = topFolders; self.topGenres = topGenres; self.topDecades = topDecades; self.genreKeys = genreKeys
    }
}

struct SMContext: Sendable {
    var profile: String
    var dayKey: String              // device-local calendar date "YYYY-MM-DD"
    var refreshCounter = 0
    var preferredLang: String? = nil
    var affinity = SMAffinity()
    /// Per shelf id; a shelf that is not listed is `.weekly`.
    var modes: [String: SMShelfMode] = [:]
    func mode(_ shelf: String) -> SMShelfMode { modes[shelf] ?? .weekly }
    var kids = false                // Kids profile: only kid-safe genre shelves
    var poolCap: Int? = nil         // degraded tiers (large / huge libraries) lower the pool
    /// Extra picks drawn after the normal ones (the first `size` picks are identical with or without it); Home composition trims, so a title removed from a row by the
    /// one-title-per-screen rule is replaced from the same draw. 0 in every shared fixture.
    var oversample = 0
    var nowYear: Int { Int(dayKey.prefix(4)) ?? 2026 }
    var loadKey: String { dayKey + "|" + String(refreshCounter) }
    init(profile: String, dayKey: String, refreshCounter: Int = 0, preferredLang: String? = nil, affinity: SMAffinity = SMAffinity(), poolCap: Int? = nil) {
        self.profile = profile; self.dayKey = dayKey; self.refreshCounter = refreshCounter
        self.preferredLang = preferredLang; self.affinity = affinity; self.poolCap = poolCap
    }
}

enum SMFallback: String, Sendable { case none, recentlyAdded, plainLibrary, existingFeatured }
enum SMCaption: String, Sendable { case none = "", trendingTMDB, mostWatchedHere }

/// Counts only. Never titles, ids of restricted items or URLs.
struct SMDiagnostics: Sendable, Equatable {
    var inCount = 0, groups = 0, restricted = 0, dismissed = 0, camOnly = 0, noArtwork = 0, watched = 0, lang = 0, notTrending = 0
    var pool = 0, drawn = 0, tier = 0
    var tiny = false, hidden = false, diversityRelaxed = false, trendMode = false
    var fallback = SMFallback.none
    var caption = SMCaption.none
    var tmdb = ""
}

struct SMPick: Sendable, Equatable {
    var id: String
    var key: String
    var year: Int?
    var kind: SMKind
    /// hero only: true when the card has a backdrop; false = poster composition tier.
    var hasBackdrop: Bool
    /// Taste metadata for composition (re-rank, exploration). Never leaves the device.
    var genre: String? = nil
    var genres: [String] = []
    var lang: String? = nil
    var franchise: String? = nil
}

/// One franchise tile of the Collections row: its display stem key, the member titles' representative ids (release order) and how many titles it has.
struct SMCollection: Sendable, Equatable {
    var key: String
    var memberIds: [String]
    var count: Int { memberIds.count }
}

struct SMShelfResult: Sendable {
    var shelfId: String
    var picks: [SMPick]
    var diag: SMDiagnostics
    var ids: [String] { picks.map(\.id) }
    /// `genres:index` only: eligible titles per genre key, and the keys chosen for today in shelf order.
    var genreCounts: [String: Int] = [:]
    var genreSelected: [String] = []
    /// `collections` only: the franchises, in tile order (`picks` holds each franchise's lead title).
    var collections: [SMCollection] = []
    /// True when the shelf must not be shown at all (lang-pref without a language / without matches).
    var isHidden: Bool { diag.hidden }
}
