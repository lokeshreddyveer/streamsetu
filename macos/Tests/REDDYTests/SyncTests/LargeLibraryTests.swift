import Testing
import Foundation
@testable import REDDY

/// A library the size of the biggest IPTV providers (about 100,000 channels and 40,000 movies). The budgets are generous, because
/// the suite runs many tests at once; the aim is to catch a query that scans everything, not to benchmark.
@Suite("Large library (100,000 channels)") @MainActor struct LargeLibraryTests {
    func timed<T>(_ label: String, _ budget: Double, _ body: () throws -> T) rethrows -> T {
        let started = Date()
        let r = try body()
        let took = Date().timeIntervalSince(started)
        print("PERF \(label): \(String(format: "%.3f", took)) s")
        #expect(took < budget, "\(label) took \(took)s (budget \(budget)s)")
        return r
    }

    @Test(.timeLimit(.minutes(5))) func everyEverydayOperationStaysFast() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-big-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let folders = 120
        let cats = (0..<folders).map { i in CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .channel, provider: "\(i)"), sourceID: src.id, kind: .channel, providerID: "\(i)", name: "Group \(i) \(["News", "Sports", "Movies", "Kids", "Music"][i % 5])", sortOrder: i) }
        let channels: [Channel] = (0..<100_000).map { n in
            var ch = TestSupport.channel(src, "\(n)", "Channel \(n) \(["Alpha", "Bravo", "Charlie", "Delta"][n % 4]) HD", cat: nil, order: n)
            ch.categoryID = cats[n % folders].id; ch.categoryName = cats[n % folders].name
            return ch
        }
        let movies: [Movie] = (0..<40_000).map { TestSupport.movie(src, "m\($0)", "Movie Title \($0)", year: 1980 + $0 % 45) }

        _ = try timed("import 100,000 channels", 120) { try c.indexer.commitChannels(source: src, categories: cats, channels: channels) }
        _ = try timed("import 40,000 movies", 60) { try c.indexer.commitMovies(source: src, categories: [], movies: movies) }

        let folderList = try timed("sidebar folder list (120 folders, with counts)", 3) { try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false) }
        #expect(folderList.count == folders && folderList.reduce(0) { $0 + $1.itemCount } > 0)
        let page = try timed("one screen of channels from one folder", 1) { try c.catalog.channels(ChannelQuery(sourceID: src.id, categoryID: cats[7].id, limit: 200)) }
        #expect(!page.isEmpty)
        let everything = try timed("every channel at once (what the Live TV list loads)", 4) { try c.catalog.channels(ChannelQuery(sourceID: src.id, collapseVariants: true)) }
        #expect(everything.count > 90_000)
        let all = try timed("first 200 of all channels", 1) { try c.catalog.channels(ChannelQuery(sourceID: src.id, limit: 200)) }
        #expect(all.count == 200)
        let found = try timed("catalog search for “charlie”", 2) { try c.catalog.channels(ChannelQuery(sourceID: src.id, search: "charlie", collapseVariants: false, limit: 200)) }
        #expect(!found.isEmpty)
        let counts = try timed("library counts", 2) { try c.catalog.counts(sourceID: src.id) }
        #expect(counts.channels == 100_000 && counts.movies == 40_000)
        let moviesPage = try timed("first 200 movies, newest first", 1) { try c.catalog.movies(VODQuery(sourceID: src.id, sort: .recentlyAdded, limit: 200)) }
        #expect(moviesPage.count == 200)
        // hiding 5,000 channels must not slow every list down
        for ch in channels.prefix(5000) { try c.favoritesRepo.hide(ch.id, kind: "channel") }
        let afterHiding = try timed("one screen of channels with 5,000 hidden", 1.5) { try c.catalog.channels(ChannelQuery(sourceID: src.id, limit: 200)) }
        #expect(afterHiding.count == 200)
        // locked folders add a clause to every query
        let parental = ParentalControls(catalog: c.catalog, defaults: UserDefaults(suiteName: "big-\(UUID().uuidString)")!)
        parental.setPIN("2468")
        for cat in cats.prefix(40) { parental.setFolder(cat.id, locked: true) }
        let restricted = try timed("one screen of channels with 40 locked folders", 1.5) { try c.catalog.channels(ChannelQuery(sourceID: src.id, limit: 200)) }
        #expect(restricted.count == 200)
        // best of three: the whole suite runs in parallel, so one slow run says more about the machine than the code
        var took = Double.infinity, globalSearch: GlobalSearchResults?
        for _ in 0..<3 {
            let started = Date()
            globalSearch = try await c.globalSearch.search("movie title 123")
            took = min(took, Date().timeIntervalSince(started))
        }
        print("PERF global search (all kinds): \(String(format: "%.3f", took)) s")
        #expect(took < 3 && globalSearch?.isEmpty == false, "global search took \(took)s")
    }
}
