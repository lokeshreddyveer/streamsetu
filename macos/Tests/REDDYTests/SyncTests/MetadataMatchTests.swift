import Testing
import Foundation
@testable import REDDY

/// Thread-safe recorder of the requests the service made, with canned replies.
private final class FakeTMDB: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var reply: @Sendable (URLRequest) throws -> Data
    init(_ reply: @escaping @Sendable (URLRequest) throws -> Data) { self.reply = reply }
    func fetch(_ r: URLRequest) throws -> Data { lock.lock(); requests.append(r); lock.unlock(); return try reply(r) }
}

private func json(_ results: String) -> Data { Data("{\"results\":[\(results)]}".utf8) }
private let matrix = #"{"id":603,"title":"The Matrix","original_title":"The Matrix","overview":"A hacker learns the truth.","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"1999-03-30","vote_average":8.2}"#

@Suite("TMDB artwork matching") struct MetadataMatchTests {
    private func setup(key: String? = "0123456789abcdef0123456789abcdef", fake: FakeTMDB) throws -> (MetadataMatchService, DatabaseManager, PlaylistSource, InMemoryCredentialStore) {
        let db = try TestSupport.makeDB()
        let src = try TestSupport.makeSource(db)
        let creds = InMemoryCredentialStore()
        if let key { try creds.save(Credentials(username: "tmdb", password: key), ref: MetadataMatchService.keyRef) }
        return (MetadataMatchService(db: db, credentials: creds, pause: 0) { try fake.fetch($0) }, db, src, creds)
    }

    private func add(_ db: DatabaseManager, _ src: PlaylistSource, _ movies: [Movie]) throws {
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: movies)
    }

    @Test func fillsOnlyTheGapsAndLeavesProviderDataAlone() async throws {
        let fake = FakeTMDB { _ in json(matrix) }
        let (svc, db, src, _) = try setup(fake: fake)
        var bare = TestSupport.movie(src, "1", "The Matrix", year: 1999)
        var owned = TestSupport.movie(src, "2", "The Matrix"); owned.posterURL = "http://provider/poster.jpg"
        bare.overview = nil
        try add(db, src, [bare, owned])
        let out = try await svc.run()
        #expect(out.looked == 1 && out.matched == 1 && out.remaining == 0, "an item that already has a poster isn't looked up")
        let repo = SQLiteCatalogRepository(db: db)
        let filled = try #require(try repo.movie(id: bare.id))
        #expect(filled.posterURL == "https://image.tmdb.org/t/p/w500/p.jpg" && filled.backdropURL == "https://image.tmdb.org/t/p/w1280/b.jpg")
        #expect(filled.overview == "A hacker learns the truth." && filled.rating == "8.2")
        #expect(try repo.movie(id: owned.id)?.posterURL == "http://provider/poster.jpg")
    }

    @Test func aWrongOrDistantMatchIsRefusedAndNotRetriedImmediately() async throws {
        let other = #"{"id":9,"title":"Matrix Reloaded","poster_path":"/x.jpg","release_date":"2003-05-15"}"#
        let wrongYear = #"{"id":10,"title":"The Matrix","poster_path":"/y.jpg","release_date":"2021-12-01"}"#
        let fake = FakeTMDB { _ in json(other + "," + wrongYear) }
        let (svc, db, src, _) = try setup(fake: fake)
        let m = TestSupport.movie(src, "1", "The Matrix", year: 1999)
        try add(db, src, [m])
        let first = try await svc.run()
        #expect(first.matched == 0 && first.unmatched == 1)
        #expect(try SQLiteCatalogRepository(db: db).movie(id: m.id)?.posterURL == nil)
        let second = try await svc.run()
        #expect(second.looked == 0, "a lookup that found nothing waits before it is repeated")
        #expect(fake.requests.count == 1)
    }

    @Test func providerTitlesAreCleanedBeforeSearching() async throws {
        let fake = FakeTMDB { _ in json(matrix) }
        let (svc, db, src, _) = try setup(fake: fake)
        try add(db, src, [TestSupport.movie(src, "1", "EN - The Matrix (1999) 4K")])
        _ = try await svc.run()
        let url = try #require(fake.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "query" }?.value == "The Matrix")
        #expect(items.first { $0.name == "year" }?.value == "1999")
        #expect(TitleCleaner.query("|FR| Amélie [HD]", year: nil).text == "Amélie")
    }

    @Test func aV3KeyGoesInTheQueryAndAV4TokenInTheHeaderOnlyToTMDB() async throws {
        let fake = FakeTMDB { _ in json("") }
        let (svc, _, _, creds) = try setup(fake: fake)
        try await svc.verifyKey()
        let v3 = try #require(fake.requests.last)
        #expect(v3.url?.host == "api.themoviedb.org" && v3.url?.query?.contains("api_key=0123456789abcdef0123456789abcdef") == true)
        #expect(v3.value(forHTTPHeaderField: "Authorization") == nil)
        let token = "eyJ" + String(repeating: "a", count: 60)
        try creds.save(Credentials(username: "tmdb", password: token), ref: MetadataMatchService.keyRef)
        try await svc.verifyKey()
        let v4 = try #require(fake.requests.last)
        #expect(v4.value(forHTTPHeaderField: "Authorization") == "Bearer " + token && v4.url?.query?.contains("api_key") != true)
    }

    @Test func problemsAreReportedWithoutLeakingTheKeyOrStoppingSilently() async throws {
        let secret = "0123456789abcdef0123456789abcdef"
        let bad = FakeTMDB { _ in throw NetworkError.http(status: 401, retryAfter: nil) }
        let (svc, db, src, _) = try setup(key: secret, fake: bad)
        try add(db, src, [TestSupport.movie(src, "1", "The Matrix")])
        await #expect(throws: MetadataMatchService.MatchError.invalidKey) { try await svc.run() }
        let limited = FakeTMDB { _ in throw NetworkError.http(status: 429, retryAfter: 5) }
        let (svc2, _, _, _) = try setup(fake: limited)
        await #expect(throws: MetadataMatchService.MatchError.rateLimited) { try await svc2.verifyKey() }
        struct Leaky: Error, CustomStringConvertible { let description: String }
        let leaky = FakeTMDB { r in throw Leaky(description: r.url?.absoluteString ?? "") }
        let (svc3, _, _, _) = try setup(key: secret, fake: leaky)
        do { try await svc3.verifyKey(); Issue.record("should have thrown") }
        catch { #expect(!"\(error) \(error.localizedDescription)".contains(secret)) }
        let (svc4, _, _, _) = try setup(key: nil, fake: bad)
        #expect(!svc4.hasKey)
        await #expect(throws: MetadataMatchService.MatchError.noKey) { try await svc4.run() }
    }

    @Test func theKeyCanBeSavedAndRemoved() throws {
        let (svc, _, _, _) = try setup(key: nil, fake: FakeTMDB { _ in Data() })
        try svc.saveKey("  abc  ")
        #expect(svc.hasKey)
        try svc.removeKey()
        #expect(!svc.hasKey)
    }
}
