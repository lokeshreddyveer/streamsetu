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
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var hero: LibraryItem?
    private(set) var progress: [String: Double] = [:]
    var search = ""
    var sort: LibrarySort = .recentlyAdded
    private(set) var coverage = VODMetadataCoverage(total: 1, rated: 1, withYear: 1, withDuration: 1)
    var availableSorts: [LibrarySort] { LibrarySort.allCases.filter { $0.isSupported(by: coverage, kind: kind) } }

    private let pageSize = 120
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(kind: ContentKind) { self.kind = kind }

    var noun: String { kind == .movie ? "movies" : "series" }
    var countText: String { "\(total.formatted()) title\(total == 1 ? "" : "s")" }

    private func query(_ selection: SidebarSelection, source: UUID?, offset: Int, favorites: Bool = false) -> VODQuery {
        var q = VODQuery(sourceID: source, search: search, sort: sort.vod, limit: pageSize, offset: offset)
        switch selection {
        case .folder(let id): q.categoryID = id
        case .shortcut(.favorites): q.favoritesOnly = true
        case .shortcut(.recentlyAdded): q.sort = .recentlyAdded
        default: break
        }
        return q
    }

    func reset(_ c: AppContainer, selection: SidebarSelection, source: UUID?) async {
        generation += 1
        let gen = generation, kind = self.kind
        loading = true
        if case .shortcut(.continueWatching) = selection { await loadContinue(c, source: source, gen: gen); return }
        let found = await Task.detached { (try? c.catalog.metadataCoverage(kind: kind, sourceID: source)) ?? VODMetadataCoverage() }.value
        coverage = found
        if !sort.isSupported(by: found, kind: kind) { sort = .recentlyAdded }               // a stored choice the data can't support
        let q = query(selection, source: source, offset: 0)
        let (page, count, heroItem) = await Task.detached { () -> ([LibraryItem], Int, LibraryItem?) in
            let items: [LibraryItem], n: Int
            if kind == .movie { items = ((try? c.catalog.movies(q)) ?? []).map { .movie($0) }; n = (try? c.catalog.countMovies(q)) ?? items.count }
            else { items = ((try? c.catalog.series(q)) ?? []).map { .series($0) }; n = (try? c.catalog.countSeries(q)) ?? items.count }
            return (items, n, nil)
        }.value
        guard gen == generation else { return }
        items = page; total = count; hasMore = page.count == pageSize; hero = heroItem; progress = [:]; loading = false
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
        let q = query(selection, source: source, offset: items.count)
        let page = await Task.detached { () -> [LibraryItem] in
            kind == .movie ? ((try? c.catalog.movies(q)) ?? []).map { .movie($0) } : ((try? c.catalog.series(q)) ?? []).map { .series($0) }
        }.value
        guard gen == generation else { return }
        items += page; hasMore = page.count == pageSize; loading = false
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
