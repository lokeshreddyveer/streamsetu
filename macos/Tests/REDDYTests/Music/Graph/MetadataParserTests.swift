import Foundation
import Testing
@testable import REDDY

/// The pure parsers, on trimmed real replies recorded from the live services (see Fixtures).
@Suite("Metadata parsers: MusicBrainz and ListenBrainz") struct MetadataMusicBrainzParserTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordingGivesIsrcDurationWorkAndPerformer() throws {
        let b = try #require(MusicBrainzParser.recording(MetadataFixtures.data("mb_recording_awara_hoon.json"), retrievedAt: at))
        let rec = try #require(b.drafts.first { $0.ref.kind == .recording })
        #expect(rec.entity.externalIDs.contains(ExternalID(.isrc, "INH109244930")))
        #expect(rec.entity.durationMs == 186_000)
        #expect(b.claims.contains { $0.predicate == .recordingOf && $0.object.kind == .work && $0.evidence.contains("performance") })
        #expect(b.source == .musicbrainz && b.license == .cc0 && b.retrievedAt == at)
    }

    @Test func workGivesComposerGroupAndLyricist() throws {
        let b = try #require(MusicBrainzParser.work(MetadataFixtures.data("mb_work_awaara_hoon.json"), retrievedAt: at))
        let work = try #require(b.drafts.first { $0.ref.kind == .work })
        #expect(work.entity.externalIDs.contains(ExternalID(.iswc, "T-915.162.162-4")))
        #expect(work.entity.lang == "hi")
        let composer = try #require(b.claims.first { $0.predicate == .composedBy })
        #expect(composer.role == .composer && composer.object.kind == .group, "Shankar Jaikishan is a credited group")
        let lyricist = try #require(b.claims.first { $0.predicate == .writtenBy })
        #expect(lyricist.role == .lyricist)
        let names = Set(b.drafts.map(\.entity.name))
        #expect(names.contains("Shankar Jaikishan") && names.contains("Shailendra"))
    }

    @Test func releaseGroup1951IsASoundtrackWithAWikidataLinkAndGenresUnderTheirOwnLicence() throws {
        let b = try #require(MusicBrainzParser.releaseGroup(MetadataFixtures.data("mb_release_group_awaara_1951.json"), retrievedAt: at))
        let g = try #require(b.drafts.first { $0.ref.kind == .album })
        #expect(g.entity.subkind == MusicAlbumSubkind.soundtrack.rawValue && g.entity.year == 1951)
        #expect(g.entity.externalIDs.contains(ExternalID(.wikidata, "Q113440753")))
        #expect(b.claims.filter { $0.predicate == .editionOf }.count == 2)
        let genre = try #require(b.claims.first { $0.predicate == .hasGenre })
        #expect(genre.license == .ccByNcSa && genre.attribution == "MusicBrainz")
        #expect(b.imageHints.values.contains { $0.hasPrefix("https://coverartarchive.org/") }, "cover art is an image hint only")
    }

    @Test func releaseGroup2010HasNoUrlRelationsAndNoSoundtrackToFilmClaim() throws {
        let b = try #require(MusicBrainzParser.releaseGroup(MetadataFixtures.data("mb_release_group_awaara_2010.json"), retrievedAt: at))
        let g = try #require(b.drafts.first { $0.ref.kind == .album })
        #expect(g.entity.year == 2010 && g.entity.subkind == MusicAlbumSubkind.soundtrack.rawValue)
        #expect(!g.entity.externalIDs.contains { $0.scheme == .wikidata })
        #expect(!b.claims.contains { $0.predicate == .soundtrackOf }, "MusicBrainz never states the film link")
        #expect(g.entity.attrs["artists"] == "Yuvan Shankar Raja")
    }

    @Test func releaseTracklistGivesTenRecordingsWithPositionsAndSingers() throws {
        let b = try #require(MusicBrainzParser.release(MetadataFixtures.data("mb_release_awaara_1951.json"), retrievedAt: at))
        #expect(b.drafts.filter { $0.ref.kind == .recording }.count == 10)
        let tracks = b.claims.filter { $0.predicate == .trackOn }
        #expect(tracks.count == 10 && tracks.first?.attributes.position == 1)
        let ek = try #require(b.drafts.first { $0.entity.name == "Ek Do Teen" })
        let singer = b.claims.first { $0.subject == ek.ref && $0.predicate == .performedBy }
        let shamshad = b.drafts.first { $0.entity.name == "Shamshad Begum" }
        #expect(singer != nil && singer?.object == shamshad?.ref)
    }

    @Test func searchesReturnCandidatesNotFacts() throws {
        let sj = MusicBrainzParser.releaseGroupSearch(MetadataFixtures.data("mb_release_group_search_awaara_shankar_jaikishan.json"), retrievedAt: at)
        #expect(sj.isSearch && sj.claims.isEmpty && sj.drafts.count == 1)
        let macron = MusicBrainzParser.releaseGroupSearch(MetadataFixtures.data("mb_release_group_search_awara_macron.json"), retrievedAt: at)
        #expect(macron.drafts.first?.entity.year == 1951 && macron.drafts.first?.entity.subkind == "soundtrack")
        let yuvan = MusicBrainzParser.releaseGroupSearch(MetadataFixtures.data("mb_release_group_search_awaara_yuvan.json"), retrievedAt: at)
        #expect(yuvan.drafts.first?.entity.year == 2010)
    }

    @Test func listenBrainzBridgesStreamingAndWikidataLinks() throws {
        let b = MusicListenBrainzParser.metadata(MetadataFixtures.data("listenbrainz_recording_awara_hoon.json"), retrievedAt: at)
        let rec = try #require(b.drafts.first { $0.ref.kind == .recording })
        #expect(rec.entity.externalIDs.contains { $0.scheme == .spotifyID } && rec.entity.externalIDs.contains { $0.scheme == .isrc })
        let artist = try #require(b.drafts.first { $0.ref.kind == .person })
        #expect(artist.entity.externalIDs.contains(ExternalID(.wikidata, "Q2367593")))
        #expect(b.imageHints[rec.ref]?.contains("coverartarchive.org") == true)
    }

    @Test func externalLinksMapToIds() {
        #expect(MusicExternalLinks.externalID(fromURL: "https://www.wikidata.org/wiki/Q858681") == ExternalID(.wikidata, "Q858681"))
        #expect(MusicExternalLinks.externalID(fromURL: "https://www.imdb.com/title/tt0043306/") == ExternalID(.imdbTitle, "tt0043306"))
        #expect(MusicExternalLinks.externalID(fromURL: "https://www.themoviedb.org/movie/39039-awara") == ExternalID(.tmdbMovie, "39039"))
        #expect(MusicExternalLinks.externalID(fromURL: "https://www.themoviedb.org/person/110860") == ExternalID(.tmdbPerson, "110860"))
        #expect(MusicExternalLinks.externalID(fromURL: "https://example.org/x") == nil)
    }
}

@Suite("Metadata parsers: Wikidata, Wikipedia, IMDb") struct MetadataFilmParserTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func awaaraFilm() throws -> MusicClaimBatch {
        let entity = MetadataFixtures.data("wikidata_entity_q858681_awaara_film.json")
        let people = MusicWikidataParser.people(MetadataFixtures.data("wikidata_people_awaara_cast.json"))
        return try #require(MusicWikidataParser.item(entity, qid: "Q858681", kind: .film, people: people, retrievedAt: at))
    }

    @Test func wikidataFilmHasCastCrewIdsAndSitelinks() throws {
        let b = try awaaraFilm()
        let film = try #require(b.drafts.first { $0.ref.kind == .film })
        #expect(film.entity.year == 1951 && film.entity.lang == "hi")
        #expect(film.entity.externalIDs.contains(ExternalID(.imdbTitle, "tt0043306")) && film.entity.externalIDs.contains(ExternalID(.tmdbMovie, "39039")))
        #expect(MusicWikidataParser.sitelinks(of: film.entity)["enwiki"] == "Awaara")
        #expect(b.claims.filter { $0.predicate == .hasCast }.count == 9)
        let raj = try #require(b.drafts.first { $0.entity.name == "Raj Kapoor" })
        let roles = Set(b.claims.filter { $0.object == raj.ref }.compactMap(\.role))
        #expect(roles == [.actor, .director, .producer], "one person, three roles, one entity")
        #expect(raj.entity.externalIDs.contains { $0.scheme == .tmdbPerson } && raj.entity.externalIDs.contains { $0.scheme == .imdbName })
        let duo = try #require(b.drafts.first { $0.entity.name.contains("Jaikishan") })
        #expect(duo.ref.kind == .group, "the composer item is a duo")
        #expect(b.claims.contains { $0.predicate == .composedBy && $0.object == duo.ref && $0.role == .composer })
        #expect(b.claims.allSatisfy { $0.predicate != .soundtrackOf }, "Wikidata does not state a soundtrack link here")
        #expect(b.imageHints[raj.ref] == "commons:Raj Kapoor 1950.jpg")
    }

    @Test func paiyaaCarriesTheTeluguArticleTheDubNeeds() throws {
        let b = try #require(MusicWikidataParser.item(MetadataFixtures.data("wikidata_entity_q3473406_paiyaa_film.json"), qid: "Q3473406", kind: .film, people: [:], retrievedAt: at))
        let film = try #require(b.drafts.first)
        #expect(film.entity.name == "Paiyaa" && film.entity.year == 2010)
        let links = MusicWikidataParser.sitelinks(of: film.entity)
        #expect(links["tewiki"] == "ఆవారా" && links["tawiki"] != nil)
        #expect(WikipediaSource.articles(sitelinks: links, language: "ta").map(\.lang) == ["en"], "only the English edition is read, whatever the film's language")
        #expect(WikipediaSource.articles(sitelinks: ["tewiki": "x"], language: "te").isEmpty, "no English article means nothing is read, not another language")
    }

    @Test func wikidataSearchSeparatesFilmSongAndAlbum() {
        let b = MusicWikidataParser.search(MetadataFixtures.data("wikidata_search_awaara.json"), retrievedAt: at)
        let kinds = Dictionary(uniqueKeysWithValues: b.drafts.map { ($0.entity.externalIDs[0].value, $0.entity.kind) })
        #expect(kinds["Q858681"] == .film && kinds["Q113440753"] == .album && kinds["Q113440934"] == .recording && kinds["Q4829819"] == .work)
        #expect(b.drafts.first { $0.entity.name == "Awaara" && $0.entity.kind == .film }?.entity.year == 1951)
        let vik = MusicWikidataParser.sparqlItems(MetadataFixtures.data("wikidata_sparql_vikram_by_imdb.json"))
        #expect(vik == ["Q102147287"])
    }

    @Test func wikipediaInfoboxCastSectionAndTeluguInfobox() throws {
        let paiyaa = MusicWikipediaParser.wikitext(MetadataFixtures.data("wikipedia_wikitext_paiyaa_en.json")) ?? ""
        let box = MusicWikipediaParser.infobox(paiyaa)
        #expect(MusicWikipediaParser.names(fromInfobox: box["starring"] ?? "") == ["Karthi", "Tamannaah Bhatia"])
        #expect(MusicWikipediaParser.names(fromInfobox: box["music"] ?? "") == ["Yuvan Shankar Raja"])
        let cast = MusicWikipediaParser.castList(paiyaa)
        #expect(cast.first == .init(name: "Karthi", character: "Shiva") && cast.count >= 6)
        let te = MusicWikipediaParser.wikitext(MetadataFixtures.data("wikipedia_wikitext_awaara_te.json")) ?? ""
        let teBox = MusicWikipediaParser.infobox(te)
        #expect(MusicWikipediaParser.names(fromInfobox: teBox["starring"] ?? "") == ["కార్తిక్", "తమన్నా"])
        let vik = MusicWikipediaParser.castList(MusicWikipediaParser.wikitext(MetadataFixtures.data("wikipedia_wikitext_vikram_en.json")) ?? "")
        #expect(vik.prefix(3).map(\.name) == ["Kamal Haasan", "Vijay Sethupathi", "Fahadh Faasil"])
    }

    @Test func wikipediaFilmBatchIsNameOnlyAttributedAndBelowWikidata() throws {
        let wt = MusicWikipediaParser.wikitext(MetadataFixtures.data("wikipedia_wikitext_paiyaa_en.json")) ?? ""
        let b = MusicWikipediaParser.film(wikitext: wt, lang: "en", article: "Paiyaa", film: .external(.film, ExternalID(.wikidata, "Q3473406")), retrievedAt: at)
        #expect(b.attribution == "Wikipedia" && b.license == .ccBySa && MusicSourceID.wikipedia.rank < MusicSourceID.wikidata.rank)
        #expect(b.drafts.allSatisfy { $0.entity.attrs["nameOnly"] == "1" })
        let first = try #require(b.claims.first { $0.predicate == .hasCast })
        #expect(first.confidence < 0.8 && first.attributes.characterName == "Shiva")
        #expect(b.claims.contains { $0.predicate == .directedBy } && b.claims.contains { $0.predicate == .composedBy })
    }

    @Test func soundtrackArticleNamesItsFilmAndSearchFindsIt() throws {
        let lead = MusicWikipediaParser.wikitext(MetadataFixtures.data("wikipedia_wikitext_paiyaa_soundtrack.json")) ?? ""
        #expect(MusicWikipediaParser.soundtrackFilmTitle(lead) == "Paiyaa")
        let s = MusicWikipediaParser.articleSearch(MetadataFixtures.data("wikipedia_search_awaara_2010.json"), retrievedAt: at)
        #expect(s.drafts.first?.entity.kind == .album && s.drafts.first?.entity.externalIDs.first == ExternalID(.wikidata, "Q7125252"))
        let item = try #require(MusicWikipediaParser.pageItem(MetadataFixtures.data("wikipedia_pageprops_paiyaa.json")))
        #expect(item.qid == "Q3473406")
        let sum = try #require(MusicWikipediaParser.summary(MetadataFixtures.data("wikipedia_summary_awaara.json")))
        #expect(sum.wikidataID == "Q858681")
    }

    @Test func commonsImageRecordKeepsLicenceAndAuthor() throws {
        let r = try #require(MusicWikipediaParser.commonsImage(MetadataFixtures.data("commons_imageinfo_raj_kapoor.json"), file: "Raj Kapoor 1950.jpg"))
        #expect(r.thumbnailURL?.hasPrefix("https://upload.wikimedia.org/") == true && r.pageURL?.contains("commons.wikimedia.org") == true)
        #expect(r.licence != nil)
        #expect(MusicWikipediaParser.commonsThumbnailURL(file: "Raj Kapoor 1950.jpg")?.absoluteString.contains("Special:FilePath/Raj_Kapoor_1950.jpg") == true)
    }

    @Test func imdbSuggestionsGiveFilmsWithTopCastAndNoNamePage() throws {
        let b = MusicIMDbParser.search(MetadataFixtures.data("imdb_suggestion_awaara.json"), retrievedAt: at)
        let film = try #require(b.drafts.first)
        #expect(film.entity.name == "Awaara" && film.entity.year == 1951 && film.entity.externalIDs == [ExternalID(.imdbTitle, "tt0043306")])
        #expect(film.entity.attrs["topCast"] == "Raj Kapoor|Nargis" && b.attribution == "IMDb" && b.retention == 30 * 86_400)
        #expect(!b.drafts.contains { $0.entity.externalIDs.contains { $0.value.hasPrefix("nm") } })
        let paiyaa = MusicIMDbParser.search(MetadataFixtures.data("imdb_suggestion_paiyaa.json"), retrievedAt: at)
        #expect(paiyaa.drafts.first?.entity.year == 2010 && paiyaa.drafts.first?.entity.attrs["topCast"] == "Karthi|Tamannaah Bhatia")
        let vik = MusicIMDbParser.search(MetadataFixtures.data("imdb_suggestion_vikram.json"), retrievedAt: at)
        #expect(vik.drafts.first?.entity.externalIDs == [ExternalID(.imdbTitle, "tt9179430")])
    }

    @Test func imdbChallengePageIsRecognisedAsBlocked() {
        let html = MetadataFixtures.text("imdb_title_page_blocked_challenge.html")
        #expect(MusicIMDbParser.jsonLD(inHTML: html) == nil && MusicIMDbParser.looksBlocked(html))
    }

    /// The title page itself is behind a bot challenge today, so this page is written by hand in the schema.org shape IMDb serves (not a recording).
    @Test func imdbJsonLDParserIsHardened() throws {
        let ld = """
        <html><head><script type="application/ld+json">{"@context":"https://schema.org","@type":"Movie","name":"Awaara","datePublished":"1951-12-14",
        "image":"https://m.media-amazon.com/images/x.jpg","aggregateRating":{"ratingValue":7.8},
        "actor":[{"@type":"Person","url":"https://www.imdb.com/name/nm0004072/","name":"Raj Kapoor"},{"@type":"Person","name":"No Link"},{"@type":"Organization","name":"X"}],
        "director":{"@type":"Person","url":"https://www.imdb.com/name/nm0004072/","name":"Raj Kapoor"}}</script><script>alert(1)</script></head></html>
        """
        let b = try #require(MusicIMDbParser.film(html: ld, imdbID: "tt0043306", retrievedAt: at))
        #expect(b.claims.filter { $0.predicate == .hasCast }.count == 2 && b.claims.filter { $0.predicate == .directedBy }.count == 1)
        let raj = try #require(b.drafts.first { $0.entity.name == "Raj Kapoor" })
        #expect(raj.entity.externalIDs == [ExternalID(.imdbName, "nm0004072")], "one person node for actor and director")
        #expect(b.drafts.first { $0.entity.name == "No Link" }?.entity.attrs["nameOnly"] == "1")
        #expect(MusicIMDbParser.film(html: "<script type=\"application/ld+json\">{broken</script>", imdbID: "tt1") == nil)
        #expect(MusicIMDbParser.film(html: "<script type=\"application/ld+json\">{\"@type\":\"Book\",\"name\":\"x\"}</script>", imdbID: "tt1") == nil)
    }

    @Test func discogsAndLastFmParsers() throws {
        let release = """
        {"id":42,"title":"Awaara","year":1951,"extraartists":[{"id":7,"name":"Shankar-Jaikishan","role":"Music By"}],
         "tracklist":[{"title":"Awaara Hoon","type_":"track","extraartists":[{"id":8,"name":"Mukesh (2)","role":"Vocals"},{"id":9,"name":"Shailendra","role":"Lyrics By"}]}]}
        """
        let b = try #require(MusicDiscogsParser.release(Data(release.utf8), retrievedAt: at))
        #expect(b.attribution == "Discogs" && b.claims.contains { $0.predicate == .writtenBy && $0.role == .lyricist })
        #expect(b.drafts.contains { $0.entity.name == "Mukesh" }, "Discogs disambiguation numbers are dropped")
        let tags = MusicLastFMGraphSourceTests.sample
        let t = LastFMGraphSource.topTags(Data(tags.utf8), artist: .external(.person, ExternalID(.mbid, "x")), retrievedAt: at)
        #expect(t.claims.count == 1 && t.claims[0].predicate == .hasGenre && t.claims[0].attribution == "Last.fm")
    }
}

enum MusicLastFMGraphSourceTests {
    static let sample = #"{"toptags":{"tag":[{"name":"bollywood","count":"100"},{"name":"seen live","count":"3"}]}}"#
}
