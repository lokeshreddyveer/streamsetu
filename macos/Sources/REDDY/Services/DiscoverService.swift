import Foundation

/// A movie or a series, as shown on cards, rails and the featured banner.
enum LibraryItem: Identifiable, Hashable, Sendable {
    case movie(Movie), series(Series)

    var id: String { switch self { case .movie(let m): m.id; case .series(let s): s.id } }
    var title: String { switch self { case .movie(let m): m.title; case .series(let s): s.title } }
    var year: Int? { switch self { case .movie(let m): m.releaseYear; case .series(let s): s.releaseYear } }
    var genre: String? { switch self { case .movie(let m): m.genre ?? m.categoryName; case .series(let s): s.genre ?? s.categoryName } }
    var posterURL: String? { switch self { case .movie(let m): m.posterURL; case .series(let s): s.posterURL } }
    var backdropURL: String? { switch self { case .movie(let m): m.backdropURL; case .series(let s): s.backdropURL } }
    var overview: String? { switch self { case .movie(let m): m.overview; case .series(let s): s.overview } }
    var isSeries: Bool { if case .series = self { true } else { false } }
    /// The provider's folder the title is in.
    var categoryID: String? { switch self { case .movie(let m): m.categoryID; case .series(let s): s.categoryID } }
    var categoryName: String? { switch self { case .movie(let m): m.categoryName; case .series(let s): s.categoryName } }
    var kind: ContentKind { isSeries ? .series : .movie }
    var sourceID: UUID { switch self { case .movie(let m): m.sourceID; case .series(let s): s.sourceID } }
    var durationSeconds: Double? { if case .movie(let m) = self { m.durationSeconds } else { nil } }
}

struct DiscoverShelf: Identifiable, Sendable {
    let id: String
    let title: String
    /// What the shelf is really based on. Never claims chart data, provider affiliation or availability.
    let caption: String
    let items: [LibraryItem]
    var ranked = false
}

struct DiscoverContent: Sendable {
    var hero: LibraryItem?
    var shelves: [DiscoverShelf]
}

/// Builds the Discover page from the playlist's own data. Shelves that have nothing to show are omitted.
final class DiscoverService: Sendable {
    #if os(macOS)
    static let thisDevice = "this Mac"
    #else
    static let thisDevice = "this device"
    #endif

    let catalog: CatalogRepository
    let history: HistoryRepository

    private let people: PeopleIndex?
    init(catalog: CatalogRepository, history: HistoryRepository, people: PeopleIndex? = nil) { self.catalog = catalog; self.history = history; self.people = people }

    static let providerShelves: [(title: String, keywords: [String], phrases: [String])] = [
        ("Netflix", ["netflix"], []),
        ("Prime Video", ["prime", "amazon", "primevideo"], ["prime video"]),
        ("Apple TV+", ["appletv"], ["apple tv"]),
    ]
    static let indianKeywords: Set<String> = ["indian", "india", "hindi", "telugu", "tamil", "malayalam", "kannada", "bengali", "marathi", "punjabi", "gujarati", "bollywood", "tollywood"]

    func build(sourceID: UUID?, now: Date = Date()) throws -> DiscoverContent {
        let size = 14
        func items(_ movies: [Movie], _ series: [Series]) -> [LibraryItem] { movies.map { .movie($0) } + series.map { .series($0) } }
        var shelves: [DiscoverShelf] = []

        let recentMovies = try catalog.movies(VODQuery(sourceID: sourceID, sort: .recentlyAdded, limit: size))
        let recentSeries = try catalog.series(VODQuery(sourceID: sourceID, sort: .recentlyAdded, limit: size))

        // Trending in Your Library: what is actually being played here, else what was added last.
        let played = try history.mostPlayed(kinds: [.movie, .episode], since: now.addingTimeInterval(-30 * 86400), limit: size * 2)
        var trending: [LibraryItem] = []
        var seen = Set<String>()
        for p in played {
            if let m = try catalog.movie(id: p.itemID), sourceID == nil || m.sourceID == sourceID, seen.insert(m.id).inserted { trending.append(.movie(m)) }
            else if let e = try catalog.episode(id: p.itemID), let s = try catalog.seriesItem(id: e.seriesID), sourceID == nil || s.sourceID == sourceID, seen.insert(s.id).inserted { trending.append(.series(s)) }
            if trending.count == size { break }
        }
        let mixed = zip(recentMovies, recentSeries).flatMap { [LibraryItem.movie($0), .series($1)] }
        if trending.count >= 6 {
            shelves.append(DiscoverShelf(id: "trending", title: "Trending in Your Library", caption: "Most played on \(Self.thisDevice) in the last 30 days", items: trending))
        } else if !(trending.isEmpty && mixed.isEmpty) {
            // Too little play history to rank: lead with what was played, then fill with the newest additions.
            let ids = Set(trending.map(\.id))
            let fill = mixed.filter { !ids.contains($0.id) }
            let caption = trending.isEmpty ? "Nothing played yet · showing what was added most recently" : "Played here first, then the newest additions"
            shelves.append(DiscoverShelf(id: "trending", title: "Trending in Your Library", caption: caption, items: Array((trending + fill).prefix(size))))
        }

        if let forYou = try forYouShelf(sourceID: sourceID, size: size) { shelves.append(forYou) }
        if let cast = try castShelf(sourceID: sourceID, size: size) { shelves.append(cast) }

        let topMovies = try catalog.movies(VODQuery(sourceID: sourceID, sort: .rating, limit: size * 3)).filter { (Double($0.rating ?? "") ?? 0) > 0 }.prefix(size)
        if !topMovies.isEmpty { shelves.append(DiscoverShelf(id: "top-movies", title: "Top Movies This Week", caption: "Ranked by your provider's ratings · not a chart", items: items(Array(topMovies), []), ranked: true)) }
        let topShows = try catalog.series(VODQuery(sourceID: sourceID, sort: .rating, limit: size * 3)).filter { (Double($0.rating ?? "") ?? 0) > 0 }.prefix(size)
        if !topShows.isEmpty { shelves.append(DiscoverShelf(id: "top-shows", title: "Top Shows This Week", caption: "Ranked by your provider's ratings · not a chart", items: items([], Array(topShows)), ranked: true)) }

        // Provider and regional shelves come from categories that really exist in this playlist.
        let movieCats = try catalog.categories(sourceID: sourceID, kind: .movie, includeHidden: false).filter { $0.itemCount > 0 }
        let seriesCats = try catalog.categories(sourceID: sourceID, kind: .series, includeHidden: false).filter { $0.itemCount > 0 }
        for def in Self.providerShelves {
            let m = movieCats.filter { Self.matches($0.name, keywords: Set(def.keywords), phrases: def.phrases) }
            let s = seriesCats.filter { Self.matches($0.name, keywords: Set(def.keywords), phrases: def.phrases) }
            if let shelf = try categoryShelf(id: def.title, title: def.title, movieCats: m, seriesCats: s, size: size) { shelves.append(shelf) }
        }
        let im = movieCats.filter { Self.matches($0.name, keywords: Self.indianKeywords, phrases: []) }
        let isr = seriesCats.filter { Self.matches($0.name, keywords: Self.indianKeywords, phrases: []) }
        if let shelf = try categoryShelf(id: "indian", title: "Indian Entertainment", movieCats: im, seriesCats: isr, size: size) { shelves.append(shelf) }

        // Prefer an item with artwork; otherwise the newest one (the banner draws a tinted placeholder).
        let hero = recentMovies.first { $0.backdropURL != nil || $0.posterURL != nil }.map { LibraryItem.movie($0) }
            ?? recentSeries.first { $0.backdropURL != nil || $0.posterURL != nil }.map { LibraryItem.series($0) }
            ?? recentMovies.first.map { LibraryItem.movie($0) } ?? recentSeries.first.map { LibraryItem.series($0) }
        return DiscoverContent(hero: hero, shelves: shelves)
    }

    /// Titles like the last few things that were watched here, skipping everything already watched. nil until there is enough to go on.
    private func forYouShelf(sourceID: UUID?, size: Int) throws -> DiscoverShelf? {
        var seeds: [LibraryItem] = []
        for id in try history.recentIDs(kind: .movie, limit: 4) { if let m = try catalog.movie(id: id), sourceID == nil || m.sourceID == sourceID { seeds.append(.movie(m)) } }
        var seenSeries = Set<String>()
        for id in try history.recentIDs(kind: .episode, limit: 8) {
            if let e = try catalog.episode(id: id), seenSeries.insert(e.seriesID).inserted, let s = try catalog.seriesItem(id: e.seriesID), sourceID == nil || s.sourceID == sourceID { seeds.append(.series(s)) }
            if seenSeries.count == 3 { break }
        }
        guard !seeds.isEmpty else { return nil }
        let watched = Set(seeds.map(\.id))
        let similar = SimilarService(catalog: catalog)
        // Each seed gives its best matches; they are taken in turns so one favourite does not fill the row.
        var lists = seeds.map { similar.suggestions(for: $0, extras: nil).filter { !watched.contains($0.item.id) && $0.reason != "Same language" }.map(\.item) }
        var out: [LibraryItem] = []
        var seen = Set<String>()
        while out.count < size, lists.contains(where: { !$0.isEmpty }) {
            for i in lists.indices where !lists[i].isEmpty && out.count < size {
                let item = lists[i].removeFirst()
                // Copies of one film (a dub, another quality) count once.
                if seen.insert("\(SimilarTitles.stem(item.title))|\(item.year ?? 0)").inserted { out.append(item) }
            }
        }
        guard out.count >= 6 else { return nil }
        let names = seeds.prefix(2).map { "“\($0.title)”" }.joined(separator: ", ")
        return DiscoverShelf(id: "for-you", title: "For You", caption: "Because you watched \(names)", items: out)
    }

    /// The person who is in the most of the titles watched lately (at least two), and how many.
    static func favouritePerson(in watched: [String: [String]]) -> (name: String, titles: Int)? {
        var counts: [String: (name: String, n: Int)] = [:]
        for names in watched.values {
            for name in Set(names.map { PeopleIndex.norm($0) }).subtracting([""]) {
                let shown = names.first { PeopleIndex.norm($0) == name } ?? name
                counts[name] = (shown, (counts[name]?.n ?? 0) + 1)
            }
        }
        guard let top = counts.values.filter({ $0.n >= 2 }).max(by: { ($0.n, $1.name) < ($1.n, $0.name) }) else { return nil }
        return (top.name, top.n)
    }

    /// "More with" the person in most of what was watched lately, from the cast already read on this device. nil until two watched titles share someone.
    private func castShelf(sourceID: UUID?, size: Int) throws -> DiscoverShelf? {
        guard let people else { return nil }
        var watched: [String] = try history.recentIDs(kind: .movie, limit: 12)
        for id in try history.recentIDs(kind: .episode, limit: 12) { if let e = try catalog.episode(id: id), !watched.contains(e.seriesID) { watched.append(e.seriesID) } }
        guard let top = Self.favouritePerson(in: people.names(forItems: watched)) else { return nil }
        let seen = Set(watched)
        var out: [LibraryItem] = []
        var dupes = Set<String>()
        for hit in people.hits(term: top.name, kinds: [.movie, .series], sourceID: sourceID, limit: size * 3) where !seen.contains(hit.itemID) {
            let item: LibraryItem? = hit.kind == .series ? (try catalog.seriesItem(id: hit.itemID)).map { .series($0) } : (try catalog.movie(id: hit.itemID)).map { .movie($0) }
            if let item, dupes.insert("\(SimilarTitles.stem(item.title))|\(item.year ?? 0)").inserted { out.append(item) }
            if out.count == size { break }
        }
        guard out.count >= 4 else { return nil }
        return DiscoverShelf(id: "more-with", title: "More with \(top.name)", caption: "You watched \(top.titles) of their titles lately", items: out)
    }

    /// Items from the largest matching categories, newest first. nil when nothing matches.
    private func categoryShelf(id: String, title: String, movieCats: [CatalogCategory], seriesCats: [CatalogCategory], size: Int) throws -> DiscoverShelf? {
        guard !(movieCats.isEmpty && seriesCats.isEmpty) else { return nil }
        let topM = movieCats.sorted { $0.itemCount > $1.itemCount }.prefix(2), topS = seriesCats.sorted { $0.itemCount > $1.itemCount }.prefix(2)
        var movies: [Movie] = [], series: [Series] = []
        for c in topM { movies += try catalog.movies(VODQuery(sourceID: c.sourceID, categoryID: c.id, sort: .recentlyAdded, limit: size)) }
        for c in topS { series += try catalog.series(VODQuery(sourceID: c.sourceID, categoryID: c.id, sort: .recentlyAdded, limit: size)) }
        let merged: [LibraryItem] = {
            var out: [LibraryItem] = [], m = movies.makeIterator(), s = series.makeIterator()
            while out.count < size { let a = m.next(), b = s.next(); if a == nil && b == nil { break }; if let a { out.append(.movie(a)) }; if let b, out.count < size { out.append(.series(b)) } }
            return out
        }()
        guard !merged.isEmpty else { return nil }
        let names = (Array(topM) + Array(topS)).map(\.name).uniqued(by: { $0 }).prefix(2).map { "“\($0)”" }.joined(separator: ", ")
        return DiscoverShelf(id: id, title: title, caption: "From your playlist's \(names) \(names.contains(",") ? "categories" : "category")", items: merged)
    }

    /// Whole-word / whole-phrase match on a normalized category name ("Apple TV+" → "apple tv plus").
    static func matches(_ name: String, keywords: Set<String>, phrases: [String]) -> Bool {
        let norm = MetadataNormalizer.normalize(name)
        let tokens = Set(norm.split(separator: " ").map(String.init))
        if !tokens.isDisjoint(with: keywords) { return true }
        return phrases.contains { norm.contains($0) }
    }
}
