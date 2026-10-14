import Testing
import Foundation
@testable import REDDY

/// The smart lists (Unwatched, Unwatched Favorites, Added in 30 Days, New Episodes) are rules over what the library holds and what was played.
@Suite("Smart lists and new episodes") @MainActor struct SmartListsTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-smart-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    func day(_ n: Int) -> Date { Date().addingTimeInterval(-Double(n) * 86400) }

    struct World { let c: AppContainer; let s: PlaylistSource; let ids: [String: String] }

    /// Movies: Seen (played, 5 days old), Unseen New (3 days), Unseen Old (90), Unseen Fav (200, favorite), Seen Fav (10, favorite, played), No Date.
    func world() throws -> World {
        let c = try container()
        let s = try TestSupport.makeSource(c.db, name: "Alpha", type: .xtream)
        func mv(_ pid: String, _ title: String, added: Date?) -> Movie { var m = TestSupport.movie(s, pid, title); m.addedAt = added; return m }
        try c.indexer.commitMovies(source: s, categories: [], movies: [
            mv("1", "Seen", added: day(5)), mv("2", "Unseen New", added: day(3)), mv("3", "Unseen Old", added: day(90)),
            mv("4", "Unseen Fav", added: day(200)), mv("5", "Seen Fav", added: day(10)), mv("6", "No Date", added: nil)])
        var ids: [String: String] = [:]
        for m in try c.catalog.movies(VODQuery(sourceID: s.id)) { ids[m.title] = m.id }
        try c.historyRepo.saveProgress(WatchProgress(itemID: ids["Seen"]!, kind: .movie, seriesID: nil, positionSeconds: 100, durationSeconds: 5000, updatedAt: Date(), completed: false))
        try c.historyRepo.recordPlay(itemID: ids["Seen Fav"]!, kind: .movie, title: "Seen Fav")
        try c.favoritesRepo.setFavorite(ids["Unseen Fav"]!, kind: .movie, on: true)
        try c.favoritesRepo.setFavorite(ids["Seen Fav"]!, kind: .movie, on: true)
        return World(c: c, s: s, ids: ids)
    }

    func titles(_ w: World, _ q: VODQuery) throws -> Set<String> { Set(try w.c.catalog.movies(q).map(\.title)) }

    @Test func unwatchedListsTitlesNeverPlayed() throws {
        let w = try world()
        var q = VODQuery(sourceID: w.s.id); q.unwatchedOnly = true
        #expect(try titles(w, q) == ["Unseen New", "Unseen Old", "Unseen Fav", "No Date"])
        #expect(try w.c.catalog.countMovies(q) == 4)
    }

    @Test func aPlayedTitleIsNotUnwatchedWhetherItHasProgressOrOnlyALogEntry() throws {
        let w = try world()
        var q = VODQuery(sourceID: w.s.id); q.unwatchedOnly = true
        let t = try titles(w, q)
        #expect(!t.contains("Seen"), "has a saved position")
        #expect(!t.contains("Seen Fav"), "has only a play-log entry")
    }

    @Test func unwatchedFavoritesAreFavoritesNotYetPlayed() throws {
        let w = try world()
        var q = VODQuery(sourceID: w.s.id); q.unwatchedOnly = true; q.favoritesOnly = true
        #expect(try titles(w, q) == ["Unseen Fav"])
    }

    @Test func addedInThirtyDaysUsesTheProvidersDateAndLeavesOutTitlesWithNone() throws {
        let w = try world()
        var q = VODQuery(sourceID: w.s.id); q.addedWithinDays = 30
        #expect(try titles(w, q) == ["Seen", "Unseen New", "Seen Fav"])
        var both = q; both.unwatchedOnly = true
        #expect(try titles(w, both) == ["Unseen New"])
    }

    @Test func theSidebarOffersTheSmartListsOnMoviesAndSeries() {
        let movies = Shortcut.pinned(for: .movies), series = Shortcut.pinned(for: .series)
        for s in [Shortcut.unwatched, .unwatchedFavorites, .addedThisMonth] { #expect(movies.contains(s) && series.contains(s)) }
        #expect(series.contains(.newEpisodes) && !movies.contains(.newEpisodes), "new episodes only make sense for series")
        #expect(Shortcut.pinned(for: .movies).first == .featured && Shortcut.pinned(for: .series).first == .library, "the start page did not change")
    }

    // MARK: new episodes

    func episode(_ series: Series, _ n: Int) -> Episode {
        Episode(id: "\(series.id)|e\(n)", seriesID: series.id, seasonID: "s1", seasonNumber: 1, providerEpisodeID: "e\(n)", episodeNumber: n, title: "Episode \(n)",
                overview: nil, imageURL: nil, durationSeconds: nil, streamRef: "\(n).mp4")
    }

    func seriesWorld() throws -> (AppContainer, Series, PlaylistSource) {
        let c = try container()
        let s = try TestSupport.makeSource(c.db, name: "Alpha", type: .xtream)
        try c.indexer.commitSeries(source: s, categories: [], series: [TestSupport.series(s, "1", "Dark"), TestSupport.series(s, "2", "Other")])
        let dark = try #require(try c.catalog.series(VODQuery(sourceID: s.id)).first { $0.title == "Dark" })
        try c.indexer.saveSeriesDetail(SeriesDetail(series: dark, seasons: [Season(id: "s1", seriesID: dark.id, number: 1, name: nil)], episodes: [episode(dark, 1), episode(dark, 2), episode(dark, 3)]))
        return (c, dark, s)
    }

    @Test func withNothingStoredBeforeNothingIsNew() {
        let s = TestSupport.series(PlaylistSource(name: "x", type: .xtream, baseURL: "http://x"), "1", "Dark")
        #expect(NewEpisodeService.newEpisodes(before: [], after: [episode(s, 1), episode(s, 2)]).isEmpty, "a first read of a series is not news")
    }

    @Test func onlyEpisodesNotSeenBeforeAreNew() {
        let s = TestSupport.series(PlaylistSource(name: "x", type: .xtream, baseURL: "http://x"), "1", "Dark")
        let before: Set<String> = [episode(s, 1).id, episode(s, 2).id]
        #expect(NewEpisodeService.newEpisodes(before: before, after: [episode(s, 1), episode(s, 2), episode(s, 3)]) == [episode(s, 3).id])
        #expect(NewEpisodeService.newEpisodes(before: before, after: [episode(s, 1), episode(s, 2)]).isEmpty)
    }

    @Test func aSeriesWithAnUnplayedNewEpisodeIsListedAndBadged() throws {
        let (c, dark, s) = try seriesWorld()
        c.newEpisodes.record(seriesID: dark.id, episodeIDs: [episode(dark, 3).id], at: Date())
        #expect(c.newEpisodes.seriesIDs() == [dark.id])
        #expect(c.newEpisodes.episodeIDs(seriesID: dark.id) == [episode(dark, 3).id])
        var q = VODQuery(sourceID: s.id); q.newEpisodesOnly = true
        #expect(try c.catalog.series(q).map(\.title) == ["Dark"], "the New Episodes list holds only that series")
        #expect(try c.catalog.countSeries(q) == 1)
    }

    @Test func playingTheNewEpisodeTakesTheSeriesOffTheListWithoutTouchingTheTable() throws {
        let (c, dark, s) = try seriesWorld()
        c.newEpisodes.record(seriesID: dark.id, episodeIDs: [episode(dark, 3).id], at: Date())
        try c.historyRepo.saveProgress(WatchProgress(itemID: episode(dark, 3).id, kind: .episode, seriesID: dark.id, positionSeconds: 60, durationSeconds: 2400, updatedAt: Date(), completed: false))
        #expect(c.newEpisodes.seriesIDs().isEmpty)
        var q = VODQuery(sourceID: s.id); q.newEpisodesOnly = true
        #expect(try c.catalog.series(q).isEmpty)
        let rows = try c.db.read { try $0.scalarInt("SELECT COUNT(*) FROM new_episodes") }
        #expect(rows == 1, "the flag row is cleaned up later, not by playback")
    }

    @Test func oldFlagsAndFlagsForMissingEpisodesAreForgotten() throws {
        let (c, dark, _) = try seriesWorld()
        c.newEpisodes.record(seriesID: dark.id, episodeIDs: [episode(dark, 2).id], at: Date().addingTimeInterval(-NewEpisodeService.keepFor - 3600))
        c.newEpisodes.record(seriesID: dark.id, episodeIDs: [episode(dark, 3).id], at: Date())
        c.newEpisodes.record(seriesID: dark.id, episodeIDs: ["gone"], at: Date())
        c.newEpisodes.prune()
        #expect(c.newEpisodes.episodeIDs(seriesID: dark.id) == [episode(dark, 3).id])
    }

    @Test func theMigrationCreatesTheTable() throws {
        let c = try container()
        #expect(DatabaseMigrator.latestVersion >= 11)
        #expect(try c.db.read { try $0.scalarInt("SELECT COUNT(*) FROM new_episodes") } == 0)
    }
}
