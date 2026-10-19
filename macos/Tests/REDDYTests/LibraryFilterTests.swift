import Testing
import Foundation
@testable import REDDY

@Suite struct LibraryFilterTests {
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository
    let history: SQLiteHistoryRepository
    let source: PlaylistSource
    let movies: [Movie]

    init() throws {
        let database = try TestSupport.makeDB()
        let src = try TestSupport.makeSource(database)
        func movie(_ pid: String, _ title: String, year: Int, rating: String?, folder: String = "Action") -> Movie {
            var m = TestSupport.movie(src, pid, title, year: year)
            m.rating = rating; m.categoryName = folder
            return m
        }
        let made = [
            movie("1", "Lucky Baskhar (2024) (Telugu)", year: 2024, rating: "8.1"),
            movie("2", "Whalefall (2026) (English) 4K", year: 2026, rating: "7.1"),
            movie("3", "Old Film (1995)", year: 1995, rating: "5.0", folder: "Hindi Classics"),
            movie("4", "Plain (2012)", year: 2012, rating: nil),
        ]
        try CatalogIndexer(db: database).commitMovies(source: src, categories: [], movies: made)
        db = database; source = src; movies = made
        catalog = SQLiteCatalogRepository(db: database)
        history = SQLiteHistoryRepository(db: database)
    }

    private func titles(_ configure: (inout VODQuery) -> Void) throws -> [String] {
        var q = VODQuery(sourceID: source.id); configure(&q)
        return try catalog.movies(q).map(\.title).sorted()
    }

    @Test func languageComesFromBracketsOrTheFolderName() throws {
        #expect(try titles { $0.language = "Telugu" } == ["Lucky Baskhar (2024) (Telugu)"])
        #expect(try titles { $0.language = "Hindi" } == ["Old Film (1995)"])
    }

    @Test func qualityRatingAndDecadeNarrowTheList() throws {
        #expect(try titles { $0.quality = "4K" } == ["Whalefall (2026) (English) 4K"])
        #expect(try titles { $0.minRating = 8 } == ["Lucky Baskhar (2024) (Telugu)"])
        #expect(try titles { $0.decade = 2020 }.count == 2)
        #expect(try titles { $0.decade = 1990 } == ["Old Film (1995)"])
    }

    @Test func watchedAndStartedUseTheResumePoints() throws {
        try history.markWatched(itemID: movies[0].id, kind: .movie, seriesID: nil, duration: 6000)
        try history.saveProgress(WatchProgress(itemID: movies[1].id, kind: .movie, seriesID: nil, positionSeconds: 900, durationSeconds: 6000, updatedAt: Date(), completed: false))
        #expect(try titles { $0.watch = .watched } == ["Lucky Baskhar (2024) (Telugu)"])
        #expect(try titles { $0.watch = .started } == ["Whalefall (2026) (English) 4K"])
    }

    @Test func theOptionsAreOnlyWhatTheListHasInAlphabeticalOrder() throws {
        let options = try catalog.filterOptions(sourceID: source.id, kind: .movie)
        #expect(options.languages == ["English", "Hindi", "Telugu"])
        #expect(options.qualities == ["4K"])
    }

    @Test func aFilterBecomesPartOfTheQuery() {
        var filter = LibraryFilter(); filter.language = "Telugu"; filter.status = .favorites; filter.minRating = 7
        var q = VODQuery(); filter.apply(to: &q, kind: .movie)
        #expect(q.language == "Telugu" && q.favoritesOnly && q.minRating == 7)
        #expect(filter.count == 3)
    }
}
