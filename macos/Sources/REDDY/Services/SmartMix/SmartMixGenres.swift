import Foundation

/// Genre shelves ("Top Thriller", "Top Science Fiction", ...): the data table, the matching rule and the choice of which shelves Home shows today.
/// Pure and integer-only, like the rest of Smart Mix. Contract: docs/SMART-MIX.md ("Genre shelves") and smartmix/fixtures/genre-shelves.json.
enum SMGenreScope: String, Sendable { case both, movie, series }

struct SMGenreDef: Sendable {
    let key: String
    /// Shelf title (English; localised by the app from the same text).
    let title: String
    let scope: SMGenreScope
    /// Normalised phrases (see `SMGenres.norm`). A title matches when one of its genre tokens equals a phrase or contains it as whole words.
    let aliases: [String]
    /// TMDB genre ids and names, for the record: the library stores the genre as text, so the names are in `aliases`.
    let tmdbMovie: [Int]
    let tmdbTV: [Int]
    /// Shown for a Kids profile.
    let kidsSafe: Bool
    /// SQL LIKE patterns the adapter uses to widen the candidate pool (a superset of the match; the engine decides).
    let like: [String]
    /// TMDB `with_original_language` for the genre lists (anime = Japanese animation).
    let tmdbLang: String?
    /// "Thriller" for "Top Thriller".
    var name: String { String(title.dropFirst(4)) }
    /// Words for a library search by genre (`like` without the wildcards).
    var words: [String] { like.map { $0.replacingOccurrences(of: "%", with: "") } }
}

enum SMGenres {
    static let minTitles = 8          // a shelf needs at least this many titles
    static let maxShown = 6           // genre shelves on Home at once
    static let maxFromAffinity = 3    // of those, at most this many are the genres watched most
    static let shelfSize = 14
    static let rankBucket = 3         // TMDB ranks closer than this are shuffled together (day-seeded)
    static let poolPerGenre = 60      // adapter: best-rated titles kept per genre per kind

    static let shelfPrefix = "genre:"
    static func shelfId(_ key: String) -> String { shelfPrefix + key }

    private static func d(_ key: String, _ title: String, scope: SMGenreScope = .both, _ aliases: [String], movie: [Int] = [], tv: [Int] = [], kids: Bool = false, like: [String]? = nil, lang: String? = nil) -> SMGenreDef {
        SMGenreDef(key: key, title: title, scope: scope, aliases: aliases, tmdbMovie: movie, tmdbTV: tv, kidsSafe: kids, like: like ?? aliases.map { "%" + $0 + "%" }, tmdbLang: lang)
    }

    /// Stable default order = how much people browse each genre on the big services (Action, Comedy, Drama first). TMDB ids: movie list and TV list.
    static let table: [SMGenreDef] = [
        d("action", "Top Action", ["action", "action adventure" ], movie: [28], tv: [10759]),
        d("comedy", "Top Comedy", ["comedy", "comedies", "sitcom"], movie: [35], tv: [35], kids: true),
        d("drama", "Top Drama", ["drama", "dramas"], movie: [18], tv: [18]),
        d("thriller", "Top Thriller", ["thriller", "thrillers", "suspense"], movie: [53]),
        d("scifi", "Top Science Fiction", ["science fiction", "sci fi", "scifi", "sci fi fantasy"], movie: [878], tv: [10765], like: ["%science fiction%", "%sci-fi%", "%sci fi%", "%scifi%"]),
        d("horror", "Top Horror", ["horror"], movie: [27]),
        d("romance", "Top Romance", ["romance", "romantic", "romcom"], movie: [10749]),
        d("crime", "Top Crime", ["crime", "gangster"], movie: [80], tv: [80]),
        d("animation", "Top Animation", ["animation", "animated", "cartoon"], movie: [16], tv: [16], kids: true),
        d("documentary", "Top Documentary", ["documentary", "documentaries", "docuseries"], movie: [99], tv: [99]),
        d("family", "Top Family", ["family"], movie: [10751], tv: [10751], kids: true),
        d("fantasy", "Top Fantasy", ["fantasy", "sci fi fantasy"], movie: [14], tv: [10765], kids: true),
        d("mystery", "Top Mystery", ["mystery", "whodunit"], movie: [9648], tv: [9648]),
        d("adventure", "Top Adventure", ["adventure", "action adventure"], movie: [12], tv: [10759], kids: true),
        d("war", "Top War", ["war", "war politics", "military"], movie: [10752], tv: [10768]),
        d("western", "Top Western", ["western"], movie: [37], tv: [37]),
        d("history", "Top History", ["history", "historical"], movie: [36]),
        d("music", "Top Music", ["music", "musical", "concert"], movie: [10402], kids: true),
        d("biography", "Top Biography", ["biography", "biographical", "biopic"]),   // no TMDB genre: local ranking only
        d("kids", "Top Kids", ["kids", "children", "childrens"], tv: [10762], kids: true),
        d("anime", "Top Anime", ["anime"], movie: [16], tv: [16], lang: "ja"),
        d("reality", "Top Reality", scope: .series, ["reality", "reality tv"], tv: [10764]),
    ]

    static let byKey: [String: SMGenreDef] = Dictionary(uniqueKeysWithValues: table.map { ($0.key, $0) })

    // MARK: text

    /// Lowercase, every run of non-letters/digits becomes one space, trimmed ("Sci-Fi & Fantasy" -> "sci fi fantasy").
    static func norm(_ s: String) -> String {
        var out = "", pendingSpace = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { if pendingSpace && !out.isEmpty { out.append(" ") }; pendingSpace = false; out.append(ch) } else { pendingSpace = true }
        }
        return out
    }

    /// The provider's genre text split into normalised tokens: separators are , / | ; (an "&" or "-" stays inside a token).
    static func tokens(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var out: [String] = []
        for part in raw.split(whereSeparator: { ",/|;".contains($0) }) {
            let n = norm(String(part))
            if !n.isEmpty, !out.contains(n) { out.append(n) }
        }
        return out
    }

    static func tokenMatches(_ token: String, _ alias: String) -> Bool { token == alias || (" " + token + " ").contains(" " + alias + " ") }

    static func matches(_ def: SMGenreDef, genres: [String], kind: SMKind) -> Bool {
        switch def.scope { case .movie where kind != .movie, .series where kind != .series: return false; default: break }
        for t in genres { for a in def.aliases where tokenMatches(t, a) { return true } }
        return false
    }

    /// Genre keys a title with these tokens belongs to, in table order.
    static func keys(genres: [String], kind: SMKind) -> [String] { table.filter { matches($0, genres: genres, kind: kind) }.map(\.key) }

    // MARK: choice of today's shelves

    /// `counts` = eligible titles per genre key (`SmartMixEngine.genreCounts`). Genres with fewer than `minTitles` never show; a Kids profile only sees `kidsSafe` genres.
    /// Up to 3 are the genres this profile watched most (in that order), the rest follow the table order rotated by a seeded start (profile, day, refresh counter), so each day differs.
    static func select(counts: [String: Int], ctx: SMContext) -> [String] {
        let eligible = Set(table.filter { (counts[$0.key] ?? 0) >= minTitles && (!ctx.kids || $0.kidsSafe) }.map(\.key))
        var chosen: [String] = []
        for k in ctx.affinity.genreKeys where eligible.contains(k) && !chosen.contains(k) {
            chosen.append(k)
            if chosen.count == maxFromAffinity { break }
        }
        let rest = table.map(\.key).filter { eligible.contains($0) && !chosen.contains($0) }
        if !rest.isEmpty, chosen.count < maxShown {
            var rng = SplitMix64(seed: SmartMixPRNG.seed(profile: ctx.profile, shelf: SMShelf.genresAuto, day: ctx.dayKey, counter: ctx.refreshCounter))
            let off = Int(rng.uniform(UInt64(rest.count)))
            chosen += Array((rest[off...] + rest[..<off]).prefix(maxShown - chosen.count))
        }
        return chosen
    }
}

/// Where the genre shelves sit among the personalised rows on Home (docs/SMART-MIX.md, "Placement"). Pure.
enum SMPlacement {
    /// "G" = the next genre shelf. A row that is not present is skipped. At most 2 genre shelves in a row; a genre shelf that does not fit is dropped.
    static let template = ["top-week", "trending", "G", "for-you", "G", "G", "lang-pref", "G", "rediscover", "G", "G"]
    static let maxRun = 2

    /// `present`: ids of the personalised rows that have titles. `genres`: genre shelf ids in the order chosen. Returns every shelf id in display order.
    static func order(present: Set<String>, genres: [String]) -> [String] {
        var out: [String] = [], queue = genres[...], run = 0
        for token in template {
            if token == "G" {
                if run < maxRun, let g = queue.first { out.append(g); queue = queue.dropFirst(); run += 1 }
            } else if present.contains(token) { out.append(token); run = 0 }
        }
        return out
    }
}

/// The remembered view of a ranked shelf, per profile and shelf. Absent = `.weekly`; `.weekly` removes the entry.
enum SMShelfModes {
    static func key(profile: String, shelf: String) -> String { "smartmix.mode.\(profile).\(shelf)" }
    static func get(_ d: UserDefaults, profile: String, shelf: String) -> SMShelfMode { d.string(forKey: key(profile: profile, shelf: shelf)).flatMap(SMShelfMode.init(rawValue:)) ?? .weekly }
    static func set(_ d: UserDefaults, _ mode: SMShelfMode, profile: String, shelf: String) {
        if mode == .weekly { d.removeObject(forKey: key(profile: profile, shelf: shelf)) } else { d.set(mode.rawValue, forKey: key(profile: profile, shelf: shelf)) }
    }
}
