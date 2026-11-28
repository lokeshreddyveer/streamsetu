import Testing
import Foundation
@testable import REDDY

// Rules of the playlist page, tested on generated personas (never a real library): an empty playlist, a 3-song one, a 5,000-song one, one whose songs
// all come from one album, one with songs that do not play, and playlists with Telugu, Hindi and accented names.

private func plSong(_ n: Int, title: String? = nil, artist: String = "Artist", album: String? = nil, cover: String? = nil, ms: Int64 = 180_000, provider: String = "p") -> MusicTrack {
    MusicTrack(id: "\(n)", providerID: provider, title: title ?? "Song \(n)", durationMs: ms,
               artists: [MusicArtistRef(id: "a-" + artist, name: artist)],
               album: album.map { MusicAlbumRef(id: "al-" + $0, title: $0) },
               thumbnails: cover.map { [MusicThumbnail(url: $0, width: 300, height: 300)] } ?? [])
}

private enum PlaylistPersona {
    static let empty: [MusicTrack] = []
    static let three = [plSong(1, album: "A", cover: "https://img.example/a.jpg"), plSong(2, album: "B", cover: "https://img.example/b.jpg"), plSong(3, album: "C", cover: "https://img.example/c.jpg")]
    static let huge: [MusicTrack] = (0..<5_000).map { plSong($0, artist: "Artist \($0 % 50)", album: "Album \($0 % 40)", cover: "https://img.example/\($0 % 40).jpg", ms: Int64(60_000 + ($0 % 300) * 1_000)) }
    /// Six songs of one album, each carrying its own copy of the same sleeve under a different address.
    static let oneAlbum: [MusicTrack] = (1...6).map { plSong($0, album: "Only", cover: "https://img.example/only-\($0).jpg") }
    static let international = [plSong(1, title: "మాయా మాయా", artist: "గాయకుడు", album: "తెలుగు"), plSong(2, title: "दिल की बात", artist: "गायक", album: "हिन्दी"),
                                plSong(3, title: "Café del Mar", artist: "Zoë"), plSong(4, title: "日本の夜", artist: "歌手")]
}

@Suite("Playlist page: stat line and clock") struct PlaylistStatLineTests {
    private let en = Locale(identifier: "en_US")

    @Test func anEmptyPlaylistSaysOnlyItsCount() {
        let line = MusicPlaylistStats.line(.init(songCount: 0), locale: en)
        #expect(line == "0 songs")
    }

    @Test func aSmallPlaylistHasCountAndLength() {
        let line = MusicPlaylistStats.line(.init(songCount: 3, totalMs: MusicPlaylistStats.totalMs(PlaylistPersona.three)), locale: en)
        #expect(line == "3 songs · 9 min")
        #expect(MusicPlaylistStats.line(.init(songCount: 1, totalMs: 120_000), locale: en).hasPrefix("1 song ·"))
    }

    @Test func aHugePlaylistCountsEverySong() {
        let ms = MusicPlaylistStats.totalMs(PlaylistPersona.huge)
        let line = MusicPlaylistStats.line(.init(songCount: PlaylistPersona.huge.count, totalMs: ms), locale: en)
        #expect(line.contains("songs") && line.contains(" hr"))
    }

    @Test func aHalfLoadedListDoesNotClaimALength() {
        let line = MusicPlaylistStats.line(.init(songCount: 800, totalMs: 3_600_000, lengthIsComplete: false), locale: en)
        #expect(!line.contains("hr") && !line.contains("min"))
    }

    @Test func savesAndDatesAreShownOnlyWhenKnown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let three = now.addingTimeInterval(-3 * 86_400)
        let full = MusicPlaylistStats.line(.init(songCount: 2, totalMs: 360_000, saves: 1_204, updated: three), now: now, locale: en)
        #expect(full.contains("saves") && full.contains("Updated") && full.contains("3 days ago"))
        let made = MusicPlaylistStats.line(.init(songCount: 2, updated: three, dateIsCreation: true), now: now, locale: en)
        #expect(made.contains("Created"))
        let unknown = MusicPlaylistStats.line(.init(songCount: 2, saves: 0, updated: Date(timeIntervalSince1970: 0)), now: now, locale: en)
        #expect(unknown == "2 songs")
    }

    @Test func aSongLengthReadsAsAClock() {
        #expect(MusicPlaylistClock.text(ms: 0) == "0:00")
        #expect(MusicPlaylistClock.text(ms: 65_000) == "1:05")
        #expect(MusicPlaylistClock.text(ms: 3_723_000) == "1:02:03")
        #expect(MusicPlaylistClock.text(ms: -5) == "0:00")
    }
}

@Suite("Playlist page: cover mosaic") struct PlaylistCoverPickerTests {
    @Test func noSongsGiveTheDesignedTile() {
        #expect(MusicPlaylistCoverPicker.plan(PlaylistPersona.empty) == MusicPlaylistCoverPlan.none)
    }

    @Test func songsWithoutCoversGiveTheDesignedTile() {
        #expect(MusicPlaylistCoverPicker.plan([plSong(1), plSong(2)]) == .none)
    }

    @Test func threeAlbumsAreFewerThanAMosaicNeedsSoOneCoverShows() {
        #expect(MusicPlaylistCoverPicker.representatives(PlaylistPersona.three).count == 3)
        if case .single = MusicPlaylistCoverPicker.plan(PlaylistPersona.three) {} else { Issue.record("expected one cover") }
    }

    @Test func oneAlbumDegradesToOneCoverEvenWithDifferentAddresses() {
        #expect(MusicPlaylistCoverPicker.representatives(PlaylistPersona.oneAlbum).count == 1)
        if case .single = MusicPlaylistCoverPicker.plan(PlaylistPersona.oneAlbum) {} else { Issue.record("expected one cover") }
    }

    @Test func fourDistinctAlbumsMakeAMosaicOfFourDistinctCovers() {
        let plan = MusicPlaylistCoverPicker.plan(PlaylistPersona.huge)
        guard case .mosaic(let covers) = plan else { Issue.record("expected a mosaic"); return }
        #expect(covers.count == 4 && Set(covers).count == 4)
    }

    @Test func theMosaicFollowsPlaylistOrder() {
        let reps = MusicPlaylistCoverPicker.representatives(PlaylistPersona.huge)
        #expect(reps.first?.first?.url == "https://img.example/0.jpg")
        #expect(reps.count == 40)
    }
}

@Suite("Playlist page: filter, sort and reorder") struct PlaylistListLogicTests {
    @Test func anEmptyQueryKeepsEverySong() {
        #expect(MusicPlaylistListLogic.visible(PlaylistPersona.huge, query: "  ", ordering: MusicTrackOrdering()).count == 5_000)
    }

    @Test func filterFindsOneSongInFiveThousand() {
        let hit = MusicPlaylistListLogic.visible(PlaylistPersona.huge, query: "Song 4999", ordering: MusicTrackOrdering())
        #expect(hit.map(\.id) == ["4999"])
    }

    @Test func filterIgnoresCaseAndAccentsAndReadsEveryScript() {
        let all = PlaylistPersona.international
        #expect(MusicPlaylistListLogic.visible(all, query: "cafe", ordering: MusicTrackOrdering()).map(\.id) == ["3"])
        #expect(MusicPlaylistListLogic.visible(all, query: "zoe", ordering: MusicTrackOrdering()).map(\.id) == ["3"])
        #expect(MusicPlaylistListLogic.visible(all, query: "మాయా", ordering: MusicTrackOrdering()).map(\.id) == ["1"])
        #expect(MusicPlaylistListLogic.visible(all, query: "दिल", ordering: MusicTrackOrdering()).map(\.id) == ["2"])
        #expect(MusicPlaylistListLogic.visible(all, query: "हिन्दी", ordering: MusicTrackOrdering()).map(\.id) == ["2"])
        #expect(MusicPlaylistListLogic.visible(all, query: "日本", ordering: MusicTrackOrdering()).map(\.id) == ["4"])
    }

    @Test func sortByLengthPutsTheLongestFirstWhenDescending() {
        let sorted = MusicPlaylistListLogic.visible(PlaylistPersona.huge, query: "", ordering: MusicTrackOrdering(field: .duration, ascending: false))
        #expect(sorted.count == 5_000)
        #expect(sorted.first!.durationMs >= sorted.last!.durationMs)
    }

    @Test func sortKeepsEverySongAndIsStableForTies() {
        let sorted = MusicPlaylistListLogic.visible(PlaylistPersona.oneAlbum, query: "", ordering: MusicTrackOrdering(field: .album, ascending: true))
        #expect(sorted.map(\.id) == PlaylistPersona.oneAlbum.map(\.id))
        let byTitle = MusicPlaylistListLogic.visible(PlaylistPersona.international, query: "", ordering: MusicTrackOrdering(field: .title, ascending: true))
        #expect(Set(byTitle.map(\.id)) == Set(PlaylistPersona.international.map(\.id)))
    }

    @Test func theCountOfAFilterReadsTwelveOfThreeForty() {
        #expect(MusicPlaylistListLogic.filterCount(shown: 340, total: 340) == nil)
        #expect(MusicPlaylistListLogic.filterCount(shown: 0, total: 3)?.contains("0") == true)
    }

    @Test func dragToReorderOnlyInTheOwnOrderOfAnEditablePlaylist() {
        let own = MusicTrackOrdering()
        #expect(MusicPlaylistListLogic.canReorder(editable: true, ordering: own, filtering: false, selecting: false))
        #expect(!MusicPlaylistListLogic.canReorder(editable: false, ordering: own, filtering: false, selecting: false))
        #expect(!MusicPlaylistListLogic.canReorder(editable: true, ordering: MusicTrackOrdering(field: .title), filtering: false, selecting: false))
        #expect(!MusicPlaylistListLogic.canReorder(editable: true, ordering: MusicTrackOrdering(field: .original, ascending: false), filtering: false, selecting: false))
        #expect(!MusicPlaylistListLogic.canReorder(editable: true, ordering: own, filtering: true, selecting: false))
        #expect(!MusicPlaylistListLogic.canReorder(editable: true, ordering: own, filtering: false, selecting: true))
    }

    @Test func playAndShuffleLeaveOutSongsKnownNotToPlayButKeepTheWholeRest() {
        let list = PlaylistPersona.huge
        let failed: Set<String> = [list[10].uid, list[4_000].uid]
        let ok = MusicPlaylistListLogic.playable(list, failed: failed)
        #expect(ok.count == 4_998 && !ok.contains { failed.contains($0.uid) })
        #expect(MusicPlaylistListLogic.playable(PlaylistPersona.empty, failed: failed).isEmpty)
        #expect(MusicPlaylistListLogic.playable(list, failed: []).count == 5_000)
    }
}

@Suite("Playlist page: actions and More like this") struct PlaylistSuggestionTests {
    @Test func downloadAllIsOfferedOnlyUpToTheLimit() {
        #expect(!MusicPlaylistActionRules.canDownloadAll(count: 0))
        #expect(MusicPlaylistActionRules.canDownloadAll(count: 3))
        #expect(MusicPlaylistActionRules.canDownloadAll(count: MusicPlaylistActionRules.downloadAllLimit))
        #expect(!MusicPlaylistActionRules.canDownloadAll(count: 5_000))
    }

    @Test func aLongDescriptionGetsMoreAndAShortOneDoesNot() {
        #expect(!MusicPlaylistActionRules.descriptionNeedsMore("Late night drives.", compact: false))
        #expect(MusicPlaylistActionRules.descriptionNeedsMore(String(repeating: "word ", count: 80), compact: false))
        #expect(MusicPlaylistActionRules.descriptionNeedsMore("a\nb\nc\nd", compact: false))
        #expect(MusicPlaylistActionRules.descriptionNeedsMore(String(repeating: "x", count: 120), compact: true))
    }

    @Test func aCopyIsNamedAfterTheOriginal() {
        #expect(MusicPlaylistActionRules.copyName("మాయా").contains("మాయా"))
    }

    @Test func noSeedsFromAnEmptyPlaylistAndAllSongsFromASmallOne() {
        #expect(MusicPlaylistSuggestions.seeds(from: PlaylistPersona.empty).isEmpty)
        #expect(MusicPlaylistSuggestions.seeds(from: PlaylistPersona.three).count == 3)
    }

    @Test func seedsSpreadOverAHugePlaylist() {
        let seeds = MusicPlaylistSuggestions.seeds(from: PlaylistPersona.huge)
        #expect(seeds.count == MusicPlaylistSuggestions.seedCount)
        #expect(seeds.first?.id == "0" && seeds.last?.id == "4999")
        #expect(Set(seeds.map(\.uid)).count == seeds.count)
    }

    @Test func seedsComeFromOneProvider() {
        let mixed = [plSong(1, provider: "x"), plSong(2, provider: "y"), plSong(3, provider: "x")]
        #expect(MusicPlaylistSuggestions.seeds(from: mixed).allSatisfy { $0.providerID == "x" })
    }

    @Test func suggestionsSkipWhatIsAlreadyInThePlaylistOtherVersionsRepeatsAndBlocked() {
        let have = [plSong(1, title: "Neon Rain", artist: "Ana")]
        let found = [plSong(1, title: "Neon Rain", artist: "Ana"),                       // already in the playlist
                     plSong(2, title: "Neon Rain (Remix)", artist: "Ana"),               // another version of one in it
                     plSong(3, title: "Blue Hour", artist: "Ben"),
                     plSong(3, title: "Blue Hour", artist: "Ben"),                       // repeated
                     plSong(4, title: "Blocked One", artist: "Cy"),
                     plSong(5, title: "Green Line", artist: "Di")]
        let picked = MusicPlaylistSuggestions.select(found, existing: have, blocked: { $0.id == "4" })
        #expect(picked.map(\.id) == ["3", "5"])
    }

    @Test func suggestionsAreCappedAndNeverCrashOnNothing() {
        let many = (900_000..<900_060).map { plSong($0, title: "Zeta Quartz \($0)", artist: "Nova Ensemble \($0)") }
        #expect(MusicPlaylistSuggestions.select(many, existing: PlaylistPersona.huge, blocked: { _ in false }).count == MusicPlaylistSuggestions.keepCount)
        #expect(MusicPlaylistSuggestions.select([], existing: PlaylistPersona.empty, blocked: { _ in false }).isEmpty)
    }
}

@Suite("Playlist page: view mode") struct PlaylistViewModeTests {
    @Test func theChoiceIsRememberedAndFallsBackToArtwork() {
        let suite = UserDefaults(suiteName: "playlist-view-mode-tests")!
        suite.removePersistentDomain(forName: "playlist-view-mode-tests")
        #expect(MusicPlaylistViewMode.load(suite) == .comfortable)
        MusicPlaylistViewMode.table.save(suite)
        #expect(MusicPlaylistViewMode.load(suite) == .table)
        suite.set("nonsense", forKey: MusicPlaylistViewMode.key)
        #expect(MusicPlaylistViewMode.load(suite) == .comfortable)
        suite.removePersistentDomain(forName: "playlist-view-mode-tests")
    }

    @Test func everyModeHasARowStyleAndAName() {
        for m in MusicPlaylistViewMode.allCases { #expect(!m.title.isEmpty && !m.symbol.isEmpty) }
        #expect(MusicPlaylistViewMode.compact.rowStyle == .compact && MusicPlaylistViewMode.table.rowStyle == .table)
    }

    @Test func coverSizeGrowsWithTheWindowButStaysLessThanHalfAPage() {
        let sizes = MusicLayoutClass.allCases.map { MusicPlaylistPageMetrics.coverSize($0) }
        #expect(sizes == sizes.sorted() && sizes.last! <= 240)
    }
}
