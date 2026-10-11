import Testing
import Foundation
@testable import REDDY

@Suite("Navigation, shortcuts, palette, state") @MainActor struct NavigationTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-nav-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    // MARK: router & sidebar

    @Test func everyFreshLaunchOpensHomeDiscover() {
        let r = AppRouter()
        #expect(r.tab == .home && r.selection == .shortcut(.discover))
        r.navigate(.movies, .shortcut(.recentlyAdded))
        #expect(AppRouter().tab == .home && AppRouter().selection == .shortcut(.discover), "nothing from a previous run is restored")
    }

    @Test func eachTabPinsExactlyItsShortcuts() {
        func titles(_ t: AppTab) -> [String] { Shortcut.pinned(for: t).map(\.title) }
        #expect(titles(.home) == ["Discover", "Continue Watching", "Recently Watched", "Watch History", "Favorites", "Collections", "Statistics"])
        #expect(titles(.movies) == ["Featured", "All Movies", "Recently Added", "Continue Watching", "Favorites"])
        #expect(titles(.series) == ["Library", "Recently Added", "Continue Watching", "Favorites"])
        #expect(titles(.liveTV) == ["All Channels", "Recently Added", "Recently Watched", "Favorites"])
        for t in AppTab.allCases { #expect(!titles(t).contains("In Progress")) }
    }

    @Test func tabsRememberTheirOwnSelection() {
        let r = AppRouter()
        r.navigate(.movies, .folder("cat-1"))
        r.navigate(.series)
        #expect(r.selection == .shortcut(.library))
        r.navigate(.movies)
        #expect(r.selection == .folder("cat-1"))
        r.navigate(.home)
        #expect(r.selection == .shortcut(.discover))
    }

    @Test func routerNavigationAndDetailSheets() {
        let r = AppRouter()
        let src = PlaylistSource(name: "S", type: .m3uRemote, baseURL: "x")
        let m = TestSupport.movie(src, "1", "Heat"), s = TestSupport.series(src, "2", "Dark")
        r.open(movie: m); #expect(r.movie?.id == m.id && r.series == nil)
        r.open(series: s); #expect(r.series?.id == s.id && r.movie == nil, "only one detail dialog at a time")
        r.closeDetail(); #expect(r.movie == nil && r.series == nil)
    }

    @Test func menusCloseTogetherAndNavigationClosesThem() {
        let r = AppRouter()
        r.accountMenuOpen = true; r.playlistMenuOpen = true
        r.closeMenus(); #expect(!r.accountMenuOpen && !r.playlistMenuOpen)
        r.playlistMenuOpen = true
        r.navigate(.liveTV); #expect(!r.playlistMenuOpen)
    }

    @Test func commandFFocusesTheScreensOwnSearch() {
        let r = AppRouter()
        for tab in [AppTab.liveTV, .movies, .series] {
            r.navigate(tab); let before = r.focusSearch
            r.focusCurrentScreenSearch()
            #expect(r.tab == tab && r.focusSearch == before + 1, "stays on \(tab.title)")
        }
    }

    @Test func searchIsInlineAndNeverAModal() {
        let r = AppRouter()
        #expect(!r.isSearching)
        r.searchQuery = "  "; #expect(!r.isSearching, "blank text is not a search")
        r.searchQuery = "heat"; #expect(r.isSearching && r.modal == nil, "typing opens nothing")
        let tab = r.tab, sel = r.selection
        r.clearSearch()
        #expect(!r.isSearching && r.tab == tab && r.selection == sel, "clearing returns to the same place")
        let before = r.topSearchFocus
        r.focusTopSearch(); #expect(r.topSearchFocus == before + 1 && r.modal == nil, "⌘K focuses the field")
    }

    // MARK: keyboard

    @Test func playerShortcutsAreContextAware() {
        func cmd(_ code: UInt16, playing: Bool = true, full: Bool = false, live: Bool = true) -> PlayerCommand? {
            PlayerShortcuts.resolve(keyCode: code, PlayerShortcutContext(hasPlayback: playing, isFullscreen: full, isLive: live))
        }
        #expect(cmd(49) == .togglePause && cmd(3) == .toggleFullscreen && cmd(46) == .toggleMute)
        #expect(cmd(49, playing: false) == nil && cmd(3, playing: false) == nil, "nothing to control without playback")
        #expect(cmd(53, full: true) == .exitFullscreen && cmd(53) == nil)
        // arrows are left to lists and the guide unless the player is fullscreen
        for k: UInt16 in [123, 124, 125, 126] { #expect(cmd(k) == nil, "key \(k) not claimed outside fullscreen") }
        #expect(cmd(126, full: true, live: true) == .channelUp && cmd(125, full: true, live: true) == .channelDown)
        #expect(cmd(126, full: true, live: false) == .adjustVolume(0.05) && cmd(125, full: true, live: false) == .adjustVolume(-0.05))
        #expect(cmd(123, full: true, live: false) == .seek(-10) && cmd(124, full: true, live: false) == .seek(10))
        #expect(cmd(123, full: true, live: true) == nil, "no seeking on a live stream")
        #expect(cmd(116) == .channelUp && cmd(121) == .channelDown && cmd(116, live: false) == nil)
        #expect(cmd(0) == nil, "unmapped keys are ignored so typing is never swallowed")
    }

    // MARK: palette

    // MARK: app state

    @Test func favoritesPersistAcrossAppStateInstances() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "1", "BBC")])
        let id = try #require(try c.catalog.channels(ChannelQuery()).first).id
        let a = AppState(container: c)
        #expect(a.toggleFavorite(id, kind: .channel) == true && a.isFavorite(id))
        let b = AppState(container: c); b.reload()
        #expect(b.isFavorite(id), "a fresh state loads hearts from the database")
        #expect(b.toggleFavorite(id, kind: .channel) == false && !b.isFavorite(id))
    }

    // MARK: playback coordinator (no real streams)

    @Test func coordinatorRemembersVideoLayoutPerChannelAndGlobally() throws {
        let c = try container()
        let src = try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/list.m3u")
        func ch(_ i: String) -> Channel {
            var x = TestSupport.channel(src, i, "Channel \(i)"); x.streamRef = "http://127.0.0.1:9/live/\(i).ts"; return x
        }
        try c.indexer.commitChannels(source: src, categories: [], channels: [ch("a"), ch("b"), ch("c")])
        let list = try c.catalog.channels(ChannelQuery(collapseVariants: false))
        let a = try #require(list.first { $0.providerID == "a" }), b = try #require(list.first { $0.providerID == "b" }), cc = try #require(list.first { $0.providerID == "c" })
        let p = c.playback

        p.play(channel: a)
        #expect(p.videoLayout.isDefault && !p.hasItemLayoutOverride)
        p.setZoom(1.5); p.setVideoSizeMode(.fill); p.setAspectRatio(.r4x3)
        #expect(p.videoLayout.zoom == 1.5 && p.videoLayout.mode == .fill)
        p.rememberLayoutForThisItem()
        #expect(p.hasItemLayoutOverride)

        p.play(channel: b)
        #expect(p.videoLayout.isDefault, "another channel is unaffected")
        p.play(channel: a)
        #expect(p.videoLayout.zoom == 1.5 && p.videoLayout.mode == .fill && p.videoLayout.aspect == .r4x3 && p.hasItemLayoutOverride, "restored for this channel")

        p.applyLayoutAsGlobalDefault()
        p.play(channel: cc)
        #expect(p.videoLayout.zoom == 1.5, "new channels start from the global default")
        p.resetVideoLayout(); #expect(p.videoLayout.isDefault)
        p.play(channel: a); p.removeItemLayoutOverride()
        #expect(!p.hasItemLayoutOverride)
        p.stop()
        #expect(p.state == .idle && p.current == nil, "stop clears the session")
    }

    @Test func coordinatorEngineAvailabilityAndQuietSwitching() throws {
        let c = try container()
        let p = c.playback
        #expect(p.availableEngines.contains(.avPlayer))
        #expect(p.activeEngine == .avPlayer)
        p.switchEngine(.avPlayer)                      // already active: no-op
        p.switchEngine(.mpv)                           // unavailable on this Mac: refused rather than faked
        if !p.availableEngines.contains(.mpv) { #expect(p.activeEngine == .avPlayer) }
        #expect(p.capabilities.qualitySelection && !p.capabilities.audioDelay, "AVPlayer capabilities are reported honestly")
        #expect(!p.capabilities.audioProcessing && !p.capabilities.subtitleDelay)
        p.setAudioDelay(99); #expect(p.audioDelay == 5, "delays are clamped")
        p.setSubtitleDelay(-99); #expect(p.subtitleDelay == -10)
    }
}
