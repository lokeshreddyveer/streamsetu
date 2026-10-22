import Foundation

/// Where a typed request can take the person.
enum CommandTarget: String, CaseIterable, Sendable {
    case discover, tonight, liveTV, movies, series, guide, favorites, watchLater, continueWatching, recentlyWatched, history, collections, statistics, downloads, settings

    var title: String {
        switch self {
        case .discover: "Discover"
        case .tonight: "Tonight"
        case .liveTV: "Live TV"
        case .movies: "Movies"
        case .series: "Series"
        case .guide: "TV Guide"
        case .favorites: "Favorites"
        case .watchLater: "Watch Later"
        case .continueWatching: "Continue Watching"
        case .recentlyWatched: "Recently Watched"
        case .history: "Watch History"
        case .collections: "Collections"
        case .statistics: "Statistics"
        case .downloads: "Downloads"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .discover: "sparkles.tv"
        case .tonight: "moon.stars"
        case .liveTV: "dot.radiowaves.left.and.right"
        case .movies: "film"
        case .series: "tv"
        case .guide: "calendar"
        case .favorites: "heart"
        case .watchLater: "bookmark"
        case .continueWatching: "play.circle"
        case .recentlyWatched: "clock.arrow.circlepath"
        case .history: "list.bullet"
        case .collections: "square.grid.2x2"
        case .statistics: "chart.bar"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }

    /// The words that name it. Longest first, so "watch history" is not read as "watch".
    static let synonyms: [(phrase: String, target: CommandTarget)] = [
        ("continue watching", .continueWatching), ("recently watched", .recentlyWatched), ("watch history", .history), ("watch later", .watchLater), ("tv guide", .guide), ("live tv", .liveTV), ("tv shows", .series), ("what's on tonight", .tonight), ("whats on tonight", .tonight),
        ("favourites", .favorites), ("favorites", .favorites), ("favs", .favorites), ("watchlist", .watchLater), ("saved", .watchLater), ("history", .history), ("recent", .recentlyWatched), ("guide", .guide), ("epg", .guide), ("schedule", .guide),
        ("channels", .liveTV), ("live", .liveTV), ("movies", .movies), ("films", .movies), ("series", .series), ("shows", .series), ("tonight", .tonight), ("collections", .collections), ("stats", .statistics), ("statistics", .statistics),
        ("downloads", .downloads), ("downloaded", .downloads), ("settings", .settings), ("preferences", .settings), ("home", .discover), ("discover", .discover),
    ]
}

/// Something the search box can do besides search.
struct SearchCommand: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Go to a screen. `library` is what to put in that screen's own search box (filters and ordering are read from it there).
        case go(CommandTarget, library: String?)
        case play(String)
        case resume
        case lastChannel
        case favourite(String, on: Bool)
        case watchLater(String, on: Bool)
    }

    let kind: Kind
    var id: String { title }

    var title: String {
        switch kind {
        case .go(let t, let q): q.map { "Open \(t.title): \($0)" } ?? "Go to \(t.title)"
        case .play(let n): "Play “\(n)”"
        case .resume: "Resume watching"
        case .lastChannel: "Play the last channel"
        case .favourite(let n, let on): on ? "Add “\(n)” to Favorites" : "Remove “\(n)” from Favorites"
        case .watchLater(let n, let on): on ? "Add “\(n)” to Watch Later" : "Remove “\(n)” from Watch Later"
        }
    }

    var symbol: String {
        switch kind {
        case .go(let t, _): t.symbol
        case .play, .resume: "play.fill"
        case .lastChannel: "dot.radiowaves.left.and.right"
        case .favourite: "heart"
        case .watchLater: "bookmark"
        }
    }
}

enum SearchCommands {
    private static let goVerbs = ["go to", "open", "show me", "show", "take me to", "switch to", "see", "view", "bring up", "my"]
    private static let playVerbs = ["play", "watch", "put on", "start", "stream"]

    /// What the typed words ask for, besides a search. Nothing here changes anything: each is a row the person chooses.
    static func parse(_ raw: String) -> [SearchCommand] {
        var t = raw.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".!?,;:".contains(last) { t.removeLast() }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count >= 3 else { return [] }
        var out: [SearchCommand] = []

        if ["resume", "resume playing", "resume watching", "carry on", "pick up where i left off", "continue where i left off", "continue playing"].contains(t) { return [.init(kind: .resume)] }
        if ["last channel", "previous channel", "play last channel", "play the last channel", "go to last channel", "back to the last channel"].contains(t) { return [.init(kind: .lastChannel)] }

        // "add X to favourites / watch later", "remove X from favourites"
        if let m = firstMatch(#"^(?:add|put|save|keep)\s+(.+?)\s+(?:to|in|into|on)\s+(?:my\s+)?(favou?rites?|favs|watch\s?later|watch\s?list)$"#, t) {
            return [.init(kind: list(m[2]) == .favorites ? .favourite(clean(m[1], raw), on: true) : .watchLater(clean(m[1], raw), on: true))]
        }
        if let m = firstMatch(#"^(?:remove|delete|take|drop)\s+(.+?)\s+from\s+(?:my\s+)?(favou?rites?|favs|watch\s?later|watch\s?list)$"#, t) {
            return [.init(kind: list(m[2]) == .favorites ? .favourite(clean(m[1], raw), on: false) : .watchLater(clean(m[1], raw), on: false))]
        }
        if let m = firstMatch(#"^(?:favou?rite|fav|like)\s+(.+)$"#, t) { return [.init(kind: .favourite(clean(m[1], raw), on: true))] }
        if let m = firstMatch(#"^(?:unfavou?rite|unfav)\s+(.+)$"#, t) { return [.init(kind: .favourite(clean(m[1], raw), on: false))] }

        // a screen, with or without filters and ordering for its own list
        if let go = destination(t) { out.append(.init(kind: go)) }

        // "play X" (but "watch later" is a screen, not a title)
        let namesAScreen = CommandTarget.synonyms.contains { $0.phrase == t }
        for v in playVerbs where !namesAScreen && t.hasPrefix(v + " ") {
            let rest = String(t.dropFirst(v.count + 1)).trimmingCharacters(in: .whitespaces)
            if rest.count >= 2, CommandTarget.synonyms.first(where: { $0.phrase == rest }) == nil, !["it", "something", "anything"].contains(rest) { out.append(.init(kind: .play(clean(rest, raw)))) }
            break
        }
        return out
    }

    // MARK: pieces

    /// "go to live tv" -> live TV; "top rated telugu movies" -> the Movies screen with "top rated telugu movies" in its search box.
    private static func destination(_ text: String) -> SearchCommand.Kind? {
        var t = text
        var hadVerb = false
        var stripped = true
        while stripped {          // "show me my favourites": more than one of these words can lead
            stripped = false
            for v in goVerbs where t.hasPrefix(v + " ") { t = String(t.dropFirst(v.count + 1)); hadVerb = true; stripped = true; break }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("the ") { t.removeFirst(4) }
        // the whole phrase names a screen
        if let s = CommandTarget.synonyms.first(where: { $0.phrase == t }) {
            // a lone "live" or "saved" or "recent" needs a verb, or it is an ordinary search
            if !hadVerb, ["live", "saved", "recent", "home", "channels", "shows"].contains(s.phrase) { return nil }
            return .go(s.target, library: nil)
        }
        // a list screen asked for with its own filters: "telugu movies unwatched", "top rated series", "movies with mahesh babu"
        for (phrase, target) in [("movies", CommandTarget.movies), ("films", .movies), ("series", .series), ("tv shows", .series), ("channels", .liveTV)] {
            let words = t.split(separator: " ").map(String.init)
            if words.contains(phrase.split(separator: " ").last.map(String.init) ?? phrase), words.count >= 2 {
                let q = NaturalQuery.parse(t)
                // Only what the screen's own search understands is put in its box: unexplained words ("today", "folder") would make it show "No matches".
                if q.isStructured { return .go(target, library: cleanedFilter(t)) }
                if hadVerb { return .go(target, library: nil) }
            }
        }
        return nil
    }

    /// The words of a filter that mean something to the library (a language, year, genre, ordering, "unwatched", a kind) with the rest dropped, and the kind itself kept.
    static func cleanedFilter(_ text: String) -> String {
        let noise: Set<String> = ["today", "now", "tonight", "folder", "folders", "section", "please", "me", "my", "the", "a", "an", "for", "in", "of", "to", "show", "open", "go", "see", "view", "with"]
        // words that order or narrow a list, understood by the library's own sentence reading (see NaturalQuery)
        let meaningful: Set<String> = ["top", "best", "highest", "rated", "newest", "latest", "oldest", "recent", "recently", "shortest", "longest", "first", "added", "unwatched", "unseen", "watched", "favourite", "favourites", "favorite", "favorites", "new",
                                       "movies", "movie", "films", "film", "series", "shows", "channels", "tv", "not", "no", "without", "a", "z", "to", "az", "za"]
        let keep = text.split(separator: " ").map(String.init).filter { w in
            if noise.contains(w), !(meaningful.contains(w) && w != "a" && w != "to") { return false }
            return meaningful.contains(w) || NaturalQuery.parse(w + " " + w).isStructured || w.allSatisfy(\.isNumber)
        }
        return keep.joined(separator: " ")
    }

    private static func list(_ word: String) -> CommandTarget { word.hasPrefix("fav") ? .favorites : .watchLater }

    /// The title as the person typed it (original capitals), taken from the same place in the original text.
    private static func clean(_ lowered: String, _ original: String) -> String {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = o.range(of: lowered, options: .caseInsensitive) { return String(o[r]) }
        return lowered
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}
