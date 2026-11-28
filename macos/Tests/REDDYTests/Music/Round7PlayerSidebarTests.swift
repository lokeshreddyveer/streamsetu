import Testing
import Foundation
@testable import REDDY

@MainActor @Suite("Round 7: player, queue, lyrics and left sidebar") struct Round7PlayerSidebarTests {
    private func tracks(_ n: Int, prefix: String = "t") -> [MusicTrack] {
        (0..<n).map { MusicTrack(id: "\(prefix)\($0)", providerID: "p", title: "Song \($0)", durationMs: 200_000, artists: [MusicArtistRef(id: "a\($0 % 3)", name: "Artist \($0 % 3)")]) }
    }

    // MARK: queue

    @Test func addingToAnEmptyQueueKeepsShuffleOn() {
        var q = MusicQueue()
        q.replace(with: tracks(3), startAt: 0)
        q.setShuffle(true)
        _ = q.removeUpcoming()
        _ = q.remove(at: 0)
        #expect(q.entries.isEmpty)
        #expect(q.shuffle)   // the player's shuffle button is still on here; the queue must agree after the add
        _ = q.addToQueue(tracks(1, prefix: "n"))
        #expect(q.shuffle)
    }

    @Test func turningShuffleOffReturnsAnAddedAlbumInItsOwnOrder() {
        var q = MusicQueue()
        q.replace(with: tracks(2), startAt: 0)
        q.setShuffle(true)
        let reverse: MusicQueue.Shuffler = { rows in rows.reverse() }
        let album = tracks(4, prefix: "alb")
        _ = q.addToQueue(album, from: "Album", shuffler: reverse)
        q.setShuffle(false)
        let ids = q.entries.map { $0.track.id }.filter { $0.hasPrefix("alb") }
        #expect(ids == album.map(\.id))
    }

    // MARK: stop after

    @Test func stopAfterIsStaleOnlyWhenItsRowWasSkippedOver() {
        let ids = (0..<5).map { _ in UUID() }
        #expect(MusicPlayer.stopAfterIsStale(stopID: ids[1], currentID: ids[3], rowIDs: ids, currentIndex: 3))
        #expect(!MusicPlayer.stopAfterIsStale(stopID: ids[4], currentID: ids[3], rowIDs: ids, currentIndex: 3))
        #expect(!MusicPlayer.stopAfterIsStale(stopID: ids[3], currentID: ids[3], rowIDs: ids, currentIndex: 3))
        #expect(MusicPlayer.stopAfterIsStale(stopID: UUID(), currentID: ids[3], rowIDs: ids, currentIndex: 3))
        #expect(!MusicPlayer.stopAfterIsStale(stopID: nil, currentID: ids[3], rowIDs: ids, currentIndex: 3))
    }

    @Test func aMediaKeyRepeatWindowIsShorterThanTwoRealPresses() {
        #expect(MusicPlayer.remoteSkipRepeatWindow <= 0.25)
    }

    // MARK: lyric clock

    @Test func theClockIgnoresARepeatedReadingButNotAJumpOrAStateChange() {
        #expect(MusicLyricsTimeKeeper.isRepeat(position: 12.5, lastPosition: 12.5, playing: true, lastPlaying: true, discontinuity: false))
        #expect(!MusicLyricsTimeKeeper.isRepeat(position: 12.75, lastPosition: 12.5, playing: true, lastPlaying: true, discontinuity: false))
        #expect(!MusicLyricsTimeKeeper.isRepeat(position: 12.5, lastPosition: 12.5, playing: true, lastPlaying: true, discontinuity: true))
        #expect(!MusicLyricsTimeKeeper.isRepeat(position: 12.5, lastPosition: 12.5, playing: false, lastPlaying: true, discontinuity: false))
        #expect(!MusicLyricsTimeKeeper.isRepeat(position: 0, lastPosition: nil, playing: true, lastPlaying: false, discontinuity: false))
    }

    @Test func extraLyricLinesAreAskedForWhenTheirSwitchIsOnAndTheSongHasNone() {
        let both = MusicLyricsExtrasRequest.plan(showRomanisation: true, showTranslation: true, hasRomanization: false, hasTranslation: false, translatorAvailable: true, isEmpty: false)
        #expect(both.romanise && both.translate)
        let has = MusicLyricsExtrasRequest.plan(showRomanisation: true, showTranslation: true, hasRomanization: true, hasTranslation: true, translatorAvailable: true, isEmpty: false)
        #expect(!has.romanise && !has.translate)
        let noTranslator = MusicLyricsExtrasRequest.plan(showRomanisation: false, showTranslation: true, hasRomanization: false, hasTranslation: false, translatorAvailable: false, isEmpty: false)
        #expect(!noTranslator.romanise && !noTranslator.translate)
        let empty = MusicLyricsExtrasRequest.plan(showRomanisation: true, showTranslation: true, hasRomanization: false, hasTranslation: false, translatorAvailable: true, isEmpty: true)
        #expect(!empty.romanise && !empty.translate)
    }

    // MARK: sidebar

    @Test func arrowKeysSkipRowsOfAFoldedGroup() {
        let folded = MusicSidebar.rowIDs(primary: ["home"], more: ["settings"], playlists: ["p1"], libraryFolded: true, playlistsFolded: true, collapsed: false)
        #expect(!folded.contains("playlist:p1"))
        #expect(!folded.contains("shortcut:songs"))
        #expect(folded.contains("shortcut:link"))
        let open = MusicSidebar.rowIDs(primary: ["home"], more: ["settings"], playlists: ["p1"], libraryFolded: false, playlistsFolded: false, collapsed: false)
        #expect(open == ["section:home", "shortcut:recent", "shortcut:artists", "shortcut:albums", "shortcut:songs", "section:settings", "shortcut:link", "newplaylist", "shortcut:allplaylists", "playlist:p1"])
        let rail = MusicSidebar.rowIDs(primary: ["home"], more: [], playlists: ["p1"], libraryFolded: true, playlistsFolded: true, collapsed: true)
        #expect(rail.contains("playlist:p1") && rail.contains("shortcut:songs"))
    }

    @Test func theNewPlaylistRowTakesTheArrowKeys() {
        let ids = MusicSidebar.rowIDs(primary: ["home"], more: [], playlists: [], libraryFolded: true, playlistsFolded: true, collapsed: false)
        #expect(ids.contains("newplaylist") && !ids.contains { $0.hasPrefix("recent:") })
    }

    @Test func aShortcutRowIsLitForItsPage() {
        #expect(MusicSidebar.litShortcut(section: .library, top: nil, standaloneTab: .songs) == "songs")
        #expect(MusicSidebar.litShortcut(section: .library, top: nil, standaloneTab: .playlists) == "allplaylists")
        #expect(MusicSidebar.litShortcut(section: .library, top: .collection(.recentlyPlayed), standaloneTab: nil) == "recent")
        #expect(MusicSidebar.litShortcut(section: .home, top: nil, standaloneTab: .songs) == nil)
        #expect(!MusicSidebar.isSectionLit(.library, section: .library, top: nil, standaloneTab: .songs, libraryRowsShown: true, playlistRowsShown: true))
        #expect(MusicSidebar.isSectionLit(.library, section: .library, top: nil, standaloneTab: .songs, libraryRowsShown: false, playlistRowsShown: true))
    }

    @Test func settingsOpeningAsASheetDoesNotCloseTheOpenSidebar() {
        #expect(!MusicSidebarPeek.closesOnNavigation(from: .settings, to: .library))
        #expect(MusicSidebarPeek.closesOnNavigation(from: .home, to: .library))
        #expect(!MusicSidebarPeek.mayClose(menuTracking: true))
    }

    @Test func aDeletedPlaylistLeavesTheWholeStack() {
        let id = UUID()
        var nav = MusicNav()
        nav.select(.library)
        nav.push(.localPlaylist(id)); nav.push(.collection(.recentlyPlayed))
        nav.remove { $0 == .localPlaylist(id) }
        #expect(!nav.stack.contains(.localPlaylist(id)))
    }

    @Test func libraryIsNotLitWhileAPlaylistIsThePage() {
        #expect(MusicSidebar.isPlaylistPage(.localPlaylist(UUID())))
        #expect(!MusicSidebar.isPlaylistPage(nil))
    }

    @Test func aLocalPlaylistSourceIDMatchesItsEntityUID() {
        let p = LocalPlaylist(name: "Mix")
        let entity = MusicPlaylist(id: p.id.uuidString, providerID: MusicStatsRules.localProviderID, name: p.name, thumbnails: [])
        #expect(p.sourceID == entity.uid)
    }

    @Test func recentlyAddedHasAnAutomationCommand() {
        #expect(MusicCommandName.allCases.contains(.openRecentlyAdded))
        #expect(MusicCommandName.openRecentlyAdded.scope == .navigate)
    }

    // MARK: strings

    @Test func theNewSidebarAndPlayerStringsHaveHindiAndTeluguLines() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1, !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Resources/Localization").path) { dir.deleteLastPathComponent() }
        let keys = ["Auto-hide sidebar", "Keep sidebar open", "Playlist %@", "Folded", "Following the host", "Open Recently Added", "Translated to %@", "Every track in the queue is blocked."]
        for lang in ["hi", "te"] {
            let url = dir.appendingPathComponent("Resources/Localization/\(lang).lproj/Localizable.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            for k in keys { #expect(text.contains("\"\(k)\" ="), "missing \(lang): \(k)") }
        }
    }
}
