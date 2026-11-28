import Testing
import Foundation
@testable import REDDY

/// A library of generated songs. The numbers never come from anyone's real library.
private func generated(_ n: Int) -> [MusicTrack] {
    let artists = ["Alpha", "Beta", "Gamma", "Delta", "Épsilon", "Zeta"]
    return (0..<n).map { i in
        MusicTrack(id: "t\(i)", providerID: i % 7 == 0 ? "local" : "yt", title: "Song \((i * 7919) % n)", durationMs: Int64(60_000 + (i * 31) % 300_000),
                   artists: [MusicArtistRef(id: "a\(i % 6)", name: artists[i % 6])], album: MusicAlbumRef(id: "al\(i % 40)", title: "Album \(i % 40)"))
    }
}

private func freshDefaults() -> UserDefaults {
    let d = UserDefaults(suiteName: "library-tests-" + UUID().uuidString)!
    return d
}

@Suite("Library index at scale") struct LibraryIndexTests {
    private let tracks = generated(20_000)
    private var entries: [MusicLibraryEntry] { tracks.map { MusicLibraryEngine.trackEntry($0) } }

    @Test func titleOrderIsSortedAndComplete() {
        let e = entries
        let order = MusicLibraryEngine.order(e, sort: .title)
        #expect(order.count == 20_000)
        #expect(Set(order).count == 20_000)
        for k in stride(from: 1, to: order.count, by: 97) {
            let a = e[order[k - 1]].sortTitle, b = e[order[k]].sortTitle
            #expect(a.compare(b, options: [.numeric]) != .orderedDescending)
        }
    }

    @Test func orderIsStableAcrossRuns() {
        let e = entries
        for sort in [MusicLibrarySort.title, .artist, .album, .duration, .recentlyAdded] {
            #expect(MusicLibraryEngine.order(e, sort: sort) == MusicLibraryEngine.order(e, sort: sort))
        }
    }

    @Test func tiesKeepSourceOrder() {
        // The generated lengths never repeat in 20,000 songs, so this test rounds them to whole seconds on 500 values to get real ties.
        let e = tracks.map { t -> MusicLibraryEntry in var t = t; t.durationMs = 60_000 + (t.durationMs / 1000 % 500) * 1000; return MusicLibraryEngine.trackEntry(t) }
        let order = MusicLibraryEngine.order(e, sort: .duration)
        var ties = 0
        // Songs of the same length keep the order they came in.
        for k in 1..<order.count where e[order[k]].durationMs == e[order[k - 1]].durationMs {
            ties += 1
            #expect(order[k] > order[k - 1])
        }
        #expect(ties > 0)
    }

    @Test func sourceOrderForRecentlyAddedAndMyOrder() {
        let e = entries
        #expect(MusicLibraryEngine.order(e, sort: .recentlyAdded) == Array(0..<e.count))
        #expect(MusicLibraryEngine.order(e, sort: .userOrder) == Array(0..<e.count))
    }

    @Test func filterMatchesBruteForce() {
        let e = entries
        let order = MusicLibraryEngine.order(e, sort: .title)
        var f = MusicLibraryFilterState(); f.query = "epsilon album 3"
        let got = MusicLibraryEngine.select(order: order, entries: e, filter: f, reversed: false)
        let terms = ["epsilon", "album", "3"]
        let want = order.filter { i in terms.allSatisfy { e[i].haystack.contains($0) } }
        #expect(got == want)
        #expect(!got.isEmpty)
        // Accents and case do not matter.
        f.query = "ÉPSILON"
        #expect(!MusicLibraryEngine.select(order: order, entries: e, filter: f, reversed: false).isEmpty)
    }

    @Test func sourceFilterAndReverse() {
        let e = entries
        let order = MusicLibraryEngine.order(e, sort: .recentlyAdded)
        var f = MusicLibraryFilterState(); f.source = "local"
        let local = MusicLibraryEngine.select(order: order, entries: e, filter: f, reversed: false)
        #expect(local.count == (0..<20_000).filter { $0 % 7 == 0 }.count)
        #expect(local.allSatisfy { e[$0].provider == "local" })
        #expect(MusicLibraryEngine.select(order: order, entries: e, filter: f, reversed: true) == local.reversed())
    }

    @Test func providersAreCountedMostFirst() {
        let p = MusicLibraryEngine.providers(entries)
        #expect(p.first?.id == "yt")
        #expect(p.map(\.count).reduce(0, +) == 20_000)
    }

    @Test func recentlyPlayedUsesTheLatestPlay() {
        let t = generated(5)
        let history = [PlayRecord(track: t[3], at: Date(timeIntervalSince1970: 500), playedMs: 1), PlayRecord(track: t[1], at: Date(timeIntervalSince1970: 400), playedMs: 1),
                       PlayRecord(track: t[3], at: Date(timeIntervalSince1970: 100), playedMs: 1)]
        let played = MusicLibraryEngine.lastPlayed(history)
        #expect(played[t[3].uid] == 500)
        let e = t.map { MusicLibraryEngine.trackEntry($0, playedAt: played[$0.uid] ?? 0) }
        #expect(Array(MusicLibraryEngine.order(e, sort: .recentlyPlayed).prefix(2)) == [3, 1])
    }

    @Test func releaseYearComesFromTheDate() {
        #expect(MusicLibraryEngine.year(of: "2019-05-03") == 2019)
        #expect(MusicLibraryEngine.year(of: "1999") == 1999)
        #expect(MusicLibraryEngine.year(of: nil) == 0)
        #expect(MusicLibraryEngine.year(of: "x") == 0)
    }

    @MainActor @Test func modelDeliversTheSameAnswerOffTheMainActor() async {
        let list = generated(20_000)
        let model = MusicLibraryListModel<MusicTrack> { t, _, _ in MusicLibraryEngine.trackEntry(t) }
        var f = MusicLibraryFilterState(); f.query = "gamma"
        model.apply(items: list, signature: MusicLibrarySignature.make(list, id: \.uid), request: MusicLibraryRequest(sort: .title, reversed: false, filter: f))
        for _ in 0..<400 where !model.hasResult { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(model.hasResult)
        #expect(model.total == 20_000)
        #expect(model.shown.count == list.filter { $0.artistLine.lowercased().contains("gamma") }.count)
        // A newer request replaces the older one.
        model.apply(items: list, signature: MusicLibrarySignature.make(list, id: \.uid), request: MusicLibraryRequest(sort: .duration, reversed: true))
        for _ in 0..<400 where model.shown.count != 20_000 { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(model.shown.count == 20_000)
        #expect(model.shown.first?.durationMs == model.shown.map(\.durationMs).max())
    }
}

@Suite("Library page rules") struct LibraryRulesTests {
    @Test func viewModeIsRememberedPerTab() {
        let prefs = MusicLibraryPrefs(defaults: freshDefaults())
        #expect(prefs.mode(.songs) == nil)
        prefs.setMode(.table, for: .songs)
        prefs.setMode(.list, for: .albums)
        #expect(prefs.mode(.songs) == .table)
        #expect(prefs.mode(.albums) == .list)
        #expect(prefs.mode(.artists) == nil)
    }

    @Test func gridIsNotTheDefaultForABigLibrary() {
        #expect(MusicLibraryModeRules.defaultMode(for: .albums, count: 40) == .grid)
        #expect(MusicLibraryModeRules.defaultMode(for: .albums, count: 5_000) == .list)
        #expect(MusicLibraryModeRules.defaultMode(for: .songs, count: 20_000) == .list)
        // A choice the person made is kept, even a grid of many.
        #expect(MusicLibraryModeRules.effective(saved: .grid, tab: .albums, count: 5_000) == .grid)
        // A mode the tab does not offer falls back.
        #expect(MusicLibraryModeRules.effective(saved: .table, tab: .albums, count: 10) == .grid)
    }

    @Test func tabsCollapseIntoAMenuWhenNarrow() {
        #expect(MusicLibraryTabStyle.resolve(layoutClass: .compact, contentWidth: 900) == .menu)
        #expect(MusicLibraryTabStyle.resolve(layoutClass: .medium, contentWidth: 640) == .menu)
        #expect(MusicLibraryTabStyle.resolve(layoutClass: .medium, contentWidth: 759) == .menu)
        #expect(MusicLibraryTabStyle.resolve(layoutClass: .medium, contentWidth: 760) == .segmented)
        #expect(MusicLibraryTabStyle.resolve(layoutClass: .expanded, contentWidth: 1100) == .segmented)
        #expect(MusicLibraryTabStyle.resolve(layoutClass: .wide, contentWidth: 0) == .segmented)
    }

    @Test func optionalTabsAppearOnlyWhenTheyHaveSomething() {
        let base = MusicLibraryTabs.visible(hasPodcasts: false, localFilesOn: false)
        #expect(base == [.songs, .albums, .artists, .playlists, .history])
        #expect(MusicLibraryTabs.visible(hasPodcasts: true, localFilesOn: true).contains(.podcasts))
        #expect(MusicLibraryTabs.visible(hasPodcasts: true, localFilesOn: true).contains(.local))
        #expect(MusicLibraryTabs.resolve(saved: .local, visible: base) == .songs)
        #expect(MusicLibraryTabs.resolve(saved: .history, visible: base) == .history)
    }

    @Test func everyTabHasItsOwnScrollKey() {
        let keys = MusicLibraryTab.allCases.map(\.scrollKey)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("library:") })
    }

    @Test func filterSurvivesNavigation() {
        let d = freshDefaults()
        let a = MusicLibraryPrefs(defaults: d)
        var f = MusicLibraryFilterState(); f.query = "rain"; f.source = "local"
        a.setFilter(f, for: .songs)
        a.setSort(.recentlyPlayed, reversed: true, for: .songs)
        a.tab = .albums
        // A new page value, as after leaving and coming back.
        let b = MusicLibraryPrefs(defaults: d)
        #expect(b.filter(.songs) == f)
        #expect(b.filter(.albums) == MusicLibraryFilterState())
        #expect(b.sort(.songs) == .recentlyPlayed && b.reversed(.songs))
        #expect(b.tab == .albums)
        b.setFilter(MusicLibraryFilterState(), for: .songs)
        #expect(MusicLibraryPrefs(defaults: d).filter(.songs).isActive == false)
    }

    @Test func aSortThatATabDoesNotOfferFallsBack() {
        let p = MusicLibraryPrefs(defaults: freshDefaults())
        p.setSort(.releaseDate, reversed: false, for: .songs)
        #expect(p.sort(.songs) == MusicLibraryTab.songs.defaultSort)
        #expect(MusicLibraryTab.albums.sorts.contains(.releaseDate))
    }

    @Test func emptyStateActionsOpenRealPlaces() {
        #expect(MusicLibraryEmptyAction.likeSong.destination == .section(.search))
        #expect(MusicLibraryEmptyAction.explore.destination == .section(.explore))
        #expect(MusicLibraryEmptyAction.downloads.destination == .section(.downloads))
        #expect(MusicLibraryEmptyAction.newPlaylist.destination == .newPlaylistPrompt)
        #expect(MusicLibraryEmptyAction.importMusic.destination == .importSheet)
        #expect(MusicLibraryEmptyAction.connectAccounts.destination == .settings(.plugins))
        #expect(MusicLibraryEmptyAction.localFiles.destination == .settings(.data))
        let songs = MusicLibraryEmptyAction.actions(for: .songs)
        #expect(songs.contains(.likeSong) && songs.contains(.importMusic) && songs.contains(.explore) && songs.contains(.connectAccounts) && songs.contains(.localFiles))
        #expect(MusicLibraryEmptyAction.actions(for: .playlists).contains(.newPlaylist))
        for t in MusicLibraryTab.allCases { #expect(!MusicLibraryEmptyAction.actions(for: t).isEmpty) }
    }

    @Test func historyPagingIsBounded() {
        #expect(MusicLibraryHistoryPaging.visible(total: 50_000, pages: 1) == 500)
        #expect(MusicLibraryHistoryPaging.visible(total: 120, pages: 3) == 120)
        let cal = Calendar(identifier: .gregorian)
        let d0 = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = [d0, d0.addingTimeInterval(60), d0.addingTimeInterval(-90_000)]
        #expect(MusicLibraryHistoryDays.startsDay(0, dates: dates, calendar: cal))
        #expect(!MusicLibraryHistoryDays.startsDay(1, dates: dates, calendar: cal))
        #expect(MusicLibraryHistoryDays.startsDay(2, dates: dates, calendar: cal))
    }

    @Test func trackListCacheReusesItsAnswer() async {
        await MainActor.run {
            let cache = MusicTrackListCache()
            let list = generated(300)
            let a = cache.snapshot(tracks: list, filter: "", ordering: MusicTrackOrdering(), presorted: false)
            let b = cache.snapshot(tracks: list, filter: "", ordering: MusicTrackOrdering(), presorted: false)
            #expect(a.signature == b.signature)
            #expect(a.list.count == 300 && a.position[list[10].uid] == 10)
            let c = cache.snapshot(tracks: list, filter: "gamma", ordering: MusicTrackOrdering(), presorted: false)
            #expect(c.signature != a.signature && c.list.count < 300)
            let p = cache.snapshot(tracks: Array(list.reversed()), filter: "gamma", ordering: MusicTrackOrdering(), presorted: true)
            #expect(p.list.count == 300)
        }
    }
}
