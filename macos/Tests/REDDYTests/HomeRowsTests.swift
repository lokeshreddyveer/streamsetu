import Testing
import Foundation
@testable import REDDY

@Suite struct HomeRowsTests {
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository
    let repo: SQLiteHistoryRepository
    let service: HistoryService
    let source: PlaylistSource
    let series: Series
    let eps: [Episode]

    init() throws {
        db = try TestSupport.makeDB()
        catalog = SQLiteCatalogRepository(db: db)
        repo = SQLiteHistoryRepository(db: db)
        service = HistoryService(repo: repo, catalog: catalog)
        source = try TestSupport.makeSource(db)
        series = TestSupport.series(source, "s1", "Show")
        let indexer = CatalogIndexer(db: db)
        try indexer.commitSeries(source: source, categories: [], series: [series])
        let src = source, ser = series
        let made: [Episode] = (1...4).map { n in
            Episode(id: ItemID.make(source: src.id, kind: .episode, provider: "e\(n)"), seriesID: ser.id, seasonID: "\(ser.id)|season|1", seasonNumber: 1,
                    providerEpisodeID: "e\(n)", episodeNumber: n, title: "Episode \(n)", overview: nil, imageURL: nil, durationSeconds: 1800, streamRef: "e\(n).mp4")
        }
        eps = made
        try indexer.saveSeriesDetail(SeriesDetail(series: series, seasons: [Season(id: "\(series.id)|season|1", seriesID: series.id, number: 1, name: nil)], episodes: made))
    }

    private func watched(_ e: Episode, finished: Bool) throws {
        try repo.recordPlay(itemID: e.id, kind: .episode, title: e.title)
        try repo.saveProgress(WatchProgress(itemID: e.id, kind: .episode, seriesID: series.id, positionSeconds: finished ? 1790 : 400, durationSeconds: 1800, updatedAt: Date(), completed: finished))
    }

    @Test func aFinishedEpisodeOffersTheNextOne() throws {
        try watched(eps[0], finished: true)
        let next = try service.upNext()
        #expect(next.count == 1 && next[0].episode.id == eps[1].id && next[0].series.id == series.id)
    }

    @Test func aHalfWatchedEpisodeIsNotUpNextBecauseItIsUnderContinueWatching() throws {
        try watched(eps[0], finished: true)
        try watched(eps[1], finished: false)
        #expect(try service.upNext().isEmpty)
    }

    @Test func theMostRecentlyWatchedEpisodeDecidesAndWatchedOnesAreSkipped() throws {
        try watched(eps[0], finished: true); try watched(eps[1], finished: true)
        #expect(try service.upNext().first?.episode.id == eps[2].id)
    }

    @Test func theLastEpisodeOfASeriesHasNothingAfterIt() throws {
        try watched(eps[3], finished: true)
        #expect(try service.upNext().isEmpty)
    }

    @Test func aSeriesIsWatchedOnlyWhenEveryEpisodeIs() throws {
        for e in eps.dropLast() { try watched(e, finished: true) }
        #expect(try repo.watchedTitleIDs().contains(series.id) == false)
        try watched(eps[3], finished: true)
        #expect(try repo.watchedTitleIDs().contains(series.id))
    }

    @Test func savingProgressTellsTheListener() throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        repo.onProgressChanged = { counter.n += 1 }
        try watched(eps[0], finished: false)
        try repo.clearProgress(itemID: eps[0].id)
        #expect(counter.n == 2)
    }

    @Test func aSeriesNeverWatchedIsNotInTheRow() throws {
        #expect(try service.upNext().isEmpty)
    }

    @Test func channelsWatchedTwiceOrMoreAreRankedByPlays() throws {
        let a = TestSupport.channel(source, "a", "Alpha TV"), b = TestSupport.channel(source, "b", "Bravo TV"), c = TestSupport.channel(source, "c", "Charlie TV")
        try CatalogIndexer(db: db).commitChannels(source: source, categories: [], channels: [a, b, c])
        for _ in 0..<5 { try repo.recordPlay(itemID: b.id, kind: .channel, title: b.name) }
        for _ in 0..<2 { try repo.recordPlay(itemID: a.id, kind: .channel, title: a.name) }
        try repo.recordPlay(itemID: c.id, kind: .channel, title: c.name)                 // once is not a habit
        #expect(try service.mostWatchedChannels().map(\.name) == ["Bravo TV", "Alpha TV"])
    }
}
