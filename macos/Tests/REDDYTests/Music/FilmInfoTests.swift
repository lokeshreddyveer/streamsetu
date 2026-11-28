import Foundation
import Testing
@testable import REDDY

// Film info: identification, matching thresholds, TMDB and Wikidata fixtures, actor to film to album resolution with fake providers, cache. No network.

private func album(_ title: String, year: String? = nil, type: String? = "Album", tracks: Int? = 6, artist: String = "Composer") -> MusicAlbum {
    MusicAlbum(id: title, providerID: "fake", title: title, artists: [MusicArtistRef(id: "a", name: artist)], releaseDate: year, totalTracks: tracks, albumType: type)
}

private func track(_ title: String, popularity: Int? = nil) -> MusicTrack {
    MusicTrack(id: title, providerID: "fake", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "Singer")], popularity: popularity)
}

@Suite("Film identification") struct FilmIdentificationTests {
    @Test func soundtrackWordingNamesTheFilm() {
        #expect(MusicFilmResolver.soundtrackFilm(inAlbumTitle: "Pushpa - The Rise (Original Motion Picture Soundtrack)") == "Pushpa - The Rise")
        #expect(MusicFilmResolver.soundtrackFilm(inAlbumTitle: "Kantara - OST") == "Kantara")
        #expect(MusicFilmResolver.soundtrackFilm(inAlbumTitle: "Top Gun: Maverick (Music From The Motion Picture)") == "Top Gun: Maverick")
        #expect(MusicFilmResolver.soundtrackFilm(inAlbumTitle: "RRR [Original Motion Picture Soundtrack]") == "RRR")
    }

    @Test func ordinaryAlbumsAreNeverFilms() {
        for title in ["Lost (Original Mix)", "Most Wanted", "Greatest Hits", "Divide", "Unplugged"] {
            var s = MusicFilmSignals(); s.albumTitle = title; s.albumArtists = ["Artist"]
            #expect(MusicFilmResolver.identify(s) == nil, "\(title)")
        }
        var single = MusicFilmSignals(); single.trackTitle = "Blinding Lights"; single.albumTitle = "After Hours"
        #expect(MusicFilmResolver.identify(single) == nil)
    }

    @Test func songTitleFromFilm() {
        #expect(MusicFilmResolver.fromFilm(inSongTitle: "Kaavaalaa (From \"Jailer\")") == "Jailer")
        #expect(MusicFilmResolver.fromFilm(inSongTitle: "Butta Bomma [From the movie Ala Vaikunthapurramuloo]") == "Ala Vaikunthapurramuloo")
        #expect(MusicFilmResolver.fromFilm(inSongTitle: "Plain Song") == nil)
        var s = MusicFilmSignals(); s.trackTitle = "Kaavaalaa (From \"Jailer\")"
        #expect(MusicFilmResolver.identify(s)?.title == "Jailer")
    }

    @Test func providerStarringIsStrongEvidence() {
        var s = MusicFilmSignals(); s.albumTitle = "Awaara"; s.albumYear = 2013; s.albumArtists = ["Yuvan Shankar Raja"]
        s.facts = MusicFilmProviderFacts(title: "Awaara", year: 2013, language: "tamil", starring: ["Karthi"], musicBy: ["Yuvan Shankar Raja"])
        let id = MusicFilmResolver.identify(s)
        #expect(id?.title == "Awaara"); #expect(id?.evidence == .provider); #expect(id?.language == "ta"); #expect(id?.starring == ["Karthi"])
    }

    @Test func catalogueFilmFieldNeedsAgreement() {
        var s = MusicFilmSignals(); s.albumTitle = "Jailer"; s.catalogueFilms = ["Jailer", "Jailer", nil, "Jailer"]; s.catalogueYear = 2023
        #expect(MusicFilmResolver.identify(s)?.evidence == .catalogue)
        var other = MusicFilmSignals(); other.albumTitle = "Night Drive"; other.catalogueFilms = ["Jailer", nil, nil, nil, nil, nil]
        #expect(MusicFilmResolver.identify(other) == nil)
    }

    @Test func titleCleaningAndSelfTitled() {
        let c = MusicFilmResolver.clean("Awaara (2013) [Telugu]")
        #expect(c.title == "Awaara"); #expect(c.year == 2013); #expect(c.language == "te")
        var s = MusicFilmSignals(); s.albumTitle = "Adele (Original Soundtrack)"; s.albumArtists = ["Adele"]
        #expect(MusicFilmResolver.identify(s) == nil)
    }

    @Test func jioSaavnFactsParse() {
        let json = """
        {"title":"Jailer","year":"2023","language":"tamil","more_info":{"music":"Anirudh Ravichander","label":"Sun Pictures"},
         "list":[{"more_info":{"artistMap":{"artists":[{"name":"Anirudh Ravichander","role":"music"},{"name":"Rajinikanth","role":"starring"},{"name":"Sunil","role":"starring"},{"name":"Shilpa Rao","role":"singer"}]}}},
                 {"more_info":{"artistMap":{"artists":[{"name":"Rajinikanth","role":"starring"}]}}}]}
        """
        let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let f = MusicFilmProviderFactsFetcher.parse(d)
        #expect(f?.starring == ["Rajinikanth", "Sunil"]); #expect(f?.musicBy == ["Anirudh Ravichander"]); #expect(f?.singers == ["Shilpa Rao"]); #expect(f?.year == 2023)
    }
}

@Suite("Film matching") struct FilmMatchingTests {
    private let awaara = MusicFilmIdentity(title: "Awaara", year: 2013, language: "ta", evidence: .provider, musicBy: ["Yuvan Shankar Raja"])

    @Test func thresholds() {
        #expect(MusicFilmMatch.score(identity: awaara, titles: ["Awaara"], year: 2013, language: "ta") != nil)
        #expect(MusicFilmMatch.score(identity: awaara, titles: ["Awara"], year: 2014, language: nil) != nil)          // same spelling key, a year apart
        #expect(MusicFilmMatch.score(identity: awaara, titles: ["Awaara Paagal Deewana"], year: 2013, language: nil) == nil)
        #expect(MusicFilmMatch.score(identity: awaara, titles: ["Awaara"], year: 1951, language: nil) == nil)           // too far
        #expect(MusicFilmMatch.score(identity: awaara, titles: ["Awaara"], year: 2010, language: nil) != nil)           // exact title, 3 years: needs the composer check later
        var noYear = awaara; noYear.year = nil
        #expect(MusicFilmMatch.score(identity: noYear, titles: ["Awaara"], year: 2010, language: nil) != nil)
        #expect(MusicFilmMatch.score(identity: noYear, titles: ["Awara Hu"], year: 2010, language: nil) == nil)
    }

    @Test func wideYearGapNeedsTheComposer() {
        var info = MusicFilmInfo(title: "Awaara", year: 2010, source: .tmdb)
        #expect(!MusicFilmMatch.accepts(info, identity: awaara))
        info.composers = [MusicFilmPerson(name: "Yuvan Shankar Raja")]
        #expect(MusicFilmMatch.accepts(info, identity: awaara))
        info.year = 2013; info.composers = []
        #expect(MusicFilmMatch.accepts(info, identity: awaara))
    }
}

@Suite("Film parsers") struct FilmParserTests {
    static let movie = """
    {"id":1,"title":"Jailer","imdb_id":"tt15327088","release_date":"2023-08-10","original_language":"ta",
     "credits":{"cast":[{"id":2,"name":"Sunil","character":"Vasanth","order":2,"profile_path":"/s.jpg"},{"id":3,"name":"Rajinikanth","character":"Muthuvel","order":0,"profile_path":"/r.jpg"},{"id":4,"name":"Tamannaah","character":"Dancer","order":5,"profile_path":null}],
      "crew":[{"id":9,"name":"Nelson Dilipkumar","job":"Director"},{"id":10,"name":"Anirudh Ravichander","job":"Original Music Composer"},{"id":11,"name":"Someone","job":"Editor"}]}}
    """

    @Test func tmdbMovieCredits() {
        let f = MusicFilmTMDBParser.film(from: Data(Self.movie.utf8))
        #expect(f?.title == "Jailer"); #expect(f?.year == 2023); #expect(f?.language == "ta"); #expect(f?.imdbID == "tt15327088")
        #expect(f?.cast.map(\.name) == ["Rajinikanth", "Sunil", "Tamannaah"])
        #expect(f?.cast.first?.photoURL == "https://image.tmdb.org/t/p/w185/r.jpg"); #expect(f?.cast.last?.photoURL == nil)
        #expect(f?.directors.map(\.name) == ["Nelson Dilipkumar"]); #expect(f?.composers.map(\.name) == ["Anirudh Ravichander"])
    }

    @Test func tmdbFilmographyDropsSelfAndFuture() {
        let json = """
        {"cast":[{"id":1,"title":"A","original_title":"A","release_date":"2021-01-01","original_language":"te","character":"Raj","popularity":50},
                 {"id":2,"title":"Doc","original_title":"Doc","release_date":"2019-01-01","character":"Self","popularity":9},
                 {"id":3,"title":"Next","original_title":"Next","release_date":"2031-01-01","character":"X","popularity":99},
                 {"id":4,"title":"NoDate","original_title":"NoDate","release_date":"","character":"Y","popularity":5}]}
        """
        let list = MusicFilmTMDBParser.filmography(from: Data(json.utf8), thisYear: 2026)
        #expect(list.map(\.tmdbID) == [1]); #expect(list.first?.character == "Raj")
    }

    @Test func wikidataFixtures() {
        let search = """
        {"search":[{"id":"Q311396","label":"prison officer","description":"profession"},
                   {"id":"Q113625011","label":"Jailer","description":"2023 Tamil film directed by Nelson Dilipkumar"},
                   {"id":"Q121667812","label":"Jailer","description":"2023 soundtrack album by Anirudh Ravichander"}]}
        """
        let hits = MusicFilmWikidataParser.searchHits(from: Data(search.utf8))
        #expect(hits.map(\.id) == ["Q113625011"]); #expect(hits.first?.year == 2023)
        let entity = """
        {"entities":{"Q113625011":{"claims":{"P161":[{"mainsnak":{"datavalue":{"value":{"id":"Q1"}}}},{"mainsnak":{"datavalue":{"value":{"id":"Q2"}}}}],
          "P57":[{"mainsnak":{"datavalue":{"value":{"id":"Q3"}}}}],"P86":[{"mainsnak":{"datavalue":{"value":{"id":"Q4"}}}}],
          "P577":[{"mainsnak":{"datavalue":{"value":{"time":"+2023-08-10T00:00:00Z"}}}}]}}}}
        """
        let film = MusicFilmWikidataParser.film(from: Data(entity.utf8), id: "Q113625011")
        #expect(film?.cast == ["Q1", "Q2"]); #expect(film?.directors == ["Q3"]); #expect(film?.composers == ["Q4"]); #expect(film?.year == 2023)
        let people = """
        {"entities":{"Q1":{"labels":{"en":{"value":"Rajinikanth"}},"claims":{"P18":[{"mainsnak":{"datavalue":{"value":"Rajini 2.jpg"}}}]}},"Q2":{"labels":{"en":{"value":"Sunil"}},"claims":{}}}}
        """
        let p = MusicFilmWikidataParser.people(from: Data(people.utf8))
        #expect(p["Q1"]?.name == "Rajinikanth"); #expect(p["Q1"]?.photoURL?.contains("Special:FilePath/Rajini_2.jpg") == true); #expect(p["Q2"]?.photoURL == nil)
    }
}

@Suite("Film service and actor music") struct FilmServiceTests {
    private func tempCache(now: @escaping @Sendable () -> Date = { Date() }) -> MusicFilmCache {
        MusicFilmCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("film-" + UUID().uuidString, isDirectory: true), now: now)
    }

    private final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func bump() { l.lock(); n += 1; l.unlock() }; var value: Int { l.lock(); defer { l.unlock() }; return n } }

    @Test func tmdbThenCacheThenWipe() async {
        let calls = Counter()
        let fetch: MusicFilmTMDBGate.Fetch = { path, _ in
            calls.bump()
            if path == "/3/search/movie" { return Data(#"{"results":[{"id":1,"title":"Jailer","original_title":"Jailer","release_date":"2023-08-10","original_language":"ta","popularity":60}]}"#.utf8) }
            return Data(FilmParserTests.movie.utf8)
        }
        let cache = tempCache()
        let service = MusicFilmService(sources: [MusicTMDBFilmSource(tmdb: fetch)], cache: cache)
        let id = MusicFilmIdentity(title: "Jailer", year: 2023, language: "ta", evidence: .titlePattern)
        let first = await service.info(for: id)
        #expect(first?.source == .tmdb); #expect(first?.provenance?.source == .tmdb); #expect(first?.cast.first?.name == "Rajinikanth")
        let afterFirst = calls.value
        _ = await service.info(for: id)
        #expect(calls.value == afterFirst)             // second read is from disk
        cache.wipe()
        _ = await service.info(for: id)
        #expect(calls.value > afterFirst)
    }

    @Test func cacheExpiresAfterThirtyDays() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let cache = tempCache { clock.now }
        cache.write(MusicFilmInfo(title: "X", source: .tmdb), key: "k")
        cache.write(Optional<MusicFilmInfo>.none, key: "miss")
        clock.now = clock.now.addingTimeInterval(3 * 24 * 3600)
        #expect(cache.read(MusicFilmInfo.self, key: "k") != nil)
        #expect(cache.read(MusicFilmInfo.self, key: "miss") == nil)       // a miss is remembered for two days only
        clock.now = clock.now.addingTimeInterval(28 * 24 * 3600)
        #expect(cache.read(MusicFilmInfo.self, key: "k") == nil)
    }

    @Test func providerNamesAreTheLastResort() async {
        let failing: MusicFilmTMDBGate.Fetch = { _, _ in throw MusicError.network("down") }
        let service = MusicFilmService(sources: [MusicTMDBFilmSource(tmdb: failing), MusicProviderNamesFilmSource()], cache: tempCache())
        let id = MusicFilmIdentity(title: "Awaara", year: 2013, language: nil, evidence: .provider, starring: ["Karthi", "Tamannaah"])
        let info = await service.info(for: id)
        #expect(info?.source == .provider); #expect(info?.cast.map(\.name) == ["Karthi", "Tamannaah"])
    }

    @Test func actorFilmsToAlbums() async {
        let credits = [
            MusicFilmCredit(tmdbID: 1, title: "Pushpa: The Rise", originalTitle: "Pushpa: The Rise", year: 2021, language: "te", character: "Pushpa Raj", popularity: 90),
            MusicFilmCredit(tmdbID: 2, title: "Ala Vaikunthapurramuloo", originalTitle: "Ala Vaikunthapurramuloo", year: 2020, language: "te", character: "Bantu", popularity: 80),
            MusicFilmCredit(tmdbID: 3, title: "No Soundtrack", originalTitle: "No Soundtrack", year: 2015, language: "te", character: "Z", popularity: 70)]
        let catalogue: [String: [MusicAlbum]] = [
            "Pushpa: The Rise": [album("Pushpa - The Rise (Original Motion Picture Soundtrack)", year: "2021-12-01"), album("Pushpa (Karaoke)", year: "2021")],
            "Ala Vaikunthapurramuloo": [album("Ala Vaikunthapurramuloo", year: "2020-01-01"), album("Ala Vaikunthapurramuloo", year: "1999")]]
        let music = MusicActorMusic(tmdb: nil, cache: MusicFilmCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            searchAlbums: { q in catalogue.first { q.hasPrefix($0.key) }?.value ?? [] },
            albumTracks: { a in [track("Song 1 of " + a.title, popularity: 1), track("Hit of " + a.title, popularity: 99), track("Song 3 of " + a.title, popularity: 5), track("Song 4 of " + a.title, popularity: 2)] },
            playable: { $0.filter { !$0.title.hasPrefix("Song 3") } })
        let films = await music.albums(for: credits)
        #expect(films.map(\.id) == [1, 2])                           // the film with no album is hidden, the karaoke album and the wrong year are refused
        #expect(films[1].album.releaseDate == "2020-01-01")
        let songs = await music.songs(from: films)
        #expect(songs.count == 6)
        #expect(songs.first?.title.hasPrefix("Hit of") == true)
        #expect(!songs.contains { $0.title.hasPrefix("Song 3") })
    }

    @Test func actorFilmOrderPrefersTheSameLanguage() {
        let a = MusicFilmCredit(tmdbID: 1, title: "A", originalTitle: "A", year: 2020, language: "hi", popularity: 99)
        let b = MusicFilmCredit(tmdbID: 2, title: "B", originalTitle: "B", year: 2021, language: "te", popularity: 10)
        let c = MusicFilmCredit(tmdbID: 3, title: "C", originalTitle: "C", year: 2022, language: "te", popularity: 20)
        #expect(MusicActorMusic.order([a, b, c], language: "te").map(\.tmdbID) == [3, 2, 1])
        #expect(MusicActorMusic.order((1...20).map { MusicFilmCredit(tmdbID: $0, title: "T", originalTitle: "T", year: 2000, language: "te", popularity: Double($0)) }, language: "te").count == 12)
    }
}
