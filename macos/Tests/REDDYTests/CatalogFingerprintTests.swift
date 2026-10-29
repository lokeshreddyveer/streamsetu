import Testing
import Foundation
@testable import REDDY

/// An unchanged provider writes nothing, and anything that changed writes everything. "Nothing was written" is seen by changing a saved row behind the indexer's back: if it is
/// still changed afterwards, the indexer left the database alone.
@Suite("Catalog fingerprints: an unchanged catalog is not rewritten") @MainActor struct CatalogFingerprintTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-fp-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    @Test func theSameChannelsAgainWriteNothing() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        let list = (0..<50).map { TestSupport.channel(src, "\($0)", "Channel \($0)", order: $0) }
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        try c.db.write { try $0.execute("UPDATE channels SET name='Marked' WHERE provider_id='7'") }
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        let name = try c.db.read { try $0.queryOne("SELECT name FROM channels WHERE provider_id='7'", []) { $0.string(0) } }
        #expect(name == "Marked", "the second import saw the same fingerprint and left the table alone")
    }

    @Test func aChangedChannelWritesEverythingAgain() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        var list = (0..<50).map { TestSupport.channel(src, "\($0)", "Channel \($0)", order: $0) }
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        try c.db.write { try $0.execute("UPDATE channels SET name='Marked' WHERE provider_id='7'") }
        list[7] = TestSupport.channel(src, "7", "Renamed upstream", order: 7)
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        let name = try c.db.read { try $0.queryOne("SELECT name FROM channels WHERE provider_id='7'", []) { $0.string(0) } }
        #expect(name == "Renamed upstream", "the provider changed a channel, so the catalog was written")
    }

    @Test func aTableChangedBehindTheFingerprintIsWrittenAgain() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        let list = (0..<20).map { TestSupport.channel(src, "\($0)", "Channel \($0)", order: $0) }
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        try c.db.write { try $0.execute("DELETE FROM channels WHERE provider_id='3'") }
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        #expect(try c.catalog.counts(sourceID: src.id).channels == 20, "a missing row means the fingerprint no longer describes the table")
    }

    @Test func moviesAndSeriesAreSkippedTheSameWay() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        let movies = (0..<30).map { TestSupport.movie(src, "\($0)", "Movie \($0)") }
        let shows = (0..<30).map { TestSupport.series(src, "\($0)", "Show \($0)") }
        try c.indexer.commitMovies(source: src, categories: [], movies: movies)
        try c.indexer.commitSeries(source: src, categories: [], series: shows)
        try c.db.write { try $0.execute("UPDATE movies SET title='Marked' WHERE provider_id='4'"); try $0.execute("UPDATE series SET title='Marked' WHERE provider_id='4'") }
        try c.indexer.commitMovies(source: src, categories: [], movies: movies)
        try c.indexer.commitSeries(source: src, categories: [], series: shows)
        let m = try c.db.read { try $0.queryOne("SELECT title FROM movies WHERE provider_id='4'", []) { $0.string(0) } }
        let s = try c.db.read { try $0.queryOne("SELECT title FROM series WHERE provider_id='4'", []) { $0.string(0) } }
        #expect(m == "Marked" && s == "Marked")
    }

    @Test func aNewerImporterVersionWritesOnce() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        let list = (0..<10).map { TestSupport.channel(src, "\($0)", "Channel \($0)", order: $0) }
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        try c.db.write { try $0.execute("UPDATE channels SET name='Marked' WHERE provider_id='2'"); try $0.execute("UPDATE catalog_fingerprints SET version = 0") }
        try c.indexer.commitChannels(source: src, categories: [], channels: list)
        let name = try c.db.read { try $0.queryOne("SELECT name FROM channels WHERE provider_id='2'", []) { $0.string(0) } }
        #expect(name == "Channel 2", "a saved fingerprint from another importer version does not count")
    }
}
