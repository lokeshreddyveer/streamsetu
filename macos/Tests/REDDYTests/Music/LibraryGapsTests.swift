import Testing
import Foundation
@testable import REDDY

// Most played, smart collections, genre and language facets and the quick links of Your library. Every list is generated for a persona; nothing comes
// from anyone's real library.

private func track(_ id: String, title: String, genre: String? = nil, language: String? = nil, album: String? = nil) -> MusicTrack {
    var t = MusicTrack(id: id, providerID: "yt", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "Artist")],
                       album: album.map { MusicAlbumRef(id: "al-" + $0, title: $0) })
    if genre != nil || language != nil { t.hints = MusicProviderHints(language: language, genre: genre) }
    return t
}

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }

/// A listener of Telugu and Hindi songs: 300 songs, the title's script says the language, the genre spelling varies, some have no genre.
private func mixedPersona() -> [MusicTrack] {
    let telugu = ["ప్రేమ కథ", "నా మనసు", "ఊహలు", "చిలిపి"]
    let hindi = ["दिल की बात", "प्यार का गीत", "ज़िंदगी", "बारिश"]
    let spellings = ["Pop", "pop", "POP ", "Rock", "rock", "Folk", "Unknown", "", "(17)", "Pop; Folk"]
    return (0..<300).map { i in
        let title = (i % 3 == 0 ? hindi[i % 4] : telugu[i % 4]) + " \(i)"
        return track("p\(i)", title: title, genre: i % 10 == 9 ? nil : spellings[i % spellings.count])
    }
}

@Suite("Most played sort") struct MostPlayedSortTests {
    private func entries(_ counts: [Int], last: [Double]) -> [MusicLibraryEntry] {
        counts.indices.map { i in MusicLibraryEngine.entry(title: "S\(i)", subtitle: "", provider: "yt", playedAt: last[i], plays: counts[i]) }
    }

    @Test func ordersByPlaysThenRecency() {
        let e = entries([3, 9, 3, 0, 9], last: [10, 5, 20, 0, 50])
        #expect(MusicLibraryEngine.order(e, sort: .mostPlayed) == [4, 1, 2, 0, 3])
    }

    @Test func fullTiesKeepTheListOrder() {
        let e = entries([2, 2, 2], last: [7, 7, 7])
        #expect(MusicLibraryEngine.order(e, sort: .mostPlayed) == [0, 1, 2])
    }

    @Test func reversedShowsLeastPlayedFirst() {
        let e = entries([1, 5, 3], last: [1, 1, 1])
        let order = MusicLibraryEngine.order(e, sort: .mostPlayed)
        #expect(MusicLibraryEngine.select(order: order, entries: e, filter: MusicLibraryFilterState(), reversed: true) == [0, 2, 1])
    }

    @Test func emptyLibraryHasNoOrder() { #expect(MusicLibraryEngine.order([], sort: .mostPlayed).isEmpty) }

    @Test func playCountsCountEveryRecord() {
        let a = track("a", title: "A"), b = track("b", title: "B")
        let history = [PlayRecord(track: a, at: ago(1), playedMs: 1), PlayRecord(track: b, at: ago(2), playedMs: 1), PlayRecord(track: a, at: ago(3), playedMs: 1)]
        let c = MusicLibraryEngine.playCounts(history)
        #expect(c[a.uid] == 2 && c[b.uid] == 1 && c.count == 2)
    }

    @Test func oldSavedSortsStillDecodeAndTheNewOneRoundTrips() throws {
        for raw in ["recentlyAdded", "recentlyPlayed", "title", "artist", "album", "releaseDate", "duration", "userOrder"] {
            let sort = try JSONDecoder().decode(MusicLibrarySort.self, from: Data("\"\(raw)\"".utf8))
            #expect(sort.rawValue == raw)
        }
        let old = Data(#"{"modes":{},"sorts":{"songs":"recentlyPlayed"},"reversed":{"songs":true},"filters":{}}"#.utf8)
        let state = try JSONDecoder().decode(MusicLibraryViewState.self, from: old)
        #expect(state.sorts["songs"] == .recentlyPlayed)
        let new = try JSONDecoder().decode(MusicLibrarySort.self, from: JSONEncoder().encode(MusicLibrarySort.mostPlayed))
        #expect(new == .mostPlayed)
    }

    @Test func onlySongListsOfferItAndEverySortHasWords() {
        #expect(MusicLibraryTab.songs.sorts.contains(.mostPlayed) && MusicLibraryTab.local.sorts.contains(.mostPlayed))
        #expect(!MusicLibraryTab.albums.sorts.contains(.mostPlayed) && !MusicLibraryTab.playlists.sorts.contains(.mostPlayed))
        for s in MusicLibrarySort.allCases { #expect(!s.title.isEmpty && !s.reversedTitle.isEmpty) }
    }

    @Test func aSavedMostPlayedSortFallsBackWhereTheTabDoesNotOfferIt() {
        let d = UserDefaults(suiteName: "gaps-" + UUID().uuidString)!
        let prefs = MusicLibraryPrefs(defaults: d)
        prefs.setSort(.mostPlayed, reversed: false, for: .albums)
        #expect(prefs.sort(.albums) == MusicLibraryTab.albums.defaultSort)
        prefs.setSort(.mostPlayed, reversed: false, for: .songs)
        #expect(prefs.sort(.songs) == .mostPlayed)
    }
}

@Suite("Smart collections: most and recently played") struct PlayedCollectionTests {
    @Test func mostPlayedNeedsTwoPlaysAndIsCapped() {
        var songs = (0..<80).map { MusicSmartSong(uid: "s\($0)", plays: Array(repeating: ago(Double($0)), count: 2 + $0 % 5)) }
        songs.append(MusicSmartSong(uid: "once", plays: [ago(1)]))
        songs.append(MusicSmartSong(uid: "never"))
        let top = MusicSmartPlaylists.mostPlayed(songs)
        #expect(top.count == MusicSmartPlaylists.mostPlayedLimit)
        #expect(!top.contains("once") && !top.contains("never"))
    }

    @Test func mostPlayedCountsAllTimeAndBreaksTiesByRecency() {
        let songs = [MusicSmartSong(uid: "old-favourite", plays: Array(repeating: ago(900), count: 40)),
                     MusicSmartSong(uid: "tie-new", plays: [ago(2), ago(3)]), MusicSmartSong(uid: "tie-old", plays: [ago(50), ago(60)])]
        #expect(MusicSmartPlaylists.mostPlayed(songs) == ["old-favourite", "tie-new", "tie-old"])
    }

    @Test func recentlyPlayedIsNewestFirstAndSkipsUnplayed() {
        let songs = [MusicSmartSong(uid: "a", plays: [ago(5)]), MusicSmartSong(uid: "b", plays: [ago(1), ago(30)]), MusicSmartSong(uid: "c"), MusicSmartSong(uid: "d", plays: [ago(3)])]
        #expect(MusicSmartPlaylists.recentlyPlayed(songs) == ["b", "d", "a"])
    }

    @Test func listsAreOfferedFromFiveSongs() {
        let few = (0..<4).map { MusicSmartSong(uid: "x\($0)", plays: [ago(1), ago(2)]) }
        #expect(!MusicSmartPlaylists.lists(few, now: now).contains { $0.kind == .mostPlayed })
        let five = (0..<5).map { MusicSmartSong(uid: "x\($0)", plays: [ago(1), ago(2)]) }
        let kinds = Set(MusicSmartPlaylists.lists(five, now: now).map(\.kind))
        #expect(kinds.contains(.mostPlayed) && kinds.contains(.recentlyPlayed))
        #expect(!MusicSmartPlaylists.lists(five, now: now, dismissed: [.mostPlayed]).contains { $0.kind == .mostPlayed })
    }

    @Test func everyKindHasATitleAReasonAndARoute() {
        for k in MusicSmartKind.allCases { #expect(!k.title.isEmpty && !k.reason.isEmpty && MusicCollectionKey(rawValue: k.rawValue) == k.collectionKey) }
    }

    @Test func emptyLibraryOffersNothing() { #expect(MusicSmartPlaylists.lists([], now: now).isEmpty) }
}

@Suite("Genre and language facets") struct FacetTests {
    @Test func mixedListenerGetsCountedLanguagesAndMergedGenres() {
        let f = MusicLibraryFacets.build(tracks: mixedPersona())
        #expect(f.languages.count == 2)
        #expect(f.languages.map(\.count).reduce(0, +) == 300)
        #expect(f.languages.first?.count ?? 0 >= f.languages.last?.count ?? 0)
        let keys = f.genres.map(\.key)
        #expect(keys.contains("pop") && keys.contains("rock") && keys.contains("folk"))
        #expect(Set(keys).count == keys.count)
        #expect(!keys.contains("unknown") && !keys.contains("17") && !keys.contains(""))
        for pair in zip(f.genres, f.genres.dropFirst()) { #expect(pair.0.count >= pair.1.count) }
    }

    @Test func spellingVariantsCollapseWhateverTheOrder() {
        let a = [track("1", title: "One", genre: "Café Jazz"), track("2", title: "Two", genre: "cafe jazz"), track("3", title: "Three", genre: "CAFÉ JAZZ"), track("4", title: "Four", genre: "Café Jazz")]
        #expect(MusicLibraryFacets.build(tracks: a).genres == MusicLibraryFacets.build(tracks: a.reversed()).genres)
        let g = MusicLibraryFacets.build(tracks: a).genres
        #expect(g.count == 1 && g[0].count == 4 && g[0].name == "Café Jazz")
    }

    @Test func oneSongCountsOnceForAGenreItNamesTwice() {
        let g = MusicLibraryFacets.build(tracks: [track("1", title: "One", genre: "Pop; pop; Rock")]).genres
        #expect(g.map(\.count) == [1, 1] && Set(g.map(\.key)) == ["pop", "rock"])
    }

    @Test func unknownAndEmptyDataMakesNoFacet() {
        let t = ["", " ", "Unknown", "N/A", "Other", "(12)", "42"].enumerated().map { track("u\($0.offset)", title: "Song", genre: $0.element) }
        #expect(MusicLibraryFacets.build(tracks: t).genres.isEmpty)
        #expect(MusicLibraryFacets.build(tracks: []).isEmpty)
    }

    @Test func latinOnlyTitlesHaveNoLanguageButAStatedOneCounts() {
        let plain = [track("1", title: "Hello World"), track("2", title: "Another Song")]
        #expect(MusicLibraryFacets.build(tracks: plain).languages.isEmpty)
        let stated = [track("3", title: "Maate Vinadhuga", language: "te"), track("4", title: "Nuvvu Nenu", language: "Telugu"), track("5", title: "Tum Hi Ho", language: "hi")]
        let l = MusicLibraryFacets.build(tracks: stated).languages
        #expect(l.count == 2 && l[0].count == 2 && l[0].key == MusicLanguage.telugu.rawValue && l[0].name == MusicLanguage.telugu.displayName)
    }

    @Test func oneLanguageListenerGetsASingleFacet() {
        let t = (0..<20).map { track("s\($0)", title: "ప్రేమ \($0)") }
        let f = MusicLibraryFacets.build(tracks: t)
        #expect(f.languages.count == 1 && f.languages[0].count == 20)
    }

    @Test func filteringByGenreLanguageAndBoth() {
        let all = mixedPersona()
        let f = MusicLibraryFacets.build(tracks: all)
        let pop = f.genres.first { $0.key == "pop" }!
        #expect(MusicLibraryFacets.filter(all, MusicFacetSelection(genre: "pop")).count == pop.count)
        let hindi = f.languages.first { $0.key == MusicLanguage.hindi.rawValue }!
        let both = MusicLibraryFacets.filter(all, MusicFacetSelection(genre: "pop", language: hindi.key))
        #expect(both.count <= min(pop.count, hindi.count))
        #expect(both.allSatisfy { MusicLibraryFacets.languages(of: $0).first?.key == hindi.key })
        #expect(MusicLibraryFacets.filter(all, MusicFacetSelection()).count == all.count)
        #expect(MusicLibraryFacets.filter(all, MusicFacetSelection(genre: "no-such-genre")).isEmpty)
    }

    @Test func aSongWithoutDataIsInNoFacetButStaysInTheUnfilteredList() {
        let all = [track("a", title: "Plain Title"), track("b", title: "Other", genre: "Pop")]
        #expect(MusicLibraryFacets.filter(all, MusicFacetSelection(genre: "pop")).map(\.id) == ["b"])
        #expect(MusicLibraryFacets.filter(all, MusicFacetSelection()).count == 2)
    }

    @Test func aStaleChoiceIsDropped() {
        let set = MusicLibraryFacets.build(tracks: [track("1", title: "One", genre: "Pop")])
        let valid = set.valid(MusicFacetSelection(genre: "gone", language: "telugu"))
        #expect(!valid.isActive)
        #expect(set.valid(MusicFacetSelection(genre: "pop")).genre == "pop")
    }

    @Test func artistsAndAlbumsUseTheirOwnData() {
        let artists = [MusicArtist(id: "1", providerID: "yt", name: "A", genres: ["Rock", "rock"]), MusicArtist(id: "2", providerID: "yt", name: "B", genres: ["Jazz"]),
                       MusicArtist(id: "3", providerID: "yt", name: "C")]
        let f = MusicLibraryFacets.build(artists: artists)
        // "Rock" and "rock" on one artist collapse to one genre counted once; equal counts sort by name.
        #expect(f.genres.map(\.key) == ["jazz", "rock"] && f.genres.allSatisfy { $0.count == 1 } && f.languages.isEmpty)
        #expect(MusicLibraryFacets.filter(artists, MusicFacetSelection(genre: "jazz")).map(\.id) == ["2"])
        let albums = [MusicAlbum(id: "x", providerID: "yt", title: "ప్రేమ"), MusicAlbum(id: "y", providerID: "yt", title: "Plain")]
        #expect(MusicLibraryFacets.build(albums: albums).languages.map(\.key) == [MusicLanguage.telugu.rawValue])
    }

    @Test func theSessionKeepsAChoicePerTab() {
        let tab = "gaps-" + UUID().uuidString
        #expect(!MusicFacetSession.selection(tab).isActive)
        MusicFacetSession.set(MusicFacetSelection(genre: "pop"), for: tab)
        #expect(MusicFacetSession.selection(tab).genre == "pop")
        MusicFacetSession.set(MusicFacetSelection(), for: tab)
        #expect(!MusicFacetSession.selection(tab).isActive)
    }
}

@Suite("Library quick links") struct QuickLinkTests {
    @Test func everyChecklistRowHasAOneClickHome() {
        let d = Dictionary(uniqueKeysWithValues: MusicLibraryQuickLink.allCases.map { ($0, $0.destination) })
        #expect(d[.favorites] == .songs(sort: MusicLibraryTab.songs.defaultSort))
        #expect(d[.recentlyAdded] == .recentlyAdded)
        #expect(d[.recentlyPlayed] == .collection(.recentlyPlayed))
        #expect(d[.mostPlayed] == .collection(.mostPlayed))
        #expect(d[.neverPlayed] == .collection(.neverPlayed))
        for l in MusicLibraryQuickLink.allCases { #expect(!l.title.isEmpty && !l.symbol.isEmpty) }
    }

    @Test func songSortsOfTheLinksAreOfferedByTheSongsTab() {
        for l in MusicLibraryQuickLink.allCases { if case .songs(let s) = l.destination { #expect(MusicLibraryTab.songs.sorts.contains(s)) } }
    }

    @Test func routesToTheNewCollectionsRoundTrip() {
        for k in [MusicCollectionKey.mostPlayed, .recentlyPlayed] { #expect(MusicRoute(path: MusicRoute.collection(k).path ?? "") == .collection(k)) }
    }
}
