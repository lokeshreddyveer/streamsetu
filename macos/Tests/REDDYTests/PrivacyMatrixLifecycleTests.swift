import Testing
import Foundation
import CoreGraphics
@testable import REDDY

/// The privacy matrix, part two: what is kept (pictures, shown history, widget payload), what changes when a lock is made or ends, and what must not change (Continue Watching).
@Suite("Privacy matrix: lifecycle") @MainActor struct PrivacyMatrixLifecycleTests {
    let m: PrivacyMatrix
    init() throws { m = try PrivacyMatrix() }

    private func progress(_ id: String, kind: ContentKind = .movie, at: Double = 600) -> WatchProgress {
        WatchProgress(itemID: id, kind: kind, seriesID: nil, positionSeconds: at, durationSeconds: 6000, updatedAt: Date(), completed: false)
    }

    // MARK: twin rule

    @Test func aTitleWithARestrictedCopyIsRestrictedOnEverySurface() throws {
        try m.lock()
        m.session(locked: false)
        let v = m.repo.baseline
        // Through the identity rule and through the fallback used before identity exists.
        for pass in 0..<2 {
            if pass == 1 { try m.db.write { try $0.execute("DELETE FROM content_identity") } }
            let movies = Set(try v.movies(VODQuery(limit: 500)).map(\.id))
            #expect(movies.isDisjoint(with: m.restrictedIDs), "pass \(pass)")
            if pass == 0 { #expect(movies.isDisjoint(with: m.restrictedTwinIDs), "pass \(pass): the open twin is withheld too") }
            #expect(try v.movie(id: m.id("B:Cross Title")) == nil, "pass \(pass)")
        }
        // The open library is untouched.
        #expect(try v.movie(id: m.id("A:Open Film One")) != nil)
        #expect(try m.repo.movie(id: m.id("B:Cross Title")) != nil, "the normal view (an explicit folder) still opens it in an unlocked session")
    }

    @Test func aLockMadeOnOneFolderLocksItsTwinFolderAndLaterOnes() async throws {
        try await IsolatedDefaults.with("privacy-family") { d in
            let p = ParentalControls(catalog: m.repo, defaults: d)
            #expect(p.setPIN("2468"))
            #expect(p.setFolder(m.aSecret + "-movie", locked: true))
            #expect(p.isLocked(m.bSecret + "-movie"), "the same-named folder of the other playlist is locked with it")
            #expect(!p.isLocked(m.aOpen + "-movie"))
            // A playlist added later, with a folder of that name, is marked in the same transaction as its folders.
            let c = try TestSupport.makeSource(m.db, name: "Gamma")
            let cat = CatalogCategory(id: "G-secret-movie", sourceID: c.id, kind: .movie, providerID: "g", name: "Secret Shelf", sortOrder: 0)
            var mv = TestSupport.movie(c, "g1", "Gamma Film", year: 2001); mv.categoryID = cat.id; mv.categoryName = cat.name
            try m.indexer.commitMovies(source: c, categories: [cat], movies: [mv])
            #expect(try m.repo.lockedCategoryIDs().contains("G-secret-movie"))
            // Unlocking a folder (needs the session unlocked) unlocks its family and nothing else.
            _ = p.unlock(pin: "2468")
            #expect(p.setFolder(m.aSecret + "-movie", locked: false))
            #expect(try m.repo.lockedCategoryIDs().isDisjoint(with: [m.aSecret + "-movie", m.bSecret + "-movie", "G-secret-movie"]))
        }
    }

    @Test func hidingAFolderHidesItsFamilyAndShowingBringsItBack() throws {
        try m.favorites.hide(m.aOpen + "-movie", kind: "category")
        #expect(Set(try m.favorites.hiddenIDs(kind: "category")).isSuperset(of: [m.aOpen + "-movie", m.bOpen + "-movie"]))
        try m.favorites.unhide(m.aOpen + "-movie")
        #expect(Set(try m.favorites.hiddenIDs(kind: "category")).isDisjoint(with: [m.aOpen + "-movie", m.bOpen + "-movie"]))
    }

    // MARK: lock, unlock, relock

    @Test func theToggleSequenceNeverWidensARecommendationSurface() async throws {
        try await IsolatedDefaults.with("privacy-toggle") { d in
            let p = ParentalControls(catalog: m.repo, defaults: d)
            #expect(p.setPIN("2468"))
            let discover = DiscoverService(catalog: m.repo, history: m.history, people: PeopleIndex(db: m.db, restriction: m.repo.restriction))
            func shown() throws -> Set<String> {
                let c = try discover.build(sourceID: nil)
                return Set(c.shelves.flatMap(\.items).map(\.id)).union(c.hero.map { [$0.id] } ?? [])
            }
            #expect(p.setFolder(m.aSecret + "-movie", locked: true)); #expect(p.setFolder(m.aSecret + "-series", locked: true))
            try m.favorites.hide(m.aHidden + "-movie", kind: "category"); try m.favorites.hide(m.aHidden + "-series", kind: "category")
            let locked = try shown()
            #expect(locked.isDisjoint(with: m.restrictedIDs.union(m.restrictedTwinIDs)))
            _ = p.unlock(pin: "2468")
            #expect(try shown() == locked, "unlocking does not widen a recommendation surface")
            // ...while the explicit folder view does open it.
            #expect(try m.repo.movie(id: m.id("A:Secret Film")) != nil)
            p.lockNow()
            #expect(try shown() == locked)
            #expect(try m.repo.movie(id: m.id("A:Secret Film")) == nil)
        }
    }

    @Test func lockedFolderRowsAreNamedAndCountNothing() throws {
        try m.lock()
        m.session(locked: true)
        let rows = try m.repo.categories(sourceID: nil, kind: .movie, includeHidden: false)
        let locked = try #require(rows.first { $0.id == m.aSecret + "-movie" })
        #expect(locked.isLocked && locked.itemCount == 0 && locked.name == "Secret Shelf")
        m.session(locked: false)
        let open = try m.repo.categories(sourceID: nil, kind: .movie, includeHidden: false)
        #expect(try #require(open.first { $0.id == m.aSecret + "-movie" }).itemCount == 3, "the explicit folder view, unlocked, still counts")
    }

    @Test func visibleCountsLeaveOutLockedAndHiddenFolders() throws {
        try m.lock()
        let raw = try m.repo.counts(sourceID: m.a.id), visible = try m.repo.visibleCounts(sourceID: m.a.id)
        #expect(raw.movies == 6 && visible.movies == 2, "A has 6 movies, 2 in the open folder (\(visible.movies))")
        #expect(raw.series == 3 && visible.series == 1)
        #expect(visible.channels == 1 && raw.channels == 2)
    }

    @Test func assistantAndSiriSeeTheBaseline() throws {
        try m.lock()
        m.session(locked: false)
        let channels = try m.repo.baseline.channels(ChannelQuery(collapseVariants: false)).map(\.id)
        #expect(!channels.contains(m.id("A:Secret Channel")) && !channels.isEmpty)
        let people = PeopleIndex(db: m.db, alwaysRestricted: true)
        try people.save(itemID: m.id("A:Secret Film"), kind: .movie, sourceID: m.a.id, names: ["Zed Famous"])
        try people.save(itemID: m.id("A:Open Film One"), kind: .movie, sourceID: m.a.id, names: ["Zed Famous"])
        #expect(people.hits(term: "famous", kinds: [.movie], sourceID: nil, limit: 20).map(\.itemID) == [m.id("A:Open Film One")], "even unlocked")
        let similar = SimilarService(catalog: m.repo).suggestions(for: .movie(try #require(try m.repo.movie(id: m.id("A:Open Film One")))), extras: nil)
        #expect(Set(similar.map(\.item.id)).isDisjoint(with: m.restrictedIDs.union(m.restrictedTwinIDs)))
    }

    // MARK: Continue Watching is protected

    @Test func continueWatchingIsUnchangedAndTheWidgetFeedIsBaseline() throws {
        try m.lock()
        let ids = ["A:Open Film One", "A:Secret Film", "B:Cross Title"].map(m.id)
        for (i, id) in ids.enumerated() { try m.history.saveProgress(progress(id, at: Double(600 + i))) }
        let before = try m.history.continueWatching(limit: 20)
        // The normal service behaves as before: locked session hides locked titles, unlocked shows them.
        let live = HistoryService(repo: m.history, catalog: m.repo)
        m.session(locked: true)
        #expect(try live.continueWatching(limit: 20).count == 2, "the locked folder's title is hidden, the open twin copy is not: the live list is as it always was")
        m.session(locked: false)
        #expect(try live.continueWatching(limit: 20).count == 3)
        // The widget feed is built from the baseline: never a restricted title, in any session.
        let feed = HistoryService(repo: m.history, catalog: m.repo.baseline)
        let entries = ContinueWidgetFeed.entries(history: feed)
        #expect(entries.map(\.title) == ["Open Film One"], "\(entries.map(\.title))")
        // Nothing was written to progress by any of this.
        #expect(try m.history.continueWatching(limit: 20) == before)
    }

    // MARK: pictures

    private func tinyImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    @Test func lockingAFolderEvictsItsPicturesFromMemoryAndDisk() async throws {
        try m.lock()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(root: root, http: HTTPClient())
        let artwork = ArtworkService(cache: cache)
        let secret = URL(string: "https://img.example/A/m3.jpg")!, open = URL(string: "https://img.example/A/m1.jpg")!
        for u in [secret, open] {
            let dir = root.appendingPathComponent("Posters", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #require(ImageCache.encode(tinyImage())).write(to: dir.appendingPathComponent(ImageCache.key(u, .poster) + ".img"))
            #expect(await cache.image(for: u, kind: .poster) != nil)          // loaded: now in memory and on disk
        }
        #expect(await cache.holds(secret, kind: .poster))
        let purge = PrivacyPurge(db: m.db, artwork: artwork)
        let removed = await purge.evictArtwork(inFolders: [m.aSecret + "-movie"])
        #expect(removed >= 1)
        #expect(await !cache.holds(secret, kind: .poster), "gone from memory and disk the moment the folder is locked")
        #expect(await cache.holds(open, kind: .poster), "pictures of open folders stay")
        // The launch / relock sweep covers every locked and hidden folder.
        let hiddenURL = URL(string: "https://img.example/A/m4.jpg")!
        let dir = root.appendingPathComponent("Posters", isDirectory: true)
        try #require(ImageCache.encode(tinyImage())).write(to: dir.appendingPathComponent(ImageCache.key(hiddenURL, .poster) + ".img"))
        #expect(await cache.holds(hiddenURL, kind: .poster))
        _ = await purge.sweepRestrictedArtwork()
        #expect(await !cache.holds(hiddenURL, kind: .poster))
    }

    // MARK: what the shelves remember

    @Test func shownHistoryAndDismissalsAreProfileKeyedAndNeverHoldRestrictedTitles() throws {
        try m.lock()
        m.session(locked: false)
        let mem = RecommendationMemory(db: m.db, catalog: m.repo)
        let open = m.id("A:Open Film One"), secret = m.id("A:Secret Film"), twin = m.id("B:Cross Title")
        #expect(try mem.recordShown(profileID: "main", shelfID: "recent", itemIDs: [open, secret, twin], loadSeq: 1) == 1, "only the open title is written")
        #expect(try mem.dismiss(profileID: "main", itemID: open))
        #expect(try !mem.dismiss(profileID: "main", itemID: secret))
        #expect(try !mem.dismiss(profileID: "main", itemID: twin))
        #expect(try mem.shownKeys(profileID: "main", shelfID: "recent", loads: 3).count == 1)
        #expect(try mem.shownKeys(profileID: "kid", shelfID: "recent", loads: 3).isEmpty, "another profile reads nothing of it")
        #expect(try mem.dismissedKeys(profileID: "kid").isEmpty)
        #expect(try mem.dismissedKeys(profileID: "main").count == 1)
        // Dismissing never touches Continue Watching.
        try m.history.saveProgress(progress(open))
        try mem.undismiss(profileID: "main", itemID: open)
        #expect(try m.history.progress(for: open) != nil)
    }

    @Test func lockingPurgesWhatWasShownBeforeTheLock() async throws {
        try await IsolatedDefaults.with("privacy-shown") { d in
            let mem = RecommendationMemory(db: m.db, catalog: m.repo)
            let secret = m.id("A:Secret Film"), open = m.id("A:Open Film One")
            // Written while nothing was locked.
            #expect(try mem.recordShown(profileID: "main", shelfID: "recent", itemIDs: [open, secret], loadSeq: 1) == 2)
            let p = ParentalControls(catalog: m.repo, defaults: d)
            p.onFoldersLocked = { _ in _ = try? mem.purgeRestricted() }
            #expect(p.setPIN("2468")); #expect(p.setFolder(m.aSecret + "-movie", locked: true))
            let left = try m.db.read { try $0.query("SELECT item_id FROM smartmix_shown") { $0.string(0) } }
            #expect(left == [open], "gone in the same call, not at the next rebuild")
        }
    }

    // MARK: the limited list and the full rule agree

    @Test func aLimitedBaselineListIsTheFullRuleCutShort() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let repo = SQLiteCatalogRepository(db: db), indexer = CatalogIndexer(db: db)
        func movie(_ s: PlaylistSource, _ i: Int, _ title: String, folder: String, age: Double) -> Movie {
            var m = TestSupport.movie(s, "\(i)", title, year: 2020); m.categoryID = folder; m.categoryName = folder; m.addedAt = Date().addingTimeInterval(-age); m.rating = "7.0"; return m
        }
        func cats(_ s: PlaylistSource, _ ms: [Movie]) -> [CatalogCategory] { Set(ms.compactMap(\.categoryID)).sorted().map { CatalogCategory(id: $0, sourceID: s.id, kind: .movie, providerID: $0, name: $0, sortOrder: 0) } }
        // The 300 newest titles of A are in a locked folder; their copies in B are in an open one. Older, unrelated titles are open.
        let am = (0..<300).map { movie(a, $0, "Hot \($0) (2020)", folder: "A-locked", age: Double($0)) } + (0..<40).map { movie(a, 1000 + $0, "Old \($0) (2020)", folder: "A-open", age: 10_000 + Double($0)) }
        let bm = (0..<300).map { movie(b, $0, "Hot \($0) (2020)", folder: "B-open", age: Double($0) + 0.5) } + (0..<40).map { movie(b, 1000 + $0, "Old \($0) (2020)", folder: "B-open", age: 10_000.5 + Double($0)) }
        _ = try indexer.commitMovies(source: a, categories: cats(a, am), movies: am); _ = try indexer.commitMovies(source: b, categories: cats(b, bm), movies: bm)
        try repo.setCategoryLocked("A-locked", true)
        let v = repo.baseline
        for sort in [VODSort.recentlyAdded, .rating, .title] {
            let limited = try v.movies(VODQuery(sort: sort, limit: 5)).map(\.id)
            let full = try v.movies(VODQuery(sort: sort, limit: nil)).map(\.id)          // no limit: the twin rule inside the query
            #expect(limited == Array(full.prefix(5)), "\(sort)")
            #expect(limited.count == 5)
        }
        let top = try v.movies(VODQuery(sort: .recentlyAdded, limit: 5))
        #expect(top.allSatisfy { $0.title.hasPrefix("Old") }, "all 300 hot titles have a locked copy, so the list starts at the old ones: \(top.map(\.title))")
        // No folder locked at all: nothing is withheld and the two forms still agree.
        try repo.setCategoryLocked("A-locked", false)
        #expect(try v.movies(VODQuery(sort: .recentlyAdded, limit: 5)).map(\.id) == Array(try v.movies(VODQuery(sort: .recentlyAdded, limit: nil)).map(\.id).prefix(5)))
    }
}
