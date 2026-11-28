import Foundation
import Testing
@testable import REDDY

@Suite struct HomeRenderedFeedTests {
    private func feedWithGraph() -> HomeFeed {
        let t = HomePersona.track("a", "Song", artist: "Alpha Rao")
        var feed = HomeFeed(seed: 1, composedAt: HomePersona.now, mode: .full)
        let graph = HomeSection(id: "graph", kind: .graph, title: "Films", reason: nil, items: [])
        let picks = HomeSection(id: "rep", kind: .onRepeat, title: "On repeat", reason: nil, items: [HomeItem.make(t)])
        feed.sections = [graph, picks]
        return feed
    }

    @Test func theFilmsAndPeopleSectionSurvivesANeverPlayList() {
        let out = HomeFeed.rendered(feedWithGraph(), trackBlocked: { _ in true }, artistBlocked: { _ in false })
        let kinds = out.sections.map(\.kind)
        #expect(kinds == [.graph])
    }

    @Test func aSectionEmptiedByNeverPlayStillGoes() {
        let out = HomeFeed.rendered(feedWithGraph(), trackBlocked: { _ in true }, artistBlocked: { _ in false })
        #expect(out.sections.contains { $0.kind == .onRepeat } == false)
    }

    @Test func nothingBlockedKeepsEverySection() {
        let out = HomeFeed.rendered(feedWithGraph(), trackBlocked: { _ in false }, artistBlocked: { _ in false })
        #expect(out.sections.count == 2)
    }
}

@MainActor @Suite struct HomeRefreshTokenTests {
    @Test func refreshOnAnotherScreenLeavesListenNowAlone() {
        #expect(MusicHomeFeedModel.tokenAfterRefresh(4, onHome: false) == 4)
    }

    @Test func refreshOnListenNowCountsAsOne() {
        #expect(MusicHomeFeedModel.tokenAfterRefresh(4, onHome: true) == 5)
    }
}

@MainActor @Suite struct GenreFamilyWordsTests {
    @Test func anApostropheInsideAWordIsDropped() {
        #expect(MusicGenreFamilies.words("Children's") == "Childrens")
    }

    @Test func anAmpersandInsideAWordStays() {
        #expect(MusicGenreFamilies.words("Contemporary R&B") == "Contemporary R&B")
    }

    @Test func aFullStopInsideAWordIsDropped() {
        #expect(MusicGenreFamilies.words("P.Funk") == "PFunk")
    }

    @Test func aLoneAmpersandIsASeparator() {
        #expect(MusicGenreFamilies.words("Folk, World, & Country") == "Folk World Country")
    }
}

@Suite struct ExploreCountryListsTests {
    private let art = [MusicThumbnail(url: "https://e.org/c.jpg", width: 300, height: 300)]

    @Test func aWorldwideAlbumListIsNotACountrysList() {
        let album = MusicAlbum(id: "a", providerID: "p", title: "Fresh", thumbnails: art)
        var top = MusicBrowseSection(id: "worldwide.albums", title: "Top albums", items: [.album(album)])
        top.scope = .global
        let part = MusicExploreComposition.Part(providerID: "x", regional: true, sections: [top], followsRegion: true)
        let r = MusicExploreComposition.compose([part], region: "fj")
        #expect(r.hasCountryLists == false)
        #expect(r.heroIsWorldwide)
    }

    @Test func aCountryListCountsAsOne() {
        let album = MusicAlbum(id: "a", providerID: "p", title: "Fresh", thumbnails: art)
        var own = MusicBrowseSection(id: "fj.albums", title: "Top albums", items: [.album(album)])
        own.scope = .regional("fj")
        let part = MusicExploreComposition.Part(providerID: "x", regional: true, sections: [own], followsRegion: true)
        let r = MusicExploreComposition.compose([part], region: "fj")
        #expect(r.hasCountryLists)
    }
}

@MainActor @Suite struct RecentlyAddedNewestTests {
    private let art = [MusicThumbnail(url: "https://e.org/c.jpg", width: 300, height: 300)]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15

    private func album(_ id: String, _ date: String) -> MusicAlbum {
        MusicAlbum(id: id, providerID: "p", title: "Album " + id, thumbnails: art, releaseDate: date)
    }

    @Test func aPreOrderNeverBeatsTheRealRecentAlbum() {
        let out = MusicRecentlyAddedPage.newestReleased([album("pre", "2030-12-15"), album("out", "2027-01-02")], now: now)
        #expect(out?.id == "out")
    }

    @Test func anArtistWithOnlyAFutureAlbumHasNone() {
        let out = MusicRecentlyAddedPage.newestReleased([album("pre", "2030-12-15")], now: now)
        #expect(out == nil)
    }

    @Test func aBareFutureYearIsInTheFuture() {
        #expect(MusicRecentlyAddedPage.isFuture("2031", now: now))
        #expect(MusicRecentlyAddedPage.isFuture("2027", now: now) == false)
        #expect(MusicRecentlyAddedPage.isFuture(nil, now: now) == false)
    }

    @Test func theTodayBucketIsGroupedLikeTheOthers() {
        var log = MusicFirstSeenLog()
        let item = MusicBrowseItem.album(album("x", "2027-01-02"))
        log.record([item], now: now)
        #expect(log.bucket(item, now: now) == .today)
    }
}

@Suite struct TasteOptionsTests {
    @Test func aFollowedArtistWhoIsAlsoTopIsListedOnce() {
        let followed = [MusicArtist(id: "1", providerID: "p", name: "Ada")]
        let top = [MusicTopArtist(id: "1", name: "Ada", thumbnails: [], plays: 9, secs: 90, linkedID: "1", providerID: "p")]
        let out = MusicTasteOptions.artists(chosen: [], followed: followed, top: top)
        #expect(out.map(\.uid) == ["p:1"])
    }

    @Test func aPlayedArtistWithoutASourceIsNotOffered() {
        let top = [MusicTopArtist(id: "1", name: "Ada", thumbnails: [], plays: 9, secs: 90, linkedID: "1")]
        let out = MusicTasteOptions.artists(chosen: [], followed: [], top: top)
        #expect(out.isEmpty, "an id means nothing without its source")
    }

    @Test func aChosenArtistIsNotListedAgainAsFollowed() {
        let a = MusicArtist(id: "1", providerID: "p", name: "Ada")
        let out = MusicTasteOptions.artists(chosen: [a], followed: [a, a], top: [])
        #expect(out.count == 1)
    }
}

@Suite struct SetupSuggestionsTests {
    @Test func suggestedArtistsDoNotBorrowAnAlbumCoverAsAPortrait() {
        let art = [MusicThumbnail(url: "https://e.org/c.jpg", width: 300, height: 300)]
        var t = MusicTrack(id: "t", providerID: "p", title: "Song", durationMs: 1000, artists: [MusicArtistRef(id: "a", name: "Ada")])
        t.thumbnails = art
        let out = MusicSetupFlow.suggestedArtists(fromTracks: [t])
        #expect(out.first?.thumbnails.isEmpty == true)
    }

    @Test func twoArtistsWithOneNameStayTwo() {
        let one = MusicTrack(id: "t1", providerID: "p", title: "A", durationMs: 1000, artists: [MusicArtistRef(id: "a1", name: "Sam")])
        let two = MusicTrack(id: "t2", providerID: "p", title: "B", durationMs: 1000, artists: [MusicArtistRef(id: "a2", name: "Sam")])
        let out = MusicSetupFlow.suggestedArtists(fromTracks: [one, two])
        #expect(out.count == 2)
    }

    @Test func theSummaryCountsGenresMarkedNotForMe() {
        var flow = MusicSetupFlow()
        #expect(flow.pickedNothing)
        flow.rejectGenre("Metal")
        #expect(flow.pickedNothing == false)
        #expect(flow.applying(to: MusicTastePrefs()).dislikedGenres.contains("Metal"))
    }
}

@Suite struct RagaMatchTests {
    private func track(_ id: String, _ title: String, artist: String, album: String) -> MusicTrack {
        var t = MusicTrack(id: id, providerID: "p", title: title, durationMs: 1000, artists: [MusicArtistRef(id: "a" + id, name: artist)])
        t.album = MusicAlbumRef(id: "al" + id, title: album)
        return t
    }

    private let song = MusicRagaSong(ragas: ["Mohanam"], title: "Chinna Chinna", film: "Roja", year: 1992, composer: "A. R. Rahman", singers: ["Minmini"], language: "Tamil")

    @Test func theSameTitleFromAnotherFilmLosesToTheRightOne() {
        let other = track("1", "Chinna Chinna", artist: "Somebody", album: "Other Film")
        let right = track("2", "Chinna Chinna", artist: "Minmini", album: "Roja")
        #expect(MusicRagaMatch.best(for: song, in: [other, right])?.id == "2")
    }

    @Test func aTitleThatOnlyContainsTheSongsIsNotTakenWithoutEvidence() {
        let loose = track("1", "Chinna Chinna Aasai Remix", artist: "Nobody", album: "Club")
        #expect(MusicRagaMatch.best(for: song, in: [loose]) == nil)
    }
}

@Suite struct ExploreClassifyBySourceTests {
    @Test func aReleaseListIsToldByItsIdNotOnlyItsEnglishTitle() {
        let fresh = MusicBrowseSection(id: "listenbrainz-fresh", title: "नई रिलीज़", items: [])
        #expect(MusicExploreComposition.isRelease(fresh))
        let chart = MusicBrowseSection(id: "itunes-songs-in", title: "Top songs", items: [])
        #expect(MusicExploreComposition.isRelease(chart) == false)
    }

    @Test func aGenreChartSaysItIsWorldwide() {
        let s = MusicBrowseSection(id: "soundcloud-electronic", title: "electronic", items: [])
        #expect(MusicChartArrangement.honestTitle(s) == "Electronic worldwide")
    }

    @Test func aCuratedRowKeepsItsOwnTitle() {
        let s = MusicBrowseSection(id: "soundcloud-sel-x", title: "Chill mixes", items: [])
        #expect(MusicChartArrangement.honestTitle(s) == "Chill mixes")
    }
}

@Suite struct ExploreRegistryShelvesTests {
    @MainActor @Test func genreAndLanguageShelvesAreListedOnceEach() {
        let all = MusicExploreRegistry.all(excluding: "")
        let ids = all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("genre-albums-132"))
        #expect(ids.contains("genre-artists-132"))
        #expect(ids.contains("spotlight-korean"))
    }

    @Test func aChartCarriesWhenItWasFetched() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let p = MusicChartProvenance(sourceName: "x", region: "India", period: "Daily", fetchedAt: when)
        #expect(p.fetchedAt == when)
    }
}

@Suite struct ExploreMemoryShelfTests {
    @MainActor @Test func aShelfAnswerIsKeptForARebuiltRow() {
        MusicExploreMemory.forget()
        let s = MusicBrowseSection(id: "chart-xx", title: "Top", items: [])
        #expect(MusicExploreMemory.shelf("chart-xx") == nil)
        MusicExploreMemory.setShelf(s, provenance: nil, id: "chart-xx")
        #expect(MusicExploreMemory.shelf("chart-xx")?.section.id == "chart-xx")
        MusicExploreMemory.forget()
    }
}

@MainActor @Suite struct ExploreFeatureCardsTests {
    private let art = [MusicThumbnail(url: "https://e.org/c.jpg", width: 300, height: 300)]

    @Test func playlistsLeadAndTracksNeverFeature() {
        let song = MusicTrack(id: "t", providerID: "p", title: "Hit", durationMs: 1000, artists: [])
        let album = MusicAlbum(id: "a", providerID: "p", title: "Fresh", thumbnails: art)
        let list = MusicPlaylist(id: "l", providerID: "p", name: "Mix", thumbnails: art)
        var r = MusicExploreComposition.Result()
        r.releases = MusicBrowseSection(id: "n", title: "New releases", items: [.album(album), .playlist(list), .track(song)])
        let out = MusicExploreView.featureItems(r)
        #expect(out.count == 2)
        if case .playlist = out.first { } else { Issue.record("a playlist leads") }
    }
}
