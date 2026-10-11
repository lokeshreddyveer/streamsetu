import Testing
import Foundation
@testable import REDDY

@Suite("Catalog indexing & search") struct IndexingTests {
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository
    let indexer: CatalogIndexer
    let search: SQLiteSearchRepository
    let favorites: SQLiteFavoritesRepository

    init() throws {
        db = try TestSupport.makeDB()
        catalog = SQLiteCatalogRepository(db: db)
        indexer = CatalogIndexer(db: db)
        search = SQLiteSearchRepository(db: db)
        favorites = SQLiteFavoritesRepository(db: db)
    }

    private func seed(_ names: [String], source: PlaylistSource) throws {
        let chans = names.enumerated().map { TestSupport.channel(source, "c\($0.offset)", $0.element, order: $0.offset) }
        try indexer.commitChannels(source: source, categories: [], channels: chans)
    }

    @Test func commitStoresAndListsChannels() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["BBC News", "CNN", "Sky Sports"], source: s)
        let list = try catalog.channels(ChannelQuery())
        #expect(list.map(\.name) == ["BBC News", "CNN", "Sky Sports"])
        #expect(try catalog.counts(sourceID: s.id).channels == 3)
    }

    @Test func prefixAndAccentInsensitiveSearch() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["Café Zürich", "BBC News", "BBC World News", "Sports Arena"], source: s)
        #expect(try catalog.channels(ChannelQuery(search: "bbc new")).count == 2)
        #expect(try catalog.channels(ChannelQuery(search: "cafe")).map(\.name) == ["Café Zürich"])
        #expect(try catalog.channels(ChannelQuery(search: "zur")).count == 1)
        #expect(try catalog.channels(ChannelQuery(search: "zzz")).isEmpty)
    }

    @Test func searchInputCannotInjectFTSSyntax() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["BBC News"], source: s)
        for evil in ["\"; DROP TABLE channels;--", "bbc OR *", "NEAR(a b)", "title:bbc", "(((", "bbc\" AND \"x"] {
            _ = try catalog.channels(ChannelQuery(search: evil))     // must not throw
        }
        #expect(try catalog.counts(sourceID: s.id).channels == 1)
    }

    @Test func globalSearchRanksExactThenPrefix() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["News Network", "Breaking News Today", "News"], source: s)
        let hits = try search.search(term: "news", filters: SearchFilters(), limit: 10)
        #expect(hits.first?.title == "News")
        #expect(hits.count == 3)
    }

    @Test func searchScopesByKind() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["Matrix Channel"], source: s)
        try indexer.commitMovies(source: s, categories: [], movies: [TestSupport.movie(s, "m1", "The Matrix", year: 1999)])
        try indexer.commitSeries(source: s, categories: [], series: [TestSupport.series(s, "s1", "Matrix Chronicles")])
        #expect(try search.search(term: "matrix", filters: SearchFilters(), limit: 10).count == 3)
        #expect(try search.search(term: "matrix", filters: SearchFilters(kinds: [.movie]), limit: 10).map(\.kind) == [.movie])
    }

    @Test func refreshKeepsFavoritesProgressAndRenames() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["BBC News", "CNN"], source: s)
        let bbc = try #require(try catalog.channels(ChannelQuery(search: "bbc")).first)
        try favorites.setFavorite(bbc.id, kind: .channel, on: true)
        try favorites.setOverride(itemID: bbc.id, displayName: "My BBC", categoryName: nil, epgID: nil)
        // provider refresh: same ids, changed order and a new channel; rotating stream refs
        var again = ["CNN", "BBC News", "Al Jazeera"].enumerated().map { TestSupport.channel(s, "c\([1, 0, 2][$0.offset])", $0.element, order: $0.offset) }
        again[1].streamRef = "http://rotated-token/1.ts"
        try indexer.commitChannels(source: s, categories: [], channels: again)
        let after = try #require(try catalog.channel(id: bbc.id))
        #expect(after.isFavorite)
        #expect(after.name == "My BBC")
        #expect(after.streamRef == "http://rotated-token/1.ts")
        #expect(try catalog.channels(ChannelQuery(search: "my bbc")).count == 1)
    }

    @Test func removedChannelsDisappearFromListAndSearch() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["Alpha One", "Alpha Two", "Beta"], source: s)
        try seed(["Alpha One", "Beta"], source: s)
        #expect(try catalog.channels(ChannelQuery(search: "alpha")).map(\.name) == ["Alpha One"])
        #expect(try IndexHealthMonitor(db: db).check().healthy)
    }

    @Test func emptyOrCollapsedRefreshNeverReplacesGoodCatalog() throws {
        let s = try TestSupport.makeSource(db)
        try seed((0..<200).map { "Channel \($0)" }, source: s)
        #expect(throws: IndexError.self) { try indexer.commitChannels(source: s, categories: [], channels: []) }
        #expect(throws: IndexError.self) {
            try indexer.commitChannels(source: s, categories: [], channels: [TestSupport.channel(s, "x", "Only one")])
        }
        #expect(try catalog.counts(sourceID: s.id).channels == 200)
    }

    @Test func duplicateIDsInOneBatchAreCollapsed() throws {
        let s = try TestSupport.makeSource(db)
        let c = TestSupport.channel(s, "dup", "Dup")
        try indexer.commitChannels(source: s, categories: [], channels: [c, c, c])
        #expect(try catalog.counts(sourceID: s.id).channels == 1)
    }

    @Test func hiddenChannelsAndCategoriesAreExcluded() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["One", "Two"], source: s)
        let list = try catalog.channels(ChannelQuery())
        try favorites.hide(list[0].id, kind: "channel")
        #expect(try catalog.channels(ChannelQuery()).map(\.name) == ["Two"])
        #expect(try catalog.channels(ChannelQuery(includeHidden: true)).count == 2)
        try favorites.unhide(list[0].id)
        #expect(try catalog.channels(ChannelQuery()).count == 2)
    }

    @Test func variantsCollapseInBrowseButNotInSearch() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["Sky Sports", "Sky Sports HD", "Sky Sports FHD", "CNN"], source: s)
        #expect(try catalog.channels(ChannelQuery()).map(\.name) == ["Sky Sports FHD", "CNN"])
        #expect(try catalog.channels(ChannelQuery(search: "sky")).count == 3)
        let v = try catalog.variants(ofChannel: try #require(try catalog.channels(ChannelQuery(search: "sky sports hd")).first).id)
        #expect(Set(v.map(\.label)) == ["FHD", "HD", "Alt 1"])
    }

    @Test func deletingSourceRemovesItsDataEverywhere() throws {
        let s = try TestSupport.makeSource(db)
        try seed(["BBC"], source: s)
        let c = try #require(try catalog.channels(ChannelQuery()).first)
        try favorites.setFavorite(c.id, kind: .channel, on: true)
        try catalog.deleteSource(id: s.id)
        #expect(try catalog.counts(sourceID: nil).channels == 0)
        #expect(try favorites.favoriteIDs(kind: .channel).isEmpty)
        #expect(try search.search(term: "bbc", filters: SearchFilters(), limit: 5).isEmpty)
        #expect(try IndexHealthMonitor(db: db).check().healthy)
    }

    @Test func movieDetailsSurviveRefresh() throws {
        let s = try TestSupport.makeSource(db)
        let m = TestSupport.movie(s, "m1", "Inception", year: 2010)
        try indexer.commitMovies(source: s, categories: [], movies: [m])
        try indexer.saveMovieDetail(id: m.id, detail: MovieDetail(overview: "Dreams.", backdropURL: "http://b", posterURL: nil, genre: "Sci-Fi", releaseYear: nil, durationSeconds: 8880, rating: "8.8"))
        try indexer.commitMovies(source: s, categories: [], movies: [m])    // refresh brings no detail fields
        let after = try #require(try catalog.movie(id: m.id))
        #expect(after.overview == "Dreams." && after.genre == "Sci-Fi" && after.durationSeconds == 8880)
        #expect(try search.search(term: "inception", filters: SearchFilters(genre: "Sci-Fi"), limit: 5).count == 1)
    }

    @Test func seriesEpisodesSortNumericallyAndKeepProgress() throws {
        let s = try TestSupport.makeSource(db)
        let sr = TestSupport.series(s, "s1", "Show")
        try indexer.commitSeries(source: s, categories: [], series: [sr])
        func ep(_ season: Int, _ n: Int) -> Episode {
            Episode(id: ItemID.make(source: s.id, kind: .episode, provider: "e\(season)-\(n)"), seriesID: sr.id, seasonID: "\(sr.id)|season|\(season)",
                    seasonNumber: season, providerEpisodeID: "e\(season)-\(n)", episodeNumber: n, title: "Episode \(n)", overview: nil,
                    imageURL: nil, durationSeconds: 1800, streamRef: "e\(season)-\(n).mp4")
        }
        let eps = [ep(1, 10), ep(1, 2), ep(2, 1), ep(1, 1)]
        let detail = SeriesDetail(series: sr, seasons: [Season(id: "\(sr.id)|season|1", seriesID: sr.id, number: 1, name: nil), Season(id: "\(sr.id)|season|2", seriesID: sr.id, number: 2, name: nil)], episodes: eps)
        try indexer.saveSeriesDetail(detail)
        let history = SQLiteHistoryRepository(db: db)
        try history.saveProgress(WatchProgress(itemID: eps[1].id, kind: .episode, seriesID: sr.id, positionSeconds: 600, durationSeconds: 1800, updatedAt: Date(), completed: false))
        try indexer.saveSeriesDetail(detail)       // re-fetch details
        let stored = try catalog.episodes(seriesID: sr.id)
        #expect(stored.map(\.episodeNumber) == [1, 2, 10, 1])
        #expect(stored.map(\.seasonNumber) == [1, 1, 1, 2])
        #expect(try history.progress(for: eps[1].id)?.positionSeconds == 600)
    }
}
