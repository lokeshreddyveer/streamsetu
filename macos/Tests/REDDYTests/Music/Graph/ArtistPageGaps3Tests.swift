import Foundation
import Testing
@testable import REDDY

private func eid(_ k: MusicEntityKind, _ n: String) -> MusicEntityID { .derive(kind: k, aliasKey: "artist-gaps3-" + n) }

private func entry(_ name: String, kind: MusicEntityKind = .recording, year: Int? = nil, lang: String? = nil, roles: [MusicRole] = [], count: Int? = nil, version: String? = nil) -> MusicPersonEntry {
    var e = MusicPersonEntry(id: eid(kind, name), name: name, kind: kind)
    e.year = year; e.lang = lang; e.roles = roles; e.count = count; e.versionKind = version
    return e
}

private func track(_ id: String, _ title: String, provider: String = "p") -> MusicTrack {
    MusicTrack(id: id, providerID: provider, title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "a1", name: "Singer")])
}

struct ArtistPageGaps3Tests {
    @Test func mergedPeopleKeepEveryRoleAndTheLargestCount() {
        let who = entry("Both", kind: .person, roles: [.lyricist], count: 3)
        var other = who; other.roles = [.composer]; other.count = 7
        let a = MusicPersonSection(.composers, [who]), b = MusicPersonSection(.composersWorkedWith, [other])
        let merged = MusicPersonViewData.condensed([a, b]).first { $0.id == .collaborations }
        let e = merged?.entries.first
        #expect(merged?.entries.count == 1)
        #expect(e?.roles == [.composer, .lyricist])
        #expect(e?.count == 7)
    }

    @Test func theSameAlbumInTwoSectionsIsOneEdition() {
        let alb = entry("Solo", kind: .album, year: 2001)
        let folded = MusicArtistCatalog.foldAlbums(sections: [MusicPersonSection(.albums, [alb]), MusicPersonSection(.soloCareers, [alb])])
        #expect(folded.count == 1)
        #expect(folded.first?.editions == 1)
    }

    @Test func personalPlaysMatchByProviderIdBeforeTitle() {
        let studio = entry("Song")
        var liveOnly = MusicPersonEntry(id: eid(.recording, "Song live"), name: "Song", kind: .recording)
        liveOnly.versionKind = "live"
        let identity = MusicArtistIdentity(providerID: nil, artistID: nil, name: "Singer")
        let history = [PlayRecord(track: track("1", "Song"), playedMs: 200_000), PlayRecord(track: track("1", "Song"), playedMs: 200_000)]
        let uids = [studio.id: ["p:1"], liveOnly.id: ["p:2"]]
        let p = MusicArtistPersonal.build(history: history, liked: [track("1", "Song")], identity: identity, uids: uids)
        #expect(p.playCount(studio) == 2)
        #expect(p.playCount(liveOnly) == 0)
        #expect(p.isLiked(studio))
        #expect(!p.isLiked(liveOnly))
    }

    @Test func aSongWithNoIdsFallsBackToItsTitle() {
        let s = entry("Plain")
        let identity = MusicArtistIdentity(providerID: nil, artistID: nil, name: "Singer")
        let p = MusicArtistPersonal.build(history: [PlayRecord(track: track("9", "Plain"), playedMs: 200_000)], liked: [], identity: identity)
        #expect(p.playCount(s) == 1)
    }

    @Test func unplayedUsesIdsWhenTheCatalogHasThem() {
        let studio = entry("Song"), other = entry("Other")
        let identity = MusicArtistIdentity(providerID: nil, artistID: nil, name: "Singer")
        let stats = MusicArtistListening.compute(history: [PlayRecord(track: track("1", "Song"), playedMs: 200_000)], identity: identity, songs: [studio, other], uids: [studio.id: ["p:1"]])
        #expect(stats.unplayed.map(\.name) == ["Other"])
        #expect(stats.top.first?.track?.uid == "p:1")
    }

    @Test func filmFilterNarrowsByDirectorAndGenre() {
        let f1 = entry("F1", kind: .film), f2 = entry("F2", kind: .film)
        let d1 = MusicFilmFacet(id: eid(.person, "d1"), name: "D1"), d2 = MusicFilmFacet(id: eid(.person, "d2"), name: "D2")
        let g = MusicFilmFacet(id: eid(.genre, "drama"), name: "Drama")
        let facts = MusicArtistFilmFacts(directors: [f1.id: [d1], f2.id: [d2]], genres: [f1.id: [g]])
        var filter = MusicArtistFilmFilter()
        filter.director = d2.id
        #expect(filter.apply(to: [f1, f2], soundtracks: [], facts: facts).map(\.name) == ["F2"])
        filter = MusicArtistFilmFilter(); filter.genre = g.id
        #expect(filter.apply(to: [f1, f2], soundtracks: [], facts: facts).map(\.name) == ["F1"])
        #expect(filter.isActive)
        let chips = MusicArtistFilmFacts.chips(facts.directors, films: [f1, f2], exclude: d1.id)
        #expect(chips.map(\.facet.name) == ["D2"])
    }

    @Test func firstWorkInAnotherLanguageIsAMilestone() {
        var c = MusicArtistCatalog(view: .singer)
        c.songs = [entry("A", year: 1990, lang: "te"), entry("B", year: 1992, lang: "te"), entry("B2", year: 1993, lang: "te"), entry("C", year: 1998, lang: "hi"), entry("D", year: 2003, lang: "hi")]
        let m = MusicArtistMilestones.newLanguageMilestones(c)
        #expect(m.count == 1)
        #expect(m.first?.year == 1998)
        #expect(m.first?.kind == .newLanguage)
        var one = MusicArtistCatalog(view: .singer); one.songs = [entry("A", year: 1990, lang: "te")]
        #expect(MusicArtistMilestones.newLanguageMilestones(one).isEmpty)
    }

    @Test func combineSummaryNamesTheLanguagesOfTheSharedSongs() {
        let s = MusicCombineSummary.build([entry("A", lang: "te"), entry("B", lang: "te"), entry("C", lang: "hi")])
        #expect(s.languages == ["te", "hi"])
        #expect(!s.isEmpty)
    }

    @Test func aSongRowNamesOnlyANonMainCredit() {
        #expect(MusicArtistWording.songRole(entry("A", roles: [.singer])) == nil)
        #expect(MusicArtistWording.songRole(entry("A", roles: [.featured])) != nil)
        #expect(MusicArtistWording.songRole(entry("A")) == nil)
    }

    @Test func sectionsOfRolesWithoutARelatedShelfNowHaveOne() {
        for v in [MusicPersonView.lyricist, .producer, .instrumentalist, .conductor, .label] {
            #expect(MusicPersonSectionID.order(for: v).contains(.relatedArtists))
        }
        #expect(MusicPersonWording.reason(.sharedCollaborators(3)) != nil)
    }

    @MainActor @Test func resettingFavoritesEmptiesMemoryAndTheSavedList() {
        let suite = "artist-gaps3-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let f = MusicFavoriteArtists(defaults: d)
        f.toggle(eid(.person, "x"))
        #expect(f.isFavorite(eid(.person, "x")))
        f.reset()
        #expect(!f.isFavorite(eid(.person, "x")))
        #expect(d.stringArray(forKey: MusicFavoriteArtists.key) == nil)
    }

    @MainActor @Test func theFavouritesMergeCheckSkipsAnUnchangedSetForAWhile() {
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(MusicFavoriteArtists.needsAdopt(signature: ["a"], lastSignature: [], lastAt: nil, now: t))
        #expect(!MusicFavoriteArtists.needsAdopt(signature: ["a"], lastSignature: ["a"], lastAt: t, now: t.addingTimeInterval(10)))
        #expect(MusicFavoriteArtists.needsAdopt(signature: ["a", "b"], lastSignature: ["a"], lastAt: t, now: t.addingTimeInterval(10)))
        #expect(MusicFavoriteArtists.needsAdopt(signature: ["a"], lastSignature: ["a"], lastAt: t, now: t.addingTimeInterval(MusicFavoriteArtists.adoptInterval + 1)))
    }

    @MainActor @Test func theProviderLookupIsRetriedOnlyWhenItFoundNothingAndHasFinished() {
        #expect(MusicPersonPlayback.shouldPrefetch(started: false, retry: false, hasProviderArtist: false, finished: false))
        #expect(!MusicPersonPlayback.shouldPrefetch(started: true, retry: false, hasProviderArtist: false, finished: true))
        #expect(MusicPersonPlayback.shouldPrefetch(started: true, retry: true, hasProviderArtist: false, finished: true))
        #expect(!MusicPersonPlayback.shouldPrefetch(started: true, retry: true, hasProviderArtist: false, finished: false))
        #expect(!MusicPersonPlayback.shouldPrefetch(started: true, retry: true, hasProviderArtist: true, finished: true))
    }

    @Test func theHighlightedPillIsTheOneShownWhenTheSavedPillIsMissing() {
        #expect(MusicArtistPills.active(.songs, in: [.overview, .about]) == .overview)
        #expect(MusicArtistPills.active(.songs, in: [.overview, .songs]) == .songs)
    }
}
