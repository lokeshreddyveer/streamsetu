import Testing
import Foundation
@testable import REDDY

@Suite struct PeopleIndexTests {
    let db: DatabaseManager
    let index: PeopleIndex
    let source: PlaylistSource
    let wick: Movie, matrix: Movie, show: Series

    init() throws {
        db = try TestSupport.makeDB()
        index = PeopleIndex(db: db)
        source = try TestSupport.makeSource(db)
        wick = TestSupport.movie(source, "1", "John Wick (2014)", year: 2014)
        matrix = TestSupport.movie(source, "2", "The Matrix (1999)", year: 1999)
        show = TestSupport.series(source, "9", "Some Show")
        let indexer = CatalogIndexer(db: db)
        try indexer.commitMovies(source: source, categories: [], movies: [wick, matrix])
        try indexer.commitSeries(source: source, categories: [], series: [show])
    }

    @Test func aPersonIsFoundByAnyPartOfTheirName() throws {
        try index.save(itemID: wick.id, kind: .movie, sourceID: source.id, names: ["Keanu Reeves", "Chad Stahelski"])
        try index.save(itemID: matrix.id, kind: .movie, sourceID: source.id, names: ["Keanu Reeves", "Carrie-Anne Moss"])
        let kinds: Set<ContentKind> = [.movie, .series]
        #expect(Set(index.hits(term: "keanu", kinds: kinds, sourceID: nil, limit: 20).map(\.itemID)) == [wick.id, matrix.id])
        #expect(Set(index.hits(term: "Reeves Keanu", kinds: kinds, sourceID: nil, limit: 20).map(\.itemID)) == [wick.id, matrix.id])
        #expect(index.hits(term: "stahelski", kinds: kinds, sourceID: nil, limit: 20).map(\.itemID) == [wick.id])
        #expect(index.hits(term: "carrie anne", kinds: kinds, sourceID: nil, limit: 20).map(\.itemID) == [matrix.id])
    }

    @Test func tooLittleTypedFindsNobody() throws {
        try index.save(itemID: wick.id, kind: .movie, sourceID: source.id, names: ["Keanu Reeves"])
        #expect(index.hits(term: "ke", kinds: [.movie], sourceID: nil, limit: 20).isEmpty)
        #expect(index.hits(term: "eanu", kinds: [.movie], sourceID: nil, limit: 20).isEmpty)          // a name is searched from the start of a word
    }

    @Test func aSeriesCastComesWithItsList() throws {
        index.saveSeries([show.id: ["Pedro Pascal", "Bella Ramsey"]], sourceID: source.id)
        #expect(index.hits(term: "pascal", kinds: [.series], sourceID: nil, limit: 20).map(\.itemID) == [show.id])
        #expect(index.hits(term: "pascal", kinds: [.movie], sourceID: nil, limit: 20).isEmpty)       // only the kinds being searched
    }

    @Test func titlesAskedAboutAreNotAskedAgain() throws {
        #expect(index.pendingMovies(limit: 10).count == 2)
        try index.save(itemID: wick.id, kind: .movie, sourceID: source.id, names: [])               // nobody named, but it was asked
        #expect(index.pendingMovies(limit: 10).map(\.id) == [matrix.id])
        let p = index.progress()
        #expect(p.done == 1 && p.total == 2)
    }

    @Test func savingAgainReplacesTheNames() throws {
        try index.save(itemID: wick.id, kind: .movie, sourceID: source.id, names: ["Wrong Name"])
        try index.save(itemID: wick.id, kind: .movie, sourceID: source.id, names: ["Keanu Reeves"])
        #expect(index.hits(term: "wrong", kinds: [.movie], sourceID: nil, limit: 20).isEmpty)
        #expect(index.hits(term: "keanu", kinds: [.movie], sourceID: nil, limit: 20).count == 1)
    }

    @Test func searchingForAPersonFindsTheirTitlesAfterTheTitlesNamedLikeIt() throws {
        try index.save(itemID: matrix.id, kind: .movie, sourceID: source.id, names: ["John Doe"])
        let repo = SQLiteSearchRepository(db: db)
        let hits = try repo.search(term: "john", filters: SearchFilters(kinds: [.movie]))
        #expect(hits.map(\.itemID) == [wick.id, matrix.id])        // "John Wick" is named like it; The Matrix has a John in it
    }

    @Test func deletingAPlaylistRemovesItsPeople() throws {
        try index.save(itemID: wick.id, kind: .movie, sourceID: source.id, names: ["Keanu Reeves"])
        try SQLiteCatalogRepository(db: db).deleteSource(id: source.id)
        #expect(index.hits(term: "keanu", kinds: [.movie], sourceID: nil, limit: 20).isEmpty)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM people") } == 0)
    }
}
