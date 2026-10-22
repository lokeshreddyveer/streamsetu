import SwiftUI
import Observation

enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added", titleAZ = "Title A–Z", titleZA = "Title Z–A"
    case newestYear = "Release Year: Newest", oldestYear = "Release Year: Oldest", topRated = "Rating: Highest"
    case shortest = "Duration: Shortest", longest = "Duration: Longest"
    var id: String { rawValue }
    var vod: VODSort {
        switch self {
        case .recentlyAdded: .recentlyAdded; case .titleAZ: .title; case .titleZA: .titleDescending
        case .newestYear: .year; case .oldestYear: .yearOldest; case .topRated: .rating
        case .shortest: .durationShortest; case .longest: .durationLongest
        }
    }

    /// Whether the indexed data can honestly support this order. Nothing is offered that would sort on made-up values.
    func isSupported(by c: VODMetadataCoverage, kind: ContentKind) -> Bool {
        switch self {
        case .recentlyAdded, .titleAZ, .titleZA: true
        case .newestYear, .oldestYear: c.supportsYear
        case .topRated: c.supportsRating
        case .shortest, .longest: kind == .movie && c.supportsDuration
        }
    }
}

/// Movies and Series share one browser: a sidebar selection decides what is listed.
@MainActor @Observable
final class LibraryBrowserViewModel {
    let kind: ContentKind
    private(set) var items: [LibraryItem] = []
    private(set) var total = 0
    /// While searching: titles that matched because of somebody in them, with who ("Cast: Mahesh Babu").
    private(set) var matchNotes: [String: String] = [:]
    /// What was understood from a sentence typed in the search box ("Telugu · 2024 · under 2 h"); empty when the search is just a title.
    private(set) var understood: [String] = []
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var hero: LibraryItem?
    private(set) var progress: [String: Double] = [:]
    var search = ""
    var sort: LibrarySort = .recentlyAdded
    /// The Filter button's choices, and the languages and qualities this list really has (read again when the playlist changes).
    var filter = LibraryFilter()
    private(set) var filterOptions = LibraryFilterOptions()
    private var optionsKey = ""
    private(set) var coverage = VODMetadataCoverage(total: 1, rated: 1, withYear: 1, withDuration: 1)
    var availableSorts: [LibrarySort] { LibrarySort.allCases.filter { $0.isSupported(by: coverage, kind: kind) } }

    private let pageSize = 120
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    /// The titles saved to watch later, for the Watch Later folder.
    private var watchLaterIDs: [String] = []

    init(kind: ContentKind) { self.kind = kind }

    var noun: String { kind == .movie ? "movies" : "series" }
    var countText: String { "\(total.formatted()) title\(total == 1 ? "" : "s")" }

    private func query(_ selection: SidebarSelection, source: UUID?, offset: Int, favorites: Bool = false, natural: NaturalQuery? = nil) -> VODQuery {
        var q = VODQuery(sourceID: source, search: natural?.text ?? search, sort: sort.vod, limit: pageSize, offset: offset)
        switch selection {
        case .folder(let id): q.categoryID = id
        case .shortcut(.favorites): q.favoritesOnly = true
        case .shortcut(.watchLater): q.ids = watchLaterIDs.isEmpty ? ["-none-"] : watchLaterIDs
        case .shortcut(.recentlyAdded): q.sort = .recentlyAdded
        case .shortcut(.unwatched): q.unwatchedOnly = true
        case .shortcut(.unwatchedFavorites): q.unwatchedOnly = true; q.favoritesOnly = true
        case .shortcut(.addedThisMonth): q.addedWithinDays = 30; q.sort = .recentlyAdded
        case .shortcut(.newEpisodes): q.newEpisodesOnly = true
        default: break
        }
        filter.apply(to: &q, kind: kind)
        if let n = natural, n.isStructured {          // what the sentence said fills in what the filters left open
            q.language = q.language ?? n.language; q.year = q.year ?? n.year; q.decade = q.decade ?? n.decade; q.quality = q.quality ?? n.quality
            q.minRating = q.minRating ?? n.minRating; q.maxMinutes = n.maxMinutes; q.minMinutes = n.minMinutes
            if n.unwatched { q.unwatchedOnly = true }
            if n.started { q.watch = .started }
            if n.favorites { q.favoritesOnly = true }
            if let d = n.addedWithinDays { q.addedWithinDays = d }
            q.genres = n.genres; q.excludeGenres = n.excludeGenres
            if let s = n.sort { q.sort = s }          // "top rated" or "newest" in the search box orders the list
        }
        return q
    }

    func reset(_ c: AppContainer, selection: SidebarSelection, source: UUID?) async {
        generation += 1
        let gen = generation, kind = self.kind
        loading = true
        if case .shortcut(.continueWatching) = selection { await loadContinue(c, source: source, gen: gen); return }
        if case .shortcut(.watchLater) = selection { watchLaterIDs = await Task.detached { Self.savedIDs(c, kind: kind) }.value }
        let found = await Task.detached { (try? c.catalog.metadataCoverage(kind: kind, sourceID: source)) ?? VODMetadataCoverage() }.value
        coverage = found
        let optionsKey = "\(source?.uuidString ?? "")-\(found.total)"
        if optionsKey != self.optionsKey {
            self.optionsKey = optionsKey
            filterOptions = await Task.detached { (try? c.catalog.filterOptions(sourceID: source, kind: kind)) ?? LibraryFilterOptions() }.value
        }
        if !sort.isSupported(by: found, kind: kind) { sort = .recentlyAdded }               // a stored choice the data can't support
        var natural = NaturalQuery.parse(search)
        var q = query(selection, source: source, offset: 0, natural: natural)
        func run(_ q: VODQuery) async -> ([LibraryItem], Int, LibraryItem?) {
            await Task.detached { () -> ([LibraryItem], Int, LibraryItem?) in
                let items: [LibraryItem], n: Int
                if kind == .movie { items = ((try? c.catalog.movies(q)) ?? []).map { .movie($0) }; n = (try? c.catalog.countMovies(q)) ?? items.count }
                else { items = ((try? c.catalog.series(q)) ?? []).map { .series($0) }; n = (try? c.catalog.countSeries(q)) ?? items.count }
                return (items, n, nil)
            }.value
        }
        var (page, count, heroItem) = await run(q)
        if page.isEmpty, natural.isStructured {          // the sentence found nothing: fall back to the words as a plain title search, so a name that looks like a filter still works
            natural = NaturalQuery(); natural.text = search
            q = query(selection, source: source, offset: 0)
            (page, count, heroItem) = await run(q)
        }
        guard gen == generation else { return }
        understood = natural.isStructured ? natural.summary : []
        items = page; total = count; hasMore = page.count == pageSize; hero = heroItem; progress = [:]; loading = false
        await refreshNotes(c)
    }

    private func refreshNotes(_ c: AppContainer) async {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { matchNotes = [:]; return }
        let shown = items.map { (id: $0.id, title: $0.title) }
        let notes = await Task.detached { PeopleIndex(db: c.db).matchNotes(term: term, items: shown) }.value
        if term == search.trimmingCharacters(in: .whitespacesAndNewlines) { matchNotes = notes }
    }

    private func loadContinue(_ c: AppContainer, source: UUID?, gen: Int) async {
        let kind = self.kind, term = search
        let (list, prog) = await Task.detached { () -> ([LibraryItem], [String: Double]) in
            var out: [LibraryItem] = [], prog: [String: Double] = [:]
            for ci in (try? c.history.continueWatching(limit: 120, sourceID: source)) ?? [] {
                switch ci.content {
                case .movie(let m) where kind == .movie: out.append(.movie(m)); prog[m.id] = ci.progress.fraction
                case .episode(_, let s) where kind == .series: if !out.contains(where: { $0.id == s.id }) { out.append(.series(s)); prog[s.id] = ci.progress.fraction }
                default: break
                }
            }
            let t = MetadataNormalizer.normalize(term)
            return (t.isEmpty ? out : out.filter { MetadataNormalizer.normalize($0.title).contains(t) }, prog)
        }.value
        guard gen == generation else { return }
        items = list; total = list.count; hasMore = false; hero = nil; progress = prog; loading = false
    }

    func loadMoreIfNeeded(_ c: AppContainer, current: LibraryItem, selection: SidebarSelection, source: UUID?) async {
        guard hasMore, !loading, items.suffix(12).contains(where: { $0.id == current.id }) else { return }
        if case .shortcut(.continueWatching) = selection { return }
        generation += 1
        let gen = generation, kind = self.kind
        loading = true
        let nat = NaturalQuery.parse(search)
        let q = query(selection, source: source, offset: items.count, natural: understood.isEmpty ? nil : nat)
        let page = await Task.detached { () -> [LibraryItem] in
            kind == .movie ? ((try? c.catalog.movies(q)) ?? []).map { .movie($0) } : ((try? c.catalog.series(q)) ?? []).map { .series($0) }
        }.value
        guard gen == generation else { return }
        items += page; hasMore = page.count == pageSize; loading = false
    }

    /// Saved titles of this kind, newest saved first.
    nonisolated private static func savedIDs(_ c: AppContainer, kind: ContentKind) -> [String] {
        ((try? c.favoritesRepo.collectionItems(id: AppState.watchLaterListID)) ?? []).filter { $0.kind == kind }.map(\.itemID).reversed()
    }

    /// Debounced; a newer keystroke cancels the pending query.
    func scheduleSearch(_ c: AppContainer, selection: SidebarSelection, source: UUID?) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if !Task.isCancelled { await self?.reset(c, selection: selection, source: source) }
        }
    }
}
