import Foundation
import Testing
@testable import REDDY

/// A random source that always gives the same numbers, so the sampled sets can be compared.
private struct FixedRNG: RandomNumberGenerator {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

private func eid(_ k: MusicEntityKind, _ n: String) -> MusicEntityID { .derive(kind: k, aliasKey: "artist-test-" + n) }

private func entry(_ kind: MusicEntityKind, _ name: String, year: Int? = nil, lang: String? = nil, film: String? = nil, duration: Int? = nil,
                   roles: [MusicRole] = [], filmID: MusicEntityID? = nil, subkind: String? = nil, count: Int? = nil) -> MusicPersonEntry {
    var e = MusicPersonEntry(id: eid(kind, name + "\(year ?? 0)"), name: name, kind: kind)
    e.year = year; e.lang = lang; e.filmTitle = film; e.durationMs = duration; e.roles = roles; e.filmID = filmID; e.subkind = subkind; e.count = count
    return e
}

private func data(_ view: MusicPersonView, _ sections: [MusicPersonSection]) -> MusicPersonViewData {
    MusicPersonViewData(person: eid(.person, "p"), view: view, sections: sections, complete: true, truncated: false)
}

@Suite("Artist page") struct ArtistPageTests {
    // MARK: pills by role

    @Test func actorGetsNoSingingCreditsEvenIfASingerSectionIsPresent() {
        let d = data(.actor, [MusicPersonSection(.topSongs, [entry(.recording, "Sung", year: 2000)]),
                              MusicPersonSection(.songsFromMovies, [entry(.recording, "From a film", year: 2001)]),
                              MusicPersonSection(.filmography, [entry(.film, "Film A", year: 2001)])])
        let c = MusicArtistCatalog.build(d)
        #expect(c.songs.map(\.name) == ["From a film"])
        #expect(MusicArtistWording.songsTitle(.actor) != MusicArtistWording.songsTitle(.singer))
    }

    @Test func directorHasNoSongsPill() {
        let d = data(.director, [MusicPersonSection(.filmography, [entry(.film, "F1", year: 1990), entry(.film, "F2", year: 1995)]),
                                 MusicPersonSection(.topSongs, [entry(.recording, "Stray")])])
        let pills = MusicArtistPills.available(MusicArtistCatalog.build(d), hasListening: false, hasAbout: false)
        #expect(!pills.contains(.songs))
        #expect(pills.contains(.films) && pills.contains(.timeline))
    }

    @Test func composerGetsCompositionsWording() {
        #expect(MusicArtistWording.songsTitle(.composer) == Localized.string("Compositions"))
        let d = data(.composer, [MusicPersonSection(.popularCompositions, [entry(.recording, "Tune", year: 1999)])])
        #expect(MusicArtistCatalog.build(d).songs.count == 1)
    }

    @Test func emptyDataLeavesOnlyOverview() {
        let c = MusicArtistCatalog.build(data(.singer, []))
        #expect(MusicArtistPills.available(c, hasListening: false, hasAbout: false) == [.overview])
        #expect(MusicArtistPills.available(nil, hasListening: false, hasAbout: false) == [.overview])
        #expect(MusicArtistPills.available(nil, hasListening: false, hasAbout: true) == [.overview, .about])
    }

    @Test func listeningPillOnlyWithData() {
        let c = MusicArtistCatalog.build(data(.singer, [MusicPersonSection(.topSongs, [entry(.recording, "A")])]))
        #expect(!MusicArtistPills.available(c, hasListening: false, hasAbout: false).contains(.listening))
        #expect(MusicArtistPills.available(c, hasListening: true, hasAbout: false).contains(.listening))
    }

    @Test func songsAreDedupedAcrossSongSections() {
        let a = entry(.recording, "Same", year: 1990)
        let d = data(.singer, [MusicPersonSection(.topSongs, [a]), MusicPersonSection(.filmSongs, [a, entry(.recording, "Other", year: 1991)])])
        let c = MusicArtistCatalog.build(d)
        #expect(c.songs.count == 2)
        #expect(c.primarySongs.count == 1)
    }

    // MARK: filters and sort

    private var songs: [MusicPersonEntry] {
        [entry(.recording, "Zebra", year: 1991, lang: "te", film: "Film One", duration: 200_000),
         entry(.recording, "alpha", year: 2005, lang: "hi", film: "Film Two", duration: 300_000),
         entry(.recording, "Mango", year: 1999, lang: "te", film: "Film One"),
         entry(.recording, "Café", year: nil, lang: nil)]
    }

    @Test func filterByLanguageDecadeFilmAndYear() {
        var f = MusicArtistSongFilter()
        f.language = "te"
        #expect(f.apply(to: songs).map(\.name) == ["Zebra", "Mango"])
        f.decade = 1990
        #expect(f.apply(to: songs).count == 2)
        f.film = "Film Two"
        #expect(f.apply(to: songs).isEmpty)
        #expect(MusicArtistSongFilter().apply(to: songs, year: 2005).map(\.name) == ["alpha"])
    }

    @Test func searchIgnoresCaseAndAccentsAndReadsFilmTitle() {
        var f = MusicArtistSongFilter(); f.query = "cafe"
        #expect(f.apply(to: songs).map(\.name) == ["Café"])
        f.query = "film two"
        #expect(f.apply(to: songs).map(\.name) == ["alpha"])
    }

    @Test func sortsKeepMissingValuesLastAndAreStable() {
        var f = MusicArtistSongFilter()
        f.sort = .title
        #expect(f.apply(to: songs).map(\.name) == ["alpha", "Café", "Mango", "Zebra"])
        f.sort = .newest
        #expect(f.apply(to: songs).map(\.name) == ["alpha", "Mango", "Zebra", "Café"])
        f.sort = .oldest
        #expect(f.apply(to: songs).map(\.name) == ["Zebra", "Mango", "alpha", "Café"])
        f.sort = .duration
        #expect(f.apply(to: songs).map(\.name) == ["alpha", "Zebra", "Mango", "Café"])
    }

    @Test func playSetsAreBounded() {
        let many = (0..<200).map { entry(.recording, "S\($0)", year: 2000) }
        #expect(MusicArtistPlayCap.play(many).count == MusicArtistPlayCap.songs)
        var g = FixedRNG()
        let sampled = MusicArtistPlayCap.sample(many, using: &g)
        #expect(sampled.count == MusicArtistPlayCap.songs && Set(sampled).count == sampled.count)
    }

    // MARK: albums

    @Test func regionalEditionsOfOneSoundtrackAreOneRow() {
        let film = eid(.film, "f")
        let tel = entry(.album, "Hit (Original Motion Picture Soundtrack)", year: 2010, filmID: film)
        var hin = entry(.album, "Hit - Hindi", year: 2011, filmID: film); hin.id = eid(.album, "hin")
        let other = entry(.album, "Studio", year: 2015)
        let albums = MusicArtistCatalog.foldAlbums(sections: [MusicPersonSection(.soundtracks, [tel, hin]), MusicPersonSection(.albums, [other])])
        #expect(albums.count == 2)
        let ost = albums.first { $0.type == .soundtrack }
        #expect(ost?.editions == 2 && ost?.entry.year == 2010)
        #expect(albums.first { $0.type == .album }?.entry.name == "Studio")
    }

    @Test func albumTypesFollowTheSectionAndSubkind() {
        #expect(MusicArtistCatalog.albumType(of: entry(.album, "x"), in: .singles) == .single)
        #expect(MusicArtistCatalog.albumType(of: entry(.album, "x", subkind: "soundtrack"), in: .albums) == .soundtrack)
        #expect(MusicArtistCatalog.albumType(of: entry(.album, "x"), in: .albums) == .album)
    }

    // MARK: timeline

    @Test func timelinePicksAlbumThenFilmThenSongPerYear() {
        let t = MusicArtistTimeline.build(songs: [entry(.recording, "S1", year: 1990), entry(.recording, "S2", year: 1992)],
                                          albums: [entry(.album, "A1", year: 1990)], films: [entry(.film, "F1", year: 1991), entry(.film, "Bad", year: 1500)])
        #expect(t.map(\.year) == [1990, 1991, 1992])
        #expect(t[0].highlight?.name == "A1" && t[0].songs == 1 && t[0].albums == 1)
        #expect(t[1].highlight?.name == "F1")
        #expect(t[2].highlight?.name == "S2")
        #expect(MusicArtistTimeline.target(t[0]) == .songs && MusicArtistTimeline.target(t[1]) == .films)
    }

    @Test func timelineNeedsTwoYearsToShow() {
        let one = MusicArtistCatalog.build(data(.singer, [MusicPersonSection(.topSongs, [entry(.recording, "A", year: 1990)])]))
        #expect(!MusicArtistPills.available(one, hasListening: false, hasAbout: false).contains(.timeline))
        let two = MusicArtistCatalog.build(data(.singer, [MusicPersonSection(.topSongs, [entry(.recording, "A", year: 1990), entry(.recording, "B", year: 1995)])]))
        #expect(MusicArtistPills.available(two, hasListening: false, hasAbout: false).contains(.timeline))
    }

    // MARK: radio modes and explore

    @Test func radioModesAreBoundedAndOfferedOnlyWhenTheyDiffer() {
        var all = (0..<120).map { entry(.recording, "T\($0)", year: 1980 + $0 % 40, lang: $0 % 2 == 0 ? "te" : "hi") }
        all.append(entry(.recording, "Solo", year: 2020, lang: "te"))
        var c = MusicArtistCatalog(view: .singer)
        c.songs = all; c.primarySongs = Array(all.prefix(40))
        let opts = MusicArtistRadioMode.options(c).map(\.mode)
        #expect(opts.contains(.essentials) && opts.contains(.deepCuts) && opts.contains(.catalog) && opts.contains(.language("te")) && opts.contains(.decade(2020)))
        var g = FixedRNG()
        #expect(MusicArtistRadioMode.ids(.essentials, in: c, using: &g).count == MusicArtistPlayCap.essentials)
        let deep = MusicArtistRadioMode.ids(.deepCuts, in: c, using: &g)
        #expect(deep.count == MusicArtistPlayCap.songs)
        let top = Set(c.primarySongs.prefix(MusicArtistPlayCap.essentials).map(\.id))
        #expect(deep.allSatisfy { !top.contains($0) })
        #expect(MusicArtistRadioMode.ids(.language("hi"), in: c, using: &g).count == MusicArtistPlayCap.songs)
        var one = MusicArtistCatalog(view: .singer)
        one.songs = [all[0]]
        #expect(MusicArtistRadioMode.options(one).isEmpty)
    }

    @Test func exploreOffersOnlyChoicesThatNarrow() {
        var c = MusicArtistCatalog(view: .singer)
        c.songs = [entry(.recording, "a", year: 1990, lang: "te"), entry(.recording, "b", year: 1990, lang: "te")]
        #expect(MusicArtistExplore.options(c).isEmpty)
        c.songs.append(entry(.recording, "c", year: 2001, lang: "hi"))
        let o = MusicArtistExplore.options(c)
        #expect(o.languages.map(\.code) == ["te", "hi"] && o.decades.map(\.decade) == [2000, 1990])
        #expect(MusicArtistExplore.options(c, includeLanguages: false).languages.isEmpty)
    }

    // MARK: combine preset

    @Test func combinePresetPutsEachPersonInTheirRoleSlot() {
        let me = eid(.person, "me")
        let other = entry(.person, "Composer Co", roles: [.musicDirector])
        let p = MusicCombinePreset.make(person: me, personName: "Me", view: .singer, other: other)
        #expect(p.singer?.id == me && p.composer?.name == "Composer Co" && p.lyricist == nil)
        let actor = MusicCombinePreset.make(person: me, personName: "Me", view: .actor, other: entry(.person, "Star", roles: [.actor]))
        #expect(actor.isEmpty)
    }

    // MARK: listening

    private func record(_ title: String, artist: String, artistID: String = "", playedMs: Int64, at: Double, duration: Int64 = 200_000) -> PlayRecord {
        PlayRecord(track: MusicTrack(id: "t-" + title, providerID: "p", title: title, durationMs: duration, artists: [MusicArtistRef(id: artistID, name: artist)]),
                   at: Date(timeIntervalSince1970: at), playedMs: playedMs)
    }

    @Test func listeningCountsOnlyThisArtistAndUsesHomeRule() {
        let id = MusicArtistIdentity(providerID: "p", artistID: "a1", name: "Singer One")
        let h = [record("Song A", artist: "Singer One", playedMs: 150_000, at: 1000),
                 record("Song A", artist: "singer one", playedMs: 200_000, at: 3000),
                 record("Song B", artist: "Someone", artistID: "a1", playedMs: 190_000, at: 2000),
                 record("Skipped", artist: "Singer One", playedMs: 10_000, at: 4000),
                 record("Elsewhere", artist: "Other", artistID: "zz", playedMs: 200_000, at: 5000)]
        let catalog = [entry(.recording, "Song A"), entry(.recording, "Song B"), entry(.recording, "Song C")]
        let s = MusicArtistListening.compute(history: h, identity: id, songs: catalog)
        #expect(s.plays == 3)
        #expect(s.listenedMs == 150_000 + 200_000 + 190_000 + 10_000)
        #expect(s.first == Date(timeIntervalSince1970: 1000) && s.last == Date(timeIntervalSince1970: 3000))
        #expect(s.top.first?.title == "Song A" && s.top.first?.plays == 2)
        #expect(s.unplayed.map(\.name) == ["Song C"])
        #expect(s.hasData)
    }

    @Test func listeningWithNoHistoryHasNoData() {
        let s = MusicArtistListening.compute(history: [], identity: MusicArtistIdentity(providerID: nil, artistID: nil, name: "Nobody"), songs: [entry(.recording, "X")])
        #expect(!s.hasData && s.plays == 0 && s.top.isEmpty && s.first == nil)
    }

    // MARK: awards and stats

    @Test func awardsParseClaimsAndLabels() throws {
        let claims = #"{"entities":{"Q1":{"claims":{"P166":[{"mainsnak":{"datavalue":{"value":{"id":"Q10"}}},"qualifiers":{"P585":[{"datavalue":{"value":{"time":"+1994-00-00T00:00:00Z"}}}]}},{"mainsnak":{"datavalue":{"value":{"id":"Q11"}}},"rank":"deprecated"},{"mainsnak":{"datavalue":{"value":{"id":"Q12"}}}}]}}}}"#
        let parsed = MusicPersonAwardsRules.parseClaims(Data(claims.utf8), qid: "Q1")
        #expect(parsed == [.init(qid: "Q10", year: 1994), .init(qid: "Q12", year: nil)])
        let labels = #"{"entities":{"Q10":{"labels":{"en":{"value":"Award Ten"}}},"Q12":{"labels":{}}}}"#
        let map = MusicPersonAwardsRules.parseLabels(Data(labels.utf8), languages: ["hi", "en"])
        #expect(map == ["Q10": "Award Ten"])
        #expect(MusicPersonAwardsRules.awards(claims: parsed, labels: map).map(\.label) == ["Award Ten"])
    }

    @Test func statsCountOnlyLoadedData() {
        var c = MusicArtistCatalog(view: .singer)
        #expect(MusicArtistStats(c).isEmpty)
        c.songs = [entry(.recording, "a", year: 1990, lang: "te"), entry(.recording, "b", year: 2000, lang: "hi")]
        let s = MusicArtistStats(c)
        #expect(s.songs == 2 && s.languages.count == 2 && s.span == 1990...2000)
    }
}
