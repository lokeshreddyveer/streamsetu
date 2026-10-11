import Testing
import Foundation
@testable import REDDY

/// The top-bar search is global: the same query gives the same results whatever screen the user starts from.
@Suite("Global search") @MainActor struct GlobalSearchTests {
    struct World {
        let c: AppContainer
        let alpha: PlaylistSource, beta: PlaylistSource
        let service: GlobalSearchService
    }

    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-gs-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    func world() throws -> World {
        let c = try container()
        let a = try TestSupport.makeSource(c.db, name: "Alpha IPTV", type: .xtream), b = try TestSupport.makeSource(c.db, name: "Beta IPTV", type: .xtream)
        let cats = [CatalogCategory(id: "A-news", sourceID: a.id, kind: .channel, providerID: "n", name: "UK News", sortOrder: 0),
                    CatalogCategory(id: "A-mx", sourceID: a.id, kind: .movie, providerID: "m", name: "Matrix Classics", sortOrder: 0)]
        func ch(_ s: PlaylistSource, _ pid: String, _ name: String, epg: String? = nil) -> Channel { TestSupport.channel(s, pid, name, cat: nil, order: 0, epg: epg) }
        try c.indexer.commitChannels(source: a, categories: [cats[0]], channels: [
            ch(a, "1", "BBC One HD", epg: "bbc1"), ch(a, "2", "Sky Sports Main Event"), ch(a, "3", "Zee Telugu"), ch(a, "4", "ఈటీవీ తెలుగు"), ch(a, "5", "Café Chaîne")])
        try c.indexer.commitChannels(source: b, categories: [], channels: [ch(b, "1", "BBC One HD"), ch(b, "2", "Matrix TV")])
        func mv(_ s: PlaylistSource, _ pid: String, _ t: String, _ y: Int? = nil, cat: String? = nil) -> Movie {
            var m = TestSupport.movie(s, pid, t, year: y); m.categoryID = cat; return m
        }
        try c.indexer.commitMovies(source: a, categories: [cats[1]], movies: [
            mv(a, "1", "Heat", 1995), mv(a, "2", "The Matrix", 1999, cat: "A-mx"), mv(a, "3", "Matrix Reloaded", 2003, cat: "A-mx"), mv(a, "4", "Heatwave: The Movie", 2012),
            mv(a, "5", "Burning Heat", 2009), mv(a, "6", "బాహుబలి", 2015), mv(a, "7", "விக்ரம்", 2022)])
        try c.indexer.commitMovies(source: b, categories: [], movies: [mv(b, "1", "Heat", 1995)])
        try c.indexer.commitSeries(source: a, categories: [], series: [
            TestSupport.series(a, "1", "Dark"), TestSupport.series(a, "2", "Matrix Chronicles"), TestSupport.series(a, "3", "कौन बनेगा करोड़पति")])
        try c.indexer.commitSeries(source: b, categories: [], series: [TestSupport.series(b, "1", "Dark")])
        let dark = try #require(try c.catalog.series(VODQuery(sourceID: a.id)).first { $0.title == "Dark" })
        try c.indexer.saveSeriesDetail(SeriesDetail(series: dark, seasons: [Season(id: "s1", seriesID: dark.id, number: 1, name: nil)],
            episodes: [Episode(id: "e1", seriesID: dark.id, seasonID: "s1", seasonNumber: 1, providerEpisodeID: "e1", episodeNumber: 3, title: "Matrix Nights", overview: nil, imageURL: nil, durationSeconds: nil, streamRef: "e.mp4")]))
        let col = try c.favoritesRepo.createCollection(name: "Matrix Collection")
        _ = col
        let now = Date()
        let xml = "<tv><channel id=\"bbc1\"><display-name>BBC</display-name></channel><programme start=\"\(EPGTests.stamp(now))\" stop=\"\(EPGTests.stamp(now.addingTimeInterval(3600)))\" channel=\"bbc1\"><title>Matrix Marathon</title></programme></tv>"
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString).xml"); try xml.write(to: f, atomically: true, encoding: .utf8)
        _ = try c.epgSync.importFile(f, sourceID: a.id)
        return World(c: c, alpha: a, beta: b, service: c.globalSearch)
    }

    func ids(_ r: GlobalSearchResults) -> Set<String> { Set(r.results(for: .all).map(\.id)) }

    // MARK: the same results from everywhere

    @Test func theSameQueryReturnsTheSameResultsFromEveryStartingTab() async throws {
        let w = try world()
        var seen: [Set<String>] = []
        for tab in AppTab.allCases {
            let router = AppRouter(); router.navigate(tab)
            let model = GlobalSearchModel(service: w.service, debounceMilliseconds: 1)
            model.term = "matrix"
            await model.run("matrix")
            seen.append(ids(model.results))
            #expect(router.tab == tab, "searching doesn't move the user")
        }
        #expect(Set(seen).count == 1, "identical from Home, Live TV, Movies, Series and TV Guide")
        let r = try await w.service.search("matrix")
        for kind in [SearchResultKind.channel, .movie, .series, .episode, .programme, .folder, .collection] { #expect(!(r.byKind[kind] ?? []).isEmpty, "\(kind) is searched too") }
    }

    @Test func findsOtherTypesFromEachSection() async throws {
        let w = try world()
        // Movies tab → a Live TV channel
        let r1 = try await w.service.search("sky sports")
        #expect((r1.byKind[.channel] ?? []).contains { $0.title == "Sky Sports Main Event" })
        // Series tab → a movie
        let r2 = try await w.service.search("heat")
        #expect((r2.byKind[.movie] ?? []).contains { $0.title == "Heat" })
        // Live TV tab → a series
        let r3 = try await w.service.search("dark")
        #expect((r3.byKind[.series] ?? []).contains { $0.title == "Dark" })
    }

    @Test func onlyAnExplicitTabNarrowsTheType() async throws {
        let w = try world()
        let all = try await w.service.search("matrix")
        let movies = try await w.service.search("matrix", tab: .movies)
        #expect(Set(all.byKind.filter { !$0.value.isEmpty }.keys).count > 1)
        #expect(Set(movies.byKind.filter { !$0.value.isEmpty }.keys) == [.movie])
        #expect(movies.byKind[.movie]?.count == all.byKind[.movie]?.count)
    }

    // MARK: playlists, duplicates, identity

    @Test func everyEnabledPlaylistIsSearchedAndVariantsStayDistinct() async throws {
        let w = try world()
        let r = try await w.service.search("bbc one")
        let rows = r.byKind[.channel] ?? []
        #expect(rows.count == 2 && Set(rows.map(\.id)).count == 2, "same name, two playlists → two results")
        #expect(Set(rows.compactMap(\.sourceID)) == [w.alpha.id, w.beta.id])
        #expect(rows.allSatisfy { $0.subtitle.contains("Alpha IPTV") || $0.subtitle.contains("Beta IPTV") }, "source shown when several playlists exist: \(rows.map(\.subtitle))")
        let heat = (try await w.service.search("heat")).byKind[.movie] ?? []
        #expect(heat.filter { $0.title == "Heat" }.count == 2)
        try w.c.catalog.setEnabled(false, sourceID: w.beta.id)
        let after = (try await w.service.search("bbc one")).byKind[.channel] ?? []
        #expect(after.count == 1 && after[0].sourceID == w.alpha.id, "a disabled playlist is not searched")
    }

    @Test func resultsAreStructuredWithStableIdentityAndDestination() async throws {
        let w = try world()
        let r = try await w.service.search("matrix")
        let movie = try #require(r.byKind[.movie]?.first)
        let stored = try #require(try w.c.catalog.movies(VODQuery(sourceID: w.alpha.id)).first { $0.title == movie.title })
        #expect(movie.id == "movie:\(stored.id)" && movie.destination == .movie(id: stored.id) && movie.sourceID == w.alpha.id && movie.sourceName == "Alpha IPTV")
        #expect(!movie.subtitle.isEmpty && movie.score > 0)
        let again = try await w.service.search("matrix")
        #expect(again.byKind[.movie]?.map(\.id) == r.byKind[.movie]?.map(\.id), "stable ids and order between runs")
    }

    // MARK: ranking

    @Test func exactBeatsPrefixBeatsContains() async throws {
        let w = try world()
        let titles = (try await w.service.search("heat")).byKind[.movie]?.map(\.title) ?? []
        #expect(titles.first == "Heat", "the exact title is first: \(titles)")
        let wave = try #require(titles.firstIndex(of: "Heatwave: The Movie")), burning = try #require(titles.firstIndex(of: "Burning Heat"))
        #expect(wave < burning, "a title starting with the query outranks one that only contains it")
        #expect(GlobalSearchService.score(title: "Heat", query: "heat", position: 99) > GlobalSearchService.score(title: "Heatwave", query: "heat", position: 0))
        #expect(GlobalSearchService.score(title: "Heatwave", query: "heat", position: 99) > GlobalSearchService.score(title: "Burning Heat", query: "heat", position: 0))
        #expect(GlobalSearchService.score(title: "Burning Heat", query: "heat", position: 99) > GlobalSearchService.score(title: "Something else", query: "heat", position: 0), "supporting-metadata matches rank last")
    }

    // MARK: languages

    @Test func unicodeAndIndianLanguageTitlesAreFound() async throws {
        let w = try world()
        for (query, kind, title) in [("బాహుబలి", SearchResultKind.movie, "బాహుబలి"), ("விக்ரம்", .movie, "விக்ரம்"), ("कौन बनेगा", .series, "कौन बनेगा करोड़पति"), ("ఈటీవీ", .channel, "ఈటీవీ తెలుగు"),
                                      ("cafe chaine", .channel, "Café Chaîne"), ("CAFÉ", .channel, "Café Chaîne")] {
            let r = try await w.service.search(query)
            #expect((r.byKind[kind] ?? []).contains { $0.title == title }, "“\(query)” should find “\(title)”")
        }
    }

    // MARK: scale, empties, bounds

    @Test func largeCatalogsAreSearchedInBoundedPages() async throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, name: "Big", type: .xtream)
        let movies = (0..<20_000).map { TestSupport.movie(src, "\($0)", "Epic Journey \($0)", year: 2000 + $0 % 25) }
        try c.indexer.commitMovies(source: src, categories: [], movies: movies)
        // Best of three: the suite runs many heavy tests in parallel, and a single sample can include time spent waiting for a
        // free thread rather than searching. A scan of 20,000 rows would be slow on every attempt.
        var best = Double.infinity
        var r = GlobalSearchResults(query: "")
        for _ in 0..<3 {
            let started = Date()
            r = try await c.globalSearch.search("epic journey")
            best = min(best, Date().timeIntervalSince(started))
        }
        #expect((r.byKind[.movie]?.count ?? 0) == GlobalSearchService.pageSize && r.hasMore.contains(.movie), "one bounded page, and it says there is more")
        #expect(best < 5, "answered from the index, not by scanning (best of three: \(best)s)")
        let model = GlobalSearchModel(service: c.globalSearch, debounceMilliseconds: 1)
        model.term = "epic journey"; await model.run("epic journey")
        await model.loadMore(.movie)
        #expect(model.results.byKind[.movie]?.count == GlobalSearchService.pageSize * 2, "each request adds exactly one more page")
    }

    @Test func emptyAndNonsenseQueriesReturnNothingWithoutErrors() async throws {
        let w = try world()
        for q in ["", "   ", "!!!", "—"] { let r = try await w.service.search(q); #expect(r.isEmpty, "“\(q)”") }
        let model = GlobalSearchModel(service: w.service, debounceMilliseconds: 1)
        model.term = ""; model.schedule()
        #expect(!model.loading && model.results.isEmpty && !model.isActive)
    }

    // MARK: typing, cancellation, playback

    @Test func rapidTypingKeepsOnlyTheLatestQuery() async throws {
        let w = try world()
        let model = GlobalSearchModel(service: w.service, debounceMilliseconds: 40)
        for t in ["h", "he", "hea", "heat", "dar", "dark"] { model.term = t; model.schedule() }
        for _ in 0..<100 where !model.searched { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(model.results.query == "dark", "stale queries never overwrite the newest: \(model.results.query)")
        #expect((model.results.byKind[.series] ?? []).contains { $0.title == "Dark" })
        model.term = ""; model.schedule()
        #expect(model.results.isEmpty && !model.loading, "clearing cancels and empties")
    }

    @Test func cancelledSearchesStopCleanly() async throws {
        let w = try world()
        let t = Task { try await w.service.search("matrix") }
        t.cancel()
        do { _ = try await t.value } catch is CancellationError { }
        let r = try await w.service.search("matrix")
        #expect(!r.isEmpty, "the service is unaffected by an earlier cancelled call")
    }

    @Test func searchingNeverTouchesPlaybackOrNavigation() async throws {
        let w = try world()
        let c = w.c
        let live = try #require(try c.catalog.channels(ChannelQuery(collapseVariants: false)).first { $0.name == "Sky Sports Main Event" })
        var ch = live; ch.streamRef = "http://127.0.0.1:9/live/x.ts"
        try c.indexer.commitChannels(source: w.alpha, categories: [], channels: [ch] + (try c.catalog.channels(ChannelQuery(sourceID: w.alpha.id, collapseVariants: false)).filter { $0.id != live.id }))
        c.playback.play(channel: ch)
        let player = c.playback.avPlayer, loads = c.playback.loadCount, item = c.playback.current
        let router = AppRouter(); router.navigate(.movies, .folder("A-mx"))
        let model = GlobalSearchModel(service: c.globalSearch, debounceMilliseconds: 1)
        for q in ["matrix", "heat", "dark", "bbc"] { router.searchQuery = q; model.term = q; await model.run(q) }
        router.clearSearch(); model.clear()
        #expect(c.playback.avPlayer === player && c.playback.loadCount == loads && c.playback.current == item, "playback untouched")
        #expect(router.tab == .movies && router.selection == .folder("A-mx"), "clearing the search restores exactly where the user was")
        c.playback.stop()
    }

    // MARK: choosing a result

    @Test func choosingAResultGoesToItsDestination() async throws {
        let w = try world()
        let c = w.c
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "gs-\(UUID().uuidString)")!)
        state.reload()
        let r = try await w.service.search("matrix")
        func perform(_ kind: SearchResultKind) throws -> AppRouter {
            let router = AppRouter(); router.navigate(.home)
            let result = try #require(r.byKind[kind]?.first)
            SearchActions.perform(result, container: c, router: router, state: state)
            return router
        }
        let movie = try perform(.movie); #expect(movie.movie != nil && movie.tab == .home, "movies open their details without leaving the tab")
        let series = try perform(.series); #expect(series.series != nil)
        let episode = try perform(.episode); #expect(episode.series?.title == "Dark", "an episode opens its series")
        let folder = try perform(.folder); #expect(folder.tab == .movies && folder.selection == .folder("A-mx"))
        let collection = try perform(.collection); #expect(collection.tab == .home && collection.selection == .shortcut(.collections))
        // a channel from a playlist that can connect (an M3U with a saved address) starts playing on Live TV
        let playable = try c.sources.addM3U(name: "Playable", url: "http://127.0.0.1:9/list.m3u")
        var pc = TestSupport.channel(playable, "p1", "Playable Matrix Channel", cat: nil); pc.streamRef = "http://127.0.0.1:9/live/p1.ts"
        try c.indexer.commitChannels(source: playable, categories: [], channels: [pc])
        state.reload()
        let found = try #require(try await w.service.search("playable matrix").byKind[.channel]?.first)
        let router = AppRouter(); router.navigate(.series)
        SearchActions.perform(found, container: c, router: router, state: state)
        #expect(router.tab == .liveTV, "choosing a channel opens Live TV")
        if case .playChannel(let id) = found.destination { #expect(c.playback.current?.itemID == id, "and starts that channel") }
        c.playback.stop()
    }

    @Test func choosingAResultInAnotherPlaylistSwitchesToIt() async throws {
        let w = try world()
        let c = w.c
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "gs-\(UUID().uuidString)")!)
        state.reload(); state.switchPlaylist(w.alpha.id)
        let tv = (try await w.service.search("matrix tv")).byKind[.channel]?.first
        let result = try #require(tv)
        #expect(result.sourceID == w.beta.id)
        SearchActions.perform(result, container: c, router: AppRouter(), state: state)
        #expect(state.activeSourceID == w.beta.id, "the channel's own playlist becomes the active one so it can play")
        c.playback.stop()
    }
}

@Suite("Named channel lists") @MainActor struct ChannelListTests {
    @Test func aListShowsItsChannelsInOrderAndOnlyListsWithChannelsAreOffered() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-lists-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let chans = (1...5).map { TestSupport.channel(src, "\($0)", "Channel \($0) \($0 % 2 == 0 ? "Sport" : "News")") }
        try c.indexer.commitChannels(source: src, categories: [], channels: chans)
        let sports = try c.favoritesRepo.createCollection(name: "Sports")
        let empty = try c.favoritesRepo.createCollection(name: "Empty")
        let moviesOnly = try c.favoritesRepo.createCollection(name: "Films")
        for ch in [chans[3], chans[1]] { try c.favoritesRepo.add(itemID: ch.id, kind: .channel, toCollection: sports.id) }
        try c.favoritesRepo.add(itemID: ItemID.make(source: src.id, kind: .movie, provider: "m1"), kind: .movie, toCollection: moviesOnly.id)
        _ = empty
        let names = LiveTVViewModel.channelsInList(sports.id, sid: src.id, query: "", c: c).map(\.name)
        #expect(names == ["Channel 4 Sport", "Channel 2 Sport"], "in the order they were added")
        #expect(LiveTVViewModel.channelsInList(sports.id, sid: src.id, query: "4", c: c).map(\.name) == ["Channel 4 Sport"])
        #expect(LiveTVViewModel.channelsInList(sports.id, sid: UUID(), query: "", c: c).isEmpty, "another playlist's channels aren't shown")
        let offered = LiveTVViewModel.listsWithChannels(c)
        #expect(offered.map(\.name) == ["Sports"] && offered.first?.itemCount == 2, "empty lists and movie-only lists are not offered")
    }
}
