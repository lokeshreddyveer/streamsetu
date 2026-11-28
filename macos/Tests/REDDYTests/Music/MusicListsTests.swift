import Testing
import Foundation
@testable import REDDY

private func track(_ id: String, _ title: String = "", artist: String = "Artist", album: String? = nil, ms: Int64 = 180_000, disc: Int? = nil, isrc: String? = nil) -> MusicTrack {
    MusicTrack(id: id, providerID: "p", title: title.isEmpty ? "Song \(id)" : title, durationMs: ms, discNumber: disc,
               artists: [MusicArtistRef(id: "a-" + artist, name: artist)], album: album.map { MusicAlbumRef(id: "al-" + $0, title: $0) }, isrc: isrc)
}

@Suite("Music track selection") struct MusicSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func plainClickPlaysUntilSelecting() {
        var s = MusicTrackSelection()
        let first = s.click("a", order: order, kind: .plain)
        #expect(!first)
        #expect(s.count == 0)
        s.enter()
        let second = s.click("a", order: order, kind: .plain)
        #expect(second && s.contains("a"))
        let third = s.click("a", order: order, kind: .plain)
        #expect(third && !s.contains("a"))
    }

    @Test func commandClickTogglesAndStartsSelecting() {
        var s = MusicTrackSelection()
        let one = s.click("b", order: order, kind: .command)
        #expect(one && s.active)
        let two = s.click("d", order: order, kind: .command)
        #expect(two)
        #expect(s.selected == ["b", "d"])
        let three = s.click("b", order: order, kind: .command)
        #expect(three && s.selected == ["d"])
    }

    @Test func shiftClickPicksTheSpanFromTheLastPick() {
        var s = MusicTrackSelection()
        s.toggle("b")
        s.extend(to: "d", order: order)
        #expect(s.selected == ["b", "c", "d"])
        var up = MusicTrackSelection()
        up.toggle("d"); up.extend(to: "b", order: order)
        #expect(up.selected == ["b", "c", "d"])
        var none = MusicTrackSelection()
        none.extend(to: "c", order: order)
        #expect(none.selected == ["c"])
    }

    @Test func selectAllClearExitAndPrune() {
        var s = MusicTrackSelection()
        s.selectAll(order)
        #expect(s.count == 5 && s.active)
        s.prune(keeping: ["a", "b"])
        #expect(s.selected == ["a", "b"])
        s.clear()
        #expect(s.count == 0 && s.active)
        s.exit()
        #expect(!s.active)
        let tracks = [track("a"), track("b"), track("c")]
        var picked = MusicTrackSelection()
        picked.toggle("p:c"); picked.toggle("p:a")
        #expect(picked.ordered(tracks).map(\.id) == ["a", "c"])
    }
}

@Suite("Music sort, filter and columns") struct MusicSortFilterTests {
    @Test func sortsByFieldAndDirectionKeepingTiesStable() {
        let list = [track("1", "Beta", artist: "Zed"), track("2", "alpha", artist: "Amy"), track("3", "Gamma", artist: "Amy", ms: 60_000)]
        #expect(MusicTrackOrdering(field: .title).apply(list).map(\.id) == ["2", "1", "3"])
        #expect(MusicTrackOrdering(field: .title, ascending: false).apply(list).map(\.id) == ["3", "1", "2"])
        #expect(MusicTrackOrdering(field: .artist).apply(list).map(\.id) == ["2", "3", "1"])
        #expect(MusicTrackOrdering(field: .duration).apply(list).first?.id == "3")
        #expect(MusicTrackOrdering().apply(list).map(\.id) == ["1", "2", "3"])
        #expect(MusicTrackOrdering(field: .original, ascending: false).apply(list).map(\.id) == ["3", "2", "1"])
    }

    @Test func filterNeedsEveryWordAndIgnoresCaseAndAccents() {
        let list = [track("1", "Café del Mar", artist: "Energy 52", album: "Ibiza"), track("2", "Other", artist: "Someone")]
        #expect(MusicTrackFilter.apply(list, query: "cafe mar").map(\.id) == ["1"])
        #expect(MusicTrackFilter.apply(list, query: "ENERGY ibiza").map(\.id) == ["1"])
        #expect(MusicTrackFilter.apply(list, query: "mar someone").isEmpty)
        #expect(MusicTrackFilter.apply(list, query: "  ").count == 2)
    }

    @Test func orderingRoundTripsAndIsRememberedPerList() throws {
        let o = MusicTrackOrdering(field: .album, ascending: false)
        #expect(MusicTrackOrdering(encoded: o.encoded) == o)
        #expect(MusicTrackOrdering(encoded: "nonsense") == nil)
        let suite = "music.lists.tests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        MusicOrderingMemory.save(o, for: "local:1", defaults: d)
        MusicOrderingMemory.save(MusicTrackOrdering(field: .title), for: "local:2", defaults: d)
        #expect(MusicOrderingMemory.load("local:1", defaults: d) == o)
        #expect(MusicOrderingMemory.load("local:3", defaults: d).isDefault)
        MusicOrderingMemory.save(MusicTrackOrdering(), for: "local:1", defaults: d)
        #expect(MusicOrderingMemory.load("local:1", defaults: d).isDefault)
        #expect(MusicOrderingMemory.load("local:2", defaults: d).field == .title)
    }

    @Test func columnsToggleSaveAndDropByWidth() throws {
        var c = MusicTrackColumns.standard
        #expect(c.has(.duration) && !c.has(.album))
        c = c.toggled(.album).toggled(.artist)
        #expect(c.effective(width: 900).has(.album))
        #expect(!c.effective(width: 600).has(.album) && c.effective(width: 600).has(.artist))
        #expect(!c.effective(width: 480).has(.artist) && c.effective(width: 480).has(.duration))
        #expect(c.effective(width: 0) == c)
        let suite = "music.columns.tests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        c.save(d)
        #expect(MusicTrackColumns.load(d) == c)
        #expect(MusicTrackColumns.standard.shown == [.duration])
    }
}

@Suite("Music scroll memory") struct MusicScrollMemoryTests {
    @Test func backRestoresTheOffsetOfThePageLeft() {
        var store = MusicScrollStore()
        let album = MusicScrollKey.route(.album(MusicAlbum(id: "1", providerID: "p", title: "A")))
        let artist = MusicScrollKey.route(.artist(MusicArtist(id: "9", providerID: "p", name: "B")))
        store.record(MusicScrollKey.section(.search), 420)
        store.record(album, 900)
        store.record(artist, 0.4)
        #expect(store.offset(for: album) == 900)
        #expect(store.offset(for: MusicScrollKey.section(.search)) == 420)
        #expect(store.offset(for: artist) == nil)
        store.record(album, 0)
        #expect(store.offset(for: album) == nil)
    }

    @Test func oldestEntriesGoFirstAndRestoreWaitsForContent() {
        var store = MusicScrollStore()
        for i in 0..<(MusicScrollStore.capacity + 5) { store.record("k\(i)", Double(i + 10)) }
        #expect(store.offset(for: "k0") == nil && store.offset(for: "k5") == 15)
        #expect(store.offsets.count == MusicScrollStore.capacity)
        #expect(!MusicScrollStore.canRestore(y: 800, contentHeight: 1000, viewport: 600))
        #expect(MusicScrollStore.canRestore(y: 400, contentHeight: 1000, viewport: 600))
    }

    @Test func routeKeysAreDistinct() {
        let keys = [MusicRoute.album(MusicAlbum(id: "1", providerID: "p", title: "x")), .artist(MusicArtist(id: "1", providerID: "p", name: "x")),
                    .playlist(MusicPlaylist(id: "1", providerID: "p", name: "x")), .localPlaylist(UUID()), .genre(MusicBrowseGenre(id: "1", name: "x")), .blacklist].map(MusicScrollKey.route)
        #expect(Set(keys).count == keys.count)
    }
}

@Suite("Music search suggestions") struct MusicSuggestionTests {
    @Test func typedWordsAreAlwaysTheFirstRowThenCompletionsThenFourSongs() {
        let songs = (1...6).map { track("\($0)", "Song \($0)", artist: "Artist \($0)") }
        let rows = MusicSuggest.rows(typed: "  son ", completions: ["song one", "song two"], tracks: songs)
        #expect(rows.first == .search("son"))
        #expect(rows.dropFirst().prefix(2).map(\.id) == ["completion:song one", "completion:song two"])
        #expect(rows.suffix(4).allSatisfy { if case .track = $0 { true } else { false } })
        #expect(rows.count == 7)
        #expect(MusicSuggest.rows(typed: "   ", completions: ["x"], tracks: songs).isEmpty)
    }

    @Test func theSameRecordingShowsOnce() {
        let a = track("1", "Same", artist: "X", isrc: "US123"), b = track("2", "Same", artist: "X", isrc: "US123"), c = track("3", "Other", artist: "Y")
        let rows = MusicSuggest.rows(typed: "same", completions: [], tracks: [a, b, c])
        #expect(rows.count == 3)
    }

    @Test func completionsPutPrefixesFirstAndNeverRepeatTheTypedWords() {
        let tracks = [track("1", "Dark Horse", artist: "Katy Perry"), track("2", "Blue", artist: "Horsefeathers")]
        let out = MusicSuggest.completions(typed: "hor", recents: ["horse", "the horse whisperer", "Hor"], tracks: tracks)
        #expect(out.first == "horse")
        #expect(!out.contains("Hor"))
        #expect(out.contains("Horsefeathers") && out.contains("Dark Horse"))
        let starts = out.firstIndex(of: "Horsefeathers") ?? 99, contains = out.firstIndex(of: "Dark Horse") ?? 0
        #expect(starts < contains)
        #expect(out.count <= MusicSuggest.maxCompletions)
        #expect(MusicSuggest.completions(typed: "", recents: ["a"], tracks: []).isEmpty)
    }

    @Test func keyboardMovesAndWraps() {
        #expect(MusicSuggest.move(nil, by: 1, count: 4) == 0)
        #expect(MusicSuggest.move(nil, by: -1, count: 4) == 3)
        #expect(MusicSuggest.move(3, by: 1, count: 4) == 0)
        #expect(MusicSuggest.move(0, by: -1, count: 4) == 3)
        #expect(MusicSuggest.move(1, by: 1, count: 0) == nil)
    }

    @Test func rulesForWhenToAsk() {
        #expect(!MusicSuggest.qualifies("a") && !MusicSuggest.qualifies(" a ") && MusicSuggest.qualifies("ab"))
        #expect(MusicSuggest.isCurrent(reply: "ab ", now: " ab"))
        #expect(!MusicSuggest.isCurrent(reply: "ab", now: "abc"))
        #expect(MusicSuggest.debounce == .milliseconds(300))
    }
}

@Suite("Music search results") struct MusicSearchResultTests {
    @Test func topResultPrefersAnExactArtistOverAWeakSong() {
        let t = track("1", "Something About Adele", artist: "Cover Band")
        let a = MusicArtist(id: "a", providerID: "p", name: "Adele")
        let pick = MusicTopResult.pick(query: "adele", tracks: [t], artists: [a], albums: [], playlists: [])
        #expect(pick == .artist(a))
        let exactSong = track("2", "Hello", artist: "Adele")
        #expect(MusicTopResult.pick(query: "hello", tracks: [exactSong], artists: [a], albums: [], playlists: []) == .track(exactSong))
        #expect(MusicTopResult.pick(query: "x", tracks: [], artists: [], albums: [], playlists: []) == nil)
    }

    @Test func scopeSwitchOnlyWhenThereIsAnotherPlaceToLook() {
        #expect(MusicSearchScope.available(localFilesOn: false) == [.everything])
        #expect(MusicSearchScope.available(localFilesOn: true).count == 3)
        #expect(MusicSearchScope.local.nothingFound(for: "q").contains("Local files"))
        #expect(MusicSearchScope.library.nothingFound(for: "q").contains("Your library"))
    }

    @Test func libraryScopeSearchesOnDeviceWithoutASource() {
        let liked = [track("1", "Blue Monday", artist: "New Order"), track("2", "Other", artist: "X")]
        let pl = LocalPlaylist(id: UUID(), name: "Blue mix", tracks: [track("3", "Blue Jeans", artist: "Lana")], created: Date())
        let hits = MusicLibrarySearch.run("blue", liked: liked, playlists: [pl], history: [], artists: [MusicArtist(id: "a", providerID: "p", name: "Blue Oyster")], albums: [])
        #expect(Set(hits.tracks.map(\.id)) == ["1", "3"])
        #expect(hits.artists.count == 1 && hits.playlists.first?.providerID == "local" && hits.playlists.first?.id == pl.id.uuidString)
    }
}

@Suite("Music pages") struct MusicPagesLogicTests {
    @Test func releasesSplitIntoAlbumsSinglesAndAppearsOn() {
        func al(_ id: String, _ type: String?, tracks: Int? = nil) -> MusicAlbum { MusicAlbum(id: id, providerID: "p", title: id, totalTracks: tracks, albumType: type) }
        let s = MusicReleaseKind.split([al("a", "album"), al("b", "single"), al("c", "EP"), al("d", "appears_on"), al("e", nil, tracks: 1), al("f", "Compilation"), al("a", "album")])
        #expect(s.albums.map(\.id) == ["a"] && s.singles.map(\.id) == ["b", "c", "e"] && s.appearsOn.map(\.id) == ["d", "f"])
    }

    @Test func discsGroupOnlyWhenNumbersExist() {
        let flat = [track("1"), track("2")]
        #expect(MusicDiscGroups.group(flat).count == 1 && MusicDiscGroups.group(flat)[0].disc == nil)
        let two = [track("1", disc: 1), track("2", disc: 2), track("3", disc: 1)]
        let g = MusicDiscGroups.group(two)
        #expect(g.map(\.disc) == [1, 2] && g[0].tracks.map(\.id) == ["1", "3"])
        #expect(MusicDiscGroups.group([track("1", disc: 1), track("2", disc: 1)]).count == 1)
    }

    @Test func totalTimeReadsAsMinutesOrHours() {
        #expect(MusicDurationText.total(ms: 48 * 60_000) == "48 min")
        #expect(MusicDurationText.total(ms: 65 * 60_000) == "1 hr 5 min")
        #expect(MusicDurationText.total(ms: 120 * 60_000) == "2 hr")
        #expect(MusicDurationText.total(ms: 10_000) == "1 min")
    }

    @Test func dedupeKeepsTheFirstOfEach() {
        #expect(MusicDedupe.by(["a", "b", "a"], key: { $0 }) == ["a", "b"])
        #expect(MusicDedupe.tracks([track("1", "T", artist: "X"), track("2", "T", artist: "X"), track("3", "U", artist: "X")]).map(\.id) == ["1", "3"])
    }

    @Test func membershipListsEveryPlaylistHoldingTheSong() {
        let t = track("1")
        let a = LocalPlaylist(id: UUID(), name: "A", tracks: [t], created: Date()), b = LocalPlaylist(id: UUID(), name: "B", tracks: [t, track("2")], created: Date())
        let idx = MusicPlaylistMembership.index([a, b])
        #expect(idx[t.uid] == ["A", "B"] && idx["p:2"] == ["B"] && idx["p:9"] == nil)
    }

    @Test func aCardDragCarriesOnlyWhatIsNeededAndComesBackTheSame() throws {
        let album = MusicAlbum(id: "al1", providerID: "p", title: "Record")
        let payload = MusicDragPayload(.album(album))
        let data = try #require(payload.encoded())
        let back = try #require(MusicDragPayload.decode(data))
        #expect(back == payload && back.kind == .album && back.uid == "p:al1")
        if case .album(let a) = back.entity { #expect(a.id == "al1" && a.providerID == "p") } else { Issue.record("not an album") }
        #expect(MusicDragPayload.decode(Data("junk".utf8)) == nil)
        #expect(MusicDragKind.browseItem.identifier.hasPrefix("app.streamsetu.music.drag"))
    }

    @Test func playlistDescriptionsAreTrimmedAndCapped() {
        #expect(MusicPlaylistExtras.cleaned("  hello \n") == "hello")
        #expect(MusicPlaylistExtras.cleaned(String(repeating: "x", count: 500)).count == MusicPlaylistExtras.descriptionLimit)
    }

    @Test func cardMenusGainGoToArtistAndPlayForArtists() {
        #expect(MusicMenuLogic.cardItems(.init(kind: .album, hasArtist: true)).contains(.goToArtist))
        #expect(!MusicMenuLogic.cardItems(.init(kind: .album)).contains(.goToArtist))
        #expect(MusicMenuLogic.cardItems(.init(kind: .artist)).first == .playArtist)
        #expect(!MusicMenuLogic.cardItems(.init(kind: .artist, hasArtist: true)).contains(.goToArtist))
    }
}

@Suite("Music paged list inline failure") @MainActor struct MusicPagedInlineFailureTests {
    @Test func aFailedNextPageKeepsTheListAndCanBeRetried() async {
        var fail = false
        let list = MusicPagedList<MusicTrack> { page in
            if page == nil { return MusicPage(items: [track("1")], next: .offset(offset: 1, limit: 1)) }
            if fail { throw MusicError.network("down") }
            return MusicPage(items: [track("2")])
        }
        await list.loadIfNeeded()
        fail = true
        await list.loadMore()
        #expect(list.state == .loaded && list.items.count == 1 && list.loadMoreFailed && list.hasMore)
        fail = false
        await list.loadMore()
        #expect(list.items.map(\.id) == ["1", "2"] && !list.loadMoreFailed && !list.hasMore)
    }
}
