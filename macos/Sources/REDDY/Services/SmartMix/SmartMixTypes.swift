import Foundation

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
    static func folder(_ key: String) -> String { "folder:" + key }
    static func isFolder(_ id: String) -> Bool { id.hasPrefix("folder:") }
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
    init(topLangs: [String] = [], topFolders: [String] = [], topGenres: [String] = [], topDecades: [Int] = []) {
        self.topLangs = topLangs; self.topFolders = topFolders; self.topGenres = topGenres; self.topDecades = topDecades
    }
}

struct SMContext: Sendable {
    var profile: String
    var dayKey: String              // device-local calendar date "YYYY-MM-DD"
    var refreshCounter = 0
    var preferredLang: String? = nil
    var affinity = SMAffinity()
    var poolCap: Int? = nil         // degraded tiers (large / huge libraries) lower the pool
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
}

struct SMShelfResult: Sendable {
    var shelfId: String
    var picks: [SMPick]
    var diag: SMDiagnostics
    var ids: [String] { picks.map(\.id) }
    /// True when the shelf must not be shown at all (lang-pref without a language / without matches).
    var isHidden: Bool { diag.hidden }
}
