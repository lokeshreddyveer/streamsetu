import Foundation

/// What the person wants to watch, in parts that can be looked up. An AI (when one is chosen) turns their words into this; without one, the same parts are read from the words directly.
/// The answers never come from the AI's memory: they come from the library on this device (its cast index and filters) and, when a TMDB key is saved, from TMDB's real filmographies.
struct WatchIntent: Equatable, Sendable {
    enum Kind: String, Sendable { case any, movie, series }
    var people: [String] = []
    var genres: [String] = []
    var languages: [String] = []
    var year: Int?
    var decade: Int?
    var keywords: [String] = []
    var likeTitles: [String] = []
    var kind: Kind = .any
    var maxMinutes: Int?
    var minRating: Double?
    var unwatchedOnly = false
    /// Genres the person does not want ("not horror").
    var excludeGenres: [String] = []
    /// "Surprise me" or no particular wish: chosen from what the person usually watches.
    var surprise = false
    /// Names read from the words ("mahesh babu movies") that the cast index does not know. They are only used when TMDB confirms a person of that name.
    var guessedPeople: [String] = []

    var isEmpty: Bool { people.isEmpty && genres.isEmpty && languages.isEmpty && year == nil && decade == nil && keywords.isEmpty && likeTitles.isEmpty && maxMinutes == nil && minRating == nil && !unwatchedOnly && excludeGenres.isEmpty && !surprise }

    /// "with Mahesh Babu · Telugu · 2010s · under 2 h": what was understood, shown so the person can see it.
    var summary: [String] {
        var out: [String] = []
        out += people.map { "with \($0)" }
        out += languages
        out += genres
        if let year { out.append(String(year)) }
        if let decade { out.append("\(decade)s") }
        out += likeTitles.map { "like \($0)" }
        out += keywords
        if let maxMinutes { out.append("under " + (maxMinutes % 60 == 0 ? "\(maxMinutes / 60) h" : "\(maxMinutes) min")) }
        if let minRating { out.append("rated \(Int(minRating))+") }
        if unwatchedOnly { out.append("unwatched") }
        out += excludeGenres.map { "no \($0)" }
        if surprise { out.append("surprise me") }
        if kind != .any { out.append(kind == .movie ? "films" : "series") }
        return out
    }

    /// The parts the AI found, filled in with what the words alone gave (the AI wins where both have an answer).
    func merged(with ai: WatchIntent) -> WatchIntent {
        var r = self
        if !ai.people.isEmpty { r.people = ai.people }
        if !ai.genres.isEmpty { r.genres = ai.genres }
        if !ai.languages.isEmpty { r.languages = ai.languages }
        if ai.year != nil { r.year = ai.year; r.decade = nil }
        if ai.decade != nil && year == nil { r.decade = ai.decade }
        if !ai.keywords.isEmpty { r.keywords = ai.keywords }
        if !ai.likeTitles.isEmpty { r.likeTitles = ai.likeTitles }
        if ai.kind != .any { r.kind = ai.kind }
        if ai.maxMinutes != nil { r.maxMinutes = ai.maxMinutes }
        if ai.minRating != nil { r.minRating = ai.minRating }
        r.unwatchedOnly = r.unwatchedOnly || ai.unwatchedOnly
        if !ai.excludeGenres.isEmpty { r.excludeGenres = Array(Set(r.excludeGenres + ai.excludeGenres)) }
        r.surprise = r.surprise || ai.surprise
        if r.people.isEmpty == false { r.keywords = [] }
        return r
    }

    /// A refinement ("only unwatched", "shorter") laid over what was asked before: what it sets replaces, what it leaves alone stays.
    func refined(by new: WatchIntent) -> WatchIntent {
        var r = self
        if !new.people.isEmpty { r.people = new.people }
        if !new.genres.isEmpty { r.genres = new.genres }
        if !new.languages.isEmpty { r.languages = new.languages }
        if new.year != nil { r.year = new.year; r.decade = nil }
        if new.decade != nil { r.decade = new.decade; r.year = nil }
        if !new.keywords.isEmpty { r.keywords = new.keywords }
        if !new.likeTitles.isEmpty { r.likeTitles = new.likeTitles }
        if new.kind != .any { r.kind = new.kind }
        if new.maxMinutes != nil { r.maxMinutes = new.maxMinutes }
        if new.minRating != nil { r.minRating = new.minRating }
        if new.unwatchedOnly { r.unwatchedOnly = true }
        if !new.excludeGenres.isEmpty { r.excludeGenres = Array(Set(r.excludeGenres + new.excludeGenres)) }
        if new.surprise { r.surprise = true }
        return r
    }
}

/// One title that fits, and why.
struct AskResult: Identifiable, Equatable, Sendable {
    let item: LibraryItem
    var reasons: [String]
    var score: Double
    var watched: Bool
    var id: String { item.id }
    static func == (a: AskResult, b: AskResult) -> Bool { a.item.id == b.item.id && a.reasons == b.reasons && a.score == b.score }
}

struct AskAnswer: Sendable {
    var intent: WatchIntent
    var results: [AskResult] = []
    /// Titles TMDB says the person has been in that are not in the library. They are real, but not here.
    var elsewhere: [String] = []
    /// How much of the library's cast has been read, for a person search (0 to 1), so a thin answer can be explained.
    var castCoverage: Double = 1
    var usedTMDB = false
    /// The chosen AI picked and explained the first few.
    var judged = false
    var note: String = ""
}

// MARK: - understanding the words without an AI

enum LocalIntent {
    /// Words that carry the sense of a request and are never a person's name.
    private static let stop: Set<String> = ["a", "an", "the", "with", "starring", "actor", "actress", "director", "directed", "by", "movies", "movie", "films", "film", "series", "show", "shows", "of", "from", "like", "something", "any", "good", "best", "new", "old", "latest",
                                            "watch", "want", "to", "in", "and", "or", "for", "me", "my", "i", "some", "that", "has", "have", "about", "tonight", "feel", "feeling", "light", "tense", "funny", "scary", "thriller", "action", "comedy", "drama", "romance", "horror", "family", "kids"]

    static let genreWords: [String: String] = ["thriller": "Thriller", "thrillers": "Thriller", "action": "Action", "comedy": "Comedy", "funny": "Comedy", "drama": "Drama", "romance": "Romance", "romantic": "Romance", "horror": "Horror", "scary": "Horror",
                                               "sci-fi": "Sci-Fi", "scifi": "Sci-Fi", "fantasy": "Fantasy", "crime": "Crime", "mystery": "Mystery", "animation": "Animation", "animated": "Animation", "documentary": "Documentary", "family": "Family", "adventure": "Adventure", "war": "War", "history": "History", "musical": "Music"]

    /// Words that describe how to order or narrow a list, never a person's name ("top rated series", "newest movies", "good films").
    private static let notNameWords: Set<String> = ["top", "rated", "best", "highest", "worst", "lowest", "newest", "latest", "oldest", "popular", "new", "old", "good", "great", "nice", "recent", "recently", "unwatched", "watched", "favourite", "favourites",
                                                    "favorite", "favorites", "short", "long", "free", "hd", "uhd", "dubbed", "random", "classic", "cheap", "scary", "funny", "family", "kids", "live", "all", "every", "more", "most", "some", "any"]
    private static let kindWords: Set<String> = ["movies", "movie", "films", "film", "series", "show", "shows", "serials", "serial"]

    /// "mahesh babu movies": two or three plain words in front of "movies" or "series" are probably a person the cast index has not read yet.
    private static func guessPerson(_ words: [String]) -> String? {
        guard let k = words.lastIndex(where: { kindWords.contains($0) }), k >= 1 else { return nil }
        var name: [String] = []
        var i = k - 1
        while i >= 0, name.count < 3, !stop.contains(words[i]), !notNameWords.contains(words[i]), genreWords[words[i]] == nil, words[i].count >= 2, words[i].allSatisfy({ $0.isLetter || $0 == "." }),
              !NaturalQuery.parse(words[i]).isStructured, !LanguageTags.known.map({ $0.lowercased() }).contains(words[i]) {
            name.insert(words[i], at: 0); i -= 1
        }
        let moodWords = Set(MoodVocabulary.rules.flatMap { $0.phrases }.flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) })
        guard name.count >= 2 ? name.allSatisfy({ $0.count >= 3 }) : (name.first.map { $0.count >= 5 && !moodWords.contains($0) } ?? false) else { return nil }
        return name.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Reads language, year, length and the like with the sentence parser, genres from known words, and a person's name by looking for a run of words in the cast index.
    static func parse(_ raw: String, hasPerson: (String) -> String?) -> WatchIntent {
        var intent = WatchIntent()
        let q = NaturalQuery.parse(raw)
        if let l = q.language { intent.languages = [l] }
        intent.year = q.year; intent.decade = q.decade; intent.maxMinutes = q.maxMinutes; intent.minRating = q.minRating; intent.unwatchedOnly = q.unwatched
        let lower = raw.lowercased()
        let words = lower.replacingOccurrences(of: "’", with: "'").split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") }).map(String.init)
        var seen = Set<String>()
        for w in words { if let g = genreWords[w], seen.insert(g).inserted { intent.genres.append(g) } }
        // "not horror", "no romance", "without comedy": genres to leave out (and they are not asked for).
        for (i, w) in words.enumerated() where i > 0 && ["not", "no", "without", "except", "avoid"].contains(words[i - 1]) {
            if let g = genreWords[w] { intent.excludeGenres.append(g); intent.genres.removeAll { $0 == g } }
        }
        intent.excludeGenres = Array(Set(intent.excludeGenres))
        let moodWords = MoodVocabulary.apply(to: &intent, lower: lower, words: words)
        if intent.people.isEmpty, let g = guessPerson(words) { intent.people = [g]; intent.guessedPeople = [g] }
        if ["surprise me", "anything", "i don't know", "i dont know", "recommend", "something good", "what should i watch", "what to watch", "decide for me"].contains(where: { lower.contains($0) }) { intent.surprise = true }
        if lower.contains(" series") || lower.hasPrefix("series") || lower.contains(" shows") { intent.kind = .series }
        else if lower.contains("movie") || lower.contains("film") { intent.kind = .movie }
        // A person: the longest run of words (up to three) that the cast index knows.
        let candidates = words.enumerated().filter { !stop.contains($0.element) && !NaturalQuery.parse($0.element).isStructured && $0.element.count >= 3 && !$0.element.allSatisfy(\.isNumber) && !LanguageTags.known.map({ $0.lowercased() }).contains($0.element) }
        var used = Set<Int>()
        for size in stride(from: 3, through: 1, by: -1) {
            var i = 0
            while i + size <= words.count {
                let range = i..<(i + size)
                if range.allSatisfy({ !stop.contains(words[$0]) && words[$0].count >= 3 && !used.contains($0) && candidates.contains(where: { $0.offset == $0.offset && $0.offset == $0.offset }) }),
                   let name = hasPerson(words[range].joined(separator: " ")) {
                    intent.people.append(name); used.formUnion(range); i += size
                } else { i += 1 }
            }
        }
        // What is left, apart from the words the parts already explain, is looked for in titles.
        let explained = moodWords.union(intent.people.flatMap { $0.lowercased().split(separator: " ").map(String.init) } + intent.genres.map { $0.lowercased() } + Array(genreWords.keys))
        let rest = words.filter { !stop.contains($0) && !notNameWords.contains($0) && !explained.contains($0) && !$0.allSatisfy(\.isNumber) && $0.count >= 3 && !LanguageTags.known.map({ $0.lowercased() }).contains($0) && !NaturalQuery.parse($0).isStructured }
        let noNegatives = Set(intent.excludeGenres.map { $0.lowercased() })
        let themeWords = rest.filter { !noNegatives.contains($0) && !["not", "no", "without", "except", "avoid", "surprise", "anything", "recommend", "decide", "something", "tonight", "what", "should", "watch", "dont", "know"].contains($0) }
        if intent.people.isEmpty, intent.genres.isEmpty, intent.languages.isEmpty, intent.year == nil, intent.decade == nil, !themeWords.isEmpty { intent.keywords = Array(themeWords.prefix(4)) }
        return intent
    }
}

// MARK: - the AI's reading of the words

enum IntentAdvisor {
    static let system = """
    You turn a request for something to watch into search parts. Reply with JSON only, no other text, shaped like:
    {"people": [], "genres": [], "languages": [], "year": null, "decade": null, "keywords": [], "like": [], "kind": "any", "maxMinutes": null, "minRating": null, "unwatched": false, "exclude": [], "surprise": false}
    "people": names of actors or directors the request names (full names, correctly spelled). "genres": from Action, Adventure, Animation, Comedy, Crime, Documentary, Drama, Family, Fantasy, History, Horror, Music, Mystery, Romance, Sci-Fi, Thriller, War.
    "languages": such as Telugu, Hindi, Tamil, English. "like": titles the request says it wants more like. "keywords": at most three words about the theme or mood. "kind": "movie", "series" or "any".
    "exclude": genres they do not want. "surprise": true when they leave the choice to you. "keywords": the mood or theme in a few plain words (such as "feel-good heist" or "slow-burn mystery").
    Use null or an empty list for anything the request does not say. Never add a film or series of your own.
    """

    /// What is said about what came before, for "make it shorter" style follow-ups.
    static func prompt(_ request: String, previous: WatchIntent?) -> String {
        var p = "Request: " + request.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previous, !previous.isEmpty { p += "\nThis follows an earlier request that was understood as: " + previous.summary.joined(separator: ", ") + ". Reply with only the parts this new request changes or adds." }
        return p
    }

    static func parse(_ answer: String) -> WatchIntent? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func strings(_ k: String) -> [String] { ((j[k] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        var i = WatchIntent()
        i.people = Array(strings("people").prefix(3)); i.genres = Array(strings("genres").prefix(3)); i.languages = Array(strings("languages").prefix(2))
        i.keywords = Array(strings("keywords").prefix(3)); i.likeTitles = Array(strings("like").prefix(2))
        i.year = (j["year"] as? Int).flatMap { (1900...2100).contains($0) ? $0 : nil }
        i.decade = (j["decade"] as? Int).flatMap { (1900...2090).contains($0) ? $0 : nil }
        i.kind = WatchIntent.Kind(rawValue: (j["kind"] as? String ?? "any").lowercased()) ?? .any
        i.maxMinutes = (j["maxMinutes"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        i.minRating = (j["minRating"] as? Double) ?? (j["minRating"] as? Int).map(Double.init)
        i.unwatchedOnly = (j["unwatched"] as? Bool) ?? false
        i.excludeGenres = Array(strings("exclude").prefix(3)); i.surprise = (j["surprise"] as? Bool) ?? false
        return i.isEmpty ? nil : i
    }
}

// MARK: - finding the answers

/// Looks things up in the library on this device. Nothing here is sent anywhere.
struct AskLibrary: @unchecked Sendable {
    let catalog: CatalogRepository
    let people: PeopleIndex
    let history: HistoryRepository
    /// Optional: a real filmography for a person, from TMDB. Titles and years, most popular first.
    var filmography: (@Sendable (String) async -> TMDBFilmography?)?
    /// Optional: what the person usually watches, to rank by.
    var taste: TasteProfile?
    /// Optional: the chosen AI, asked to pick the best of the real candidates. Takes the system text and the prompt, returns the answer.
    var judge: (@Sendable (String, String) async -> String?)?
    /// The person's own words, shown to the judge.
    var request = ""
    var semantic = SemanticMatcher()

    struct TMDBFilmography: Sendable { let name: String; let credits: [(title: String, year: Int?, isShow: Bool)] }

    func answer(_ intent: WatchIntent) async -> AskAnswer {
        var out = AskAnswer(intent: intent)
        var pool: [String: (item: LibraryItem, reasons: [String], score: Double)] = [:]
        func add(_ item: LibraryItem, _ reason: String, _ score: Double) {
            var e = pool[item.id] ?? (item, [], 0)
            if !e.reasons.contains(reason) { e.reasons.append(reason) }
            e.score += score; pool[item.id] = e
        }
        let kinds: Set<ContentKind> = intent.kind == .movie ? [.movie] : intent.kind == .series ? [.series] : [.movie, .series]
        let progress = people.progress()
        out.castCoverage = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 1

        // People: the cast index first (exact), then TMDB's filmography for anyone it has not read yet.
        var tmdbCredits: [(String, Int?, Bool)] = []
        for name in intent.people {
            for hit in people.hits(term: name, kinds: kinds, sourceID: nil, limit: 200) {
                if let item = item(hit.itemID, hit.kind) { add(item, "With \(name)", 4) }
            }
            if let film = await filmography?(name) {
                if intent.guessedPeople.contains(name) {
                    let want = Set(MetadataNormalizer.normalize(name).split(separator: " ")), got = Set(MetadataNormalizer.normalize(film.name).split(separator: " "))
                    if !want.isSubset(of: got) { continue }          // TMDB found somebody else: a guess is only used when it is the same name
                }
                out.usedTMDB = true
                tmdbCredits += film.credits.map { ($0.title, $0.year, $0.isShow) }
                for c in film.credits where (c.isShow ? kinds.contains(.series) : kinds.contains(.movie)) {
                    if let item = match(title: c.title, year: c.year, isShow: c.isShow) { add(item, "With \(name)", 4) }
                }
            }
        }
        // More like these titles.
        if !intent.likeTitles.isEmpty {
            let similar = SimilarService(catalog: catalog)
            for t in intent.likeTitles {
                guard let seed = match(title: t, year: nil, isShow: false) ?? match(title: t, year: nil, isShow: true) else { continue }
                for s in similar.suggestions(for: seed, extras: nil).prefix(30) where s.item.id != seed.id { add(s.item, "Like \(t) · \(s.reason)", 2.5) }
            }
        }
        // The library's own filters, with the people (if any) as the starting set.
        let hasFilters = !intent.languages.isEmpty || intent.year != nil || intent.decade != nil || intent.maxMinutes != nil || intent.minRating != nil
        let startSet: Set<String>? = (!intent.people.isEmpty || !intent.likeTitles.isEmpty) ? Set(pool.keys) : nil
        // Asked for somebody's films (or titles like some others) and none were found: the filters alone must not fill the answer with unrelated titles.
        let nothingFromPeople = startSet?.isEmpty == true
        if !nothingFromPeople, startSet == nil || hasFilters || !intent.keywords.isEmpty || !intent.genres.isEmpty {
            var q = VODQuery(); q.sort = .rating
            q.language = intent.languages.first; q.year = intent.year; q.decade = intent.decade; q.maxMinutes = intent.maxMinutes; q.minRating = intent.minRating
            if !intent.keywords.isEmpty { q.search = intent.keywords.joined(separator: " ") }
            if let startSet { q.ids = Array(startSet) } else { q.limit = 120 }
            var found: [LibraryItem] = []
            if kinds.contains(.movie) { found += ((try? catalog.movies(q)) ?? []).map { .movie($0) } }
            if kinds.contains(.series), intent.maxMinutes == nil { found += ((try? catalog.series(q)) ?? []).map { .series($0) } }
            if let startSet { pool = pool.filter { id, _ in found.contains { $0.id == id } || (!hasFilters && intent.keywords.isEmpty && startSet.contains(id)) } }
            else { for item in found { add(item, "Matches your words", 0.5) } }
        }
        // Meaning: a mood or theme ("feel-good heist") is matched against each title's genre and plot, not just its name.
        if !nothingFromPeople, !intent.keywords.isEmpty, semantic.isAvailable {
            let idea = intent.keywords.joined(separator: " ")
            var q = VODQuery(); q.sort = .rating; q.limit = 400
            q.language = intent.languages.first; q.year = intent.year; q.decade = intent.decade; q.maxMinutes = intent.maxMinutes; q.minRating = intent.minRating
            var broad: [LibraryItem] = []
            if kinds.contains(.movie) { broad += ((try? catalog.movies(q)) ?? []).map { .movie($0) } }
            if kinds.contains(.series), intent.maxMinutes == nil { broad += ((try? catalog.series(q)) ?? []).map { .series($0) } }
            let fits = semantic.rank(idea: idea, texts: broad.map { ($0.title, $0.genre, $0.overview) })
            let scored = zip(broad, fits).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            for (item, fit) in scored.prefix(40) { add(item, "Fits “\(idea)”", 1 + fit * 3) }
        }
        // Surprise me, or no wish at all: what the person usually watches, best rated first.
        if !nothingFromPeople, intent.surprise || (intent.isEmpty && pool.isEmpty) {
            var q = VODQuery(); q.sort = .rating; q.limit = 300; q.minRating = intent.minRating ?? 6.5
            var broad: [LibraryItem] = []
            if kinds.contains(.movie) { broad += ((try? catalog.movies(q)) ?? []).map { .movie($0) } }
            if kinds.contains(.series) { broad += ((try? catalog.series(q)) ?? []).map { .series($0) } }
            for item in broad { add(item, "Well rated", 0.3) }
        }
        // Genres: matched against the title's genre and folder; if nothing matches any, the genre is left out rather than emptying the answer.
        if !intent.genres.isEmpty {
            let wanted = intent.genres.map { $0.lowercased() }
            func genreText(_ i: LibraryItem) -> String { ((i.genre ?? "") + " " + (i.categoryName ?? "")).lowercased() }
            let matching = pool.filter { _, e in wanted.contains { genreText(e.item).contains($0) } }
            if !matching.isEmpty { pool = matching; for k in pool.keys { for g in intent.genres where genreText(pool[k]!.item).contains(g.lowercased()) { add(pool[k]!.item, g, 1.5) } } }
        }
        for l in intent.languages { for k in pool.keys { add(pool[k]!.item, l, 0.5) } }

        // Genres the person does not want.
        if !intent.excludeGenres.isEmpty {
            let banned = intent.excludeGenres.map { $0.lowercased() }
            pool = pool.filter { _, e in let t = ((e.item.genre ?? "") + " " + (e.item.categoryName ?? "")).lowercased(); return !banned.contains { t.contains($0) } }
        }
        // What the person usually watches nudges the order, and says why.
        var tasteWhy: [String: String] = [:]
        if let taste, taste.isUsable, !pool.isEmpty {
            let cast = people.names(forItems: Array(pool.keys))
            for (id, e) in pool {
                let a = taste.affinity(genreText: ((e.item.genre ?? "") + " " + (e.item.categoryName ?? "")).lowercased(), languages: LanguageTags.languages(of: e.item), cast: cast[id] ?? [])
                if a.score > 0 { pool[id]!.score += a.score * (intent.surprise ? 4 : 1.5) }
                if let w = a.why { tasteWhy[id] = w }
            }
        }
        // Watched or not, and a quality nudge.
        let watched = watchedIDs(Array(pool.keys))
        var results: [AskResult] = []
        for (id, e) in pool {
            let isWatched = watched.contains(id)
            if intent.unwatchedOnly && isWatched { continue }
            var reasons = e.reasons
            if let w = tasteWhy[id] { reasons.insert(w, at: min(1, reasons.count)) }
            if let r = rating(e.item), r >= 6 { reasons.append("Rated " + String(format: "%.1f", r)) }
            if let y = e.item.year, !reasons.contains(String(y)) { reasons.append(String(y)) }
            reasons.append(isWatched ? "Watched" : "Unwatched")
            let score = e.score + (rating(e.item) ?? 5) / 10 + (isWatched ? -1.5 : 0.4)
            results.append(AskResult(item: e.item, reasons: reasons, score: score, watched: isWatched))
        }
        // A copy of the same film (another quality or dub) counts once.
        var seen = Set<String>(), perFranchise: [String: Int] = [:]
        var ranked = results.sorted { $0.score > $1.score }.filter { seen.insert("\(SimilarTitles.stem($0.item.title))|\($0.item.year ?? 0)").inserted }
        // Variety: no more than two of one franchise in the first page of answers (the rest follow after).
        var first: [AskResult] = [], later: [AskResult] = []
        for r in ranked {
            let key = SimilarTitles.stem(r.item.title).split(separator: " ").prefix(2).joined(separator: " ")
            if first.count < 24, perFranchise[key, default: 0] < 2 { perFranchise[key, default: 0] += 1; first.append(r) } else { later.append(r) }
        }
        ranked = first + later
        // The chosen AI picks the best of these real candidates, and says why. It can only choose from the list it is given.
        if let judge, ranked.count >= 3, !request.isEmpty {
            let head = Array(ranked.prefix(24))
            let cands = head.enumerated().map { i, r in JudgeAdvisor.Candidate(n: i + 1, title: TraktItem.cleanTitle(r.item.title), year: r.item.year, genre: r.item.genre, rating: rating(r.item).map { String(format: "%.1f", $0) }, overview: r.item.overview) }
            let tasteLine = taste.flatMap { $0.isUsable ? Self.describe($0) : nil }
            if let reply = await judge(JudgeAdvisor.system, JudgeAdvisor.prompt(request: request, taste: tasteLine, candidates: cands)) {
                let picks = JudgeAdvisor.parse(reply, valid: Set(cands.map(\.n)))
                if !picks.isEmpty {
                    var chosen: [AskResult] = []
                    for p in picks { var r = head[p.n - 1]; if !p.why.isEmpty { r.reasons.insert("AI: " + p.why, at: 0) }; r.score += 10; chosen.append(r) }
                    let chosenIDs = Set(chosen.map(\.id))
                    ranked = chosen + ranked.filter { !chosenIDs.contains($0.id) }
                    out.judged = true
                }
            }
        }
        out.results = Array(ranked.prefix(60))
        // What TMDB says exists but is not here.
        if !tmdbCredits.isEmpty {
            let have = Set(out.results.map { MetadataNormalizer.normalize(TraktItem.cleanTitle($0.item.title)) })
            out.elsewhere = tmdbCredits.filter { !have.contains(MetadataNormalizer.normalize(TraktItem.cleanTitle($0.0))) }.prefix(8).map { c in c.1.map { y in "\(c.0) (\(y))" } ?? c.0 }
        }
        out.note = Self.note(out)
        return out
    }

    /// "Drama, Thriller; mostly Telugu; Nani": a few words about taste, for the judge.
    static func describe(_ t: TasteProfile) -> String {
        func top(_ d: [String: Double], _ n: Int) -> String { d.sorted { $0.value > $1.value }.prefix(n).map(\.key).joined(separator: ", ") }
        return [top(t.genres, 3), t.languages.isEmpty ? "" : "mostly " + top(t.languages, 2), top(t.people, 2)].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    /// A true sentence about the answer, made from the numbers (not by an AI).
    static func note(_ a: AskAnswer) -> String {
        let n = a.results.count, fresh = a.results.filter { !$0.watched }.count
        if n == 0 {
            if !a.intent.people.isEmpty && a.castCoverage < 0.9 { return "Nothing found yet. The cast has been read for \(Int(a.castCoverage * 100))% of your films, so more may appear after Read Cast Now in Settings." }
            return "Nothing in your library fits all of that. Try fewer words."
        }
        var s = n == 1 ? "1 title in your library" : "\(n) titles in your library"
        if !a.intent.people.isEmpty { s += " with " + a.intent.people.joined(separator: " and ") }
        s += fresh == 0 ? ", all watched." : (fresh == n ? ", none watched yet." : ", \(fresh) not watched yet.")
        if a.judged { s += " The AI picked the best of them." }
        if !a.intent.people.isEmpty, !a.usedTMDB, a.castCoverage < 0.9 { s += " Cast read for \(Int(a.castCoverage * 100))% of films, so there may be more." }
        return s
    }

    // MARK: small helpers

    private func item(_ id: String, _ kind: ContentKind) -> LibraryItem? {
        if kind == .series { return (try? catalog.seriesItem(id: id)).flatMap { $0 }.map { .series($0) } }
        return (try? catalog.movie(id: id)).flatMap { $0 }.map { .movie($0) }
    }

    private func rating(_ i: LibraryItem) -> Double? {
        switch i { case .movie(let m): return m.rating.flatMap(Double.init); case .series(let s): return s.rating.flatMap(Double.init) }
    }

    private func match(title: String, year: Int?, isShow: Bool) -> LibraryItem? {
        let name = TraktItem.cleanTitle(title)
        guard name.count >= 2 else { return nil }
        var q = VODQuery(); q.search = name; q.limit = 25
        let listed = TraktListed(title: name, year: year, isShow: isShow)
        if isShow { return ((try? catalog.series(q)) ?? []).first { TraktMatching.matches(listed: listed, title: $0.title, year: $0.releaseYear) }.map { .series($0) } }
        return ((try? catalog.movies(q)) ?? []).first { TraktMatching.matches(listed: listed, title: $0.title, year: $0.releaseYear ?? MetadataNormalizer.year(from: $0.title)) }.map { .movie($0) }
    }

    private func watchedIDs(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var out = Set<String>()
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let args = chunk.map { $0 as (any SQLConvertible)? }
            // a film is watched when it is in the history; a series when any of its episodes is
            let sql = "SELECT item_id FROM watch_history WHERE item_id IN (\(marks)) UNION SELECT e.series_id FROM watch_history h JOIN episodes e ON e.id = h.item_id WHERE e.series_id IN (\(marks))"
            if let rows = try? (history as? SQLiteHistoryRepository)?.rawStrings(sql, args + args) { out.formUnion(rows) }
        }
        return out
    }
}


// MARK: - moods and occasions

/// What people say instead of a genre: "date night", "something light", "scary", "with the kids", "short". Each phrase stands for genres, a length or a kind of title. Used with or without an AI.
enum MoodVocabulary {
    struct Rule { let phrases: [String]; var genres: [String] = []; var maxMinutes: Int?; var kind: WatchIntent.Kind?; var minRating: Double? }

    static let rules: [Rule] = [
        .init(phrases: ["date night", "romantic evening", "with my girlfriend", "with my boyfriend", "with my wife", "with my husband", "with my partner"], genres: ["Romance", "Comedy"]),
        .init(phrases: ["with the kids", "with kids", "for kids", "family night", "family movie", "with my children", "kid friendly", "kid-friendly"], genres: ["Family", "Animation"]),
        .init(phrases: ["feel good", "feel-good", "uplifting", "cheer me up", "make me smile", "something light", "light hearted", "light-hearted", "lighthearted"], genres: ["Comedy", "Family"]),
        .init(phrases: ["make me cry", "tearjerker", "tear jerker", "emotional", "heartbreaking", "sad movie"], genres: ["Drama", "Romance"]),
        .init(phrases: ["scary", "spooky", "frightening", "creepy", "halloween"], genres: ["Horror"]),
        .init(phrases: ["edge of my seat", "edge of the seat", "nail biting", "nail-biting", "suspense", "suspenseful", "gripping", "tense"], genres: ["Thriller"]),
        .init(phrases: ["mind bending", "mind-bending", "twist ending", "plot twist", "make me think", "head scratcher"], genres: ["Mystery", "Sci-Fi", "Thriller"]),
        .init(phrases: ["adrenaline", "explosions", "fight scenes", "high octane", "high-octane", "mass movie", "masala"], genres: ["Action"]),
        .init(phrases: ["laugh out loud", "make me laugh", "hilarious", "funny", "laughs"], genres: ["Comedy"]),
        .init(phrases: ["true story", "based on a true", "real events", "real life"], genres: ["History", "Documentary", "Drama"]),
        .init(phrases: ["space", "aliens", "futuristic", "time travel", "dystopian"], genres: ["Sci-Fi"]),
        .init(phrases: ["magic", "wizards", "dragons", "mythical"], genres: ["Fantasy"]),
        .init(phrases: ["war movie", "battlefield", "world war"], genres: ["War"]),
        .init(phrases: ["cowboys", "wild west"], genres: ["Western"]),
        .init(phrases: ["short movie", "something short", "quick watch", "before bed", "short one", "not too long", "quick movie", "short film"], maxMinutes: 100, kind: .movie),
        .init(phrases: ["binge", "binge watch", "binge-watch", "weekend marathon", "marathon", "whole season", "long weekend"], kind: .series),
        .init(phrases: ["background", "something easy", "easy watch", "no thinking", "switch off", "switch my brain off", "turn my brain off"], genres: ["Comedy"], maxMinutes: 120),
        .init(phrases: ["award winning", "award-winning", "oscar", "critically acclaimed", "must watch", "must-watch", "masterpiece", "all time best", "all-time best", "classic"], minRating: 7.5),
        .init(phrases: ["hidden gem", "underrated", "overlooked"], minRating: 7.0),
    ]

    /// Adds what the phrases stand for, without taking away anything the person said outright. Genres they ruled out stay out.
    @discardableResult static func apply(to intent: inout WatchIntent, lower: String, words: [String]) -> Set<String> {
        var used = Set<String>()
        guard words.count >= 3 else { return used }          // two words are a title ("Space Jam"), not a mood
        let text = " " + lower.replacingOccurrences(of: "’", with: "'") + " "
        for r in rules where r.phrases.contains(where: { text.contains(" " + $0 + " ") || text.contains(" " + $0 + "s ") }) {
            for p in r.phrases where text.contains(" " + p + " ") { used.formUnion(p.split(whereSeparator: { !$0.isLetter }).map(String.init)) }
            for g in r.genres where !intent.genres.contains(g) && !intent.excludeGenres.contains(g) { intent.genres.append(g) }
            if let m = r.maxMinutes, intent.maxMinutes == nil { intent.maxMinutes = m }
            if let k = r.kind, intent.kind == .any { intent.kind = k }
            if let q = r.minRating, intent.minRating == nil { intent.minRating = q }
        }
        intent.genres = Array(intent.genres.prefix(3))
        return used
    }
}
