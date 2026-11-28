import Foundation
import Testing
@testable import REDDY

private func eid(_ k: MusicEntityKind, _ n: String) -> MusicEntityID { .derive(kind: k, aliasKey: "artist-gaps-" + n) }

private func song(_ name: String, year: Int? = nil, film: String? = nil, filmID: MusicEntityID? = nil, version: String? = nil, roles: [MusicRole] = []) -> MusicPersonEntry {
    var e = MusicPersonEntry(id: eid(.recording, name + "\(year ?? 0)" + (filmID?.rawValue ?? "")), name: name, kind: .recording)
    e.year = year; e.filmTitle = film; e.filmID = filmID; e.versionKind = version; e.roles = roles
    return e
}

private func claim(_ p: String, _ q: String, rank: String = "normal") -> String {
    #""\#(p)":[{"rank":"\#(rank)","mainsnak":{"datavalue":{"value":{"id":"\#(q)"}}}}]"#
}

private func entityJSON(_ qid: String, claims: [String]) -> Data {
    Data(#"{"entities":{"\#(qid)":{"claims":{\#(claims.joined(separator: ","))}}}}"#.utf8)
}

private func labelsJSON(_ labels: [String: String]) -> Data {
    let body = labels.map { #""\#($0.key)":{"labels":{"en":{"value":"\#($0.value)"}}}"# }.joined(separator: ",")
    return Data(#"{"entities":{\#(body)}}"#.utf8)
}

/// Answers the claims and the labels of one person; fails every call while `fail` is set.
private final class FactsTransport: MusicMetadataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _fail = true, _calls = 0
    let claims: Data, labels: Data
    init(claims: Data, labels: Data) { self.claims = claims; self.labels = labels }
    var fail: Bool { get { lock.lock(); defer { lock.unlock() }; return _fail } set { lock.lock(); _fail = newValue; lock.unlock() } }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    /// Counts a call and says whether it should fail (kept out of the async function: a lock cannot be held across an await there).
    private func bump() -> Bool { lock.lock(); defer { lock.unlock() }; _calls += 1; return _fail }
    func get(_ url: URL, query: [String: String], headers: [String: String]) async throws -> Data {
        let failing = bump()
        if failing { throw URLError(.timedOut) }
        return query["props"] == "claims" ? claims : labels
    }
}

@Suite("Artist page gaps") struct ArtistPageGapsTests {
    // MARK: Wikidata facts

    @Test func factsReadPlacesInstrumentsGenresLabelsWebsiteAndYears() throws {
        let data = entityJSON("Q1", claims: [claim("P19", "Q10"), claim("P69", "Q11"), claim("P1303", "Q12"), claim("P136", "Q13"), claim("P264", "Q14"),
                                             #""P856":[{"mainsnak":{"datavalue":{"value":"https://example.com/artist"}}}]"#,
                                             #""P2031":[{"mainsnak":{"datavalue":{"value":{"time":"+1975-00-00T00:00:00Z"}}}}]"#,
                                             #""P2032":[{"mainsnak":{"datavalue":{"value":{"time":"+2005-00-00T00:00:00Z"}}}}]"#])
        let raw = try #require(MusicPersonFactsRules.parse(data, qid: "Q1"))
        #expect(raw.birthPlace == ["Q10"] && raw.activeFrom == 1975 && raw.activeTo == 2005 && raw.website == "https://example.com/artist")
        let f = MusicPersonFactsRules.facts(raw, labels: ["Q10": "Chennai", "Q11": "A College", "Q12": "Veena", "Q13": "Carnatic", "Q14": "A Label"])
        #expect(f.birthPlace == "Chennai" && f.education == ["A College"] && f.instruments == ["Veena"] && f.genres == ["Carnatic"] && f.labels == ["A Label"])
        #expect(MusicPersonFactsRules.activeYears(f)?.from == 1975 && MusicPersonFactsRules.activeYears(f)?.to == 2005)
        #expect(MusicPersonFactsRules.displayHost("https://www.example.com/x") == "example.com")
    }

    @Test func factsSkipDeprecatedClaimsUnlabelledItemsAndBadWebsites() throws {
        let data = entityJSON("Q2", claims: [claim("P136", "Q20", rank: "deprecated"), claim("P1303", "Q21"),
                                             #""P856":[{"mainsnak":{"datavalue":{"value":"javascript:alert(1)"}}}]"#])
        let raw = try #require(MusicPersonFactsRules.parse(data, qid: "Q2"))
        #expect(raw.genres.isEmpty && raw.website == nil)
        #expect(MusicPersonFactsRules.facts(raw, labels: [:]).isEmpty, "an item with no label says nothing")
        #expect(MusicPersonFactsRules.cleanWebsite("ftp://example.com") == nil && MusicPersonFactsRules.cleanWebsite("http://example.com") != nil)
    }

    @Test func aGroupUsesItsFormingYearsAndAnEndBeforeTheStartIsDropped() throws {
        let data = entityJSON("Q3", claims: [#""P571":[{"mainsnak":{"datavalue":{"value":{"time":"+1990-00-00T00:00:00Z"}}}}]"#,
                                             #""P576":[{"mainsnak":{"datavalue":{"value":{"time":"+1980-00-00T00:00:00Z"}}}}]"#])
        let f = MusicPersonFactsRules.facts(try #require(MusicPersonFactsRules.parse(data, qid: "Q3")), labels: [:])
        #expect(f.activeFrom == 1990 && f.activeTo == nil)
    }

    @Test func aFailedFactsReadIsNotRememberedAndASuccessIsAskedOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = MusicPersonFactsLoader(directory: dir)
        let t = FactsTransport(claims: entityJSON("Q5", claims: [claim("P19", "Q10")]), labels: labelsJSON(["Q10": "Hyderabad"]))
        #expect(await loader.facts(qid: "Q5", readingLanguages: ["en"], transport: t) == nil)
        t.fail = false
        let ok = await loader.facts(qid: "Q5", readingLanguages: ["en"], transport: t)
        #expect(ok?.birthPlace == "Hyderabad", "the failure was not kept")
        let before = t.calls
        #expect(await loader.facts(qid: "Q5", readingLanguages: ["en"], transport: t)?.birthPlace == "Hyderabad")
        #expect(t.calls == before, "a whole answer is remembered")
        #expect(await loader.facts(qid: "not-an-id", readingLanguages: ["en"], transport: t) == nil)
    }

    // MARK: biography cache

    @Test func aPartialBiographyAnswerIsKeptAnHourAndNeverOnDisk() throws {
        var info = MusicPersonWikiInfo(qid: "Q1", description: nil, extract: nil, extractLanguage: nil, nativeLanguage: "te", portraitFile: nil, fetchedAt: Date())
        #expect(MusicPersonWikiInfoLoader.keep(info) == MusicPersonWikiInfoLoader.hit)
        info.partial = true
        #expect(MusicPersonWikiInfoLoader.keep(info) == MusicPersonWikiInfoLoader.partialKeep)
        #expect(MusicPersonWikiInfoLoader.keep(nil) == MusicPersonWikiInfoLoader.miss)
        let old = Data(#"{"qid":"Q1","nativeLanguage":"te","fetchedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(MusicPersonWikiInfo.self, from: old).partial == nil, "files saved before the flag existed still read")
    }

    // MARK: recording type and performance

    @Test func aLiveTypeFromATitleWordIsNotTrustedButATaggedOneIs() {
        #expect(MusicSongPerformance.trustedVersionKind(["versionKind": "live", "versionEvidence": "title-live"]) == nil)
        #expect(MusicSongPerformance.trustedVersionKind(["versionKind": "live", "versionTags": "live"]) == "live")
        #expect(MusicSongPerformance.trustedVersionKind(["versionKind": "remix", "versionEvidence": "title-remix"]) == "remix")
        #expect(MusicSongPerformance.trustedVersionKind([:]) == nil)
    }

    @Test func performanceFilterUsesOnlyWhatTheGraphStates() {
        let songs = [song("A", version: "live"), song("B", version: "remix"), song("C", roles: [.featured]), song("D")]
        #expect(MusicSongPerformance.of(songs[3]).isEmpty)
        var f = MusicArtistSongFilter(); f.performance = .live
        #expect(f.apply(to: songs).map(\.name) == ["A"])
        f.performance = .featured
        #expect(f.apply(to: songs).map(\.name) == ["C"])
        #expect(MusicSongPerformance.facets(in: songs).map(\.kind) == [.live, .remix, .featured])
    }

    // MARK: songs filters and sort

    @Test func yearRangeLikedAndMostPlayedWorkFromLocalData() {
        let songs = [song("Old", year: 1990), song("Mid", year: 2000), song("New", year: 2010), song("NoYear")]
        var f = MusicArtistSongFilter(); f.yearFrom = 1995; f.yearTo = 2005
        #expect(f.apply(to: songs).map(\.name) == ["Mid"])
        f.yearFrom = 2005; f.yearTo = 1995
        #expect(f.apply(to: songs).map(\.name) == ["Mid"], "a range given backwards is the same span")
        f = MusicArtistSongFilter(); f.yearFrom = 2000
        #expect(f.apply(to: songs).map(\.name) == ["Mid", "New"], "a song with no year is not placed in a range")
        var p = MusicArtistPersonal()
        p.plays[MusicArtistPersonal.key("New")] = 5; p.plays[MusicArtistPersonal.key("Old")] = 2; p.liked = [MusicArtistPersonal.key("Old")]
        f = MusicArtistSongFilter(); f.likedOnly = true
        #expect(f.apply(to: songs, personal: p).map(\.name) == ["Old"])
        f = MusicArtistSongFilter(); f.sort = .mostPlayed
        #expect(f.apply(to: songs, personal: p).map(\.name) == ["New", "Old", "Mid", "NoYear"])
        #expect(f.isActive == false && MusicArtistSongFilter(likedOnly: true).isActive)
    }

    @Test func personalCountsMatchTheArtistByIdAndCountOnlyRealPlays() {
        let identity = MusicArtistIdentity(providerID: "p", artistID: "a1", name: "Asha")
        func t(_ id: String, _ title: String, _ artist: String) -> MusicTrack { MusicTrack(id: id, providerID: "p", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: artist, name: "Asha")]) }
        let mine = t("1", "Song One", "a1"), other = t("2", "Song Two", "a2")
        let history = [PlayRecord(track: mine, at: Date(), playedMs: 150_000), PlayRecord(track: mine, at: Date(), playedMs: 150_000),
                       PlayRecord(track: mine, at: Date(), playedMs: 1_000), PlayRecord(track: other, at: Date(), playedMs: 150_000)]
        let p = MusicArtistPersonal.build(history: history, liked: [mine, other], identity: identity)
        #expect(p.plays[MusicArtistPersonal.key("Song One")] == 2 && p.plays[MusicArtistPersonal.key("Song Two")] == nil)
        #expect(p.liked == [MusicArtistPersonal.key("Song One")])
    }

    // MARK: the film choice is by id

    @Test func twoFilmsWithOneTitleAreTwoChipsAndTwoFilters() {
        let f1 = eid(.film, "don-1978"), f2 = eid(.film, "don-2006")
        var a = song("S1", year: 1978, film: "Don", filmID: f1); a.year = 1978
        var b = song("S2", year: 2006, film: "Don", filmID: f2); b.year = 2006
        let chips = MusicArtistFacets.films(in: [a, b])
        #expect(chips.count == 2 && chips.allSatisfy { $0.title.contains("(") }, "the year tells the two apart")
        var filter = MusicArtistSongFilter(); filter.film = f2.rawValue
        #expect(filter.apply(to: [a, b]).map(\.name) == ["S2"])
        let plain = MusicArtistFacets.films(in: [song("X", film: "Solo", filmID: eid(.film, "solo"))])
        #expect(plain.first?.title == "Solo")
    }

    // MARK: album types and radio modes

    @Test func compilationsAndScoresAreTheirOwnAlbumTypes() {
        func album(_ sub: String) -> MusicPersonEntry { var e = MusicPersonEntry(id: eid(.album, sub), name: sub, kind: .album); e.subkind = sub; return e }
        #expect(MusicArtistCatalog.albumType(of: album("compilation"), in: .albums) == .compilation)
        #expect(MusicArtistCatalog.albumType(of: album("score"), in: .soundtracks) == .score)
        #expect(MusicArtistCatalog.albumType(of: album("soundtrack"), in: .soundtracks) == .soundtrack)
        #expect(MusicArtistCatalog.albumType(of: album("album"), in: .albums) == .album)
    }

    @Test func newRadioModesAreBoundedAndOnlyOfferedWithData() {
        var c = MusicArtistCatalog(view: .singer)
        let film = eid(.film, "f")
        c.songs = (0..<80).map { song("S\($0)", year: 1990 + $0 % 30, film: $0 % 2 == 0 ? "F" : nil, filmID: $0 % 2 == 0 ? film : nil, version: $0 % 10 == 0 ? "live" : nil) }
        c.primarySongs = Array(c.songs.prefix(30))
        let modes = MusicArtistRadioMode.options(c).map(\.mode)
        #expect(modes.contains(.filmMusic) && modes.contains(.recent) && modes.contains(.performance(.live)) && !modes.contains(.liked))
        var g = SystemRandomNumberGenerator()
        for m in [MusicArtistRadioMode.filmMusic, .recent, .performance(.live)] { #expect(MusicArtistRadioMode.ids(m, in: c, using: &g).count <= MusicArtistPlayCap.songs) }
        #expect(MusicArtistRadioMode.recentSongs(c).count == MusicArtistRadioMode.recentPool)
        var p = MusicArtistPersonal(); p.liked = [MusicArtistPersonal.key("S1"), MusicArtistPersonal.key("S2")]
        #expect(MusicArtistRadioMode.options(c, personal: p).map(\.mode).contains(.liked))
        #expect(Set(MusicArtistRadioMode.ids(.liked, in: c, personal: p, using: &g)).count == 2)
    }

    // MARK: spotlight, milestones, film credit filter

    @Test func latestReleaseIsTheNewestYearAndNoneWithoutYears() {
        var c = MusicArtistCatalog(view: .singer)
        func alb(_ n: String, _ y: Int?, _ t: MusicAlbumType) -> MusicArtistAlbum { var e = MusicPersonEntry(id: eid(.album, n), name: n, kind: .album); e.year = y; return MusicArtistAlbum(entry: e, type: t, editions: 1) }
        #expect(MusicArtistSpotlight.latest(c) == nil)
        c.albums = [alb("Old", 1999, .album), alb("Undated", nil, .album), alb("NewSingle", 2020, .single), alb("NewAlbum", 2020, .album)]
        #expect(MusicArtistSpotlight.latest(c)?.entry.name == "NewAlbum")
        c.albums = [alb("Undated", nil, .album)]
        #expect(MusicArtistSpotlight.latest(c) == nil)
    }

    @Test func milestonesAreOldestFirstWithAwardsByYear() {
        var c = MusicArtistCatalog(view: .singer)
        var a = MusicPersonEntry(id: eid(.album, "first"), name: "First", kind: .album); a.year = 1995
        var b = MusicPersonEntry(id: eid(.album, "last"), name: "Last", kind: .album); b.year = 2015
        c.albums = [MusicArtistAlbum(entry: b, type: .album, editions: 1), MusicArtistAlbum(entry: a, type: .album, editions: 1)]
        c.songs = [song("Early", year: 1993)]
        let m = MusicArtistMilestones.build(catalog: c, awards: [MusicPersonAward(qid: "Q1", label: "Big Prize", year: 2001), MusicPersonAward(qid: "Q2", label: "No year", year: nil)], activeFrom: 1990)
        #expect(m.map(\.year) == [1990, 1993, 1995, 2001, 2015])
        #expect(m.map(\.kind) == [.careerStart, .earliestSong, .earliestAlbum, .award, .latestRelease])
        #expect(MusicArtistMilestones.build(catalog: MusicArtistCatalog(view: .singer), awards: [], activeFrom: nil).isEmpty)
    }

    @Test func anActorOrDirectorTimelineCreditsNoLatestRelease() {
        var a = MusicPersonEntry(id: eid(.album, "ost"), name: "Film OST", kind: .album); a.year = 2015
        for view in [MusicPersonView.actor, .director] {
            var c = MusicArtistCatalog(view: view)
            c.albums = [MusicArtistAlbum(entry: a, type: .soundtrack, editions: 1)]
            let m = MusicArtistMilestones.build(catalog: c, awards: [], activeFrom: nil)
            #expect(!m.contains { $0.kind == .latestRelease })
        }
    }

    @MainActor @Test func theFilmDirectorAndGenreSurviveBack() {
        var s = MusicArtistPageSnapshot()
        s.pill = .films; s.filmDirector = eid(.person, "dir"); s.filmGenre = eid(.genre, "gen")
        let e = s.encoded()
        #expect(e.filters.values.allSatisfy { $0.count <= 64 })
        #expect(MusicArtistPageSnapshot.decode(tab: e.tab, filters: e.filters) == s)
        #expect(MusicArtistPageState(restoring: s).filmFilter.director == s.filmDirector)
    }

    @Test func filmCreditAndSoundtrackFiltersUseTheCatalogOnly() {
        let f1 = eid(.film, "f1"), f2 = eid(.film, "f2")
        var a = MusicPersonEntry(id: f1, name: "A", kind: .film); a.roles = [.actor]
        var b = MusicPersonEntry(id: f2, name: "B", kind: .film); b.roles = [.director]
        var ost = MusicPersonEntry(id: eid(.album, "ost"), name: "A OST", kind: .album); ost.filmID = f1
        var c = MusicArtistCatalog(view: .actor); c.films = [a, b]; c.albums = [MusicArtistAlbum(entry: ost, type: .soundtrack, editions: 1)]
        let st = MusicArtistFilmFilter.soundtrackFilms(c)
        #expect(st == [f1])
        #expect(MusicArtistFilmFilter(role: .director).apply(to: c.films, soundtracks: st).map(\.name) == ["B"])
        #expect(MusicArtistFilmFilter(withSoundtrack: true).apply(to: c.films, soundtracks: st).map(\.name) == ["A"])
        #expect(MusicArtistFilmFilter.roles(in: c.films).count == 2 && !MusicArtistFilmFilter().isActive)
    }

    // MARK: favorites, share, memory, combine

    @MainActor @Test func favoritesAreKeptByIdAndSeparateFromFollow() {
        let a = eid(.person, "a"), b = eid(.person, "b")
        var s = MusicFavoriteArtistSet()
        s.toggle(a); s.toggle(b)
        #expect(s.contains(a) && s.contains(b) && s.ids.first == b.rawValue)
        s.toggle(a)
        #expect(!s.contains(a) && s.contains(b))
        #expect(MusicFavoriteArtistSet(ids: ["x", "x", ""]).ids == ["x"])
        let suite = UserDefaults(suiteName: "artist-gaps-" + UUID().uuidString)!
        MusicFavoriteArtists(defaults: suite).toggle(a)
        #expect(MusicFavoriteArtists(defaults: suite).isFavorite(a), "a favorite survives a restart")
    }

    @Test func shareLinkPrefersTheAppThenWikipediaThenWikidata() {
        let app = URL(string: "streamsetu://music/artist/x")
        #expect(MusicArtistShareLink.url(appLink: app, sitelinks: "enwiki:A B", wikidataID: "Q1") == app)
        #expect(MusicArtistShareLink.url(appLink: nil, sitelinks: "tewiki:ఎ|enwiki:A B", wikidataID: "Q1")?.absoluteString == "https://en.wikipedia.org/wiki/A_B")
        #expect(MusicArtistShareLink.url(appLink: nil, sitelinks: nil, wikidataID: "Q42")?.absoluteString == "https://www.wikidata.org/wiki/Q42")
        #expect(MusicArtistShareLink.url(appLink: nil, sitelinks: nil, wikidataID: nil) == nil)
    }

    @Test func pageSnapshotRoundTripsWithinMemoryLimits() {
        var s = MusicArtistPageSnapshot()
        s.pill = .songs; s.songLanguage = "te"; s.songDecade = 1990; s.songSort = .mostPlayed; s.songPerformance = .live; s.yearFrom = 1991; s.yearTo = 2001; s.likedOnly = true
        s.year = 1994; s.albumType = .score; s.albumDecade = 2000; s.filmLanguage = "hi"; s.filmDecade = 1980; s.filmRole = .director; s.filmSoundtrack = true
        let e = s.encoded()
        #expect(e.filters.count <= 3 && e.filters.values.allSatisfy { $0.count <= 64 })
        #expect(MusicArtistPageSnapshot.decode(tab: e.tab, filters: e.filters) == s)
        #expect(MusicArtistPageSnapshot().encoded().tab == nil && MusicArtistPageSnapshot().encoded().filters.isEmpty)
        #expect(MusicArtistPageSnapshot.decode(tab: "nonsense", filters: ["artist.songs": "d=abc|zz"]) == MusicArtistPageSnapshot())
    }

    @MainActor @Test func aRestoredStateKeepsThePillAndFilters() {
        var s = MusicArtistPageSnapshot(); s.pill = .films; s.songLanguage = "ta"
        let st = MusicArtistPageState(restoring: s)
        #expect(st.pill == .films && st.songs.language == "ta" && st.snapshot == s)
        st.reset()
        #expect(st.pill == .overview && st.snapshot == MusicArtistPageSnapshot())
    }

    @Test func combineSummaryCountsFilmsAndYears() {
        let f = eid(.film, "cf"), g = eid(.film, "cg")
        let songs = [song("a", year: 1990, film: "F", filmID: f), song("b", year: 1994, film: "F", filmID: f), song("c", year: 1992, film: "G", filmID: g), song("d")]
        let s = MusicCombineSummary.build(songs)
        #expect(s.firstYear == 1990 && s.lastYear == 1994 && s.films.first?.id == f && s.films.first?.songs == 2 && s.films.count == 2)
        #expect(MusicCombineSummary.build([]).isEmpty)
    }
}
