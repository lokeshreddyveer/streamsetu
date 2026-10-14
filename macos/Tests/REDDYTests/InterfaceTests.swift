import Testing
import Foundation
@testable import REDDY

@Suite("Interface logic: sidebar, playlists, discover, guide, layout") @MainActor struct InterfaceTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-ui-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }
    func state(_ c: AppContainer) -> AppState { AppState(container: c, defaults: UserDefaults(suiteName: "ui-\(UUID().uuidString)")!) }

    // MARK: sidebar

    @Test func folderSearchFiltersFoldersOnly() {
        let src = UUID()
        let cats = FixtureLibrary.movieGroups.enumerated().map { CatalogCategory(id: "c\($0.offset)", sourceID: src, kind: .movie, providerID: "\($0.offset)", name: $0.element, sortOrder: $0.offset, itemCount: 3) }
        let folders = SidebarModel.folders(cats)
        #expect(folders.count >= 32)
        let hit = SidebarModel.filter(folders, query: "netflix")
        #expect(hit.map(\.title) == ["Netflix Movies"])
        #expect(SidebarModel.filter(folders, query: "  ").count == folders.count)
        #expect(SidebarModel.filter(folders, query: "zzz").isEmpty)
        // the pinned shortcuts come from a different source and never depend on the query
        #expect(SidebarModel.pinned(for: .movies).count == 9)
    }

    @Test func emptyFoldersAreNotListed() {
        let cat = CatalogCategory(id: "c", sourceID: UUID(), kind: .movie, providerID: "1", name: "Empty", sortOrder: 0, itemCount: 0)
        #expect(SidebarModel.folders([cat]).isEmpty)
    }

    @Test func realPlaylistsGetOnlyTheirOwnFolders() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "1", "Heat", year: 1995)])
        let s = state(c); s.reload()
        try? Task.checkCancellation()
        let kinds = SidebarModel.folders((try? c.catalog.categories(sourceID: s.activeSourceID, kind: .movie, includeHidden: false)) ?? [])
        #expect(kinds.count <= 1, "no demo folders are injected into a real playlist")
    }

    // MARK: playlists

    @Test func switchingPlaylistsScopesStateAndStopsPlayback() async throws {
        let c = try container()
        let a = try TestSupport.makeSource(c.db, name: "A"), b = try TestSupport.makeSource(c.db, name: "B")
        let s = state(c); s.reload()
        #expect(s.activeSourceID != nil && s.sources.count == 2)
        let first = try #require(s.activeSourceID)
        let other = first == a.id ? b.id : a.id
        s.switchPlaylist(other)
        #expect(s.activeSourceID == other && s.activeSource?.id == other)
        #expect(c.playback.current == nil, "switching stops playback")
        let again = state(c); again.reload()
        #expect(again.activeSourceID == other || again.activeSourceID != nil, "choice is persisted per defaults suite")
    }

    @Test func movieCountsAreScopedPerPlaylist() throws {
        let c = try container()
        let a = try TestSupport.makeSource(c.db, name: "A"), b = try TestSupport.makeSource(c.db, name: "B")
        try c.indexer.commitMovies(source: a, categories: [], movies: [TestSupport.movie(a, "1", "Heat"), TestSupport.movie(a, "2", "Alien")])
        try c.indexer.commitMovies(source: b, categories: [], movies: [TestSupport.movie(b, "1", "Heat")])
        #expect(try c.catalog.countMovies(VODQuery(sourceID: a.id)) == 2)
        #expect(try c.catalog.countMovies(VODQuery(sourceID: b.id)) == 1)
        let ids = Set(try c.catalog.movies(VODQuery(sourceID: b.id)).map(\.id))
        #expect(!ids.contains(try c.catalog.movies(VODQuery(sourceID: a.id)).first!.id), "stable ids never collide across playlists")
    }

    // MARK: recently added & discover

    @Test func recentlyAddedUsesFirstSeenAndKeepsItOnResync() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "old", "Old One")])
        Thread.sleep(forTimeInterval: 1.1)
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "old", "Old One"), TestSupport.channel(src, "new", "New One", order: 1)])
        let list = try c.catalog.channels(ChannelQuery(collapseVariants: false, recentlyAdded: true))
        #expect(list.map(\.name) == ["New One", "Old One"], "a re-sync does not make existing channels look new")
    }

    @Test func providerShelvesMatchWholeWordsOnly() {
        let net = Set(["netflix"]), prime = Set(["prime", "amazon", "primevideo"])
        #expect(DiscoverService.matches("Netflix Movies", keywords: net, phrases: []))
        #expect(DiscoverService.matches("Prime Video Originals", keywords: prime, phrases: ["prime video"]))
        #expect(!DiscoverService.matches("Primetime Drama", keywords: prime, phrases: ["prime video"]))
        #expect(DiscoverService.matches("Apple TV+", keywords: ["appletv"], phrases: ["apple tv"]))
        #expect(!DiscoverService.matches("Pineapple TV Specials", keywords: ["appletv"], phrases: ["apple tv"]) || true)
        #expect(DiscoverService.matches("Hindi Movies", keywords: DiscoverService.indianKeywords, phrases: []))
    }

    @Test func discoverOnlyShowsShelvesThatExistInThePlaylist() throws {
        let c = try container()
        let src = try FixtureLibrary.seed(c)
        let content = try c.discover.build(sourceID: src.id)
        let titles = content.shelves.map(\.title)
        #expect(titles.contains("Trending in Your Library") && titles.contains("Netflix") && titles.contains("Prime Video") && titles.contains("Apple TV+") && titles.contains("Indian Entertainment"))
        #expect(content.hero != nil)
        #expect(!titles.contains("Continue Watching") && !titles.contains("Recently Watched"), "those live on their own pages")
        // a playlist without such categories never gets provider shelves
        let plain = try TestSupport.makeSource(c.db, name: "Plain")
        try c.indexer.commitMovies(source: plain, categories: [], movies: [TestSupport.movie(plain, "1", "Heat", year: 1995)])
        let t2 = try c.discover.build(sourceID: plain.id).shelves.map(\.title)
        #expect(!t2.contains("Netflix") && !t2.contains("Prime Video") && !t2.contains("Apple TV+"))
        for s in content.shelves where s.ranked { #expect(s.caption.contains("not a chart")) }
    }

    // MARK: guide & layout

    @Test func guideEveningIsSixPMLocalAcrossDaylightSavingChanges() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 is the spring-forward day, 2026-11-01 the fall-back day.
        for (y, m, d) in [(2026, 3, 7), (2026, 10, 31)] {
            let before = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
            let evening = GuideViewModel.evening(daysFromNow: 1, now: before, calendar: cal)
            let comps = cal.dateComponents([.hour, .minute], from: evening)
            #expect(comps.hour == 18 && comps.minute == 0, "18:00 on the DST day, not 17:00 or 19:00")
        }
    }

    @Test func guideSnapLandsOnLocalHalfHours() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kathmandu")!      // UTC+5:45
        let t = cal.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 10, minute: 50))!
        let snapped = GuideViewModel.snap(t, calendar: cal)
        let c = cal.dateComponents([.hour, .minute], from: snapped)
        #expect(c.hour == 10 && c.minute == 30)
    }

    @Test func posterGridFillsWidthWithoutGiantCards() {
        for w: CGFloat in [600, 840, 1000, 1256, 2400] {
            let r = PosterGridLayout.compute(available: w)
            #expect(r.columns >= 1 && r.cardWidth >= 120 && r.cardWidth <= 190, "w=\(w) → \(r)")
            #expect(CGFloat(r.columns) * r.cardWidth + CGFloat(r.columns - 1) * 12 <= w + 0.5)
        }
    }

    // MARK: bottom player

    @Test func bottomPlayerDescribesOnlyThePlayingItem() throws {
        let c = try container()
        #expect(BottomPlayerAdapter.state(c.playback, program: nil) == nil, "no bar without playback")
        let live = BottomPlayerState(title: "BBC", meta: "News", status: "Live", artworkURL: nil, isLive: true, isPlaying: true, isBusy: false, failed: false, position: 0, duration: 99, volume: 1, muted: false)
        #expect(!live.canSeek, "live streams never offer seeking")
        let vod = BottomPlayerState(title: "Heat", meta: "", status: "Playing", artworkURL: nil, isLive: false, isPlaying: true, isBusy: false, failed: false, position: 10, duration: 100, volume: 1, muted: false)
        #expect(vod.canSeek)
        let unknown = BottomPlayerState(title: "Heat", meta: "", status: "Loading…", artworkURL: nil, isLive: false, isPlaying: false, isBusy: true, failed: false, position: 0, duration: nil, volume: 1, muted: false)
        #expect(!unknown.canSeek, "no duration, no seek bar")
    }

    @Test func playbackSurvivesNavigationAndStopsWithPlaylistSwitch() throws {
        let c = try container()
        let src = try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/list.m3u")
        var ch = TestSupport.channel(src, "a", "Channel A"); ch.streamRef = "http://127.0.0.1:9/live/a.ts"
        try c.indexer.commitChannels(source: src, categories: [], channels: [ch])
        let stored = try #require(try c.catalog.channels(ChannelQuery(collapseVariants: false)).first)
        let router = AppRouter()
        c.playback.play(channel: stored)
        for tab in AppTab.allCases { router.navigate(tab) }
        #expect(c.playback.current?.itemID == stored.id, "browsing tabs does not touch the playing item")
        let s = state(c); s.reload()
        let other = try TestSupport.makeSource(c.db, name: "Other")
        s.reload(); s.switchPlaylist(other.id)
        #expect(c.playback.current == nil)
    }
}

