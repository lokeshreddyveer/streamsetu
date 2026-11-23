import Testing
import Foundation
@testable import REDDY

/// Screen models kept across tab switches: they survive a switch, stay bounded, and never cross a profile, playlist or restriction change.
@Suite("Screen retention", .serialized) @MainActor struct ScreenRetentionTests {
    let a = UUID(), b = UUID()
    func key(_ s: ScreenKey.Screen = .library(.movie), profile: String = "main", source: UUID? = nil) -> ScreenKey { ScreenKey(screen: s, profile: profile, source: source) }

    @Test func aModelSurvivesAndTheSameInstanceComesBack() {
        let store = ScreenRetention.makeStore()
        let first = store.model(key(source: a), revision: 0) { LibraryBrowserViewModel(kind: .movie) }
        first.search = "heist"; first.sort = .titleAZ; first.scrollAnchor = "m42"
        var built = 0
        let again = store.model(key(source: a), revision: 0) { built += 1; return LibraryBrowserViewModel(kind: .movie) }
        #expect(again === first && built == 0)
        #expect(again.search == "heist" && again.sort == .titleAZ && again.scrollAnchor == "m42")
    }

    @Test func eachScreenAndKindHasItsOwnModel() {
        let store = ScreenRetention.makeStore()
        let movies = store.model(key(.library(.movie)), revision: 0) { LibraryBrowserViewModel(kind: .movie) }
        let series = store.model(key(.library(.series)), revision: 0) { LibraryBrowserViewModel(kind: .series) }
        let live = store.model(key(.liveTV), revision: 0) { LiveTVViewModel() }
        let guide = store.model(key(.guide), revision: 0) { GuideViewModel() }
        #expect(movies !== series && store.count == 4)
        #expect(live === store.model(key(.liveTV), revision: 0) { LiveTVViewModel() })
        #expect(guide === store.model(key(.guide), revision: 0) { GuideViewModel() })
    }

    @Test func anotherProfileOrPlaylistNeverGetsTheModel() {
        let store = ScreenRetention.makeStore()
        let mine = store.model(key(profile: "main", source: a), revision: 0) { LibraryBrowserViewModel(kind: .movie) }
        mine.search = "private"
        let kid = store.model(key(profile: "kid", source: a), revision: 0) { LibraryBrowserViewModel(kind: .movie) }
        let other = store.model(key(profile: "main", source: b), revision: 0) { LibraryBrowserViewModel(kind: .movie) }
        #expect(kid !== mine && other !== mine)
        #expect(kid.search.isEmpty && other.search.isEmpty)
    }

    @Test func aRestrictionChangeDiscardsTheModel() {
        let store = ScreenRetention.makeStore()
        let first = store.model(key(), revision: 1) { LibraryBrowserViewModel(kind: .movie) }
        let after = store.model(key(), revision: 2) { LibraryBrowserViewModel(kind: .movie) }
        #expect(after !== first)
        #expect(store.model(key(), revision: 1) { LibraryBrowserViewModel(kind: .movie) } !== after, "the old revision never comes back either")
    }

    @Test func theLeastRecentlyUsedModelGoesFirstAndTheCountIsBounded() {
        let store = ScreenRetention.makeStore()
        let keys = (0..<ScreenRetention.maxModels).map { key(.library(.movie), profile: "p\($0)") }
        let models = keys.map { k in store.model(k, revision: 0) { LibraryBrowserViewModel(kind: .movie) } }
        #expect(store.count == ScreenRetention.maxModels)
        _ = store.model(keys[0], revision: 0) { LibraryBrowserViewModel(kind: .movie) }          // keys[0] is now the most recent
        _ = store.model(key(.liveTV), revision: 0) { LiveTVViewModel() }                           // one more: keys[1] is the oldest
        #expect(store.count == ScreenRetention.maxModels)
        #expect(store.model(keys[0], revision: 0) { LibraryBrowserViewModel(kind: .movie) } === models[0])
        #expect(store.model(keys[1], revision: 0) { LibraryBrowserViewModel(kind: .movie) } !== models[1])
        for i in 0..<50 { _ = store.model(key(profile: "x\(i)"), revision: 0) { LibraryBrowserViewModel(kind: .movie) } }
        #expect(store.count <= ScreenRetention.maxModels && store.totalCost <= ScreenRetention.maxModels)
    }

    @Test func leavingAProfileOrPlaylistReleasesItsModels() {
        let store = ScreenRetention.makeStore()
        _ = store.model(key(profile: "main", source: a), revision: 0) { LibraryBrowserViewModel(kind: .movie) }
        _ = store.model(key(.liveTV, profile: "main", source: a), revision: 0) { LiveTVViewModel() }
        _ = store.model(key(profile: "kid", source: a), revision: 0) { LibraryBrowserViewModel(kind: .movie) }
        store.removeAll { $0.profile != "kid" }
        #expect(store.count == 1)
        store.removeAll { $0.source != b }
        #expect(store.count == 0)
    }

    @Test func memoryPressureAndLockingEmptyTheStore() {
        let store = ScreenRetention.makeStore()
        for i in 0..<4 { _ = store.model(key(profile: "p\(i)"), revision: 0) { LibraryBrowserViewModel(kind: .movie) } }
        store.clear()
        #expect(store.count == 0 && store.totalCost == 0)
    }

    @Test func aLongListIsCutBackWhileHiddenAndStillLoadsMore() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-sr-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "Retention")
        let movies = (0..<700).map { TestSupport.movie(s, "m\($0)", "Title \(String(format: "%04d", $0))", year: 2020) }
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [], movies: movies)
        let vm = LibraryBrowserViewModel(kind: .movie)
        vm.sort = .titleAZ
        let sel = SidebarSelection.shortcut(.allMovies)
        await vm.reset(c, selection: sel, source: s.id)
        #expect(vm.items.count == 120)
        vm.trimForRetention()
        #expect(vm.items.count == 120, "a short list is kept whole")
        while vm.hasMore, vm.items.count < 600 { await vm.loadMoreIfNeeded(c, current: vm.items[vm.items.count - 1], selection: sel, source: s.id) }
        #expect(vm.items.count == 600 && ScreenRetention.maxRetainedItems == 480)
        let full = vm.items.map(\.id)
        vm.trimForRetention()
        #expect(vm.items.count == ScreenRetention.maxRetainedItems && vm.hasMore, "cut back to the cap while hidden")
        #expect(vm.items.map(\.id) == Array(full.prefix(480)))
        await vm.loadMoreIfNeeded(c, current: vm.items[vm.items.count - 1], selection: sel, source: s.id)
        #expect(vm.items.map(\.id) == Array(full.prefix(600)), "loading more continues at the cut, with no gap and no repeat")
    }

    @Test func aListThatDependsOnWatchedOrFavouriteStateIsNeverSkippedOnReturn() {
        let all = SidebarSelection.shortcut(.allMovies)
        #expect(LibraryBrowserViewModel.isStaticListing(all, filter: LibraryFilter(), search: ""))
        var f = LibraryFilter(); f.language = "Hindi"; f.quality = "4K"
        #expect(LibraryBrowserViewModel.isStaticListing(all, filter: f, search: "heist"), "catalog-only filters and a title search stay static")
        for status in LibraryFilter.Status.allCases {
            var g = LibraryFilter(); g.status = status
            #expect(!LibraryBrowserViewModel.isStaticListing(all, filter: g, search: ""), "\(status)")
            #expect(!LibraryBrowserViewModel.isStaticListing(.folder("x"), filter: g, search: ""))
        }
        #expect(!LibraryBrowserViewModel.isStaticListing(all, filter: LibraryFilter(), search: "unwatched thriller"), "a sentence that says unwatched is a watched-state list")
    }

    @Test func leavingWhileASearchIsPendingMakesTheReturnReadTheListAgain() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-sr3-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let vm = LibraryBrowserViewModel(kind: .movie)
        vm.loadedKey = "k"
        vm.search = "bbc"; vm.scheduleSearch(c, selection: .shortcut(.allMovies), source: nil)
        vm.trimForRetention()
        #expect(vm.loadedKey == nil, "the text says bbc but the list is the old one: the return must read it again")
        let live = LiveTVViewModel()
        live.loadedKey = "k"
        live.search = "bbc"; live.scheduleSearch(c)
        live.trimForRetention()
        #expect(live.loadedKey == nil)
        let quiet = LibraryBrowserViewModel(kind: .movie); quiet.loadedKey = "k"; quiet.trimForRetention()
        #expect(quiet.loadedKey == "k", "nothing pending: the list is kept")
    }

    @Test func nowNextFetchingResumesAfterAScreenIsLeftWhileOneWasScheduled() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-sr4-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let live = LiveTVViewModel()
        live.want("a", c)                  // schedules the batch (250 ms)
        live.trimForRetention()            // the person switched tab before it ran
        live.want("b", c)                  // back on the screen: a new row appears
        for _ in 0..<200 where !live.nowNext.isKnown("b") { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(live.nowNext.isKnown("b"), "the fetch must start again; before, the cancelled one left the guard shut for good")
    }

    @Test func aChangedDefaultSortApplies_ButAChosenSortSurvivesAReturn() {
        let vm = LibraryBrowserViewModel(kind: .movie)
        vm.applyDefaultSort(.recentlyAdded)
        vm.sort = .titleZA                                     // the person's own choice
        vm.applyDefaultSort(.recentlyAdded)                    // returning to the screen: same setting
        #expect(vm.sort == .titleZA)
        vm.applyDefaultSort(.topRated)                         // the setting changed
        #expect(vm.sort == .topRated)
    }

    @Test func everyModelGetsItsOwnNumber() {
        let ids = (0..<20).map { _ in LibraryBrowserViewModel(kind: .movie).uid } + (0..<20).map { _ in LiveTVViewModel().uid } + (0..<5).map { _ in GuideViewModel().uid } + (0..<5).map { _ in FolderRowsModel(kind: .movie).uid }
        #expect(Set(ids).count == ids.count)
    }

    @Test func staticListingsAreTheOnlyOnesSkippedOnReturn() {
        #expect(LibraryBrowserViewModel.isStaticListing(.folder("x")))
        #expect(LibraryBrowserViewModel.isStaticListing(.shortcut(.allMovies)))
        #expect(!LibraryBrowserViewModel.isStaticListing(.shortcut(.favorites)))
        #expect(!LibraryBrowserViewModel.isStaticListing(.shortcut(.continueWatching)))
        #expect(!LibraryBrowserViewModel.isStaticListing(.shortcut(.watchLater)))
        let live = LiveTVViewModel()
        #expect(live.isStaticListing(.all) && live.isStaticListing(.category("c")))
        #expect(!live.isStaticListing(.favorites) && !live.isStaticListing(.recent))
        live.listID = "list"
        #expect(!live.isStaticListing(.all))
    }

    @Test func aLongChannelListIsDroppedWhileHiddenButASmallOneIsKept() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-sr2-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "Live")
        let live = LiveTVViewModel()
        live.channels = (0..<10).map { TestSupport.channel(s, "\($0)", "Channel \($0)", order: $0) }
        live.loadedKey = "k"
        live.trimForRetention()
        #expect(live.channels.count == 10 && live.loadedKey == "k")
        live.channels = (0..<(ScreenRetention.maxRetainedChannels + 1)).map { TestSupport.channel(s, "\($0)", "Channel \($0)", order: $0) }
        live.trimForRetention()
        #expect(live.channels.isEmpty && live.loadedKey == nil, "dropped, and marked as needing a read")
    }

    @Test func theGuideWindowIsReusedOnlyWhileFresh() {
        let g = GuideViewModel()
        #expect(!g.isFresh(maxAge: 600))
        g.markLoaded("k")
        #expect(g.isFresh(maxAge: 600) && g.loadedKey == "k")
        #expect(!g.isFresh(maxAge: -1))
    }
}

/// The filter choices are read once per playlist and catalog state, off the main thread, shared by every model.
@Suite("Filter options store", .serialized) @MainActor struct FilterOptionsStoreTests {
    final class Counter: @unchecked Sendable { private let lock = NSLock(); private var n = 0; var value: Int { lock.lock(); defer { lock.unlock() }; return n }; func hit() { lock.lock(); n += 1; lock.unlock() } }
    let src = UUID()
    func key(total: Int = 100, restriction: Int = 0, stamp: Double = 0, source: UUID? = nil, kind: ContentKind = .movie) -> FilterOptionsStore.Key { .init(source: source ?? src, kind: kind, total: total, restriction: restriction, stamp: stamp) }
    func options(_ n: Counter) -> @Sendable () -> LibraryFilterOptions { { n.hit(); Thread.sleep(forTimeInterval: 0.02); return LibraryFilterOptions(languages: ["Hindi"], qualities: ["4K"]) } }

    @Test func theSecondAskIsAnsweredFromTheStore() async {
        let store = FilterOptionsStore(), n = Counter()
        let first = await store.options(for: key(), compute: options(n))
        let second = await store.options(for: key(), compute: options(n))
        #expect(first == second && n.value == 1 && store.computeCount == 1)
    }

    @Test func askersAtTheSameTimeShareOneRead() async {
        let store = FilterOptionsStore(), n = Counter()
        async let x = store.options(for: key(), compute: options(n))
        async let y = store.options(for: key(), compute: options(n))
        async let z = store.options(for: key(), compute: options(n))
        let all = await [x, y, z]
        #expect(all.allSatisfy { $0.languages == ["Hindi"] } && n.value == 1)
    }

    @Test func aChangedCatalogOrRestrictionIsAnotherKey() async {
        let store = FilterOptionsStore(), n = Counter()
        _ = await store.options(for: key(), compute: options(n))
        _ = await store.options(for: key(total: 101), compute: options(n))
        _ = await store.options(for: key(restriction: 1), compute: options(n))
        _ = await store.options(for: key(stamp: 5), compute: options(n))
        _ = await store.options(for: key(kind: .series), compute: options(n))
        #expect(n.value == 5)
    }

    @Test func invalidatingForgetsEverythingOrOnePlaylist() async {
        let store = FilterOptionsStore(), n = Counter(), other = UUID()
        _ = await store.options(for: key(), compute: options(n))
        _ = await store.options(for: key(source: other), compute: options(n))
        store.invalidate(source: src)
        #expect(store.count == 1)
        _ = await store.options(for: key(), compute: options(n))
        #expect(n.value == 3)
        store.invalidate()
        #expect(store.count == 0)
    }

    @Test func theStoreIsBounded() async {
        let store = FilterOptionsStore(maxEntries: 3), n = Counter()
        for i in 0..<10 { _ = await store.options(for: key(total: i), compute: options(n)) }
        #expect(store.count == 3)
    }

    @Test func twoLibraryModelsShareOneRealRead() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-fo-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "Options")
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [], movies: (0..<30).map { TestSupport.movie(s, "m\($0)", "Title \($0)", year: 2020) })
        let one = LibraryBrowserViewModel(kind: .movie), two = LibraryBrowserViewModel(kind: .movie)
        await one.reset(c, selection: .shortcut(.allMovies), source: s.id)
        await two.reset(c, selection: .shortcut(.allMovies), source: s.id)
        #expect(c.filterOptionsStore.computeCount == 1)
        #expect(one.filterOptions == two.filterOptions)
    }

    final class Gate: @unchecked Sendable {
        let sem = DispatchSemaphore(value: 0)
        func open() { sem.signal() }
        func wait() { _ = sem.wait(timeout: .now() + 10) }
    }

    @Test func anAnswerStartedBeforeAnInvalidationIsNeverStoredOrServed() async {
        let store = FilterOptionsStore()
        let old = Gate(), fresh = Gate()
        let k = key()
        let a = Task { await store.options(for: k) { old.wait(); return LibraryFilterOptions(languages: ["OLD"], qualities: []) } }
        while store.computeCount < 1 { await Task.yield() }
        store.invalidate()                                   // a profile switch, say
        let b = Task { await store.options(for: k) { fresh.wait(); return LibraryFilterOptions(languages: ["NEW"], qualities: []) } }
        while store.computeCount < 2 { await Task.yield() }
        old.open()
        let oldValue = await a.value
        #expect(oldValue.languages == ["OLD"], "its own asker still gets it")
        #expect(store.count == 0, "but it is not kept")
        fresh.open()
        let newValue = await b.value
        #expect(newValue.languages == ["NEW"])
        let again = await store.options(for: k) { LibraryFilterOptions(languages: ["unexpected read"], qualities: []) }
        #expect(again.languages == ["NEW"], "later askers are served the answer computed after the invalidation")
    }
}
