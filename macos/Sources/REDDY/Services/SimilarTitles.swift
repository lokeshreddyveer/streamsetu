import Foundation

/// A title suggested for the one that is open, and the reason it was chosen ("Same director", "Similar story", …).
struct SimilarSuggestion: Identifiable, Hashable, Sendable {
    let item: LibraryItem
    let reason: String
    var id: String { item.id }
}

/// "More like this": ranks a pool of titles by how much they resemble one title, using only what is on the device plus the genre, cast and director the provider sent for the
/// open title. Nothing is invented: a title with no real reason is left out. Signals, strongest first: the same franchise, the same director, the same genre, shared cast,
/// a similar story (plot words that are rare in the pool), then language, year, rating and folder as tie-breakers.
enum SimilarTitles {
    struct Candidate: Sendable {
        let item: LibraryItem
        let rating: Double?
        let plot: String?
        let genres: Set<String>
        let folder: String?
    }

    private static let languages: Set<String> = ["english", "hindi", "tamil", "telugu", "kannada", "malayalam", "urdu", "punjabi", "bengali", "marathi", "gujarati", "arabic", "spanish", "french", "german", "korean", "japanese", "chinese", "turkish", "russian", "italian", "portuguese", "thai", "indonesian"]
    private static let noise: Set<String> = ["hd", "fhd", "uhd", "4k", "sd", "hdcam", "cam", "webrip", "web", "dl", "bluray", "dvdrip", "hevc", "x264", "x265", "h264", "h265", "dubbed", "dub", "multi", "sub", "subs", "eng", "season", "episode"]
    private static let stop: Set<String> = Set(("the a an and or of to in on at for with from by is are was were be been it its this that these those his her their they them he she we you i as but not no so if then than who whom what when where why how into out up down over under about after before while during against between through only also just very more most some any all each one two has have had will would could should can may might own other such").split(separator: " ").map(String.init))
    private static let roman: Set<String> = ["ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    static func language(_ texts: String?...) -> String? {
        for t in texts { guard let t else { continue }; if let w = normalize(t).split(separator: " ").map(String.init).first(where: languages.contains) { return w } }
        return nil
    }

    private static let markerWords: Set<String> = ["part", "chapter", "vol", "volume"]

    /// The words of a title's main part (before a colon or a dash) once the year, quality tags and language are removed.
    private static func headWords(_ title: String) -> [String] {
        var head = title
        if let r = head.range(of: ":") { head = String(head[..<r.lowerBound]) }
        if let r = head.range(of: " - ") { head = String(head[..<r.lowerBound]) }
        return normalize(head).split(separator: " ").map(String.init).filter { w in
            !(w.count == 4 && w.allSatisfy(\.isNumber) && (w.hasPrefix("19") || w.hasPrefix("20"))) && !noise.contains(w) && !languages.contains(w)
        }
    }

    private static func isMarker(_ w: String) -> Bool { w.allSatisfy(\.isNumber) || roman.contains(w) || markerWords.contains(w) }

    /// What is left of a title once the year, quality, language and sequel markers are removed: "John Wick 3 (2019)" becomes "john wick".
    static func stem(_ title: String) -> String {
        var words = headWords(title)
        while words.count > 1, let last = words.last, isMarker(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// True for "John Wick 3", "Mission Impossible II", "Rocky Part 2": the title carries a sequel number.
    static func sequelMarked(_ title: String) -> Bool { let w = headWords(title); return w.count > 1 && isMarker(w.last!) }

    private static func lead(_ stem: String) -> String {
        for article in ["the ", "a ", "an "] where stem.hasPrefix(article) { return String(stem.dropFirst(article.count)) }
        return stem
    }

    /// A title with only its year, quality tags and language removed: two titles with the same identity are the same film or show (a dub, another quality), not a suggestion for each other.
    static func identity(_ title: String) -> String {
        normalize(title).split(separator: " ").map(String.init).filter { w in
            !(w.count == 4 && w.allSatisfy(\.isNumber) && (w.hasPrefix("19") || w.hasPrefix("20"))) && !noise.contains(w) && !languages.contains(w)
        }.joined(separator: " ")
    }

    private static func sameFranchise(_ a: String, _ b: String) -> Bool {
        let x0 = lead(a), y0 = lead(b)
        guard !x0.isEmpty, !y0.isEmpty else { return false }
        if x0 == y0 { return true }
        let x = x0.split(separator: " "), y = y0.split(separator: " ")
        // The first two words must match. Leading articles are ignored, so "The Amazing Spider-Man" is not "The Amazing Bulk".
        return x.count >= 2 && y.count >= 2 && x[0] == y[0] && x[1] == y[1]
    }

    /// The films of the same franchise as [target], with the target among them, in the order they came out. A sequel or another film of the series counts (the first words of the
    /// title match once the year, quality, language and sequel number are removed); a dub or another quality of the same film does not appear twice. Fewer than two films is no
    /// franchise, and the result is empty.
    static func franchise(target: Candidate, pool: [Candidate], limit: Int = 12) -> [LibraryItem] {
        let stem = stem(target.item.title)
        guard !stem.isEmpty else { return [] }
        func score(_ c: Candidate) -> Int { (c.rating ?? 0) > 0 ? 1 : 0 }
        let oneWord = lead(stem).split(separator: " ").count == 1
        // A one-word name ("Crash", "Heat") is a franchise only through a sequel number: two unrelated films can share it.
        let siblings = pool.filter { $0.item.id != target.item.id && sameFranchise(stem, Self.stem($0.item.title)) && (!oneWord || sequelMarked($0.item.title) || sequelMarked(target.item.title)) }
        // Provider titles carry tags in every shape ("[Tam, Tel, Hin]", "(Telugu)", "(4K)"), so copies of one film are told apart by its release year, not by its name.
        var byFilm: [String: Candidate] = [:]
        var order: [String] = []
        for c in [target] + siblings {
            let key = c.item.year.map(String.init) ?? identity(c.item.title)
            if let have = byFilm[key] {
                if have.item.id != target.item.id, c.item.id == target.item.id || score(c) > score(have) || (score(c) == score(have) && c.item.title.count < have.item.title.count) { byFilm[key] = c }
            } else { byFilm[key] = c; order.append(key) }
        }
        guard byFilm.count >= 2 else { return [] }
        return order.compactMap { byFilm[$0] }
            .sorted { ($0.item.year ?? Int.max, $0.item.title) < ($1.item.year ?? Int.max, $1.item.title) }
            .prefix(limit).map(\.item)
    }

    private static func words(_ plot: String?) -> Set<String> {
        guard let plot, !plot.isEmpty else { return [] }
        return Set(normalize(plot).split(separator: " ").map(String.init).filter { $0.count >= 4 && !stop.contains($0) && !languages.contains($0) })
    }

    /// Genre names as a set of lower-case words ("Action, Sci-Fi" → ["action", "sci fi"]).
    static func genreSet(_ s: String?) -> Set<String> {
        Set((s ?? "").split(whereSeparator: { ",/|&".contains($0) }).map { normalize(String($0)) }.filter { $0.count >= 3 })
    }

    static func rank(target: Candidate, extras: ProviderExtras?, pool: [Candidate], known: [String: ProviderExtras] = [:], limit: Int = 24) -> [SimilarSuggestion] {
        let tStem = stem(target.item.title), tID = identity(target.item.title)
        let tWords = words(target.plot)
        let tLang = language(target.item.title, target.folder)
        let tCast = Set((extras?.cast ?? []).map(normalize)), tDirectors = Set((extras?.directors ?? []).map(normalize))
        let candidates = pool.filter { $0.item.id != target.item.id && identity($0.item.title) != tID }
        var df: [String: Int] = [:]
        let candWords = Dictionary(candidates.map { ($0.item.id, words($0.plot)) }, uniquingKeysWith: { a, _ in a })
        for ws in candWords.values { for w in ws { df[w, default: 0] += 1 } }
        let n = Double(max(candidates.count, 1))
        func idf(_ w: String) -> Double { log((n + 1) / Double(1 + (df[w] ?? 0))) + 0.1 }
        let tNorm2 = sqrt(tWords.reduce(0) { $0 + idf($1) * idf($1) })

        var out: [(SimilarSuggestion, Double)] = []
        var weak: [(SimilarSuggestion, Double)] = []
        for c in candidates {
            var total = 0.0, best = 0.0, reason = ""
            func add(_ points: Double, _ why: String) { guard points > 0 else { return }; total += points; if points > best { best = points; reason = why } }
            if sameFranchise(tStem, stem(c.item.title)) { add(7, "Same franchise") }
            if let k = known[c.item.id] {
                if !tDirectors.isEmpty, !tDirectors.isDisjoint(with: Set(k.directors.map(normalize))) { add(5, "Same director") }
                let shared = tCast.intersection(Set(k.cast.map(normalize))).count
                if shared > 0 { add(Double(min(shared, 3)) * 2, "Shared cast") }
            } else if !tCast.isEmpty || !tDirectors.isEmpty {
                let text = normalize((c.plot ?? "") + " " + c.item.title)
                let named = tCast.union(tDirectors).filter { $0.count >= 5 && text.contains($0) }.count
                if named > 0 { add(Double(min(named, 2)) * 2, "Shared cast") }
            }
            let g = target.genres.intersection(c.genres).count
            if g > 0 { add(3 + 1.5 * Double(min(g, 3)), "Same genre") }
            let cw = candWords[c.item.id] ?? []
            if tNorm2 > 0, !cw.isEmpty {
                let shared = tWords.intersection(cw)
                if !shared.isEmpty {
                    let dot = shared.reduce(0) { $0 + idf($1) * idf($1) }
                    let cNorm = sqrt(cw.reduce(0) { $0 + idf($1) * idf($1) })
                    add(min(6, 14 * dot / (tNorm2 * cNorm)), "Similar story")
                }
            }
            if let tl = tLang, let cl = language(c.item.title, c.folder) { if tl == cl { add(1.5, "Same language") } else { total -= 2 } }
            if let ty = target.item.year, let cy = c.item.year { add(1.5 * max(0, 1 - Double(abs(ty - cy)) / 12), "Close in time") }
            if let tr = target.rating, let cr = c.rating, tr > 0, cr > 0 { add(1.2 * max(0, 1 - abs(tr - cr) / 3), "Rated alike") }
            if let tf = target.folder, tf == c.folder { add(1, "From the same folder") }
            let meaningful = ["Same franchise", "Same director", "Same genre", "Shared cast", "Similar story"].contains(reason)
            if meaningful, total > 1 { out.append((SimilarSuggestion(item: c.item, reason: reason), total + (c.rating ?? 0) / 100)) }
            else if total > 1 { weak.append((SimilarSuggestion(item: c.item, reason: reason == "Same language" ? reason : "Similar year and rating"), total)) }
        }
        // Too little to go on (no plots, genres or facts): fall back to the same folder so the row is never empty.
        if out.count < 6, let tf = target.folder {
            let have = Set(out.map { $0.0.id })
            let fill = candidates.filter { !have.contains($0.item.id) && $0.folder == tf }
                .sorted { a, b in
                    let ay = abs((a.item.year ?? 0) - (target.item.year ?? 0)), by = abs((b.item.year ?? 0) - (target.item.year ?? 0))
                    return ay != by ? ay < by : (a.rating ?? 0) > (b.rating ?? 0)
                }.prefix(10 - out.count)
            for c in fill { out.append((SimilarSuggestion(item: c.item, reason: "From the same folder"), 0.5)) }
        }
        // Still thin (a catalog with no plots, genres or facts): add the closest by language, year and rating, saying so.
        if out.count < 6 {
            let have = Set(out.map { $0.0.id })
            for w in weak.filter({ !have.contains($0.0.id) }).sorted(by: { $0.1 > $1.1 }).prefix(10 - out.count) { out.append((w.0, 0.4)) }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

/// Finds the pool for a title (its own folder, and titles with the same start of name) from the catalog and ranks it.
struct SimilarService: Sendable {
    let catalog: CatalogRepository

    private func candidate(_ item: LibraryItem) -> SimilarTitles.Candidate {
        switch item {
        case .movie(let m): return .init(item: item, rating: Double(m.rating ?? ""), plot: m.overview, genres: SimilarTitles.genreSet(m.genre), folder: m.categoryID)
        case .series(let s): return .init(item: item, rating: Double(s.rating ?? ""), plot: s.overview, genres: SimilarTitles.genreSet(s.genre), folder: s.categoryID)
        }
    }

    func suggestions(for item: LibraryItem, extras: ProviderExtras?, known: [String: ProviderExtras] = [:]) -> [SimilarSuggestion] {
        var pool: [LibraryItem] = []
        let folder: String? = { switch item { case .movie(let m): m.categoryID; case .series(let s): s.categoryID } }()
        let stemWords = SimilarTitles.stem(item.title).split(separator: " ").prefix(2).joined(separator: " ")
        switch item {
        case .movie:
            if let folder { pool += ((try? catalog.movies(VODQuery(sourceID: item.sourceID, categoryID: folder, sort: .rating, limit: 800))) ?? []).map { .movie($0) } }
            if stemWords.count >= 3 { pool += ((try? catalog.movies(VODQuery(search: stemWords, sort: .rating, limit: 60))) ?? []).map { .movie($0) } }
        case .series:
            if let folder { pool += ((try? catalog.series(VODQuery(sourceID: item.sourceID, categoryID: folder, sort: .rating, limit: 800))) ?? []).map { .series($0) } }
            if stemWords.count >= 3 { pool += ((try? catalog.series(VODQuery(search: stemWords, sort: .rating, limit: 60))) ?? []).map { .series($0) } }
        }
        var seen = Set<String>()
        let unique = pool.filter { seen.insert($0.id).inserted }
        return SimilarTitles.rank(target: candidate(item), extras: extras, pool: unique.map(candidate), known: known)
    }

    /// The franchise of an open movie, found anywhere in the library, in release order; empty when it has no sequels or siblings.
    func franchise(of movie: Movie) -> [LibraryItem] {
        let words = SimilarTitles.stem(movie.title).split(separator: " ").prefix(2).joined(separator: " ")
        guard !words.isEmpty else { return [] }
        let found = ((try? catalog.movies(VODQuery(search: words, sort: .recentlyAdded, limit: 200))) ?? []).map { LibraryItem.movie($0) }
        return SimilarTitles.franchise(target: candidate(.movie(movie)), pool: found.map(candidate))
    }
}
