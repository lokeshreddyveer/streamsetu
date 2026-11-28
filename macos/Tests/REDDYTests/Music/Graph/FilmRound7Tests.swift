import Foundation
import Testing
@testable import REDDY

@Suite("Film round 7") struct FilmRound7Tests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func album(_ id: String, dub: String? = nil) -> MusicFilmAlbumItem {
        MusicFilmAlbumItem(album: MusicEntityID(kind: .album, token: id), name: id, year: nil, imageRef: nil, lang: nil, dubLanguage: dub, status: .verified, confidence: 1,
                           matchEvidence: [], via: nil, film: nil, filmName: nil)
    }

    private func person(_ name: String, character: String?, order: Int) -> MusicFilmPersonItem {
        MusicFilmPersonItem(person: MusicEntityID(kind: .person, token: name), name: name, imageRef: nil, role: .actor, character: character, order: order, status: .verified,
                            creditLevel: .film, nameOnly: false, attribution: nil, birthYear: nil)
    }

    // F1
    @MainActor @Test func tryAgainRunsTheFailedEntityLoadAgain() async throws {
        let f = await SongFixture.awaara()
        let store = MusicEntityStore(graph: f.graph)
        let model = MusicEntityModel(id: MusicEntityID(kind: .film, token: "NOSUCHFILM"), store: store)
        model.start()
        for _ in 0..<200 where model.phase != .failed { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(model.phase == .failed)
        model.start()
        #expect(model.snapshotLoads == 1)   // start alone never retries a failed page: this was the no-op
        model.restart()
        for _ in 0..<200 where model.snapshotLoads < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(model.snapshotLoads == 2)
    }

    // F2
    @Test func aFranchiseIsNotAFilm() {
        #expect(MusicFranchise.isFranchise("franchise"))
        #expect(!MusicFranchise.isFranchise(nil))
        #expect(!MusicFranchise.isFranchise("tv"))
    }

    // F3
    @Test func aSeriesReplyGivesCertificateRuntimeCastAndWikidata() throws {
        let json = """
        {"id": 7, "name": "Show", "first_air_date": "2020-01-02", "episode_run_time": [0, 45], "original_language": "en",
         "content_ratings": {"results": [{"iso_3166_1": "GB", "rating": "15"}, {"iso_3166_1": "US", "rating": "TV-MA"}]},
         "external_ids": {"wikidata_id": "Q123"},
         "credits": {"cast": [{"id": 2, "name": "B", "character": "Bee", "order": 1}, {"id": 1, "name": "A", "character": "Self", "order": 0}, {"id": 3, "name": "C", "character": "Cee", "order": 0}]}}
        """
        let f = TMDBGraphSource.facts(data(json))
        #expect(f["certification"] == "TV-MA")
        #expect(f["certificationRegion"] == "US")
        #expect(f["runtimeMinutes"] == "45")
        let b = try #require(TMDBGraphSource.seriesBatch(data(json), tmdbID: "7", now: Date()))
        let cast = b.claims.filter { $0.predicate == .hasCast }
        #expect(cast.count == 2)   // "Self" is a walk-on
        #expect(b.drafts.first?.entity.externalIDs.contains(ExternalID(.wikidata, "Q123")) == true)
    }

    @Test func aSeriesCrewBecomesPeopleWithTheirTMDBIds() throws {
        let json = """
        {"id": 7, "name": "Show", "first_air_date": "2020-01-02",
         "credits": {"cast": [], "crew": [{"id": 7, "name": "Ravi", "job": "Director of Photography"}, {"id": 8, "name": "Sita", "job": "Editor"}]}}
        """
        let b = try #require(TMDBGraphSource.seriesBatch(data(json), tmdbID: "7", now: Date()))
        let ids = b.drafts.flatMap { $0.entity.externalIDs }
        #expect(ids.contains(ExternalID(.tmdbPerson, "7")) && ids.contains(ExternalID(.tmdbPerson, "8")))
    }

    @Test func aCollectionBecomesTheFilmsFranchise() throws {
        let json = #"{"id": 1, "title": "Part Two", "release_date": "2003-05-01", "belongs_to_collection": {"id": 2344, "name": "The Matrix Collection"}, "credits": {"cast": [], "crew": []}}"#
        let c = try #require(TMDBGraphSource.collection(data(json)))
        #expect(c.name == "The Matrix")
        let b = try #require(TMDBGraphSource.filmBatch(data(json), now: Date()))
        #expect(b.claims.contains { $0.predicate == .inFranchise })
        #expect(b.drafts.contains { $0.entity.subkind == "franchise" })
    }

    // F4
    @Test func theSongCapStopsOriginalAlbumsButNeverADub() {
        let cap = MusicFilmGraphReading.songsTotal
        #expect(MusicFilmGraphReading.reads(album("o"), haveSongs: cap - 1))
        #expect(!MusicFilmGraphReading.reads(album("o"), haveSongs: cap))
        #expect(MusicFilmGraphReading.reads(album("d", dub: "te"), haveSongs: cap))
    }

    // F5
    @Test func aRowQueuesTheWholeContextWhenItHoldsTheTrack() {
        func t(_ id: String) -> MusicTrack { MusicTrack(id: id, providerID: "p", title: id, durationMs: 1000, artists: []) }
        let shown = [t("a"), t("b")], context = [t("a"), t("b"), t("c")]
        #expect(MusicTrackList.queue(for: t("b"), shown: shown, context: context).count == 3)
        #expect(MusicTrackList.queue(for: t("z"), shown: shown, context: context).count == 2)
        #expect(MusicTrackList.queue(for: t("a"), shown: shown, context: nil).count == 2)
    }

    // cast roles
    @Test func characterTextStatesTheKindOfAppearance() {
        #expect(MusicFilmCastRoles.appearance(character: "Simba (voice)") == .voice)
        #expect(MusicFilmCastRoles.appearance(character: "Narrator") == .narrator)
        #expect(MusicFilmCastRoles.appearance(character: "Doctor (cameo)") == .cameo)
        #expect(MusicFilmCastRoles.appearance(character: "Raju") == nil)
        let p = MusicFilmCastRoles.partition([person("A", character: "Raju", order: 0), person("B", character: "Lion (voice)", order: 1)])
        #expect(p.main.map(\.name) == ["A"])
        #expect(p.byAppearance.first?.0 == .voice)
    }

    // About
    @Test func aReleaseDateIsWrittenAsTheDayItWasStated() {
        // Read at midnight UTC and written in UTC, so no time zone moves it to the day before.
        let text = MusicFilmAboutSection.displayDate("2019-05-03")
        let day = Date(timeIntervalSince1970: 1_556_841_600)   // 2019-05-03 00:00 UTC
        let expected = day.formatted(Date.FormatStyle(locale: Locale(identifier: Localized.activeCode), timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt).day().month(.wide).year())
        #expect(text == expected, "the day as stated, in the app's language, never the day before")
        #expect(MusicFilmAboutSection.displayDate("2019") == "2019", "a value that is not a full date is shown as it came")
    }

    @Test func aFilmIsSharedByAnIdOtherSystemsKnow() {
        let film = MusicEntityID.derive(kind: .film, aliasKey: "share-film")
        let tmdb = MusicFilmShare.url(entity: film, externalIDs: [ExternalID(.wikidata, "Q858681"), ExternalID(.tmdbMovie, "39039")])
        #expect(tmdb?.absoluteString.contains("ext") == true && tmdb?.absoluteString.contains("39039") == true)
        let own = MusicFilmShare.url(entity: film, externalIDs: [ExternalID(.provider, "p:1")])
        #expect(own == MusicDeepLinks.link(entity: .entity(film, role: nil)), "no shareable id: the page's own id is the fallback")
    }

    @Test func aboutListsOtherNamesAndDubsButNoSourceIdentifiers() {
        let aliases = [NameAlias("Film"), NameAlias("Pelicula", lang: "es"), NameAlias("pelicula", lang: "es")]
        let rows = MusicFilmIdentifiers.rows(aliases: aliases, title: "Film", dubLanguages: [nil, "te", "te"])
        #expect(rows.filter { $0.1.contains("Pelicula") }.count == 1)
        #expect(rows.first { $0.1.contains("Film") } == nil)
        #expect(rows.count == 2, "other names and the dubbed languages, nothing else")
        #expect(!rows.contains { $0.0.hasSuffix(" ID") }, "no IMDb, TMDB or Wikidata id row: Music's pages never name a source")
        #expect(MusicFilmIdentifiers.dubbedLanguages([nil, nil]) == nil)
    }
}
