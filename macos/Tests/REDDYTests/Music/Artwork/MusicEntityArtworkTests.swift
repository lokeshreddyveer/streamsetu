import Testing
import Foundation
#if canImport(REDDY)
@testable import REDDY
#else
@testable import ArtworkCore
#endif

// Fixtures in Fixtures/ are live replies captured on 2026-11-25 (trimmed): Wikidata, Wikipedia, Commons, MusicBrainz, IMDb, Deezer, iTunes, JioSaavn.
// The TMDB shapes follow developer.themoviedb.org (no key is needed to test a parser).

private enum AF {
    static var dir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true) }
    static func data(_ name: String) -> Data { (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data() }
}

/// Answers by a substring of `url?sorted=query`; counts every call. An unmatched address answers "not found".
private final class ArtworkFixtureTransport: MusicMetadataTransport, @unchecked Sendable {
    struct Route { var match: String; var data: Data? ; var fail: MusicError? = nil }
    private let lock = NSLock()
    private var routes: [Route]
    private(set) var calls: [String] = []
    init(_ routes: [Route]) { self.routes = routes }
    func get(_ url: URL, query: [String: String], headers: [String: String]) async throws -> Data {
        let key = url.absoluteString + "?" + query.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
        let hit = record(key)
        if let f = hit?.fail { throw f }
        guard let d = hit?.data else { throw MusicError.notFound }
        return d
    }
    private func record(_ key: String) -> Route? { lock.lock(); defer { lock.unlock() }; calls.append(key); return routes.first { key.contains($0.match) } }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
}

private func context(_ t: any MusicMetadataTransport, tmdb: (@Sendable (String, [URLQueryItem]) async throws -> Data)? = nil) -> MusicArtworkContext {
    MusicArtworkContext(transport: t, tmdb: tmdb)
}

private let gvp = "G. V. Prakash Kumar"

// MARK: - parsers

@Suite("Artwork parsers (live fixtures)")
struct MusicArtworkParserTests {
    @Test func wikidataSearchAndFacts() {
        let hits = MusicArtworkParsers.wikidataSearch(AF.data("wikidata_search_person.json"))
        #expect(hits.count == 1)
        #expect(hits[0].id == "Q5512526")
        #expect(hits[0].names.contains("G. V. Prakash Kumar"))
        #expect(hits[0].description == "Indian actor and music director")
        let facts = MusicArtworkParsers.wikidataEntities(AF.data("wikidata_entities.json"))
        #expect(facts["Q5512526"]?.imdb == "nm1574854")
        #expect(facts["Q5512526"]?.musicBrainz == "a740619d-27d6-46da-a438-7b9bc70d6633")
        #expect(facts["Q5512526"]?.image == nil)
        #expect(facts["Q5512526"]?.enwikiTitle == "G. V. Prakash Kumar")
        #expect(facts["Q63135778"]?.tmdbMovie != nil)
    }

    @Test func wikipediaLeadImageAndCommonsRecord() {
        let lead = MusicArtworkParsers.wikipediaPageImage(AF.data("wikipedia_pageimage_person.json"))
        #expect(lead?.wikibaseItem == "Q5512526")
        #expect(lead?.thumbnail?.contains("500px-GvprakashRecent") == true)
        let none = MusicArtworkParsers.wikipediaPageImage(AF.data("wikipedia_pageimage_film_none.json"))
        #expect(none?.wikibaseItem == "Q63135778")
        #expect(none?.thumbnail == nil)
        let c = MusicArtworkParsers.commonsImage(AF.data("commons_imageinfo.json"))
        #expect(c?.thumbnail.contains("500px-") == true)
        #expect(c?.licence == "CC0")
        #expect(c?.creditLine?.contains("Wikimedia Commons") == true)
    }

    @Test func musicBrainzLinksArtistsAndReleaseGroups() {
        let links = MusicArtworkParsers.musicBrainzArtistLinks(AF.data("mb_artist_urlrels.json"))
        #expect(links.wikidata == "Q5512526")
        #expect(links.imdbName == "nm1574854")
        #expect(MusicArtworkParsers.musicBrainzArtists(AF.data("mb_artist_search.json")).first?.score == 100)
        let rg = MusicArtworkParsers.musicBrainzReleaseGroups(AF.data("mb_releasegroup_search.json"))
        #expect(rg.first?.id == "0de25d19-e99f-4059-887e-ac3572f2101a")
        #expect(rg.first?.artists == ["Anirudh Ravichander"])
    }

    @Test func imdbDeezerItunesSaavn() {
        let person = MusicArtworkParsers.imdbSuggestions(AF.data("imdb_person_suggestion.json"))
        #expect(person.first?.id == "nm1574854")
        #expect(person.first?.line == "Composer, Soorarai Pottru (2020)")
        #expect(person.first?.image != nil)
        let film = MusicArtworkParsers.imdbSuggestions(AF.data("imdb_film_suggestion.json")).first
        #expect(film?.id == "tt10189514" && film?.year == 2020 && film?.type == "movie")
        let dz = MusicArtworkParsers.deezerAlbums(AF.data("deezer_album_search.json"))
        #expect(dz.first?.artist == "Anirudh Ravichander")
        #expect(dz.first?.artistPicture?.hasSuffix("500x500-000000-80-0-0.jpg") == true)
        #expect(MusicArtworkParsers.deezerArtist(AF.data("deezer_artist.json"))?.name == "G.V. Prakash Kumar")
        let it = MusicArtworkParsers.itunes(AF.data("itunes_album_search.json"))
        #expect(it.first?.collection.contains("Vaathi Coming") == true)
        #expect(MusicArtworkMatch.iTunesLarge(it[0].art100).hasSuffix("/600x600bb.jpg"))
        let sv = MusicArtworkParsers.saavnAutocomplete(AF.data("saavn_autocomplete.json"))
        #expect(sv.contains { $0.kind == .album } && sv.contains { $0.kind == .song })
        let artist = sv.first { $0.kind == .artist }
        #expect(artist?.title == "Anirudh Ravichander")
        #expect(artist?.detail.contains("Music director") == true)
        #expect(MusicArtworkMatch.saavnLarge(artist!.image).contains("500x500."))
    }

    @Test func garbageGivesEmptyNeverCrashes() {
        let junk = Data("<html>not json</html>".utf8)
        #expect(MusicArtworkParsers.wikidataSearch(junk).isEmpty)
        #expect(MusicArtworkParsers.wikidataEntities(junk).isEmpty)
        #expect(MusicArtworkParsers.wikipediaPageImage(junk) == nil)
        #expect(MusicArtworkParsers.commonsImage(junk) == nil)
        #expect(MusicArtworkParsers.deezerAlbums(junk).isEmpty)
        #expect(MusicArtworkParsers.itunes(junk).isEmpty)
        #expect(MusicArtworkParsers.saavnAutocomplete(junk).isEmpty)
        #expect(MusicArtworkParsers.imdbSuggestions(Data()).isEmpty)
    }
}

// MARK: - matching rules

@Suite("Artwork matching rules")
struct MusicArtworkMatchTests {
    @Test func initialsAndDotsMeetButAnotherPersonDoesNot() {
        #expect(MusicArtworkMatch.namesMatch("G. V. Prakash Kumar", "G.V. Prakash Kumar"))
        #expect(MusicArtworkMatch.namesMatch("G. V. Prakash Kumar", "GV Prakash Kumar"))
        #expect(!MusicArtworkMatch.namesMatch("G. V. Prakash Kumar", "Mst.G.V.Prakash Kumar"))
        #expect(!MusicArtworkMatch.namesMatch("Anirudh", "Anirudh Ravichander"))
    }

    @Test func storeSpecificTitleNoiseIsIgnored() {
        #expect(MusicArtworkMatch.titlesMatch("Vaathi Coming (From \"Master\") - Single", "Vaathi Coming"))
        #expect(MusicArtworkMatch.titlesMatch("Master (Original Motion Picture Soundtrack)", "Master"))
        #expect(MusicArtworkMatch.titlesMatch("Soorarai Pottru \u{2013} Original Motion Picture Soundtrack", "Soorarai Pottru"))
        #expect(!MusicArtworkMatch.titlesMatch("Master: Original Background Score", "Masterpiece"))
    }

    @Test func creditsAndLines() {
        #expect(MusicArtworkMatch.creatorsOverlap("Anirudh Ravichander & Gana Balachandar", "Anirudh Ravichander"))
        #expect(!MusicArtworkMatch.creatorsOverlap("Gana Balachandar", "Anirudh Ravichander"))
        #expect(MusicArtworkMatch.lineMentions("Master \u{00B7} Anirudh Ravichander, Gana Balachandar", creator: "Gana Balachandar"))
    }

    @Test func rolesYearsAndAddresses() {
        #expect(MusicArtworkMatch.roleFits(description: "Indian actor and music director", roles: [.composer]))
        #expect(!MusicArtworkMatch.roleFits(description: "Indian cricketer", roles: []))
        #expect(!MusicArtworkMatch.roleFits(description: "Indian actor", roles: [.composer]))
        #expect(MusicArtworkMatch.mentionsYear("2020 Tamil film", 2020))
        #expect(!MusicArtworkMatch.mentionsYear("12020 Tamil film", 2020))
        #expect(MusicArtworkMatch.address(fromImageRef: "commons:Foo bar.jpg")?.contains("Foo_bar.jpg?width=500") == true)
        #expect(MusicArtworkMatch.address(fromImageRef: "ftp://x") == nil)
        #expect(MusicArtworkMatch.isDeezerPlaceholder("https://cdn-images.dzcdn.net/images/artist//500x500-000000-80-0-0.jpg"))
        #expect(MusicArtworkMatch.minimumConfidence(for: .person) > MusicArtworkMatch.minimumConfidence(for: .film))
    }

    @Test func monogramsPerKind() {
        #expect(MusicArtworkSubject.person(gvp).monogram == "GV")
        #expect(MusicArtworkSubject(kind: .language, name: "\u{0C24}\u{0C46}\u{0C32}\u{0C41}\u{0C17}\u{0C41}").monogram?.isEmpty == false)
        #expect(MusicArtworkSubject.album("Master").monogram == nil)
    }
}

// MARK: - sources against fixtures

@Suite("Artwork sources (fixtures)")
struct MusicArtworkSourceTests {
    private func wikiTransport(commons: Bool = true) -> ArtworkFixtureTransport {
        ArtworkFixtureTransport([
            .init(match: "action=wbsearchentities", data: AF.data("wikidata_search_person.json")),
            .init(match: "action=wbgetentities", data: AF.data("wikidata_entities.json")),
            .init(match: "commons.wikimedia.org/w/api.php", data: AF.data("commons_imageinfo.json")),
            .init(match: "en.wikipedia.org/w/api.php", data: AF.data("wikipedia_pageimage_person.json")),
        ])
    }

    @Test func personPhotoFromTheSameWikidataItem() async throws {
        let t = wikiTransport()
        let c = try await WikimediaArtworkSource().candidates(for: .person(gvp), context: context(t))
        #expect(c.count == 1)
        #expect(c[0].address.contains("500px-GvprakashRecent"))
        #expect(c[0].evidence.contains("name") && c[0].evidence.contains("role") && c[0].evidence.contains("wikipedia-lead"))
        #expect(c[0].confidence >= MusicArtworkMatch.personThreshold)
    }

    @Test func aKnownIdThatDisagreesRejectsTheItem() async throws {
        var s = MusicArtworkSubject.person(gvp)
        s.externalIDs = [ExternalID(.imdbName, "nm0000001")]
        let c = try await WikimediaArtworkSource().candidates(for: s, context: context(wikiTransport()))
        #expect(c.isEmpty)
    }

    @Test func aLeadImageOfAnotherItemIsNotTaken() async throws {
        let other = Data(#"{"query":{"pages":{"1":{"pageid":1,"title":"G. V. Prakash Kumar","pageprops":{"wikibase_item":"Q999"},"thumbnail":{"source":"https://thumb.wikimedia.org/x/500px-x.jpg"}}}}}"#.utf8)
        let t = ArtworkFixtureTransport([
            .init(match: "action=wbsearchentities", data: AF.data("wikidata_search_person.json")),
            .init(match: "action=wbgetentities", data: AF.data("wikidata_entities.json")),
            .init(match: "en.wikipedia.org/w/api.php", data: other),
        ])
        #expect(try await WikimediaArtworkSource().candidates(for: .person(gvp), context: context(t)).isEmpty)
    }

    @Test func twoPeopleOfOneNameAreAmbiguousAndGetNoPhoto() async throws {
        let two = Data(#"{"search":[{"id":"Q1","label":"Ravi Kumar","description":"Indian actor","match":{"type":"label","text":"Ravi Kumar"}},{"id":"Q2","label":"Ravi Kumar","description":"Indian composer","match":{"type":"label","text":"Ravi Kumar"}}]}"#.utf8)
        let ents = Data(#"{"entities":{"Q1":{"id":"Q1","labels":{"en":{"value":"Ravi Kumar"}},"claims":{"P18":[{"rank":"normal","mainsnak":{"datavalue":{"value":"A.jpg"}}}]},"sitelinks":{}},"Q2":{"id":"Q2","labels":{"en":{"value":"Ravi Kumar"}},"claims":{"P18":[{"rank":"normal","mainsnak":{"datavalue":{"value":"B.jpg"}}}]},"sitelinks":{}}}}"#.utf8)
        let t = ArtworkFixtureTransport([.init(match: "action=wbsearchentities", data: two), .init(match: "action=wbgetentities", data: ents), .init(match: "musicbrainz.org", data: nil)])
        #expect(try await WikimediaArtworkSource().identify(.person("Ravi Kumar"), context(t)) == nil)
        // The graph's IMDb id breaks the tie: only Q2 carries it.
        let ents2 = Data(#"{"entities":{"Q1":{"id":"Q1","labels":{"en":{"value":"Ravi Kumar"}},"claims":{"P345":[{"rank":"normal","mainsnak":{"datavalue":{"value":"nm1"}}}]},"sitelinks":{}},"Q2":{"id":"Q2","labels":{"en":{"value":"Ravi Kumar"}},"claims":{"P345":[{"rank":"normal","mainsnak":{"datavalue":{"value":"nm2"}}}]},"sitelinks":{}}}}"#.utf8)
        let t2 = ArtworkFixtureTransport([.init(match: "action=wbsearchentities", data: two), .init(match: "action=wbgetentities", data: ents2)])
        var s = MusicArtworkSubject.person("Ravi Kumar"); s.externalIDs = [ExternalID(.imdbName, "nm2")]
        #expect(try await WikimediaArtworkSource().identify(s, context(t2))?.facts.id == "Q2")
    }

    @Test func filmNeedsTheRightYearInTheDescription() async throws {
        let t = ArtworkFixtureTransport([
            .init(match: "action=wbsearchentities", data: AF.data("wikidata_search_film.json")),
            .init(match: "action=wbgetentities", data: AF.data("wikidata_entities.json")),
        ])
        let right = try await WikimediaArtworkSource().identify(.film("Soorarai Pottru", year: 2020), context(t))
        #expect(right?.facts.id == "Q63135778")
        #expect(try await WikimediaArtworkSource().identify(.film("Soorarai Pottru", year: 2019), context(t)) == nil)
    }

    @Test func tmdbPersonNeedsDepartmentAndKnownWork() async throws {
        let body = Data(#"{"results":[{"id":7,"name":"G. V. Prakash Kumar","known_for_department":"Sound","profile_path":"/abc.jpg","known_for":[{"title":"Soorarai Pottru"}]}]}"#.utf8)
        let fetch: @Sendable (String, [URLQueryItem]) async throws -> Data = { _, _ in body }
        let t = ArtworkFixtureTransport([])
        var s = MusicArtworkSubject.person(gvp, roles: [.composer], works: ["Soorarai Pottru"])
        let c = try await TMDBArtworkSource().candidates(for: s, context: context(t, tmdb: fetch))
        #expect(c.first?.address == "https://image.tmdb.org/t/p/h632/abc.jpg")
        #expect(c.first?.confidence == 0.92)
        s.roles = []; s.works = []
        #expect(try await TMDBArtworkSource().candidates(for: s, context: context(t, tmdb: fetch)).isEmpty)   // a name alone is never enough
        #expect(try await TMDBArtworkSource().candidates(for: s, context: context(t, tmdb: nil)).isEmpty)
    }

    @Test func tmdbTwoSameNamesOnlyAKnownWorkPicksOne() async throws {
        let body = Data(#"{"results":[{"id":1,"name":"Ravi","known_for_department":"Acting","profile_path":"/a.jpg","known_for":[{"title":"Other"}]},{"id":2,"name":"Ravi","known_for_department":"Acting","profile_path":"/b.jpg","known_for":[{"title":"Kaithi"}]}]}"#.utf8)
        let fetch: @Sendable (String, [URLQueryItem]) async throws -> Data = { _, _ in body }
        let none = try await TMDBArtworkSource().candidates(for: .person("Ravi", roles: [.actor]), context: context(ArtworkFixtureTransport([]), tmdb: fetch))
        #expect(none.isEmpty)
        let one = try await TMDBArtworkSource().candidates(for: .person("Ravi", roles: [.actor], works: ["Kaithi"]), context: context(ArtworkFixtureTransport([]), tmdb: fetch))
        #expect(one.first?.address.hasSuffix("/b.jpg") == true)
    }

    @Test func tmdbFilmNeedsTitleAndYear() async throws {
        let body = Data(#"{"results":[{"id":9,"title":"Soorarai Pottru","release_date":"2020-11-12","poster_path":"/p.jpg"}]}"#.utf8)
        let fetch: @Sendable (String, [URLQueryItem]) async throws -> Data = { _, _ in body }
        let c = try await TMDBArtworkSource().candidates(for: .film("Soorarai Pottru", year: 2020), context: context(ArtworkFixtureTransport([]), tmdb: fetch))
        #expect(c.first?.address == "https://image.tmdb.org/t/p/w500/p.jpg")
        #expect(try await TMDBArtworkSource().candidates(for: .film("Soorarai Pottru", year: 2018), context: context(ArtworkFixtureTransport([]), tmdb: fetch)).isEmpty)
    }

    @Test func imdbPersonNeedsRoleAndWorkOnTheDescriptionLine() async throws {
        let t = ArtworkFixtureTransport([.init(match: "suggestion/g/g_v_prakash_kumar", data: AF.data("imdb_person_suggestion.json"))])
        let good = try await IMDbArtworkSource().candidates(for: .person(gvp, roles: [.composer], works: ["Soorarai Pottru"]), context: context(t))
        #expect(good.first?.confidence == 0.9)
        #expect(try await IMDbArtworkSource().candidates(for: .person(gvp), context: context(t)).isEmpty)   // name only: no photo
        var wrong = MusicArtworkSubject.person(gvp, roles: [.composer]); wrong.externalIDs = [ExternalID(.imdbName, "nm9999999")]
        #expect(try await IMDbArtworkSource().candidates(for: wrong, context: context(t)).isEmpty)
    }

    @Test func imdbFilmNeedsYear() async throws {
        let t = ArtworkFixtureTransport([.init(match: "suggestion/s/soorarai_pottru", data: AF.data("imdb_film_suggestion.json"))])
        let ok = try await IMDbArtworkSource().candidates(for: .film("Soorarai Pottru", year: 2020), context: context(t))
        #expect(ok.first?.evidence == ["title", "year"])
        #expect(try await IMDbArtworkSource().candidates(for: .film("Soorarai Pottru", year: 2021), context: context(t)).isEmpty)
        #expect(IMDbArtworkSource.slug("G. V. Prakash Kumar") == "g_v_prakash_kumar")
    }

    @Test func deezerFindsAPersonThroughAnAlbumTheyMade() async throws {
        let t = ArtworkFixtureTransport([.init(match: "api.deezer.com/search/album", data: AF.data("deezer_album_search.json"))])
        let ok = try await DeezerArtworkSource().candidates(for: .person("Anirudh Ravichander", works: ["Master"]), context: context(t))
        #expect(ok.first?.confidence == 0.88)
        #expect(ok.first?.address.contains("9da0a547b39e99bc35c6a9724aef91bf") == true)
        #expect(try await DeezerArtworkSource().candidates(for: .person("Gana Balachandar", works: ["Master"]), context: context(t)).isEmpty)
        #expect(try await DeezerArtworkSource().candidates(for: .person("Anirudh Ravichander"), context: context(t)).isEmpty)   // no work to prove it
    }

    @Test func aBareTitleSharedByTwoAlbumsGetsNoCover() async throws {
        let two = Data(#"{"data":[{"id":1,"title":"Hits","cover_big":"https://x/a.jpg","artist":{"id":1,"name":"A"}},{"id":2,"title":"Hits","cover_big":"https://x/b.jpg","artist":{"id":2,"name":"B"}}]}"#.utf8)
        let t = ArtworkFixtureTransport([.init(match: "api.deezer.com/search/album", data: two)])
        #expect(try await DeezerArtworkSource().candidates(for: .album("Hits"), context: context(t)).isEmpty)
        #expect(try await DeezerArtworkSource().candidates(for: .album("Hits", creator: "B"), context: context(t)).first?.address == "https://x/b.jpg")
    }

    @Test func deezerFilmBorrowsItsSoundtrackCover() async throws {
        let t = ArtworkFixtureTransport([.init(match: "api.deezer.com/search/album", data: AF.data("deezer_album_search.json"))])
        let c = try await DeezerArtworkSource().candidates(for: .film("Master", year: 2021), context: context(t))
        #expect(c.first?.evidence == ["soundtrack-title"])
        #expect(c.first.map { $0.confidence >= MusicArtworkMatch.workThreshold } == true)
    }

    @Test func itunesAlbumAtLargeSizeThenSmall() async throws {
        let t = ArtworkFixtureTransport([.init(match: "itunes.apple.com/search", data: AF.data("itunes_album_search.json"))])
        let c = try await ITunesArtworkSource().candidates(for: .album("Vaathi Coming", creator: "Anirudh Ravichander"), context: context(t))
        #expect(c.count == 2)
        #expect(c[0].address.hasSuffix("/600x600bb.jpg") && c[1].address.hasSuffix("/100x100bb.jpg"))
        #expect(try await ITunesArtworkSource().candidates(for: .album("Vaathi Coming", creator: "Somebody Else"), context: context(t)).isEmpty)
    }

    @Test func saavnAlbumAndPersonRules() async throws {
        let t = ArtworkFixtureTransport([.init(match: "jiosaavn.com/api.php", data: AF.data("saavn_autocomplete.json"))])
        let a = try await JioSaavnArtworkSource().candidates(for: .album("Vaathi Coming (From \"Master\")", creator: "Anirudh Ravichander"), context: context(t))
        #expect(a.first?.address.contains("500x500.") == true)
        let p = try await JioSaavnArtworkSource().candidates(for: .person("Anirudh Ravichander", roles: [.composer]), context: context(t))
        #expect(p.first?.evidence == ["name", "role"])
        #expect(try await JioSaavnArtworkSource().candidates(for: .person("Anirudh Ravichander"), context: context(t)).isEmpty)
        #expect(try await JioSaavnArtworkSource().candidates(for: .person("Anirudh Ravichander", roles: [.actor]), context: context(t)).isEmpty)
    }

    @Test func coverArtArchiveByIdAndBySearch() async throws {
        var s = MusicArtworkSubject.album("Master"); s.externalIDs = [ExternalID(.mbReleaseGroup, "0de25d19-e99f-4059-887e-ac3572f2101a")]
        let byID = try await CoverArtArtworkSource().candidates(for: s, context: context(ArtworkFixtureTransport([])))
        #expect(byID.first?.address == "https://coverartarchive.org/release-group/0de25d19-e99f-4059-887e-ac3572f2101a/front-500")
        #expect(byID.count == 2 && byID[0].confidence == 1)
        let t = ArtworkFixtureTransport([.init(match: "musicbrainz.org/ws/2/release-group", data: AF.data("mb_releasegroup_search.json"))])
        let found = try await CoverArtArtworkSource().candidates(for: .album("Master", creator: "Anirudh Ravichander"), context: context(t))
        #expect(found.first?.confidence == 0.9)
        #expect(try await CoverArtArtworkSource().candidates(for: .album("Master", creator: "Nobody"), context: context(t)).isEmpty)
    }
}

// MARK: - the resolver: order, thresholds, negative cache, single flight

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock(); private(set) var order: [String] = []; private var running = 0; private(set) var peak = 0
    func add(_ s: String) { lock.lock(); order.append(s); lock.unlock() }
    func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
    func leave() { lock.lock(); running -= 1; lock.unlock() }
    func count(_ s: String) -> Int { lock.lock(); defer { lock.unlock() }; return order.filter { $0 == s }.count }
}

private struct FakeSource: MusicArtworkSource {
    var id: MusicArtworkSourceID
    var switchID: MusicSourceID? = nil
    var kinds: Set<MusicEntityKind>? = nil
    var log: CallLog
    var delay: Duration? = nil
    var answer: @Sendable (MusicArtworkSubject) throws -> [MusicArtworkCandidate]
    func applies(to kind: MusicEntityKind) -> Bool { kinds?.contains(kind) ?? true }
    func candidates(for s: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        log.add(id.rawValue); log.enter(); defer { log.leave() }
        if let delay { try await Task.sleep(for: delay) }
        return try answer(s)
    }
}

private func cand(_ a: String, _ s: MusicArtworkSourceID, _ c: Double) -> MusicArtworkCandidate { MusicArtworkCandidate(address: a, source: s, confidence: c, evidence: ["test"]) }

private struct FakeGraph: MusicArtworkGraphContext {
    var stored: [String: String] = [:]
    var relations: [String: [MusicArtworkRelation]] = [:]
    func enrich(_ s: MusicArtworkSubject) async -> MusicArtworkSubject { s }
    func storedAddress(for s: MusicArtworkSubject) async -> String? { stored[s.key] }
    func related(to s: MusicArtworkSubject) async -> [MusicArtworkRelation] { relations[s.key] ?? [] }
}

private func makeResolver(_ sources: [FakeSource], graph: FakeGraph? = nil, clock: Clock = Clock(), gate: MusicArtworkGate = .open, dead: Set<String> = [],
                          maxConcurrent: Int = 3, cache: MusicArtworkResolutionCache? = nil) -> (MusicEntityArtworkResolver, MusicArtworkResolutionCache) {
    let c = cache ?? MusicArtworkResolutionCache(file: nil, now: { clock.now })
    let ctx = MusicArtworkContext(transport: ArtworkFixtureTransport([]), tmdb: nil, now: { clock.now })
    let r = MusicEntityArtworkResolver(sources: sources, graph: graph, cache: c, gate: gate, context: ctx, maxConcurrent: maxConcurrent, probe: { !dead.contains($0) })
    return (r, c)
}

@Suite("Artwork resolver")
struct MusicEntityArtworkResolverTests {
    @Test func personChainOrderStopsAtTheFirstVerifiedPicture() async {
        let log = CallLog()
        let src: [FakeSource] = [
            FakeSource(id: .wikimedia, log: log) { _ in [] },
            FakeSource(id: .tmdb, log: log) { _ in [] },
            FakeSource(id: .imdb, log: log) { _ in [cand("https://img/imdb.jpg", .imdb, 0.8)] },
            FakeSource(id: .deezer, log: log) { _ in [cand("https://img/dz.jpg", .deezer, 0.9)] },
        ]
        let (r, _) = makeResolver(src)
        let got = await r.resolve(.person(gvp))
        #expect(got?.source == .imdb)
        #expect(log.order == ["wikimedia", "tmdb", "imdb"])
    }

    @Test func aPersonBelowThresholdIsRefusedButAWorkAtTheSameScoreIsKept() async {
        let log = CallLog()
        let src = [FakeSource(id: .wikimedia, log: log) { _ in [cand("https://img/a.jpg", .wikimedia, 0.7)] },
                   FakeSource(id: .itunes, log: log) { _ in [cand("https://img/b.jpg", .itunes, 0.7)] }]
        let (r, _) = makeResolver(src)
        #expect(await r.resolve(.person(gvp)) == nil)
        #expect((await r.resolve(.album("X", creator: "Y")))?.address == "https://img/b.jpg")
    }

    @Test func aMissIsRemembered_aDayForAnEmptyAnswer() async {
        let log = CallLog(); let clock = Clock()
        let src = [FakeSource(id: .itunes, log: log) { _ in [] }]
        let (r, _) = makeResolver(src, clock: clock)
        let s = MusicArtworkSubject.album("Nothing", creator: "Nobody")
        #expect(await r.resolve(s) == nil); #expect(await r.resolve(s) == nil)
        #expect(log.count("itunes") == 1)
        clock.advance(23 * 3600); #expect(await r.resolve(s) == nil); #expect(log.count("itunes") == 1)
        clock.advance(2 * 3600); #expect(await r.resolve(s) == nil); #expect(log.count("itunes") == 2)
    }

    @Test func aNetworkFailureIsRememberedOnlyTenMinutes() async {
        struct Boom: Error {}
        let log = CallLog(); let clock = Clock()
        let src = [FakeSource(id: .itunes, log: log) { _ in throw Boom() }]
        let (r, _) = makeResolver(src, clock: clock)
        let s = MusicArtworkSubject.album("Flaky", creator: "Band")
        #expect(await r.resolve(s) == nil); #expect(await r.resolve(s) == nil)
        #expect(log.count("itunes") == 1)
        clock.advance(31 * 60)
        #expect(await r.resolve(s) == nil); #expect(log.count("itunes") == 2)
    }

    @Test func oneSourcesMissIsNotAskedAgainWhileTheNextIsTried() async {
        let log = CallLog(); let clock = Clock()
        // First run: itunes empty, deezer dead link. Second run (after the subject-level transient miss ends): itunes is still remembered, deezer is asked again.
        let src = [FakeSource(id: .itunes, log: log) { _ in [] }, FakeSource(id: .deezer, log: log) { _ in [cand("https://dead/x.jpg", .deezer, 0.9)] }]
        let (r, _) = makeResolver(src, clock: clock, dead: ["https://dead/x.jpg"])
        let s = MusicArtworkSubject.album("T", creator: "A")
        #expect(await r.resolve(s) == nil)
        clock.advance(31 * 60)
        #expect(await r.resolve(s) == nil)
        #expect(log.count("itunes") == 1)
        #expect(log.count("deezer") == 2)
    }

    @Test func aDeadAddressFallsThroughToTheNextSource() async {
        let log = CallLog()
        let src = [FakeSource(id: .coverArtArchive, log: log) { _ in [cand("https://dead/1.jpg", .coverArtArchive, 1), cand("https://ok/2.jpg", .coverArtArchive, 0.99)] },
                   FakeSource(id: .itunes, log: log) { _ in [cand("https://ok/3.jpg", .itunes, 0.9)] }]
        let (r, _) = makeResolver(src, dead: ["https://dead/1.jpg"])
        #expect((await r.resolve(.album("T", creator: "A")))?.address == "https://ok/2.jpg")
    }

    @Test func concurrentAsksShareOneRun() async {
        let log = CallLog()
        let src = [FakeSource(id: .itunes, log: log, delay: .milliseconds(80)) { _ in [cand("https://ok/a.jpg", .itunes, 0.9)] }]
        let (r, _) = makeResolver(src)
        let s = MusicArtworkSubject.album("Shared", creator: "A")
        let results = await withTaskGroup(of: String?.self) { g -> [String?] in
            for _ in 0..<8 { g.addTask { await r.resolve(s)?.address } }
            var out: [String?] = []; for await x in g { out.append(x) }; return out
        }
        #expect(results.allSatisfy { $0 == "https://ok/a.jpg" })
        #expect(log.count("itunes") == 1)
    }

    @Test func atMostThreeSubjectsResolveAtOnce() async {
        let log = CallLog()
        let src = [FakeSource(id: .itunes, log: log, delay: .milliseconds(40)) { s in [cand("https://ok/\(s.name).jpg", .itunes, 0.9)] }]
        let (r, _) = makeResolver(src, maxConcurrent: 3)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<12 { g.addTask { _ = await r.resolve(.album("Album \(i)", creator: "A")) } }
        }
        #expect(log.peak <= 3 && log.peak >= 2)
        #expect(log.count("itunes") == 12)
    }

    @Test func aFilmWithoutAPosterBorrowsItsSoundtrackCover() async {
        let log = CallLog()
        let film = MusicArtworkSubject.film("Master", year: 2021), album = MusicArtworkSubject.album("Master (OST)", creator: "Anirudh Ravichander")
        let graph = FakeGraph(relations: [film.key: [MusicArtworkRelation(subject: album, label: "Master (OST)")]])
        let src = [FakeSource(id: .tmdb, log: log) { _ in [] },
                   FakeSource(id: .itunes, kinds: [.album], log: log) { _ in [cand("https://ok/ost.jpg", .itunes, 0.85)] }]
        let (r, _) = makeResolver(src, graph: graph)
        let got = await r.resolve(film)
        #expect(got?.source == .relation)
        #expect(got?.borrowedFrom == "Master (OST)")
        #expect(got?.address == "https://ok/ost.jpg")
        #expect(log.order == ["tmdb", "itunes"])
    }

    @Test func aSongWithoutGraphEdgesBorrowsItsAlbumByTitle() async {
        let log = CallLog()
        let src = [FakeSource(id: .itunes, kinds: [.album], log: log) { s in s.name == "Master" ? [cand("https://ok/master.jpg", .itunes, 0.85)] : [] }]
        let (r, _) = makeResolver(src)
        var song = MusicArtworkSubject.recording("Vaathi Coming", creator: "Anirudh Ravichander"); song.works = ["Master"]
        let got = await r.resolve(song)
        #expect(got?.address == "https://ok/master.jpg" && got?.borrowedFrom == "Master" && got?.source == .relation)
    }

    @Test func aRelationCycleEndsInsteadOfLooping() async {
        let log = CallLog()
        let a = MusicArtworkSubject.recording("A", creator: "X"), b = MusicArtworkSubject.recording("B", creator: "X")
        let graph = FakeGraph(relations: [a.key: [MusicArtworkRelation(subject: b, label: "B")], b.key: [MusicArtworkRelation(subject: a, label: "A")]])
        let (r, _) = makeResolver([FakeSource(id: .itunes, log: log) { _ in [] }], graph: graph)
        #expect(await r.resolve(a) == nil)
    }

    @Test func theGraphsOwnPictureWinsAndNeedsNoNetwork() async {
        let log = CallLog()
        let s = MusicArtworkSubject.person(gvp)
        let graph = FakeGraph(stored: [s.key: "https://stored/gv.jpg"])
        let (r, _) = makeResolver([FakeSource(id: .wikimedia, log: log) { _ in [cand("https://w/x.jpg", .wikimedia, 1)] }], graph: graph, gate: .closed)
        let got = await r.resolve(s)
        #expect(got?.source == .stored && got?.address == "https://stored/gv.jpg")
        #expect(log.order.isEmpty)
    }

    @Test func aClosedGateSkipsEveryNetworkSource_aSwitchedOffSourceIsSkipped() async {
        let log = CallLog()
        let src = [FakeSource(id: .tmdb, switchID: .tmdb, log: log) { _ in [cand("https://t/a.jpg", .tmdb, 0.95)] },
                   FakeSource(id: .imdb, switchID: .imdb, log: log) { _ in [cand("https://i/a.jpg", .imdb, 0.9)] }]
        let (closed, _) = makeResolver(src, gate: .closed)
        #expect(await closed.resolve(.person(gvp)) == nil); #expect(log.order.isEmpty)
        let gate = MusicArtworkGate(networkAllowed: { true }, sourceOn: { $0 != .tmdb })
        let (partial, _) = makeResolver(src, gate: gate)
        #expect((await partial.resolve(.person(gvp)))?.source == .imdb)
        #expect(log.order == ["imdb"])
    }

    @Test func facetsWithNothingKeepTheDesignedTile() async {
        let (r, _) = makeResolver([FakeSource(id: .itunes, log: CallLog()) { _ in [cand("https://x/y.jpg", .itunes, 1)] }], graph: FakeGraph())
        #expect(await r.resolve(MusicArtworkSubject(kind: .genre, name: "Melody")) == nil)   // genres have no network step
    }

    @Test func positiveAnswersLastThirtyDaysAndSurviveARestart() async throws {
        let clock = Clock()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c1 = MusicArtworkResolutionCache(file: file, now: { clock.now })
        c1.store(MusicResolvedArtwork(address: "https://x/y.jpg", source: .tmdb, confidence: 0.9, evidence: ["t"], credit: "TMDB", resolvedAt: clock.now, borrowedFrom: nil), for: "k")
        c1.recordMiss("m", transient: false)
        c1.flush()
        let c2 = MusicArtworkResolutionCache(file: file, now: { clock.now })
        #expect(c2.positive("k")?.address == "https://x/y.jpg")
        #expect(c2.isMiss("m"))
        clock.advance(29 * 86_400); #expect(c2.positive("k") != nil)
        clock.advance(2 * 86_400); #expect(c2.positive("k") == nil)
        #expect(!c2.isMiss("m"))
        c2.clear(); #expect(c2.counts.positives == 0)
    }

    @Test func aBrokenAddressIsForgottenSoItResolvesAgain() async {
        let log = CallLog()
        let (r, _) = makeResolver([FakeSource(id: .itunes, log: log) { _ in [cand("https://ok/a.jpg", .itunes, 0.9)] }])
        let s = MusicArtworkSubject.album("T", creator: "A")
        _ = await r.resolve(s); #expect(r.cached(s) != nil)
        await r.forget(s, address: "https://ok/a.jpg"); #expect(r.cached(s) == nil)
        _ = await r.resolve(s); #expect(log.count("itunes") == 2)
    }
}
