import Foundation
import Testing
@testable import REDDY

@Suite("Completeness: Wikidata, MusicBrainz and IMDb parsers (inline fixtures)") struct CompletenessParserTests {
    typealias F = CompletenessFixtures

    // MARK: Wikidata

    @Test func searchPicksTheOnePersonAndRefusesATie() {
        let c = MusicPersonWikidataParser.searchCandidates(F.searchGV)
        #expect(c.count == 2)
        #expect(MusicPersonWikidataParser.pick(c, name: "G. V. Prakash Kumar")?.qid == "Q444")
        let tie = [MusicPersonWikidataParser.Candidate(qid: "Q1", label: "Ravi", description: "Indian composer"), .init(qid: "Q2", label: "Ravi", description: "Indian singer")]
        #expect(MusicPersonWikidataParser.pick(tie, name: "Ravi") == nil, "two plausible people: never guess")
        #expect(MusicPersonWikidataParser.pick([.init(qid: "Q3", label: "G. V. Prakash Kumar", description: "village")], name: "G. V. Prakash Kumar") == nil, "no occupation: not a person")
    }

    @Test func factsGiveIdsAndTheBirthYear() throws {
        let f = try #require(MusicPersonWikidataParser.facts(F.factsGV(), qid: "Q444"))
        #expect(f.isHuman && f.birthYear == 1987)
        #expect(f.ids.contains(ExternalID(.mbid, "22222222-2222-2222-2222-222222222222")) && f.ids.contains(ExternalID(.imdbName, "nm2111287")) && f.ids.contains(ExternalID(.wikidata, "Q444")))
    }

    @Test func worksQueryRefusesAnythingButAQID() {
        #expect(MusicPersonWikidataParser.worksQuery(qid: "Q444")?.contains("wd:Q444") == true)
        #expect(MusicPersonWikidataParser.worksQuery(qid: "Q1 } DROP") == nil)
        #expect(MusicPersonWikidataParser.worksQuery(qid: "444") == nil)
        let q = MusicPersonWikidataParser.worksQuery(qid: "Q444") ?? ""
        for p in ["P86", "P161", "P57", "P676", "P175", "P406"] { #expect(q.contains(p)) }
    }

    @Test func sparqlRowsBecomeFilmsAndAlbumsOncePerItem() {
        let w = MusicPersonWikidataParser.works(sparql: F.sparql(F.vaathiRows))
        let films = w.filter { $0.kind == .film }, albums = w.filter { $0.kind == .album }
        #expect(Set(films.map(\.title)) == ["Vaathi", "Soorarai Pottru", "Asuran", "Aadukalam"])
        #expect(films.first { $0.title == "Vaathi" }?.year == 2023 && films.first { $0.title == "Vaathi" }?.relations == [.composer], "earliest date, one entry per item")
        #expect(films.first { $0.title == "Vaathi" }?.soundtrackQID == "Q211")
        #expect(films.first { $0.title == "Aadukalam" }.map { $0.ids.contains(ExternalID(.imdbTitle, "tt1704594")) } == true)
        #expect(albums.count == 1 && albums[0].subkind == "soundtrack" && albums[0].ids.contains(ExternalID(.mbReleaseGroup, "11111111-1111-1111-1111-111111111111")))
        #expect(!w.contains { $0.title == "Q300" }, "an unlabelled item is not shown under its id")
    }

    @Test func aFilmCreditedAsComposerAndCastKeepsBothRelations() {
        let w = MusicPersonWikidataParser.works(sparql: F.sparql([F.row("Q9", "Naanum Rowdy Dhaan", rel: "composer", imdb: "tt1"), F.row("Q9", "Naanum Rowdy Dhaan", rel: "cast", imdb: "tt1")]))
        #expect(w.count == 1 && w[0].relations == [.composer, .cast])
    }

    @Test func searchApiFallbackReadsHitsAndEntities() {
        let hits = MusicPersonWikidataParser.searchHits(F.data("{\"continue\":{\"sroffset\":50},\"query\":{\"search\":[{\"title\":\"Q7\"},{\"title\":\"Talk:x\"},{\"title\":\"Q8\"}]}}"))
        #expect(hits.qids == ["Q7", "Q8"] && hits.next == 50)
        let ents = F.data("""
        {"entities":{"Q7":{"labels":{"en":{"value":"Jailer"}},"claims":{"P577":[{"mainsnak":{"datavalue":{"value":{"time":"+2023-08-10T00:00:00Z"}}}}],"P345":[{"mainsnak":{"datavalue":{"value":"tt15"}}}]}}}}
        """)
        let w = MusicPersonWikidataParser.works(entities: ents, relation: .composer)
        #expect(w.count == 1 && w[0].kind == .film && w[0].year == 2023 && w[0].relations == [.composer])
    }

    @Test func soundtrackReleasesOfAFilm() {
        let film = F.data("{\"entities\":{\"Q1\":{\"claims\":{\"P406\":[{\"mainsnak\":{\"datavalue\":{\"value\":{\"id\":\"Q50\"}}}},{\"rank\":\"deprecated\",\"mainsnak\":{\"datavalue\":{\"value\":{\"id\":\"Q51\"}}}}]}}}}")
        #expect(MusicPersonWikidataParser.soundtrackIDs(entity: film, qid: "Q1") == ["Q50"])
        let albums = MusicPersonWikidataParser.soundtrackAlbums(entities: F.data("{\"entities\":{\"Q50\":{\"labels\":{\"en\":{\"value\":\"Vaathi (OST)\"}},\"claims\":{}}}}"), film: "Vaathi")
        #expect(albums.count == 1 && albums[0].statesFilm && albums[0].isSoundtrack)
    }

    // MARK: MusicBrainz

    @Test func releaseGroupPageGivesTypesPagingAndNoVariousArtists() {
        let json = F.data("""
        {"release-group-count":230,"release-groups":[
          {"id":"a","title":"Vaathi (Original Motion Picture Soundtrack)","first-release-date":"2023-02-02","primary-type":"Album","secondary-types":["Soundtrack"],"artist-credit":[{"name":"G. V. Prakash Kumar"},{"name":"Various Artists"}]},
          {"id":"b","title":"Single X","first-release-date":"2019","primary-type":"Single","secondary-types":[],"artist-credit":[{"name":"G. V. Prakash Kumar"}]}]}
        """)
        let p = MusicPersonMusicBrainzParser.releaseGroups(json)
        #expect(p.items.count == 2 && p.total == 230)
        #expect(p.items[0].subkind == "soundtrack" && p.items[0].artists == ["G. V. Prakash Kumar"], "Various Artists is never an identity")
        #expect(p.items[1].subkind == "single" && p.items[1].year == 2019)
        #expect(p.next(offset: 0) == 2 && p.next(offset: 228) == nil)
    }

    @Test func worksCountOnlyThroughARelationToThisArtist() {
        let json = F.data("""
        {"work-count":2,"works":[
          {"id":"w1","title":"Adiye","relations":[{"type":"composer","target-type":"artist","artist":{"id":"me"}},{"type":"lyricist","target-type":"artist","artist":{"id":"other"}}]},
          {"id":"w2","title":"Not mine","relations":[{"type":"composer","target-type":"artist","artist":{"id":"other"}}]}]}
        """)
        let p = MusicPersonMusicBrainzParser.works(json, artist: "me")
        #expect(p.items.count == 1 && p.items[0].relations == [.composer] && p.items[0].kind == .work)
    }

    @Test func anArtistIsAcceptedOnlyThroughALinkBackToThePerson() {
        let links = MusicPersonMusicBrainzParser.artistLinks(F.data("{\"relations\":[{\"target-type\":\"url\",\"url\":{\"resource\":\"https://www.wikidata.org/wiki/Q444\"}},{\"target-type\":\"url\",\"url\":{\"resource\":\"https://www.imdb.com/name/nm2111287/\"}}]}"))
        #expect(MusicPersonMusicBrainzParser.linked(links, to: [ExternalID(.wikidata, "Q444")]))
        #expect(!MusicPersonMusicBrainzParser.linked(links, to: [ExternalID(.wikidata, "Q999")]))
        #expect(!MusicPersonMusicBrainzParser.linked(links, to: []))
    }

    // MARK: IMDb

    private func page(_ json: String) -> String { "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>" }

    @Test func nameCreditsAreFoundByWalkingForTitleNodes() {
        let json = """
        {"props":{"pageProps":{"mainColumnData":{"releasedPrimaryCredits":[
          {"category":{"id":"composer","text":"Music Department"},"credits":{"edges":[
            {"node":{"title":{"id":"tt15327088","titleText":{"text":"Vaathi"},"releaseYear":{"year":2023},"titleType":{"id":"movie"}}}},
            {"node":{"title":{"id":"tt0000001","titleText":{"text":"Ep 4"},"releaseYear":{"year":2020},"titleType":{"id":"tvEpisode"}}}}]}},
          {"category":{"id":"actor","text":"Actor"},"credits":{"edges":[
            {"node":{"title":{"id":"tt15327088","titleText":{"text":"Vaathi"},"releaseYear":{"year":2023},"titleType":{"id":"movie"}}}},
            {"node":{"title":{"id":"tt1704594","titleText":{"text":"Aadukalam"},"releaseYear":{"year":2011},"titleType":{"id":"movie"}}}}]}}]}}}}
        """
        let w = MusicPersonIMDbParser.credits(html: page(json))
        #expect(w.count == 2, "episodes are not films")
        #expect(w.first { $0.title == "Vaathi" }?.relations == [.composer, .cast])
        #expect(w.first { $0.title == "Aadukalam" }?.relations == [.cast] && w.first { $0.title == "Aadukalam" }?.ids == [ExternalID(.imdbTitle, "tt1704594")])
    }

    @Test func aPageWithoutTheDataBlockGivesNothingAndIsRecognisedAsBlocked() {
        #expect(MusicPersonIMDbParser.credits(html: "<html>captcha awswaf</html>").isEmpty)
        #expect(MusicIMDbParser.looksBlocked("<html>captcha awswaf</html>"))
        #expect(MusicPersonIMDbParser.nameHits(F.data("{\"d\":[{\"id\":\"nm2111287\",\"l\":\"G.V. Prakash Kumar\",\"s\":\"Composer, Vaathi\"},{\"id\":\"tt1\",\"l\":\"Film\"}]}")).map(\.id) == ["nm2111287"])
    }
}
