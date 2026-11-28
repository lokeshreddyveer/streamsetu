import Foundation
import Testing
@testable import REDDY

private func eid(_ k: MusicEntityKind, _ n: String) -> MusicEntityID { .derive(kind: k, aliasKey: "artist-round7-" + n) }

private func entry(_ name: String, kind: MusicEntityKind = .recording, roles: [MusicRole] = []) -> MusicPersonEntry {
    var e = MusicPersonEntry(id: eid(kind, name), name: name, kind: kind)
    e.roles = roles
    return e
}

@MainActor struct ArtistRound7Tests {
    @Test func appliedFilterKeepsItsChipEvenWithOneChoice() {
        #expect(!MusicArtistChipRules.offered(1, selected: false))
        #expect(MusicArtistChipRules.offered(1, selected: true))
        #expect(MusicArtistChipRules.offered(0, selected: true))
        #expect(MusicArtistChipRules.offered(2, selected: false))
        #expect(!MusicArtistChipRules.offered(0, above: 0, selected: false))
        #expect(MusicArtistChipRules.offered(1, above: 0, selected: false))
    }

    @Test func clearFiltersEmptiesEveryListFilter() {
        let state = MusicArtistPageState()
        state.songs.language = "te"; state.songs.query = "x"; state.songs.sort = .newest; state.year = 1999
        state.clearSongFilters()
        #expect(!state.songs.isActive)
        #expect(state.year == nil)
        #expect(state.songs.sort == .newest, "the sort is a choice of order, not a filter")
        state.albumType = .single; state.albumDecade = 1990; state.year = 1990
        state.clearAlbumFilters()
        #expect(state.albumType == nil && state.albumDecade == nil && state.year == nil)
        state.filmLanguage = "hi"; state.filmDecade = 2000; state.filmFilter.withSoundtrack = true
        state.clearFilmFilters()
        #expect(state.filmLanguage == nil && state.filmDecade == nil && !state.filmFilter.isActive)
    }

    @Test func aCardOpensOnTheOnlyRoleNotAnArbitraryOne() {
        let multi = entry("Both", kind: .person, roles: [.singer, .musicDirector])
        let single = entry("One", kind: .person, roles: [.composer])
        let none = entry("None", kind: .person)
        #expect(multi.openRole == nil)
        #expect(single.openRole == .composer)
        #expect(none.openRole == nil)
    }

    @Test func goToArtistSkipsCompilationAndIdLessCredits() {
        let various = MusicArtistRef(id: "v1", name: "Various Artists")
        let nameOnly = MusicArtistRef(id: "", name: "Some Singer")
        let real = MusicArtistRef(id: "a9", name: "Real Singer")
        #expect(MusicCompilationArtist.primary(in: [various, nameOnly, real])?.id == "a9")
        #expect(MusicCompilationArtist.primary(in: [various, nameOnly]) == nil)
        #expect(MusicCompilationArtist.primary(in: []) == nil)
    }

    @Test func headerFactsClearOnlyForAnotherPerson() {
        let a = eid(.person, "a"), b = eid(.person, "b")
        #expect(!MusicPersonHeaderLoadRules.clearsFacts(loadedFor: nil, now: a))
        #expect(!MusicPersonHeaderLoadRules.clearsFacts(loadedFor: a, now: a), "a role switch keeps the lines")
        #expect(MusicPersonHeaderLoadRules.clearsFacts(loadedFor: a, now: b))
    }

    @Test func actorAndDirectorViewsOfferNoFollow() {
        #expect(!MusicPersonFollowRules.offersFollow(view: .actor))
        #expect(!MusicPersonFollowRules.offersFollow(view: .director))
        #expect(MusicPersonFollowRules.offersFollow(view: .singer))
        #expect(MusicPersonFollowRules.offersFollow(view: .composer))
        #expect(MusicPersonFollowRules.offersFollow(view: nil))
    }

    @Test func favoriteArtistsShelfReadsTheStoredMarksNewestFirst() {
        let a = eid(.person, "fa"), b = eid(.person, "fb")
        var set = MusicFavoriteArtistSet()
        set.toggle(a); set.toggle(b)
        let ids = MusicFavoriteArtistShelfRules.ids(set)
        #expect(ids == [b, a])
        let junk = MusicFavoriteArtistSet(ids: ["not-an-id", a.rawValue])
        #expect(MusicFavoriteArtistShelfRules.ids(junk) == [a])
    }

    @Test func aliasLineSkipsTheShownNamesAndCapsAtThree() {
        let line = MusicPersonAliasLine.line(aliases: ["Raj", "RAJ", "Rajé", "Rajkumar", "Rk", "Other"], display: "Raj", otherScript: nil)
        #expect(line != nil)
        #expect(MusicPersonAliasLine.line(aliases: ["Raj", "raj"], display: "Raj", otherScript: nil) == nil)
        #expect(MusicPersonAliasLine.line(aliases: ["राज"], display: "Raj", otherScript: "राज") == nil)
        let text = line ?? ""
        #expect(!text.contains("Other"))
    }

    @Test func unplayedRadioModeNeedsAHistoryAndTakesOnlyUnplayedSongs() {
        var c = MusicArtistCatalog(view: .singer)
        c.songs = [entry("Heard"), entry("Fresh One"), entry("Fresh Two")]
        c.primarySongs = c.songs
        var personal = MusicArtistPersonal()
        #expect(!MusicArtistRadioMode.options(c, personal: personal).contains { $0.mode == .unplayed })
        personal.plays[MusicArtistPersonal.key("Heard")] = 4
        let opt = MusicArtistRadioMode.options(c, personal: personal).first { $0.mode == .unplayed }
        #expect(opt?.count == 2)
        var g = SystemRandomNumberGenerator()
        let ids = MusicArtistRadioMode.ids(.unplayed, in: c, personal: personal, using: &g)
        #expect(Set(ids) == Set([eid(.recording, "Fresh One"), eid(.recording, "Fresh Two")]))
    }
}
