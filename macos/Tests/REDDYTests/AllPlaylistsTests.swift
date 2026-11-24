import Testing
import Foundation
@testable import REDDY

/// Several playlists at once, with "All Playlists" chosen: three synthetic playlists (an Xtream-like one with live, movies and series; an M3U one that shares channel
/// and group names with it; a media-server one with movies and series) in a temporary database, driven through AppState and the screen models.
@Suite("All Playlists", .serialized) @MainActor struct AllPlaylistsTests {
    struct World {
        let c: AppContainer
        let xtream: PlaylistSource, m3u: PlaylistSource, media: PlaylistSource
        let state: AppState
        var all: [PlaylistSource] { [xtream, m3u, media] }
    }

    static func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-allpl-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    static func cat(_ s: PlaylistSource, _ kind: ContentKind, _ name: String, _ i: Int) -> CatalogCategory {
        CatalogCategory(id: CatalogCategory.makeID(source: s.id, kind: kind, provider: name), sourceID: s.id, kind: kind, providerID: name, name: name, sortOrder: i)
    }

    static func ch(_ s: PlaylistSource, _ pid: String, _ name: String, _ cat: CatalogCategory, order: Int, epg: String? = nil) -> Channel {
        var x = TestSupport.channel(s, pid, name, cat: nil, order: order, epg: epg); x.categoryID = cat.id; x.categoryName = cat.name; return x
    }

    static func world() async throws -> World {
        let c = try container()
        let x = PlaylistSource(name: "Xtream One", type: .xtream, baseURL: "http://x.example", lastSync: Date(), syncStatus: "completed", createdAt: Date().addingTimeInterval(-300), capabilities: SourceCapabilities(live: true, movies: true, series: true, epg: true))
        let m = PlaylistSource(name: "M3U Two", type: .m3uRemote, baseURL: "http://m.example/p.m3u", lastSync: Date(), syncStatus: "completed", createdAt: Date().addingTimeInterval(-200))
        let j = PlaylistSource(name: "Jelly Three", type: .jellyfin, baseURL: "http://j.example", lastSync: Date(), syncStatus: "completed", createdAt: Date().addingTimeInterval(-100))
        for s in [x, m, j] { try c.catalog.save(source: s) }
        // Live: both x and m have "Sports" and "News" groups and the same channel names; ids differ only by playlist.
        let xs = cat(x, .channel, "Sports", 0), xn = cat(x, .channel, "News", 1)
        try c.indexer.commitChannels(source: x, categories: [xs, xn], channels: [
            ch(x, "1", "BBC One HD", xn, order: 0, epg: "bbc1"), ch(x, "2", "Sky Sports Main Event", xs, order: 1, epg: "sky1"), ch(x, "3", "Eurosport 1", xs, order: 2)])
        let ms = cat(m, .channel, "Sports", 0), mn = cat(m, .channel, "News", 1), mx = cat(m, .channel, "Extra", 2)
        try c.indexer.commitChannels(source: m, categories: [ms, mn, mx], channels: [
            ch(m, "1", "BBC One HD", mn, order: 0, epg: "bbc1"), ch(m, "2", "Sky Sports Main Event", ms, order: 1, epg: "sky1"), ch(m, "9", "Only On M3U", mx, order: 2)])
        // Movies and series: Xtream and the media server both carry "Heat" (1995) and "Dark".
        let xm = cat(x, .movie, "Action", 0), jm = cat(j, .movie, "Action", 0)
        func mv(_ s: PlaylistSource, _ pid: String, _ t: String, _ y: Int, _ c: CatalogCategory) -> Movie { var v = TestSupport.movie(s, pid, t, year: y); v.categoryID = c.id; v.categoryName = c.name; v.addedAt = Date(); return v }
        try c.indexer.commitMovies(source: x, categories: [xm], movies: [mv(x, "1", "Heat", 1995, xm), mv(x, "2", "Ronin", 1998, xm)])
        try c.indexer.commitMovies(source: j, categories: [jm], movies: [mv(j, "1", "Heat", 1995, jm), mv(j, "7", "Alien", 1979, jm), mv(j, "8", "Brazil", 1985, jm)])
        let xr = cat(x, .series, "Drama", 0), jr = cat(j, .series, "Drama", 0)
        func se(_ s: PlaylistSource, _ pid: String, _ t: String, _ c: CatalogCategory) -> Series { var v = TestSupport.series(s, pid, t); v.categoryID = c.id; v.categoryName = c.name; return v }
        try c.indexer.commitSeries(source: x, categories: [xr], series: [se(x, "1", "Dark", xr)])
        try c.indexer.commitSeries(source: j, categories: [jr], series: [se(j, "1", "Dark", jr), se(j, "2", "Severance", jr)])
        // A guide for the Xtream playlist only.
        let now = Date()
        let xml = "<tv><channel id=\"bbc1\"><display-name>BBC</display-name></channel><programme start=\"\(EPGTests.stamp(now.addingTimeInterval(-600)))\" stop=\"\(EPGTests.stamp(now.addingTimeInterval(3000)))\" channel=\"bbc1\"><title>Now Show</title></programme></tv>"
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("allpl-\(UUID().uuidString).xml"); try xml.write(to: f, atomically: true, encoding: .utf8)
        _ = try c.epgSync.importFile(f, sourceID: x.id)
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "allpl-\(UUID().uuidString)")!)
        state.reload()
        return World(c: c, xtream: x, m3u: m, media: j, state: state)
    }

    /// Polls until `check` holds (the folder and count reads run off the main actor).
    static func eventually(_ check: () -> Bool) async -> Bool {
        for _ in 0..<150 { if check() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return check()
    }

    // MARK: counts and lists

    @Test func allModeListsEveryEnabledPlaylistTogether() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        #expect(w.state.showsAllPlaylists && w.state.activeSourceID == nil && w.state.libraryName == "All Playlists")
        let live = try w.c.catalog.channels(ChannelQuery(sourceID: nil, collapseVariants: false))
        #expect(live.count == 6 && Set(live.map(\.sourceID)) == [w.xtream.id, w.m3u.id])
        let ids = live.map(\.id)
        #expect(Set(ids).count == ids.count, "same channel in two playlists keeps two different ids")
        let movies = try w.c.catalog.movies(VODQuery(sourceID: nil))
        #expect(movies.count == 5)
        #expect(try w.c.catalog.series(VODQuery(sourceID: nil)).count == 3)
        #expect(try w.c.catalog.visibleCounts(sourceID: nil) == CatalogCounts(channels: 6, movies: 5, series: 3))
    }

    @Test func countsInAllModeIgnoreADisabledPlaylist() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        try w.c.sources.setEnabled(w.media.id, false)
        w.state.reload()
        #expect(w.state.showsAllPlaylists, "two playlists are still on")
        #expect(w.state.counts == CatalogCounts(channels: 6, movies: 2, series: 1), "the playlist that is switched off is not counted")
        let listed = try w.c.catalog.movies(VODQuery(sourceID: nil)).count
        #expect(w.state.counts.movies == listed, "the count and the list agree")
    }

    @Test func liveTVModelInAllModeShowsEveryPlaylistAndTheGroupsAreNotMerged() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        let vm = LiveTVViewModel(); vm.sourceID = w.state.activeSourceID; vm.filter = .all
        await vm.reload(w.c)
        #expect(Set(vm.channels.map(\.sourceID)) == [w.xtream.id, w.m3u.id])
        // Playlist order, not the order of random ids: Xtream (added first) comes before M3U.
        let order = vm.channels.map(\.sourceID)
        let firstM3U = try #require(order.firstIndex(of: w.m3u.id))
        #expect(order[..<firstM3U].allSatisfy { $0 == w.xtream.id } && order[firstM3U...].allSatisfy { $0 == w.m3u.id }, "\(vm.channels.map { ($0.sourceID == w.xtream.id ? "x:" : "m:") + $0.name })")
        // Choosing the M3U "Sports" group shows only its own channels, not the Xtream group of the same name.
        let msports = CatalogCategory.makeID(source: w.m3u.id, kind: .channel, provider: "Sports")
        vm.filter = .category(msports); await vm.reload(w.c)
        #expect(vm.channels.count == 1 && vm.channels[0].sourceID == w.m3u.id)
    }

    @Test func foldersOfAllModeAreToldApartWhenTwoPlaylistsShareAName() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        w.state.reloadFolders()
        #expect(await Self.eventually { (w.state.folders[.channel] ?? []).count >= 5 })
        let titles = (w.state.folders[.channel] ?? []).map(\.title)
        #expect(Set(titles).count == titles.count, "two rows are never called the same: \(titles)")
        #expect(titles.contains { $0.hasPrefix("Sports") && $0.contains("Xtream One") } && titles.contains { $0.hasPrefix("Sports") && $0.contains("M3U Two") })
        #expect(titles.contains("Extra"), "a name only one playlist has stays plain")
        // A single playlist keeps plain names.
        w.state.switchPlaylist(w.xtream.id)
        #expect(await Self.eventually { (w.state.folders[.channel] ?? []).map(\.title).sorted() == ["News", "Sports"] })
    }

    @Test func theLiveTVFolderRowsOfAllModeUseTheChannelsOfEveryPlaylistWithThatGroup() async throws {
        let w = try await Self.world()
        let model = FolderRowsModel(kind: .channel)
        await model.reload(w.c, sourceID: nil, profile: "p")
        let sports = try #require(model.rows.first { $0.name == "Sports" })
        #expect(model.rows.filter { $0.name == "Sports" }.count == 1, "one row per group name")
        #expect(sports.siblings.count == 1)
        await model.ensureTiles(sports, w.c, sourceID: nil, profile: "p")
        let tiles = try #require(model.channelTiles[sports.id])
        #expect(Set(tiles.map(\.sourceID)) == [w.xtream.id, w.m3u.id], "the M3U Sports channels are on the row too: \(tiles.map(\.name))")
        #expect(model.rows.contains { $0.name == "Extra" }, "a group only the M3U playlist has is still a row")
        // One playlist open: only its own group, as before.
        let single = FolderRowsModel(kind: .channel)
        await single.reload(w.c, sourceID: w.xtream.id, profile: "p")
        let own = try #require(single.rows.first { $0.name == "Sports" })
        #expect(own.siblings.isEmpty)
        await single.ensureTiles(own, w.c, sourceID: w.xtream.id, profile: "p")
        #expect(Set(try #require(single.channelTiles[own.id]).map(\.sourceID)) == [w.xtream.id])
    }

    // MARK: switching

    @Test func switchingBetweenAllAndOnePlaylistRefreshesFoldersAndCounts() async throws {
        let w = try await Self.world()
        w.state.switchPlaylist(w.xtream.id)
        #expect(await Self.eventually { w.state.counts == CatalogCounts(channels: 3, movies: 2, series: 1) })
        w.state.switchToAllPlaylists()
        #expect(await Self.eventually { w.state.counts == CatalogCounts(channels: 6, movies: 5, series: 3) }, "All shows the totals of every playlist, not the last playlist's: \(w.state.counts)")
        w.state.switchPlaylist(w.media.id)
        #expect(await Self.eventually { w.state.counts == CatalogCounts(channels: 0, movies: 3, series: 2) })
        #expect(await Self.eventually { (w.state.folders[.channel] ?? []).isEmpty && (w.state.folders[.movie] ?? []).map(\.title) == ["Action"] }, "the sidebar lists the folders of the playlist now open")
    }

    @Test func choosingASearchResultInAllModeStaysInAllMode() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        let router = AppRouter()
        let cat = CatalogCategory.makeID(source: w.m3u.id, kind: .channel, provider: "Extra")
        let r = SearchResult(id: "f", kind: .folder, title: "Extra", subtitle: "", sourceID: w.m3u.id, sourceName: "M3U Two", artworkURL: nil, destination: .folder(categoryID: cat, kind: .channel), score: 1)
        SearchActions.perform(r, container: w.c, router: router, state: w.state)
        #expect(w.state.showsAllPlaylists && w.state.activeSourceID == nil, "All Playlists already shows that playlist")
        #expect(router.tab == .liveTV && router.selection == .folder(cat))
    }

    // MARK: stale folder selections

    @Test func aFolderOfAnotherPlaylistIsNotKeptAsTheSelection() async throws {
        let w = try await Self.world()
        let router = AppRouter()
        let mFolder = CatalogCategory.makeID(source: w.m3u.id, kind: .channel, provider: "Extra")
        let xFolder = CatalogCategory.makeID(source: w.xtream.id, kind: .movie, provider: "Action")
        router.rememberFolders = true
        router.navigate(.liveTV, .folder(mFolder)); router.navigate(.movies, .folder(xFolder))
        router.pruneFolderSelections(scope: w.xtream.id, validSources: Set(w.all.map(\.id)))
        router.navigate(.liveTV); #expect(router.selection == AppRouter.defaultSelection(for: .liveTV), "the M3U folder does not exist in the Xtream playlist")
        router.navigate(.movies); #expect(router.selection == .folder(xFolder), "its own folder stays")
        router.pruneFolderSelections(scope: nil, validSources: [w.xtream.id, w.media.id])      // All, with the M3U playlist gone
        router.navigate(.movies); #expect(router.selection == .folder(xFolder))
        router.pruneFolderSelections(scope: nil, validSources: [w.media.id])
        router.navigate(.movies); #expect(router.selection == AppRouter.defaultSelection(for: .movies))
    }

    // MARK: removing

    @Test func removingAPlaylistLeavesNoRowsOrMarksBehind() async throws {
        let w = try await Self.world()
        let folder = CatalogCategory.makeID(source: w.m3u.id, kind: .channel, provider: "Extra")
        let heat = try #require(try w.c.catalog.movies(VODQuery(sourceID: w.xtream.id, search: "Heat")).first)
        try w.c.catalog.setCategoryLocked(folder, true)
        try w.c.catalog.setFolderOrder([folder])
        try w.c.historyRepo.hideFromContinue(itemID: heat.id)
        try w.c.favoritesRepo.setFavorite(heat.id, kind: .movie, on: true)
        w.state.removePlaylist(w.xtream.id)
        w.state.removePlaylist(w.m3u.id)
        #expect(try w.c.catalog.lockedCategoryIDs().isEmpty)
        let n = try w.c.db.read { c in
            try ["categories", "channels", "movies", "series", "epg_channels", "epg_programs", "content_identity", "search_docs", "folder_order", "continue_hidden", "favorites"].map { t -> Int in
                let rows = try c.scalarInt("SELECT COUNT(*) FROM \(t)", [])
                return t == "movies" || t == "series" || t == "categories" || t == "content_identity" || t == "search_docs" ? 0 : rows       // those still hold the media-server playlist
            }
        }
        #expect(n.allSatisfy { $0 == 0 }, "every table keyed to the removed playlists is empty: \(n)")
        #expect(try w.c.catalog.movies(VODQuery(sourceID: nil)).allSatisfy { $0.sourceID == w.media.id })
    }

    @Test func removingAPlaylistWhileInAllModeKeepsAllWhileTwoRemain() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        let screen = ScreenKey(screen: .liveTV, profile: "p", source: nil)
        _ = w.c.screens.model(screen, revision: 0) { NSObject() }
        w.state.removePlaylist(w.m3u.id)
        #expect(w.state.sources.map(\.id) == [w.xtream.id, w.media.id])
        #expect(w.state.showsAllPlaylists && w.state.activeSourceID == nil)
        #expect(try w.c.catalog.channels(ChannelQuery(sourceID: nil, collapseVariants: false)).allSatisfy { $0.sourceID == w.xtream.id })
        #expect(w.state.counts == CatalogCounts(channels: 3, movies: 5, series: 3))
        #expect(try w.c.catalog.source(id: w.m3u.id) == nil)
        let leftover = try w.c.catalog.categories(sourceID: nil, kind: .channel, includeHidden: true).filter { $0.sourceID == w.m3u.id }
        #expect(leftover.isEmpty)
        // One more removal leaves a single playlist: it becomes the active one (no "All" of one).
        w.state.removePlaylist(w.media.id)
        #expect(!w.state.showsAllPlaylists && w.state.activeSourceID == w.xtream.id && !w.state.canCombinePlaylists)
        #expect(w.state.counts == CatalogCounts(channels: 3, movies: 2, series: 1))
        // And the last one leaves the empty (onboarding) state.
        w.state.removePlaylist(w.xtream.id)
        #expect(w.state.sources.isEmpty && w.state.activeSourceID == nil && !w.state.showsAllPlaylists && !w.state.hasLibrary)
        #expect(w.state.counts == CatalogCounts())
    }

    @Test func removingTheActivePlaylistSwitchesToAllWhenSeveralRemain() async throws {
        let w = try await Self.world()
        w.state.switchPlaylist(w.xtream.id)
        w.state.removePlaylist(w.xtream.id)
        #expect(w.state.showsAllPlaylists && w.state.activeSourceID == nil, "two are left: All Playlists")
        w.state.switchPlaylist(w.media.id)
        w.state.removePlaylist(w.media.id)
        #expect(!w.state.showsAllPlaylists && w.state.activeSourceID == w.m3u.id, "one is left: that one")
    }

    @Test func removingAnotherPlaylistLeavesTheActiveOneAlone() async throws {
        let w = try await Self.world()
        w.state.switchPlaylist(w.media.id)
        w.state.removePlaylist(w.m3u.id)
        #expect(w.state.activeSourceID == w.media.id && !w.state.showsAllPlaylists)
    }

    @Test func removingAPlaylistStopsItsPlaybackAndDropsItsRetainedScreens() async throws {
        let w = try await Self.world()
        let live = try w.c.sources.addM3U(name: "Live Local", url: "http://127.0.0.1:9/list.m3u")
        var ch = TestSupport.channel(live, "a", "Channel A"); ch.streamRef = "http://127.0.0.1:9/live/a.ts"
        try w.c.indexer.commitChannels(source: live, categories: [], channels: [ch])
        w.state.reload(); w.state.switchPlaylist(live.id)
        _ = w.c.screens.model(ScreenKey(screen: .liveTV, profile: "p", source: live.id), revision: 0) { NSObject() }
        let stored = try #require(try w.c.catalog.channels(ChannelQuery(sourceID: live.id, collapseVariants: false)).first)
        w.c.playback.play(channel: stored)
        #expect(w.c.playback.current?.itemID == stored.id)
        w.state.removePlaylist(live.id)
        #expect(w.c.playback.current == nil, "what was playing from the removed playlist stops")
        #expect(w.c.screens.get(ScreenKey(screen: .liveTV, profile: "p", source: live.id), revision: 0) == nil)
        #expect(w.state.showsAllPlaylists, "three playlists remain")
    }

    @Test func addingAPlaylistWhileInAllModeKeepsAllMode() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        let fourth = PlaylistSource(name: "Four", type: .m3uRemote, baseURL: "http://f.example/p.m3u", lastSync: Date(), syncStatus: "completed")
        try w.c.catalog.save(source: fourth)
        let f = Self.cat(fourth, .channel, "Fresh", 0)
        try w.c.indexer.commitChannels(source: fourth, categories: [f], channels: [Self.ch(fourth, "1", "Fresh One", f, order: 0)])
        w.state.reload()
        w.state.playlistAdded(fourth.id)
        #expect(w.state.showsAllPlaylists && w.state.sources.count == 4)
        #expect(await Self.eventually { w.state.counts.channels == 7 })
        #expect(try w.c.catalog.channels(ChannelQuery(sourceID: nil, collapseVariants: false)).count == 7)
    }

    @Test func addingAPlaylistWhileOnOnePlaylistOpensTheNewOne() async throws {
        let w = try await Self.world()
        w.state.switchPlaylist(w.xtream.id)
        let fourth = PlaylistSource(name: "Four", type: .m3uRemote, baseURL: "http://f.example/p.m3u", lastSync: Date(), syncStatus: "completed")
        try w.c.catalog.save(source: fourth)
        w.state.reload(); w.state.playlistAdded(fourth.id)
        #expect(w.state.activeSourceID == fourth.id && !w.state.showsAllPlaylists)
    }

    // MARK: movies, series, guide, favourites

    @Test func moviesSeriesAndTheGuideReadEveryPlaylistInAllMode() async throws {
        let w = try await Self.world()
        w.state.switchToAllPlaylists()
        let vm = LibraryBrowserViewModel(kind: .movie)
        await vm.reset(w.c, selection: .shortcut(.allMovies), source: nil)
        #expect(Set(vm.items.map(\.sourceID)) == [w.xtream.id, w.media.id] && vm.items.count == 5)
        let g = GuideViewModel(); g.sourceID = nil; g.scope = .withGuide
        await g.reload(w.c)
        #expect(g.channels.count == 1 && g.channels.allSatisfy { $0.sourceID == w.xtream.id }, "only channels with a guide; the M3U twin has none of its own: \(g.channels.map { $0.sourceID == w.xtream.id ? "x:" + $0.name : "other:" + $0.name })")
        // Favourites and recently watched are per item, so the same title in two playlists is two entries.
        let heats = try w.c.catalog.movies(VODQuery(sourceID: nil, search: "Heat"))
        #expect(heats.count == 2)
        try w.c.favoritesRepo.setFavorite(heats[0].id, kind: .movie, on: true)
        let favs = try w.c.catalog.movies(VODQuery(sourceID: nil, favoritesOnly: true))
        #expect(favs.map(\.id) == [heats[0].id])
        let onlyOther = try w.c.catalog.movies(VODQuery(sourceID: heats[1].sourceID, favoritesOnly: true))
        #expect(onlyOther.isEmpty)
    }

    @Test func homeBuildsFromEveryPlaylistInAllMode() async throws {
        let w = try await Self.world()
        let content = try #require(try w.c.discover.build(sourceID: nil))
        let ids = content.shelves.flatMap { $0.items.map(\.id) }
        #expect(!ids.isEmpty)
        let sources = Set(content.shelves.flatMap { $0.items.map(\.sourceID) })
        #expect(sources.isSubset(of: [w.xtream.id, w.media.id]) && sources.count == 2, "the shelves draw on both playlists that have movies and series")
    }
}
