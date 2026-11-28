import Foundation
import Testing
@testable import REDDY

/// Holds the fixes the repeated audits found, so they cannot quietly return.
@MainActor @Suite("Audit round fixes") struct AuditRoundFixesTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    @Test func isRecentReadsRealDatesOnly() {
        let now = date(2026, 11, 27)
        #expect(MusicRecentlyAddedPage.isRecent("2026-11-20", now: now))
        #expect(MusicRecentlyAddedPage.isRecent("2026-10-31", now: now))
        #expect(!MusicRecentlyAddedPage.isRecent("2026-10-01", now: now), "more than 28 days ago")
        #expect(!MusicRecentlyAddedPage.isRecent("2026", now: now), "a bare year says nothing")
        #expect(!MusicRecentlyAddedPage.isRecent(nil, now: now))
        #expect(!MusicRecentlyAddedPage.isRecent("2026-02-30", now: now), "not a calendar date")
        #expect(!MusicRecentlyAddedPage.isRecent("2026-13-01", now: now))
        #expect(!MusicRecentlyAddedPage.isRecent("2026-12-20", now: now), "in the future")
        #expect(MusicRecentlyAddedPage.isRecent("2026-11", now: now), "this month has begun")
        #expect(!MusicRecentlyAddedPage.isRecent("2026-12", now: now), "next month has not")
        #expect(!MusicRecentlyAddedPage.isRecent("2026-08", now: now))
    }

    @Test func aGenreHasOneStateAfterSetup() {
        var prefs = MusicTastePrefs()
        prefs.dislikedGenres = ["Metal"]; prefs.lovedGenres = ["Jazz"]
        var flow = MusicSetupFlow()
        flow.genres = ["Metal"]; flow.dislikedGenres = ["Jazz"]
        let out = flow.applying(to: prefs)
        #expect(out.genres.contains("Metal") && !out.dislikedGenres.contains("Metal"), "liked again: no longer disliked")
        #expect(out.dislikedGenres.contains("Jazz") && !out.lovedGenres.contains("Jazz") && !out.genres.contains("Jazz"))
        #expect(!MusicTasteBias.genres(out).contains { $0.name == "Jazz" })
    }

    @Test func aDislikedGenreIsNeverQueried() {
        var p = MusicTastePrefs()
        p.genres = ["Pop", "Metal"]; p.lovedGenres = ["Metal"]; p.dislikedGenres = ["Metal"]
        #expect(MusicTasteBias.genres(p).map(\.name) == ["Pop"])
    }

    @Test func firstSeenRepairsAFutureDate() {
        let item = MusicBrowseItem.track(MusicTrack(id: "1", providerID: "p", title: "T", durationMs: 0, artists: []))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MusicFirstSeenLog(seen: [MusicFirstSeenLog.key(item): now.addingTimeInterval(10 * 86_400)])
        #expect(log.bucket(item, now: now) == nil)
        log.record([item], now: now)
        #expect(log.bucket(item, now: now) == .today)
    }

    @Test func wipeCoversTheStateTheseScreensKeep() {
        for key in ["music.firstSeen.v1", "music.taste.prefs", "music.setup.done", "music.setup.cardDismissed", "music.album.prefs.v1"] {
            #expect(MusicDefaultsKeys.activity.contains(key), "\(key) must be removed by a wipe")
        }
    }

    @Test func hiddenSongsLeaveMixesAndTheHero() {
        func track(_ n: Int) -> MusicTrack { MusicTrack(id: "t\(n)", providerID: "p", title: "S\(n)", durationMs: 1000, artists: [MusicArtistRef(id: "a\(n % 2)", name: "A\(n % 2)")]) }
        let tracks = (0..<12).map(track)
        let mix = HomeItem.mix(id: "daily", title: "Daily", subtitle: "Mix", tracks: tracks)
        var feed = HomeFeed(seed: 1, composedAt: Date(), mode: .full)
        feed.sections = [HomeSection(id: "madeForYou", kind: .madeForYou, title: "Made", reason: nil, items: [mix])]
        feed.hero = HomeHero(kind: .randomFavourite, item: HomeItem.make(tracks[0]), reason: "r")
        var hidden = MusicHiddenSet()
        hidden.tracks = [tracks[0].uid]
        let out = hidden.filter(feed)
        #expect(out.hero == nil, "a hidden song is not the hero")
        #expect(out.sections.first?.items.first?.mixTracks.contains { $0.uid == tracks[0].uid } == false)
        hidden.tracks = Set(tracks.prefix(6).map(\.uid))
        #expect(hidden.filter(feed).sections.isEmpty, "a mix left too short goes")
    }

    @Test func aFilmCountsAsIndianOnlyWhenItIsMadeThere() {
        #expect(MusicFilmIndustry.classify(language: "te", country: "IN")?.name == "Tollywood")
        #expect(MusicFilmIndustry.classify(language: "pa", country: "PK") == nil)
        #expect(TMDBGraphSource.languageOf(country: "JP") == "ja" && TMDBGraphSource.languageOf(country: "IN") == nil)
    }
}

@Suite("Artist audit fixes") struct ArtistAuditFixesTests {
    @Test func sameNameDifferentIdIsAnotherArtistOnTheSameProvider() {
        let identity = MusicArtistIdentity(providerID: "p", artistID: "a1", name: "Asha")
        let mine = MusicTrack(id: "1", providerID: "p", title: "S", durationMs: 1, artists: [MusicArtistRef(id: "a1", name: "Asha")])
        let other = MusicTrack(id: "2", providerID: "p", title: "S2", durationMs: 1, artists: [MusicArtistRef(id: "a2", name: "Asha")])
        #expect(MusicArtistListening.matches(mine, identity: identity))
        #expect(!MusicArtistListening.matches(other, identity: identity))
    }

    @Test func twoSingersAreNotACombinePair() {
        let a = MusicEntityID.provisional(kind: .person, name: "A"), b = MusicEntityID.provisional(kind: .person, name: "B")
        var e = MusicPersonEntry(id: b, name: "B", kind: .person); e.roles = [.singer]
        #expect(!MusicCombinePreset.make(person: a, personName: "A", view: .singer, other: e).isPair, "both fill the singer slot")
        e.roles = [.composer]
        #expect(MusicCombinePreset.make(person: a, personName: "A", view: .singer, other: e).isPair)
    }

    @Test func distinctReleasesWithOneTitleAreNotFolded() {
        func album(_ n: String, _ year: Int) -> MusicPersonEntry {
            var e = MusicPersonEntry(id: MusicEntityID.provisional(kind: .album, name: n, year: year), name: n, kind: .album); e.year = year; return e
        }
        let s = MusicPersonSection(.albums, [album("Hits", 1995), album("Hits", 2015), album("(Original Motion Picture Soundtrack)", 2001), album("(Original Motion Picture Soundtrack)", 2003)])
        let folded = MusicArtistCatalog.foldAlbums(sections: [s])
        #expect(folded.count == 4, "different decades are different releases; an all-bracket title never merges unrelated albums")
    }
}

@Suite("Audit round 2 fixes") struct AuditRound2FixesTests {
    @Test func bannedWordsMatchWholeWordsOnly() {
        #expect(!MusicFilmEditionRules.hasWord("undercover (original soundtrack)", in: ["cover", "8d"]))
        #expect(MusicFilmEditionRules.hasWord("song (8d audio)", in: ["cover", "8d"]))
        #expect(MusicFilmEditionRules.hasWord("tribute cover", in: ["cover"]))
    }

    @MainActor @Test func genreStyleNamesBecomeSearchWords() {
        #expect(MusicGenreFamilies.words("Funk / Soul") == "Funk Soul")
        #expect(MusicGenreFamilies.words("Folk, World, & Country") == "Folk World Country")
    }

    @Test func aShelfThatLostSongsToHidingBelowItsMinimumGoes() {
        func t(_ n: Int) -> MusicTrack { MusicTrack(id: "t\(n)", providerID: "p", title: "S\(n)", durationMs: 1000, artists: []) }
        let tracks = (0..<(HomeEngine.minItems + 1)).map(t)
        var feed = HomeFeed(seed: 1, composedAt: Date(), mode: .full)
        feed.sections = [HomeSection(id: "x", kind: .onRepeat, title: "X", reason: nil, items: tracks.map { HomeItem.make($0) })]
        var hidden = MusicHiddenSet(); hidden.tracks = [tracks[0].uid, tracks[1].uid]
        #expect(hidden.filter(feed).sections.isEmpty, "left under the size a shelf needs")
        hidden.tracks = [tracks[0].uid]
        #expect(hidden.filter(feed).sections.first?.items.count == HomeEngine.minItems)
    }
}

@MainActor @Suite("Audit round 6 fixes") struct AuditRound6FixesTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    @Test func thisYearOnlyMeansReleasedAndInThisYear() {
        let now = date(2026, 11, 27)
        #expect(MusicRecentlyAddedPage.isThisYear("2026", now: now))
        #expect(!MusicRecentlyAddedPage.isThisYear("2025", now: now), "last year is only counted in January and February")
        #expect(MusicRecentlyAddedPage.isThisYear("2025", now: date(2026, 2, 3)))
        #expect(MusicRecentlyAddedPage.isEarlierThisYear("2026-03-01", now: now))
        #expect(!MusicRecentlyAddedPage.isEarlierThisYear("2026-12-15", now: now), "an announced album is not from this year yet")
        #expect(!MusicRecentlyAddedPage.isEarlierThisYear("2026-12", now: now))
        #expect(MusicRecentlyAddedPage.isEarlierThisYear("2026-11", now: now))
        #expect(!MusicRecentlyAddedPage.isEarlierThisYear("2025-03-01", now: now))
    }

    @Test func aFeedMadeOfflineIsNotKeptOnceBackOnline() {
        #expect(MusicHomeFeedModel.sameState(.full, .light))
        #expect(MusicHomeFeedModel.sameState(.newUser, .full))
        #expect(!MusicHomeFeedModel.sameState(.offline, .full))
        #expect(!MusicHomeFeedModel.sameState(.gated, .full))
        #expect(MusicHomeFeedModel.sameState(.offline, .offline))
    }
}
