import Testing
import Foundation
@testable import REDDY

/// provider_ids (what the playlist claims) and hub_identity (the one crosswalk) stay in step: nothing is lost on either side, and the matcher sees ids the hub found.
@Suite("Identity tables") struct IdentityTablesTests {
    @Test func savingProviderIDsMirrorsThemIntoTheCrosswalkWithoutBlankingFoundIDs() throws {
        let db = try TestSupport.makeDB()
        let hub = HubStore(db: db)
        hub.saveIdentity("m1", HubIdentity(tmdb: nil, tvdb: 77, imdb: nil, tvmaze: 5, kind: .series), from: .tvmaze)
        ProviderIDStore(db: db).save(["m1": ProviderIDs(tmdb: 603, imdb: "tt0133093"), "m2": ProviderIDs(tmdb: nil, imdb: "tt0000001")])
        let a = try #require(hub.identity("m1")?.ids)
        #expect(a.tmdb == 603 && a.imdb == "tt0133093" && a.tvdb == 77 && a.tvmaze == 5, "the playlist's ids are added, the hub's own are kept")
        #expect(hub.identity("m2")?.ids.imdb == "tt0000001")
        #expect(ProviderIDStore(db: db).ids(for: "m1")?.tmdb == 603, "provider_ids still holds what the playlist said")
        ProviderIDStore(db: db).save(["m1": ProviderIDs(tmdb: nil, imdb: "tt0133093")])
        #expect(hub.identity("m1")?.ids.tmdb == 603, "a later partial save never blanks an id")
    }

    @Test func theMatcherQueueSeesAnIDOnlyTheHubResolved() throws {
        let db = try TestSupport.makeDB()
        let s = try TestSupport.makeSource(db)
        let m = TestSupport.movie(s, "p1", "Heat", year: 1995)
        _ = try CatalogIndexer(db: db).commitMovies(source: s, categories: [], movies: [m])
        HubStore(db: db).saveIdentity(m.id, HubIdentity(tmdb: 949), from: .tmdb)
        let pending = try MetadataMatchService(db: db, credentials: InMemoryCredentialStore(), defaults: InMemoryDefaults(), builtIn: { nil }) { _ in throw URLError(.notConnectedToInternet) }.pending(limit: 5).items
        #expect(pending.first { $0.id == m.id }?.tmdbID == 949)
    }
}
