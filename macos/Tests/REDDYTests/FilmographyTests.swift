import Testing
import Foundation
@testable import REDDY

@Suite("Filmography", .serialized) struct FilmographyTests {
    private func credit(_ id: Int, _ title: String, _ date: String?, series: Bool = false, pop: Double = 1, rating: Double? = nil, poster: String? = "/p.jpg") -> FilmCredit {
        FilmCredit(tmdbID: id, isSeries: series, title: title, originalTitle: nil, date: date, posterPath: poster, overview: nil, rating: rating, votes: nil, popularity: pop, role: nil)
    }

    private func library() throws -> (DatabaseManager, PlaylistSource, [String: String]) {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        func cat(_ s: PlaylistSource, _ id: String, _ name: String) -> CatalogCategory { CatalogCategory(id: id, sourceID: s.id, kind: .movie, providerID: id, name: name, sortOrder: 0) }
        let open = cat(a, "open", "ENGLISH"), hin = cat(a, "hin", "HINDI DUBBED"), secret = cat(a, "secret", "SECRET"), bopen = cat(b, "bopen", "ENGLISH")
        func mv(_ s: PlaylistSource, _ pid: String, _ t: String, _ y: Int?, _ c: CatalogCategory) -> Movie { var m = TestSupport.movie(s, pid, t, year: y); m.categoryID = c.id; m.categoryName = c.name; return m }
        let movies = [mv(a, "pokiri", "Pokiri (2006)", 2006, open), mv(a, "pokiri-h", "Pokiri (2006) Hindi", 2006, hin), mv(b, "pokiri-b", "Pokiri (2006)", 2006, bopen),
                      mv(a, "dookudu", "Dookudu Returns (2011)", 2012, open),                       // a year off by one
                      mv(a, "hidden", "Secret Film (2015)", 2015, secret), mv(b, "hidden-b", "Secret Film (2015)", 2015, bopen),   // twin of a locked one
                      mv(a, "exact", "Totally Different Name", nil, open), mv(a, "other", "Okkadu (2003)", 2003, open)]
        _ = try CatalogIndexer(db: db).commitMovies(source: a, categories: [open, hin, secret], movies: movies.filter { $0.sourceID == a.id })
        _ = try CatalogIndexer(db: db).commitMovies(source: b, categories: [bopen], movies: movies.filter { $0.sourceID == b.id })
        _ = try IdentityStore(db: db).backfill()
        try db.write { try $0.execute("INSERT INTO metadata_matches(item_id, kind, tmdb_id, matched_at) VALUES(?,?,?,?)", [movies[6].id, "movie", 777, Date().timeIntervalSince1970]) }
        try db.write { try $0.execute("INSERT INTO metadata_matches(item_id, kind, tmdb_id, matched_at) VALUES(?,?,?,?)", [movies[7].id, "movie", 555, Date().timeIntervalSince1970]) }
        _ = try SQLiteCatalogRepository(db: db).setCategoryLocked("secret", true, family: false)
        return (db, a, Dictionary(uniqueKeysWithValues: movies.map { ($0.providerID, $0.id) }))
    }

    @Test func matchingByIdTitleYearAndFoldedVersions() throws {
        let (db, _, ids) = try library()
        let m = FilmographyMatcher(db: db).match([
            credit(1, "Pokiri", "2006-04-28"), credit(2, "Dookudu Returns", "2011-09-23"), credit(3, "Different Name Here", "2010-01-01"),
            credit(4, "Okkadu", "2003-01-01"), credit(5, "Secret Film", "2015-01-01"), credit(6, "Never Heard Of It", "2001-01-01"),
            credit(7, "Okkadu", "2003-01-01", series: true)])
        #expect(m["movie1"]?.versions == 3, "other language and twin playlist folded into one match")
        #expect(m["movie1"]?.languages == ["Hindi"])
        #expect(Set(m["movie1"]?.memberIDs ?? []) == [ids["pokiri"]!, ids["pokiri-h"]!, ids["pokiri-b"]!])
        #expect(m["movie2"]?.representative == ids["dookudu"], "year within one")
        #expect(m["movie3"] == nil && m["movie6"] == nil)
        #expect(m["movie5"] == nil, "a title with a copy in a locked folder is never available, twins included")
        #expect(m["tv7"] == nil, "a series never matches a film")
    }

    @Test func shortTitlesNeedTheExactYear() throws {
        let db = try TestSupport.makeDB(), a = try TestSupport.makeSource(db)
        func cat(_ id: String) -> CatalogCategory { CatalogCategory(id: id, sourceID: a.id, kind: .movie, providerID: id, name: "ENGLISH", sortOrder: 0) }
        let c = cat("c")
        func mv(_ pid: String, _ t: String, _ y: Int) -> Movie { var m = TestSupport.movie(a, pid, t, year: y); m.categoryID = c.id; m.categoryName = c.name; return m }
        _ = try CatalogIndexer(db: db).commitMovies(source: a, categories: [c], movies: [mv("d", "Dhoom (2004)", 2004), mv("l", "Long Title Here (2010)", 2010), mv("w", "Seven (1995)", 1995)])
        _ = try IdentityStore(db: db).backfill()
        let m = FilmographyMatcher(db: db).match([credit(1, "Dhoom", "2005-01-01"), credit(2, "Dhoom", "2004-01-01"), credit(3, "Long Title Here", "2011-01-01"), credit(4, "Seven", "1996-01-01")])
        #expect(m["movie1"] == nil, "one-word title: a year off by one is a different film")
        #expect(m["movie2"] != nil, "exact year matches")
        #expect(m["movie3"] != nil, "longer title keeps the one-year slack")
        #expect(m["movie4"] == nil)
        #expect(MetadataMatchService.yearTolerance(for: "Dhoom") == 0 && MetadataMatchService.yearTolerance(for: "Big Film") == 0 && MetadataMatchService.yearTolerance(for: "Long Title Here") == 1)
        let r = { (y: Int) in MetadataMatchService.SearchResult(id: 1, title: "Dhoom", name: nil, original_title: nil, original_name: nil, overview: nil, poster_path: nil, backdrop_path: nil, release_date: "\(y)-01-01", first_air_date: nil, vote_average: nil, popularity: nil) }
        #expect(MetadataMatchService.best([r(2005)], for: "Dhoom", year: 2004) != nil, "the artwork matcher is name-only now (final policy): the year is not read")
        #expect(MetadataMatchService.best([r(2004)], for: "Dhoom", year: 2004) != nil)
    }

    @Test func exactTMDBIDBeatsTheName() throws {
        let (db, _, ids) = try library()
        let m = FilmographyMatcher(db: db).match([credit(777, "Some Completely Other Title", "1999-01-01"), credit(999, "Okkadu", "2003-01-01")])
        #expect(m["movie777"]?.representative == ids["exact"])
        #expect(m["movie999"] == nil, "a library title already known to be another TMDB title is not matched by name")
    }

    @Test func tilesAndArrangement() {
        let t = [credit(1, "A", "2020-01-01", pop: 5, rating: 6), credit(2, "B", "2022-01-01", pop: 9, rating: 8), credit(3, "C", nil, pop: 1), credit(4, "D", "2021-01-01", series: true, pop: 2, rating: 7)]
        let tiles = Filmography.tiles(credits: t, matches: [:], items: [:])
        #expect(Filmography.arrange(tiles, kind: .all, scope: .all, sort: .newest).shown.map(\.title) == ["B", "D", "A", "C"], "newest first, undated last")
        #expect(Filmography.arrange(tiles, kind: .all, scope: .all, sort: .popular).shown.map(\.title) == ["B", "A", "D", "C"])
        #expect(Filmography.arrange(tiles, kind: .all, scope: .all, sort: .rating).shown.map(\.title) == ["B", "D", "A", "C"])
        let s = Filmography.arrange(tiles, kind: .series, scope: .all, sort: .newest)
        #expect(s.shown.map(\.title) == ["D"] && s.allCount == 1 && s.libraryCount == 0)
        let lib = Filmography.arrange(tiles, kind: .all, scope: .library, sort: .newest)
        #expect(lib.shown.isEmpty && lib.allCount == 4 && lib.libraryCount == 0, "empty state: nothing matched")
    }

    @Test func parsingDedupesDropsAndKeepsCredibleRatingsOnly() {
        let json = """
        {"cast":[{"id":1,"media_type":"movie","title":"Pokiri","release_date":"2006-04-28","poster_path":"/a.jpg","vote_average":7.4,"vote_count":100,"popularity":9,"character":"Pandu"},
                 {"id":1,"media_type":"movie","title":"Pokiri","release_date":"2006-04-28","poster_path":"/a.jpg","vote_average":7.4,"vote_count":100,"popularity":9},
                 {"id":2,"media_type":"movie","title":"No Date No Poster"},
                 {"id":3,"media_type":"movie","title":"Dated Only","release_date":"2010-01-01","vote_average":0,"vote_count":0},
                 {"id":4,"media_type":"tv","name":"Talk","first_air_date":"2015-01-01","genre_ids":[10767]},
                 {"id":5,"media_type":"movie","title":"Ten","release_date":"2011-01-01","vote_average":10.0,"vote_count":3},
                 {"id":6,"media_type":"movie","title":"Adult","release_date":"2011-01-01","adult":true}],
         "crew":[{"id":9,"media_type":"movie","title":"Directed","release_date":"2012-01-01","job":"Director"},{"id":10,"media_type":"movie","title":"Edited","release_date":"2012-01-01","job":"Editor"}]}
        """
        let actor = PersonParser.credits(Data(json.utf8), department: "Acting")
        #expect(actor.map(\.title) == ["Pokiri", "Dated Only", "Ten"])
        #expect(actor.first?.role == "Pandu" && actor.first?.rating == 7.4)
        #expect(actor[1].rating == nil && actor[2].rating == nil, "junk ratings (0, 10) are not shown")
        #expect(PersonParser.credits(Data(json.utf8), department: "Directing").map(\.title) == ["Directed"], "directors get their Director credits")
    }

    @Test func personPickedByKnownForOverlapThenExactName() {
        let json = #"{"results":[{"id":1,"name":"Mahesh Babu","popularity":9,"known_for":[{"title":"Other"}]},{"id":2,"name":"Mahesh Babu","popularity":3,"known_for":[{"title":"Pokiri"}]},{"id":3,"name":"Mahesh Babu Jr","popularity":99,"known_for":[]}]}"#
        #expect(PersonParser.pickPerson(Data(json.utf8), name: "Mahesh Babu", hintTitles: ["Pokiri"]) == 2)
        #expect(PersonParser.pickPerson(Data(json.utf8), name: "Mahesh Babu", hintTitles: []) == 1, "most popular exact-name result")
        #expect(PersonParser.pickPerson(Data(json.utf8), name: "Nobody", hintTitles: []) == nil)
    }

    @Test func bornLineAndKnownFor() {
        let p = PersonProfile(tmdbID: 1, name: "X", birthday: "1975-08-09", placeOfBirth: "Chennai, India", department: "Acting", alsoKnownAs: ["A", "B"])
        let now = ISO8601DateFormatter().date(from: "2026-11-22T00:00:00Z")!
        #expect(PersonFacts.bornLine(p, now: now) == "Born 9 Aug 1975 (age 51) · Chennai, India")
        #expect(PersonFacts.knownFor(p, credits: [credit(1, "Low", nil, pop: 1), credit(2, "High", nil, pop: 9)]) == "Acting · High, Low")
        #expect(PersonFacts.alsoKnownAs(p) == "A · B")
        var many = p; many.alsoKnownAs = ["a", "b", "c", "d"]
        #expect(PersonFacts.alsoKnownAs(many) == nil)
    }

    // MARK: credentials, offline, cache, purge

    private func service(_ db: DatabaseManager, key: Bool, calls: LockedBox<[String]>, fail: Bool = false) throws -> MetadataMatchService {
        let svc = MetadataMatchService(db: db, credentials: InMemoryCredentialStore(), pause: 0, builtIn: { nil }) { req in
            let path = req.url?.path ?? ""; calls.value.append(path)
            if fail { throw NetworkError.cancelled }
            if path == "/3/person/5" { return Data(#"{"id":5,"name":"Mahesh Babu","biography":"","known_for_department":"Acting","images":{"profiles":[{"file_path":"/x.jpg"}]}}"#.utf8) }
            if path.hasSuffix("combined_credits") { return Data(#"{"cast":[{"id":1,"media_type":"movie","title":"Pokiri","release_date":"2006-04-28","poster_path":"/a.jpg","popularity":5}],"crew":[]}"#.utf8) }
            if path == "/3/search/person" { return Data(#"{"results":[{"id":5,"name":"Mahesh Babu","popularity":3,"known_for":[{"title":"Pokiri"}]}]}"#.utf8) }
            return Data()
        }
        if key { try svc.saveKey("k") }
        return svc
    }

    @Test func fetchSavesFor30DaysAndPurges() async throws {
        let db = try TestSupport.makeDB(), calls = LockedBox<[String]>([])
        let svc = try service(db, key: true, calls: calls)
        let id = try await svc.resolvePerson(name: "Mahesh Babu", hints: ["Pokiri"])
        #expect(id == 5 && svc.savedPersonID(name: "Mahesh Babu", hints: ["Pokiri"]) == 5)
        let file = try await svc.refreshPerson(id: 5, language: "te-IN")
        #expect(file.credits.count == 1 && file.profile.photos == ["/x.jpg"])
        #expect(calls.value.filter { $0 == "/3/person/5" }.count == 2, "app language first, then English when the biography is empty")
        #expect(svc.savedPerson(id: 5, language: "te-IN")?.credits.count == 1)
        #expect(svc.savedPerson(id: 5, language: "te-IN", now: Date().addingTimeInterval(31 * 86400)) == nil, "older than 30 days is not used")
        svc.purgeExpired(now: Date().addingTimeInterval(31 * 86400))
        #expect(svc.savedPerson(id: 5, language: "te-IN") == nil, "the expiry purge removes it")
        _ = try await svc.refreshPerson(id: 5, language: "te-IN")
        #expect(svc.purgePeople() >= 1 && svc.savedPerson(id: 5, language: "te-IN") == nil && svc.savedPersonID(name: "Mahesh Babu", hints: ["Pokiri"]) == nil, "key removal / switch off deletes it")
    }

    @Test func withoutACredentialNothingIsSentAndOfflineThrows() async throws {
        let db = try TestSupport.makeDB(), calls = LockedBox<[String]>([])
        let none = try service(db, key: false, calls: calls)
        #expect(!none.hasKey)
        await #expect(throws: MetadataMatchService.MatchError.noKey) { _ = try await none.refreshPerson(id: 5, language: "en-US") }
        #expect(calls.value.isEmpty)
        let off = try service(db, key: true, calls: calls, fail: true)
        await #expect(throws: MetadataMatchService.MatchError.offline) { _ = try await off.refreshPerson(id: 5, language: "en-US") }
    }

    @Test @MainActor func pageFallsBackToTheLocalListWithAQuietLine() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-fg-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "People")
        let cat = CatalogCategory(id: "open", sourceID: s.id, kind: .movie, providerID: "open", name: "ENGLISH", sortOrder: 0)
        var m = TestSupport.movie(s, "p", "Pokiri (2006)", year: 2006); m.categoryID = cat.id; m.categoryName = cat.name
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [cat], movies: [m])
        _ = try IdentityStore(db: c.db).backfill()
        try PeopleIndex(db: c.db).save(itemID: m.id, kind: .movie, sourceID: s.id, names: ["Mahesh Babu"])
        let model = PersonPageModel()
        await model.load(PersonRoute(name: "Mahesh Babu", fromTitle: "Pokiri"), container: c)
        #expect(model.phase == .ready && model.localOnly && model.tiles.count == 1 && model.tiles[0].inLibrary)
        #expect(model.note == nil || model.note == "Add an artwork and details key for the full filmography")
    }
}

@Suite("Title page artwork and person route", .serialized) struct TitlePageDataTests {
    private func setup(series: Bool) throws -> (DatabaseManager, MetadataMatchService, String, LockedBox<[String]>) {
        let db = try TestSupport.makeDB(), s = try TestSupport.makeSource(db), calls = LockedBox<[String]>([])
        let cat = CatalogCategory(id: "c", sourceID: s.id, kind: series ? .series : .movie, providerID: "c", name: "ENGLISH", sortOrder: 0)
        var id = ""
        if series {
            var x = TestSupport.series(s, "s1", "Pokiri Show (2006)"); x.categoryID = cat.id; id = x.id
            _ = try CatalogIndexer(db: db).commitSeries(source: s, categories: [cat], series: [x])
        } else {
            var m = TestSupport.movie(s, "p", "Pokiri (2006)", year: 2006); m.categoryID = cat.id; id = m.id
            _ = try CatalogIndexer(db: db).commitMovies(source: s, categories: [cat], movies: [m])
        }
        _ = try IdentityStore(db: db).backfill()
        // matched to TMDB earlier (by the background matcher), but without a backdrop or summary
        try db.write { try $0.execute("INSERT INTO metadata_matches(item_id, kind, tmdb_id, matched_at) VALUES(?,?,?,?)", [id, series ? "series" : "movie", 42, Date().timeIntervalSince1970]) }
        let svc = MetadataMatchService(db: db, credentials: InMemoryCredentialStore(), pause: 0, builtIn: { nil }) { req in
            calls.value.append(req.url?.path ?? "")
            return Data(#"{"id":42,"overview":"A story.","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"2006-04-28","first_air_date":"2006-04-28","vote_average":7.6,"credits":{"cast":[{"id":7,"name":"Mahesh Babu","character":"Pandu","profile_path":"/m.jpg"}],"crew":[]}}"#.utf8)
        }
        try svc.saveKey("k")
        return (db, svc, id, calls)
    }

    @Test func openingAMatchedMovieFillsItsBackdropPosterAndSummary() async throws {
        let (db, svc, id, _) = try setup(series: false)
        let landed = LockedBox<Int>(0)
        let token = NotificationCenter.default.addObserver(forName: .titleMetadataLanded, object: nil, queue: nil) { n in if (n.userInfo?["ids"] as? [String])?.contains(id) == true { landed.value += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        let d = await svc.details(for: .init(id: id, isSeries: false, title: "Pokiri (2006)", year: 2006))
        #expect(d?.cast.first?.tmdbID == 7)
        let m = try #require(try SQLiteCatalogRepository(db: db).movie(id: id))
        #expect(m.backdropURL == "https://image.tmdb.org/t/p/w1280/b.jpg" && m.posterURL == "https://image.tmdb.org/t/p/w500/p.jpg" && m.overview == "A story.")
        #expect(landed.value >= 1, "the page on screen is told")
        // the header's own read: details(id:) returns the stored values
        let again = try #require(try SQLiteCatalogRepository(db: db).movie(id: id))
        #expect(again.backdropURL?.hasPrefix("https://") == true)
    }

    @Test func aProviderPosterIsNeverReplaced() async throws {
        let (db, svc, id, _) = try setup(series: false)
        try db.write { try $0.execute("UPDATE movies SET poster_url='https://provider/p.jpg' WHERE id=?", [id]) }
        _ = await svc.details(for: .init(id: id, isSeries: false, title: "Pokiri (2006)", year: 2006))
        let m = try #require(try SQLiteCatalogRepository(db: db).movie(id: id))
        #expect(m.posterURL == "https://provider/p.jpg" && m.backdropURL != nil)
    }

    @Test func seriesGetTheirBackdropToo() async throws {
        let (db, svc, id, _) = try setup(series: true)
        _ = await svc.details(for: .init(id: id, isSeries: true, title: "Pokiri Show (2006)", year: 2006))
        let s = try #require(try SQLiteCatalogRepository(db: db).seriesItem(id: id))
        #expect(s.backdropURL == "https://image.tmdb.org/t/p/w1280/b.jpg")
    }

    private func source(_ rel: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }          // macos/Tests/REDDYTests/File.swift -> macos
        return try String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test func aCastTapGoesToThePersonScreenOnEveryPath() throws {
        let cast = try source("Sources/REDDY/Features/Shared/Views/CastSection.swift")
        #expect(cast.contains("NavigationLink(value: route(p))") && cast.contains("onPerson(route(p))"), "both the push (iPhone/iPad) and the sheet (Mac) use the person route")
        let ios = try source("../ios/StreamSetu/Components/TitleDestinations.swift")
        #expect(ios.contains("navigationDestination(for: PersonRoute.self)") && ios.contains("navigationDestination(for: LibraryItem.self)") && ios.contains("PersonPage(route:"), "one shared modifier registers both")
        #expect(!(try source("../ios/StreamSetu/Screens/DetailView.swift")).contains("PersonTitlesList"), "the old list is not a destination any more")
        #expect(PersonRoute(name: "A").hashValue != PersonRoute(name: "A", tmdbID: 1).hashValue || PersonRoute(name: "A") != PersonRoute(name: "A", tmdbID: 1))
    }

    @Test @MainActor func theScreenIsAPersonScreenFromTheFirstFrame() async throws {
        let model = PersonPageModel()
        #expect(model.phase == .loading && model.profile == nil && model.tiles.isEmpty, "before anything loads there is no film content that could look like a title page")
        let page = try source("Sources/REDDY/Features/Shared/Views/PersonPage.swift")
        #expect(page.contains("controls          // always drawn") && page.contains("navigationTitle(route.name)"))
    }
}

@Suite("Credit roles") struct CreditRoleTests {
    @Test func classifier() {
        #expect(FilmRole.classify(character: "Narrator (voice)", order: 23) == .voice)
        #expect(FilmRole.classify(character: "Voiceover", order: 3) == .voice)
        #expect(FilmRole.classify(character: "Special Appearance", order: 4) == .cameo)
        #expect(FilmRole.classify(character: "Himself", order: 2) == .cameo)
        #expect(FilmRole.classify(character: "Guest", order: 1) == .cameo)
        #expect(FilmRole.classify(character: "Major Ajay Krishna", order: 0) == .lead)
        #expect(FilmRole.classify(character: "Friend", order: 14) == .lead, "below the threshold is a supporting part")
        #expect(FilmRole.classify(character: "", order: 15) == .cameo && FilmRole.classify(character: nil, order: 40) == .cameo)
        #expect(FilmRole.classify(character: "Director", order: nil, isCrewMaker: true) == .lead)
        #expect(FilmRole.tag(character: "Narrator (voice)", kind: .voice) == "Narrator" && FilmRole.tag(character: "Voiceover", kind: .voice) == "Voice")
        #expect(FilmRole.tag(character: "Cameo", kind: .cameo) == "Cameo" && FilmRole.tag(character: "Guest", kind: .cameo) == "Guest" && FilmRole.tag(character: "X", kind: .lead) == nil)
    }

    private let json = """
    {"cast":[{"id":1,"media_type":"movie","title":"Pokiri","release_date":"2006-04-28","poster_path":"/a.jpg","character":"Pandu","order":0,"popularity":9},
             {"id":2,"media_type":"movie","title":"Acharya","release_date":"2022-04-29","poster_path":"/b.jpg","character":"Narrator (voice)","order":23,"popularity":5},
             {"id":3,"media_type":"movie","title":"Baadshah","release_date":"2013-04-05","poster_path":"/c.jpg","character":"Narrator (voice)","order":30,"popularity":4},
             {"id":4,"media_type":"movie","title":"Cameo Film","release_date":"2015-01-01","poster_path":"/d.jpg","character":"Cameo","order":9,"popularity":3},
             {"id":5,"media_type":"movie","title":"Spider","release_date":"2004-01-01","poster_path":"/e.jpg","character":"Major Ajay Krishna","order":1,"popularity":6}],
     "crew":[{"id":6,"media_type":"movie","title":"Produced","release_date":"2012-01-01","job":"Producer"},{"id":7,"media_type":"movie","title":"Directed","release_date":"2014-01-01","job":"Director"}]}
    """

    @Test func groupingOrderFilterAndCounts() {
        let credits = PersonParser.credits(Data(json.utf8), department: "Acting")
        #expect(credits.map(\.title).contains("Produced") == false && credits.count == 5, "crew credits (Producer) stay out for an actor")
        let tiles = Filmography.tiles(credits: credits, matches: [:], items: [:])
        let a = Filmography.arrange(tiles, kind: .all, scope: .all, sort: .newest)
        #expect(a.onScreen.map(\.title) == ["Pokiri", "Spider"], "newest first among the on-screen parts")
        #expect(a.voiceAndCameo.map(\.title) == ["Acharya", "Cameo Film", "Baadshah"], "voice and cameo credits follow, newest first")
        #expect(a.shown.prefix(2).allSatisfy { $0.kind == .lead }, "on-screen parts come first")
        #expect(a.voiceAndCameo.first { $0.title == "Acharya" }?.tag == "Narrator" && a.voiceAndCameo.first { $0.title == "Cameo Film" }?.tag == "Cameo")
        #expect(a.onScreen.first { $0.title == "Spider" }?.role == "Major Ajay Krishna")
        let acting = Filmography.arrange(tiles, kind: .all, scope: .all, sort: .popular, actingOnly: true)
        #expect(acting.shown.map(\.title) == ["Pokiri", "Spider"] && acting.allCount == 2, "Acting only hides voice and cameo credits, and the counts follow")
    }

    @Test func directorsKeepTheirDirectorCredits() {
        let credits = PersonParser.credits(Data(json.utf8), department: "Directing")
        #expect(credits.map(\.title) == ["Directed"] && credits[0].kind == .lead && credits[0].isCrewMaker)
    }
}

@Suite("Navigation destinations") struct NavigationDestinationTests {
    private func files(_ dir: String) throws -> [(String, String)] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let root = url.appendingPathComponent(dir)
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let f = en?.nextObject() as? URL { guard f.pathExtension == "swift" else { continue }; out.append((f.lastPathComponent, try String(contentsOf: f, encoding: .utf8))) }
        return out
    }

    @Test func noBindingBasedTitleDestinationAnywhere() throws {
        for (name, text) in try files("../ios/StreamSetu") + files("Sources/REDDY/Features/Shared") {
            #expect(!text.contains("navigationDestination(item:"), "\(name) opens a title with a binding-based destination")
            #expect(!text.contains("navigationDestination(isPresented:"), "\(name)")
            #expect(!text.contains("opensTitle("), "\(name)")
        }
    }

    @Test func everyTitleStackRootAppliesTheSharedModifier() throws {
        let all = Dictionary(uniqueKeysWithValues: try files("../ios/StreamSetu").map { ($0.0, $0.1) })
        for name in ["HomeView.swift", "LibraryView.swift", "RootView.swift"] {
            #expect(all[name]?.contains(".titleAndPersonDestinations()") == true, "\(name) must register the title and person destinations")
        }
        #expect((all["RootView.swift"] ?? "").components(separatedBy: ".titleAndPersonDestinations()").count >= 3, "the More stack and the assistant sheet both register them")
        #expect((all["SearchView.swift"] ?? "").contains(".titleAndPersonDestinations(ownsStack: !embedded)"), "Search registers them only when it owns its stack; pushed into Home, Library or More it must not register them a second time")
        #expect(!(all["DetailView.swift"] ?? "").contains("DetailView(item:"), "a title page is only built by the shared destination")
    }
}

@Suite("Title page parts") struct TitlePagePartsTests {
    private func version(_ id: String, _ lang: String, current: Bool, quality: String? = "FHD") -> OtherLanguages.Version {
        let s = try! TestSupport.makeSource(TestSupport.makeDB())
        return OtherLanguages.Version(item: .movie(TestSupport.movie(s, id, "Pokiri")), language: lang, dubbed: false, folderLabel: nil, quality: quality, caption: nil, isCurrent: current)
    }

    @Test func credibleRatingOnly() {
        for junk in [nil, 0, 10, 10.0] as [Double?] { #expect(TitlePage.rating(junk) == nil, "\(String(describing: junk))") }
        #expect(TitlePage.rating(7.6) == 7.6 && TitlePage.rating(text: "abc") == nil && TitlePage.rating(text: "0") == nil)
    }

    @Test func metaLineSkipsWhatIsUnknown() {
        #expect(TitlePage.metaParts(year: 2006, runtimeSeconds: 9600, age: "U/A", quality: "FHD") == ["2006", "2h 40m", "U/A", "FHD"])
        #expect(TitlePage.metaParts(year: nil, runtimeSeconds: 0, age: "", quality: nil).isEmpty)
    }

    @Test func versionPickerHiddenWithOneVersionAndNamesLanguageAndQuality() {
        #expect(TitlePage.versionLine([version("a", "English", current: true)]) == nil)
        let two = [version("a", "English", current: true), version("b", "Hindi", current: false, quality: "HD")]
        #expect(TitlePage.versionLine(two) == "English · FHD · 2 versions")
        #expect(two[1].versionText == "Hindi · HD", "no playlist or profile names")
    }

    @Test func playWordsAndActionRow() {
        #expect(TitlePage.playTitle(remainingSeconds: nil, episode: nil) == "Play")
        #expect(TitlePage.playTitle(remainingSeconds: 34 * 60, episode: nil) == "Resume · 34m left")
        #expect(TitlePage.playTitle(remainingSeconds: nil, episode: (1, 3)) == "Play S1 E3")
        #expect(TitleActions(isFavorite: false, isWatchLater: false, hasTrailer: false, canDownload: false, canShare: true).labels == ["Favourite", "Watch Later", "Share"])
        #expect(TitleActions(isFavorite: true, isWatchLater: true, hasTrailer: true, canDownload: true, canShare: true).labels == ["Favourite", "Watch Later", "Trailer", "Download", "Share"])
    }

    @Test func detailRowsAndLinkTargets() {
        let people = [PersonRoute(name: "Mahesh Babu", tmdbID: 7, fromTitle: "Pokiri", fromYear: 2006)]
        let rows = TitleDetails_.rows(directors: ["Puri Jagannadh"], isSeries: false, starring: people, country: "India", studio: nil, released: "28 Apr 2006", folder: "TELUGU", openFolder: {})
        #expect(rows.map(\.label) == ["Directed by", "Starring", "Country", "Released", "In folder"], "studio is left out when unknown")
        if case .people(let p) = rows[1].value { #expect(p.first?.tmdbID == 7 && p.first?.fromTitle == "Pokiri") } else { Issue.record("Starring must be person links") }
        #expect(TitleDetails_.rows(directors: ["A"], isSeries: true, starring: [], country: nil, studio: nil, released: nil, folder: nil, openFolder: {}).first?.label == "Created by")
        #expect(!TitleHeroImage.hasBackdrop(nil) && !TitleHeroImage.hasBackdrop("") && TitleHeroImage.hasBackdrop("https://x/b.jpg"))
        #expect(TitleHeroImage.titleTrailingInset(backdrop: nil, poster: "https://x/p.jpg", width: 400) > 0 && TitleHeroImage.titleTrailingInset(backdrop: "https://x/b.jpg", poster: "p", width: 400) == 0)
    }
}

@Suite("Saved details still fill artwork", .serialized) struct SavedDetailsArtworkTests {
    @Test func aTitleWhoseDetailsWereSavedEarlierStillGetsItsBackdrop() async throws {
        let db = try TestSupport.makeDB(), s = try TestSupport.makeSource(db)
        let cat = CatalogCategory(id: "c", sourceID: s.id, kind: .movie, providerID: "c", name: "ENGLISH", sortOrder: 0)
        var m = TestSupport.movie(s, "p", "Pokiri (2006)", year: 2006); m.categoryID = cat.id
        _ = try CatalogIndexer(db: db).commitMovies(source: s, categories: [cat], movies: [m])
        _ = try IdentityStore(db: db).backfill()
        try db.write { try $0.execute("INSERT INTO metadata_matches(item_id, kind, tmdb_id, matched_at) VALUES(?,?,?,?)", [m.id, "movie", 42, Date().timeIntervalSince1970]) }
        let svc = MetadataMatchService(db: db, credentials: InMemoryCredentialStore(), pause: 0, builtIn: { nil }) { _ in
            Data(#"{"id":42,"overview":"A story.","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"2006-04-28","credits":{"cast":[],"crew":[]}}"#.utf8) }
        try svc.saveKey("k")
        // details were saved two hours ago, with no backdrop on the row
        let old = Date().addingTimeInterval(-7200).timeIntervalSince1970
        try db.write { try $0.execute("INSERT INTO title_details(item_id, json, fetched_at) VALUES(?,?,?)", [m.id, String(decoding: try JSONEncoder().encode(TitleDetails(tmdbID: 42, isSeries: false)), as: UTF8.self), old]) }
        _ = await svc.details(for: .init(id: m.id, isSeries: false, title: m.title, year: 2006))
        let row = try #require(try SQLiteCatalogRepository(db: db).movie(id: m.id))
        #expect(row.backdropURL == "https://image.tmdb.org/t/p/w1280/b.jpg")
    }
}
