import Testing
import Foundation
@testable import REDDY

@MainActor @Suite struct WatchQueueTests {
    let catalog: SQLiteCatalogRepository
    let source: PlaylistSource
    let a: Movie, b: Movie, show: Series
    let defaults: UserDefaults

    init() throws {
        let db = try TestSupport.makeDB()
        catalog = SQLiteCatalogRepository(db: db)
        source = try TestSupport.makeSource(db)
        a = TestSupport.movie(source, "1", "Alpha"); b = TestSupport.movie(source, "2", "Beta"); show = TestSupport.series(source, "9", "Gamma Show")
        let indexer = CatalogIndexer(db: db)
        try indexer.commitMovies(source: source, categories: [], movies: [a, b])
        try indexer.commitSeries(source: source, categories: [], series: [show])
        defaults = UserDefaults(suiteName: "queue-test-\(UUID().uuidString)")!
    }

    @Test func titlesPlayInTheOrderTheyWereAdded() {
        let q = WatchQueue(catalog: catalog, defaults: defaults)
        q.add(.movie(a)); q.add(.series(show))
        #expect(q.popNext()?.id == a.id)
        #expect(q.popNext()?.id == show.id)
        #expect(q.popNext() == nil)
    }

    @Test func playNextGoesToTheFrontAndATitleIsNeverQueuedTwice() {
        let q = WatchQueue(catalog: catalog, defaults: defaults)
        q.add(.movie(a)); q.add(.movie(b))
        q.add(.movie(b), next: true)
        #expect(q.items.map(\.id) == [b.id, a.id])
        q.add(.movie(a))                                  // adding again moves it to the end, it does not appear twice
        #expect(q.items.map(\.id) == [b.id, a.id])
    }

    @Test func aTitleCanBeTakenOutOrTheWholeLineCleared() {
        let q = WatchQueue(catalog: catalog, defaults: defaults)
        q.add(.movie(a)); q.add(.movie(b))
        q.remove(a.id)
        #expect(q.items.map(\.id) == [b.id] && !q.contains(a.id))
        q.clear()
        #expect(q.items.isEmpty)
    }

    @Test func theLineIsKeptBetweenLaunches() {
        let first = WatchQueue(catalog: catalog, defaults: defaults)
        first.add(.movie(a)); first.add(.series(show))
        let second = WatchQueue(catalog: catalog, defaults: defaults)
        #expect(second.items.map(\.id) == [a.id, show.id])
    }

    @Test func aTitleThatLeftTheLibraryIsDroppedOnLoad() throws {
        defaults.set(["movie:\(a.id)", "movie:gone"], forKey: "watchQueue")
        let q = WatchQueue(catalog: catalog, defaults: defaults)
        #expect(q.items.map(\.id) == [a.id])
    }
}
