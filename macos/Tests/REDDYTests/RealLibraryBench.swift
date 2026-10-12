import Testing
import Foundation
@testable import REDDY

/// Temporary timing of the screens' real queries against a copy of a real library. Skipped unless BENCH_DB is set.
@Suite struct RealLibraryBench {
    @Test func timings() throws {
        guard let path = ProcessInfo.processInfo.environment["BENCH_DB"] else { return }
        let db = try DatabaseManager(path: path)
        let c = SQLiteCatalogRepository(db: db)
        func t(_ name: String, _ f: () throws -> Int) {
            let s = Date(); let n = (try? f()) ?? -1
            print("BENCH \(name): \(String(format: "%.0f", Date().timeIntervalSince(s) * 1000)) ms (\(n))")
        }
        t("sources") { (try c.sources()).count }
        t("counts") { let k = try c.counts(sourceID: nil); return k.channels + k.movies + k.series }
        t("categories channel") { (try c.categories(sourceID: nil, kind: .channel, includeHidden: false)).count }
        t("channels page 600") { var q = ChannelQuery(sourceID: nil); q.limit = 600; return (try c.channels(q)).count }
        t("channels search 'news'") { var q = ChannelQuery(sourceID: nil, search: "news"); q.limit = 600; return (try c.channels(q)).count }
        t("movies page 60") { (try c.movies(VODQuery(sourceID: nil, sort: .recentlyAdded, limit: 60))).count }
        t("movies count") { try c.countMovies(VODQuery(sourceID: nil, sort: .recentlyAdded, limit: 60)) }
        t("movies search 'dune' page") { (try c.movies(VODQuery(sourceID: nil, search: "dune", sort: .recentlyAdded, limit: 60))).count }
        t("movies search 'dune' count") { try c.countMovies(VODQuery(sourceID: nil, search: "dune", sort: .recentlyAdded, limit: 60)) }
        t("series page 60") { (try c.series(VODQuery(sourceID: nil, sort: .recentlyAdded, limit: 60))).count }
        t("movies by rating 42") { (try c.movies(VODQuery(sourceID: nil, sort: .rating, limit: 42))).count }
        t("movie categories") { (try c.categories(sourceID: nil, kind: .movie, includeHidden: false)).count }
        let svc = DiscoverService(catalog: c, history: SQLiteHistoryRepository(db: db))
        t("discover.build") { (try svc.build(sourceID: nil)).shelves.count }
    }
}
