import Foundation

// MARK: - Result model

/// What a result is. The order here is the order of the groups on the results page.
enum SearchResultKind: String, CaseIterable, Sendable, Hashable {
    case channel, movie, series, episode, programme, folder, collection

    var groupTitle: String {
        switch self {
        case .channel: "Live TV"
        case .movie: "Movies"
        case .series: "Series"
        case .episode: "Episodes"
        case .programme: "TV Guide"
        case .folder: "Folders"
        case .collection: "Collections"
        }
    }
    var typeLabel: String {
        switch self {
        case .channel: "Live TV"
        case .movie: "Movie"
        case .series: "Series"
        case .episode: "Episode"
        case .programme: "Programme"
        case .folder: "Folder"
        case .collection: "Collection"
        }
    }
    var symbol: String {
        switch self {
        case .channel: "dot.radiowaves.left.and.right"
        case .movie: "film"
        case .series: "rectangle.stack"
        case .episode: "play.rectangle"
        case .programme: "calendar"
        case .folder: "folder"
        case .collection: "square.stack"
        }
    }
}

/// The result tabs. "All Results" is the default; a type is only filtered when the user picks one of these.
enum SearchTab: String, CaseIterable, Identifiable, Sendable {
    case all = "All Results", liveTV = "Live TV", movies = "Movies", series = "Series", episodes = "Episodes", tvGuide = "TV Guide"
    var id: String { rawValue }
    var kinds: Set<SearchResultKind> {
        switch self {
        case .all: Set(SearchResultKind.allCases)
        case .liveTV: [.channel]
        case .movies: [.movie]
        case .series: [.series]
        case .episodes: [.episode]
        case .tvGuide: [.programme]
        }
    }
}

/// Where choosing a result goes.
enum SearchDestination: Hashable, Sendable {
    case playChannel(channelID: String)
    case movie(id: String)
    case series(id: String)
    case episode(id: String, seriesID: String)
    case programme(channelID: String)
    case folder(categoryID: String, kind: ContentKind)
    case collection(id: String)
}

struct SearchResult: Identifiable, Hashable, Sendable {
    /// Stable catalog identity ("<kind>:<item id>"). The item id already embeds the playlist, so the same title in two
    /// playlists stays two results.
    let id: String
    let kind: SearchResultKind
    let title: String
    let subtitle: String
    let sourceID: UUID?
    let sourceName: String?
    let artworkURL: String?
    let destination: SearchDestination
    /// Higher is more relevant. See `GlobalSearchService.score`.
    let score: Double
}

struct GlobalSearchResults: Sendable {
    var query = ""
    /// Per kind, best first, at most the requested limit.
    var byKind: [SearchResultKind: [SearchResult]] = [:]
    /// Whether more results exist beyond what was returned for that kind.
    var hasMore: Set<SearchResultKind> = []

    func results(for tab: SearchTab) -> [SearchResult] {
        SearchResultKind.allCases.filter { tab.kinds.contains($0) }.flatMap { byKind[$0] ?? [] }
    }
    func count(for tab: SearchTab) -> Int { tab.kinds.reduce(0) { $0 + (byKind[$1]?.count ?? 0) } }
    var isEmpty: Bool { byKind.values.allSatisfy(\.isEmpty) }
}

// MARK: - Service

/// Searches the whole indexed catalog: every enabled playlist, every content type. It takes no information about the screen
/// the user is on, so the same query returns the same results from Home, Live TV, Movies, Series or the guide. Narrowing
/// to one type is only done when the caller passes a tab the user chose.
///
/// Everything runs against indexed SQLite data (FTS5 for titles, indexed lookups for the rest), in bounded pages, off the
/// main actor. Nothing here calls a provider.
final class GlobalSearchService: Sendable {
    private let searchRepo: SearchRepository
    private let catalog: CatalogRepository
    private let epg: EPGRepository
    private let favorites: FavoritesRepository

    init(searchRepo: SearchRepository, catalog: CatalogRepository, epg: EPGRepository, favorites: FavoritesRepository) {
        self.searchRepo = searchRepo; self.catalog = catalog; self.epg = epg; self.favorites = favorites
    }

    /// Per-kind page size for the first page; `loadMore` raises it.
    static let pageSize = 24

    func search(_ query: String, tab: SearchTab = .all, limit: Int = pageSize) async throws -> GlobalSearchResults {
        try await Task.detached(priority: .userInitiated) { [self] in try run(query, kinds: tab.kinds, limit: limit) }.value
    }

    // MARK: ranking

    /// 1000 exact title · 800 title starts with the query · 600 a title word starts with it · 400 the title contains it ·
    /// 100 matched through supporting metadata (folder, genre, playlist name). Ties keep the index's own relevance order,
    /// which is why a small bonus for earlier position is added.
    static func score(title: String, query: String, position: Int) -> Double {
        let q = MetadataNormalizer.normalize(query), t = MetadataNormalizer.normalize(title)
        guard !q.isEmpty else { return 0 }
        let bonus = max(0, 9 - Double(position) * 0.01)
        if t == q { return 1000 + bonus }
        if t.hasPrefix(q) { return 800 + bonus }
        let words = t.split(separator: " ")
        if words.contains(where: { $0.hasPrefix(q) }) || q.split(separator: " ").allSatisfy({ w in words.contains { $0.hasPrefix(w) } }) { return 600 + bonus }
        if t.contains(q) { return 400 + bonus }
        return 100 + bonus
    }

    // MARK: query

    private func run(_ rawQuery: String, kinds: Set<SearchResultKind>, limit: Int) throws -> GlobalSearchResults {
        var out = GlobalSearchResults(query: rawQuery)
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !MetadataNormalizer.normalize(q).isEmpty else { return out }
        let allSources = (try? catalog.sources()) ?? []
        let sources = Dictionary(allSources.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let multipleSources = allSources.filter(\.enabled).count > 1
        func sourceName(_ id: UUID?) -> String? { id.flatMap { sources[$0] } }
        let over = limit + 1                                     // one extra row tells us whether there is another page

        // Catalog titles (FTS5): channels, movies, series
        let ftsKinds = Set(kinds.compactMap { k -> ContentKind? in k == .channel ? .channel : k == .movie ? .movie : k == .series ? .series : nil })
        if !ftsKinds.isEmpty {
            // One index query per type, so a type with a huge catalog (movies) can't push the others out of a shared limit.
            func take(_ k: ContentKind) throws -> [SearchHit] {
                guard ftsKinds.contains(k) else { return [] }
                defer { _ = try? Task.checkCancellation() }
                return try searchRepo.search(term: q, filters: SearchFilters(kinds: [k], sourceID: nil), limit: over)
            }
            let ch = try take(.channel); try Task.checkCancellation()
            let mv = try take(.movie); try Task.checkCancellation()
            let sr = try take(.series)
            if !ch.isEmpty {
                let by = Dictionary(try catalog.channels(ChannelQuery(collapseVariants: false, ids: ch.map(\.itemID))).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                add(.channel, ch.enumerated().compactMap { i, h in by[h.itemID].map { c in
                    SearchResult(id: "channel:\(c.id)", kind: .channel, title: c.name, subtitle: [c.categoryName, multipleSources ? sourceName(c.sourceID) : nil].compactMap { $0 }.joined(separator: " · "),
                                 sourceID: c.sourceID, sourceName: sourceName(c.sourceID), artworkURL: c.logoURL, destination: .playChannel(channelID: c.id),
                                 score: Self.score(title: c.name, query: q, position: i))
                } }, to: &out, limit: limit)
            }
            try Task.checkCancellation()
            if !mv.isEmpty {
                let by = Dictionary(try catalog.movies(VODQuery(ids: mv.map(\.itemID))).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                add(.movie, mv.enumerated().compactMap { i, h in by[h.itemID].map { m in
                    SearchResult(id: "movie:\(m.id)", kind: .movie, title: m.title, subtitle: [m.releaseYear.map(String.init), m.genre ?? m.categoryName, multipleSources ? sourceName(m.sourceID) : nil].compactMap { $0 }.joined(separator: " · "),
                                 sourceID: m.sourceID, sourceName: sourceName(m.sourceID), artworkURL: m.posterURL, destination: .movie(id: m.id),
                                 score: Self.score(title: m.title, query: q, position: i))
                } }, to: &out, limit: limit)
            }
            if !sr.isEmpty {
                let by = Dictionary(try catalog.series(VODQuery(ids: sr.map(\.itemID))).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                add(.series, sr.enumerated().compactMap { i, h in by[h.itemID].map { s in
                    SearchResult(id: "series:\(s.id)", kind: .series, title: s.title, subtitle: [s.releaseYear.map(String.init), s.genre ?? s.categoryName, multipleSources ? sourceName(s.sourceID) : nil].compactMap { $0 }.joined(separator: " · "),
                                 sourceID: s.sourceID, sourceName: sourceName(s.sourceID), artworkURL: s.posterURL, destination: .series(id: s.id),
                                 score: Self.score(title: s.title, query: q, position: i))
                } }, to: &out, limit: limit)
            }
        }
        try Task.checkCancellation()

        // Episodes that have been downloaded (providers list them per series, so only series that were opened have them)
        if kinds.contains(.episode) {
            let eps = try catalog.searchEpisodes(term: q, sourceID: nil, limit: over)
            var rows: [SearchResult] = []
            for (i, e) in eps.enumerated() {
                guard let s = try catalog.seriesItem(id: e.seriesID) else { continue }
                rows.append(SearchResult(id: "episode:\(e.id)", kind: .episode, title: e.title, subtitle: ["\(s.title) · S\(e.seasonNumber)E\(e.episodeNumber)", multipleSources ? sourceName(s.sourceID) : nil].compactMap { $0 }.joined(separator: " · "),
                                         sourceID: s.sourceID, sourceName: sourceName(s.sourceID), artworkURL: e.imageURL ?? s.posterURL, destination: .episode(id: e.id, seriesID: s.id),
                                         score: Self.score(title: e.title, query: q, position: i)))
            }
            add(.episode, rows, to: &out, limit: limit)
        }
        try Task.checkCancellation()

        // Programme guide
        if kinds.contains(.programme) {
            let progs = try epg.searchPrograms(term: q, sourceID: nil, from: Date(), limit: over)
            add(.programme, progs.enumerated().map { i, p in
                SearchResult(id: "programme:\(p.program.id)", kind: .programme, title: p.program.title,
                             subtitle: "\(p.channelName) · \(TimeFormatter.dayAndTime(p.program.start))", sourceID: p.program.sourceID, sourceName: sourceName(p.program.sourceID),
                             artworkURL: p.program.imageURL, destination: .programme(channelID: p.channelID), score: Self.score(title: p.program.title, query: q, position: i))
            }, to: &out, limit: limit)
        }
        try Task.checkCancellation()

        // Folders and collections
        if kinds.contains(.folder) {
            let cats = try catalog.searchCategories(term: q, limit: over)
            add(.folder, cats.enumerated().map { i, c in
                SearchResult(id: "folder:\(c.id)", kind: .folder, title: c.name,
                             subtitle: [c.kind == .channel ? "Live TV folder" : c.kind == .movie ? "Movies folder" : "Series folder", multipleSources ? sourceName(c.sourceID) : nil].compactMap { $0 }.joined(separator: " · "),
                             sourceID: c.sourceID, sourceName: sourceName(c.sourceID), artworkURL: nil, destination: .folder(categoryID: c.id, kind: c.kind), score: Self.score(title: c.name, query: q, position: i))
            }, to: &out, limit: limit)
        }
        if kinds.contains(.collection) {
            let nq = MetadataNormalizer.normalize(q)
            let cols = ((try? favorites.collections()) ?? []).filter { MetadataNormalizer.normalize($0.name).contains(nq) }
            add(.collection, cols.enumerated().map { i, c in
                SearchResult(id: "collection:\(c.id)", kind: .collection, title: c.name, subtitle: "\(c.itemCount) item\(c.itemCount == 1 ? "" : "s")", sourceID: nil, sourceName: nil, artworkURL: nil,
                             destination: .collection(id: c.id), score: Self.score(title: c.name, query: q, position: i))
            }, to: &out, limit: limit)
        }
        return out
    }

    /// Dedupes by stable identity, ranks by score (then the index's order), and trims to the page. An extra row beyond the
    /// page means there is more to load.
    private func add(_ kind: SearchResultKind, _ rows: [SearchResult], to out: inout GlobalSearchResults, limit: Int) {
        var seen = Set<String>(), unique: [SearchResult] = []
        for r in rows where seen.insert(r.id).inserted { unique.append(r) }
        let ranked = unique.enumerated().sorted { a, b in a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset }.map(\.element)
        if ranked.count > limit { out.hasMore.insert(kind) }
        out.byKind[kind] = Array(ranked.prefix(limit))
    }
}
