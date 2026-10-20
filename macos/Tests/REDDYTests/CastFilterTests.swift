import Testing
import Foundation
@testable import REDDY

@Suite struct CastFilterTests {
    @Test func theMoviesFilterFindsATitleByItsCast() throws {
        let db = try TestSupport.makeDB()
        let catalog = SQLiteCatalogRepository(db: db)
        let src = try TestSupport.makeSource(db)
        let a = TestSupport.movie(src, "1", "Sarkaru Vaari Paata"), b = TestSupport.movie(src, "2", "Another Film")
        try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: [a, b])
        try PeopleIndex(db: db).save(itemID: a.id, kind: .movie, sourceID: src.id, names: ["Mahesh Babu", "Keerthy Suresh"])
        #expect(try catalog.movies(VODQuery(sourceID: nil, search: "mahesh babu", limit: 20, offset: 0)).map(\.id) == [a.id])
        #expect(try catalog.movies(VODQuery(sourceID: nil, search: "keerthy", limit: 20, offset: 0)).map(\.id) == [a.id])
        #expect(try catalog.movies(VODQuery(sourceID: nil, search: "Another", limit: 20, offset: 0)).map(\.id) == [b.id])      // a title still works
        #expect(try catalog.movies(VODQuery(sourceID: nil, search: "nobody here", limit: 20, offset: 0)).isEmpty)
    }
}
