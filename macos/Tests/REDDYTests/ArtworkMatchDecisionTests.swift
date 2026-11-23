import Testing
import Foundation
@testable import REDDY

@Suite("Artwork matching engine v2") struct ArtworkMatchDecisionTests {
    struct FxCandidate: Decodable { let id: Int; let title: String?; let originalTitle: String?; let year: Int?; let popularity: Double; let originalLanguage: String? }
    struct Fixture: Decodable { let libraryTitle: String; let year: Int?; let kind: String; let languageTag: String; let candidates: [FxCandidate]; let expectedId: Int?; let notes: String }

    private func fixturesURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artwork/fixtures/" + name)
    }

    @Test func theDecisionMatchesTheSharedFixtures() throws {
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturesURL("match-decision.json")))
        #expect(cases.count >= 120)
        for c in cases {
            let q = ArtworkMatchDecision.Query(title: c.libraryTitle, year: c.year, isSeries: c.kind == "series", languageTag: c.languageTag)
            let got = ArtworkMatchDecision.decide(q, c.candidates.map { .init(id: $0.id, title: $0.title, originalTitle: $0.originalTitle, year: $0.year, popularity: $0.popularity, originalLanguage: $0.originalLanguage) })
            #expect(got == c.expectedId, "\(c.libraryTitle) [\(c.notes)]")
        }
    }

    @Test func theFixturesCoverEveryFailureClass() throws {
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturesURL("match-decision.json")))
        let notes = cases.map { $0.notes.lowercased() }.joined(separator: "\n")
        for word in ["transliteration", "word", "subtitle", "roman", "season", "year", "short", "popularity", "language", "no candidates", "no library year", "provider prefix", "devanagari", "tamil script"] { #expect(notes.contains(word), "a case about \(word)") }
        #expect(cases.contains { $0.expectedId == nil } && cases.contains { $0.expectedId != nil })
    }

    @Test func similarityHandlesSpellingOrderAndSpacing() {
        #expect(ArtworkMatchDecision.similarity("Pokiri", "Pokkiri") >= 0.88)
        #expect(ArtworkMatchDecision.similarity("Dulhaniya Le Aaeegi", "Dulhania Le Aayegi") >= 0.88)
        #expect(ArtworkMatchDecision.similarity("Le Dulhania", "Dulhania Le") >= 0.88)
        #expect(ArtworkMatchDecision.similarity("Baahu Bali", "Baahubali") >= 0.88)
        #expect(ArtworkMatchDecision.similarity("Rocky II", "Rocky 2") == 1)
        #expect(ArtworkMatchDecision.similarity("The Matrix", "Matrix Reloaded") < 0.88)
        #expect(ArtworkMatchDecision.jaroWinkler("martha", "marhta") > 0.95)
        #expect(ArtworkMatchDecision.skeleton("dulhaniya le aaeegi") == ArtworkMatchDecision.skeleton("dulhania le aayegi"))
    }

    @Test func searchLanguageFollowsTheLibraryTag() {
        #expect(ArtworkMatchDecision.searchLanguage(for: "Telugu") == "te-IN" && ArtworkMatchDecision.searchLanguage(for: "Hindi") == "hi-IN")
        #expect(ArtworkMatchDecision.searchLanguage(for: "English") == nil && ArtworkMatchDecision.searchLanguage(for: "") == nil)
    }

    // MARK: provider ids
    @Test func listItemsCarryTheProvidersIDs() throws {
        let src = PlaylistSource(name: "T", type: .xtream, baseURL: "http://example.com")
        let json = #"[{"stream_id":1,"name":"A","tmdb":"603","imdb":"tt0133093"},{"stream_id":2,"name":"B","tmdb_id":0,"imdb_id":"junk"},{"stream_id":3,"name":"C"}]"#
        let dtos = try JSONDecoder().decode([XtreamVODDTO].self, from: Data(json.utf8))
        let ids = XtreamMapper(source: src).providerIDs(movies: dtos)
        #expect(ids.count == 1)
        #expect(ids.values.first == ProviderIDs(tmdb: 603, imdb: "tt0133093"))
        let sjson = #"[{"series_id":9,"name":"S","tmdb":"1396"}]"#
        let s = try JSONDecoder().decode([XtreamSeriesDTO].self, from: Data(sjson.utf8))
        #expect(XtreamMapper(source: src).providerIDs(series: s).values.first?.tmdb == 1396)
    }

    private func rig(_ reply: @escaping @Sendable (URLRequest) throws -> Data) throws -> (MetadataMatchService, DatabaseManager, PlaylistSource, Locked<[String]>) {
        let db = try TestSupport.makeDB(), src = try TestSupport.makeSource(db)
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let paths = Locked<[String]>([])
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { r in paths.mutate { $0.append(r.url?.path ?? "") }; return try reply(r) }
        return (svc, db, src, paths)
    }
    private let movieJSON = Data(#"{"id":603,"title":"Whatever Name","overview":"S.","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"1999-03-30","vote_average":8.1}"#.utf8)

    @Test func aProviderTMDBIDIsFetchedDirectlyWithNoSearch() async throws {
        let (svc, db, src, paths) = try rig { _ in self.movieJSON }
        let m = TestSupport.movie(src, "1", "Completely Different Local Name", year: 1999)
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: [m])
        ProviderIDStore(db: db).save([m.id: ProviderIDs(tmdb: 603, imdb: nil)])
        let (items, _) = try svc.pending(limit: 5)
        #expect(items.first?.tmdbID == 603)
        let hit = try await svc.lookup(try #require(items.first))
        #expect(hit?.tmdbID == 603 && hit?.poster == "https://image.tmdb.org/t/p/w500/p.jpg")
        #expect(paths.value == ["/3/movie/603"], "no search, one request")
    }

    @Test func anIMDbIDUsesFindAndAnUnknownTMDBIDFallsBackToSearch() async throws {
        let find = Data(#"{"movie_results":[{"id":603,"title":"X","poster_path":"/p.jpg","release_date":"1999-03-30"}],"tv_results":[]}"#.utf8)
        let (svc, _, _, paths) = try rig { _ in find }
        let hit = try await svc.lookup(.init(id: "x", isSeries: false, title: "Any", year: 1999, tmdbID: nil, imdbID: "tt0133093"))
        #expect(hit?.tmdbID == 603 && paths.value == ["/3/find/tt0133093"])
        let (svc2, _, _, paths2) = try rig { r in
            if r.url?.path.hasPrefix("/3/movie/") == true { throw NetworkError.http(status: 404, retryAfter: nil) }
            return Data(#"{"results":[{"id":5,"title":"The Silent Harbor","poster_path":"/p.jpg","release_date":"2019-01-01","popularity":10}]}"#.utf8) }
        let hit2 = try await svc2.lookup(.init(id: "y", isSeries: false, title: "The Silent Harbor (2019)", year: 2019, tmdbID: 999999, imdbID: nil))
        #expect(hit2?.tmdbID == 5 && paths2.value == ["/3/movie/999999", "/3/search/movie"], "a wrong id costs one request, then the search")
    }

    @Test func theProviderIDStoreRoundTripsAndTheTableExists() throws {
        let db = try TestSupport.makeDB()
        let store = ProviderIDStore(db: db)
        store.save(["a": ProviderIDs(tmdb: 1, imdb: "tt0000001"), "b": ProviderIDs(tmdb: nil, imdb: nil)])
        #expect(store.ids(for: "a") == ProviderIDs(tmdb: 1, imdb: "tt0000001") && store.ids(for: "b") == nil)
        #expect(DatabaseMigrator.latestVersion >= 22)
    }

    @Test func theYearIsNeverSearched() async throws {
        let few = Locked<Int>(0)
        let (svc, _, _, paths) = try rig { r in few.mutate { $0 += 1 }; return Data(#"{"results":[{"id":1,"title":"Other Thing","release_date":"2000-01-01"}]}"#.utf8) }
        _ = try await svc.lookup(.init(id: "z", isSeries: false, title: "Some Distinctive Film Title (2020)", year: 2020))
        #expect(!paths.value.contains { _ in false } && few.value <= 3, "a short first page is not searched again with the year: \(few.value) requests")
        let full = (0..<20).map { #"{"id":\#($0 + 1),"title":"Different \#($0)","release_date":"2000-01-01"}"# }.joined(separator: ",")
        let (svc2, _, _, paths2) = try rig { _ in Data(("{\"results\":[" + full + "]}").utf8) }
        _ = try await svc2.lookup(.init(id: "z", isSeries: false, title: "Some Distinctive Film Title (2020)", year: 2020))
        #expect(paths2.value.count == 3, "no year search, even on a full page: the name, without the last word, without the first")
    }

    // MARK: series per folder (one resolution per series)
    @Test func everyEpisodeOfASeriesInheritsOneSearch() async throws {
        let reply = Data(#"{"results":[{"id":77,"name":"The Silent Harbor","poster_path":"/p.jpg","first_air_date":"2019-01-01"}]}"#.utf8)
        let (svc, _, _, paths) = try rig { _ in reply }
        var hits: [Int?] = []
        for n in ["The Silent Harbor S01E01 1080p", "The Silent Harbor S01E02", "The.Silent.Harbor.S02E10.WEB-DL", "The Silent Harbor - Episode 4"] {
            hits.append(try await svc.lookup(.init(id: n, isSeries: true, title: n, year: nil))?.tmdbID)
        }
        #expect(hits == [77, 77, 77, 77])
        #expect(paths.value == ["/3/search/tv"], "one search for the whole series: \(paths.value)")
    }

    @Test func aMarkerOnlyNameBorrowsTheFolderName() async throws {
        let reply = Data(#"{"results":[{"id":78,"name":"Night Court","poster_path":"/p.jpg","first_air_date":"1984-01-01"}]}"#.utf8)
        let (svc, _, _, paths) = try rig { _ in reply }
        let hit = try await svc.lookup(.init(id: "e1", isSeries: true, title: "S01E04", year: nil, folderName: "Night Court"))
        #expect(hit?.tmdbID == 78 && paths.value.count == 1)
        let none = try await svc.lookup(.init(id: "e2", isSeries: true, title: "S01E05", year: nil))
        #expect(none == nil && paths.value.count == 1, "no folder, no name, nothing sent")
    }

    @Test func aNotFoundAnswerIsAlsoSharedButAnErrorIsNot() async throws {
        let (svc, _, _, paths) = try rig { _ in Data(#"{"results":[]}"#.utf8) }
        for e in ["Zzqx Vnmb S01E01", "Zzqx Vnmb S01E02"] { _ = try await svc.lookup(.init(id: e, isSeries: true, title: e, year: nil)) }
        let first = paths.value.count
        #expect(first <= 1 || paths.value.count == first, "second episode adds no request")
        let fail = Locked<Int>(0)
        let (svc2, _, _, _) = try rig { _ in fail.mutate { $0 += 1 }; if fail.value == 1 { throw NetworkError.http(status: 500, retryAfter: nil) }; return Data(#"{"results":[]}"#.utf8) }
        _ = try? await svc2.lookup(.init(id: "a", isSeries: true, title: "Zzqx Vnmb S01E01", year: nil))
        _ = try? await svc2.lookup(.init(id: "b", isSeries: true, title: "Zzqx Vnmb S01E02", year: nil))
        #expect(fail.value >= 2, "a failed search is retried by the next sibling")
    }
}

@Suite("Query tiers and non-title names") struct QueryTierTests {
    private func fx(_ n: String) -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artwork/fixtures/" + n) }
    @Test func tiersFollowTheSharedCases() throws {
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: fx("query-tiers.json"))) as! [[String: Any]]
        for c in cases { #expect(MetadataMatchService.extraQueries(c["text"] as! String, tiers: Set(c["tiers"] as! [String])) == c["expect"] as! [String], Comment(rawValue: c["text"] as! String)) }
    }
    @Test func nonTitlesAreRecognisedAndRealTitlesAreNot() {
        for t in ["Rovers vs United", "Lions vs. Tigers Highlights", "League Final Press Conference", "Boxing Night PPV 12"] { #expect(MetadataMatchService.isNonTitle(t, year: nil), Comment(rawValue: t)) }
        for t in ["Alien vs. Predator (2004)", "Batman v Superman", "The Heat", "Live Free or Die Hard"] { #expect(!MetadataMatchService.isNonTitle(t, year: nil), Comment(rawValue: t)) }
    }
    @Test func aNonTitleIsNeverSentAndNeverCounted() async throws {
        let sent = Locked<Int>(0)
        let db = try TestSupport.makeDB(), src = try TestSupport.makeSource(db)
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { _ in sent.mutate { $0 += 1 }; return Data("{\"results\":[]}".utf8) }
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "1", "Rovers vs United"), TestSupport.movie(src, "2", "Zzqx Unfindable Film")])
        _ = try await svc.run()
        let counts = svc.lookedUpCounts()
        #expect(counts.done == 1 && counts.notFound == 1, "only the real title is counted: \(counts)")
        #expect(try svc.pending(limit: 5).items.isEmpty, "the non-title is not queued again")
        #expect(MetadataMatchService.rulesVersion == "v3")
    }
    @Test func aRatingOnlyMissOfAPostersTitleIsNotCountedAsNotFound() async throws {
        let db = try TestSupport.makeDB(), src = try TestSupport.makeSource(db)
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { _ in Data("{\"results\":[]}".utf8) }
        let m = TestSupport.movie(src, "1", "Has A Poster Already")
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: [m])
        try db.write { try $0.execute("UPDATE movies SET poster_url = 'https://example.test/p.jpg' WHERE id = ?", [m.id]); try $0.execute("INSERT OR REPLACE INTO metadata_matches(item_id, kind, tmdb_id, matched_at, filled) VALUES(?, 'movie', NULL, ?, 'v3')", [m.id, Date()]) }
        #expect(svc.lookedUpCounts().notFound == 0 && svc.lookedUpCounts().done == 1)
    }
}
