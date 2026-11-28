import Testing
import Foundation
@testable import REDDY

@Suite("Music shell: history, panel, geometry, links") @MainActor struct MusicShellTests {
    private let album = MusicAlbum(id: "a1", providerID: "p", title: "Album")
    private let artist = MusicArtist(id: "r1", providerID: "p", name: "Artist")

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "music.shell.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    // MARK: history

    @Test func backAfterSwitchingSectionReturnsToTheSectionBefore() {
        var h = MusicNavHistory()
        #expect(h.observe(MusicNavEntry(section: .search)) == .recorded)
        #expect(h.observe(MusicNavEntry(section: .library)) == .recorded)
        #expect(h.canGoBack && !h.canGoForward)
        #expect(h.back() == MusicNavEntry(section: .search))
        #expect(h.back() == MusicNavEntry(section: .home))
        #expect(h.back() == nil)
        #expect(h.forward() == MusicNavEntry(section: .search))
        #expect(h.depth.depth == 1 && h.depth.deepest == 2)
    }

    @Test func newNavigationForgetsWhatWasAhead() {
        var h = MusicNavHistory()
        h.observe(MusicNavEntry(section: .search)); h.observe(MusicNavEntry(section: .library))
        _ = h.back()
        #expect(h.observe(MusicNavEntry(section: .radio)) == .recorded)
        #expect(!h.canGoForward)
        #expect(h.entries.map(\.section) == [.home, .search, .radio])
    }

    @Test func thePagesOwnBackIsRecognisedAsAStepBack() {
        var h = MusicNavHistory()
        h.observe(MusicNavEntry(section: .library))
        h.observe(MusicNavEntry(section: .library, stack: [.album(album)]))
        h.observe(MusicNavEntry(section: .library, stack: [.album(album), .artist(artist)]))
        // The page pops one route itself.
        #expect(h.observe(MusicNavEntry(section: .library, stack: [.album(album)])) == .steppedBack)
        #expect(h.canGoForward)
        #expect(h.observe(MusicNavEntry(section: .library, stack: [.album(album)])) == .unchanged)
        #expect(h.observe(MusicNavEntry(section: .library, stack: [.album(album), .artist(artist)])) == .steppedForward)
    }

    @Test func entriesCarryTheirScrollKey() {
        #expect(MusicNavEntry(section: .explore).scrollKey == MusicScrollKey.section(.explore))
        #expect(MusicNavEntry(section: .library, stack: [.album(album)]).scrollKey == MusicScrollKey.route(.album(album)))
    }

    @Test func historyIsCapped() {
        var h = MusicNavHistory()
        for _ in 0..<(MusicNavHistory.capacity + 20) { h.observe(MusicNavEntry(section: .library, stack: [.localPlaylist(UUID())])) }
        #expect(h.entries.count == MusicNavHistory.capacity)
        #expect(h.index == h.entries.count - 1)
    }

    @Test func navRestoreSetsSectionAndStack() {
        var nav = MusicNav()
        nav.restore(MusicNavEntry(section: .library, stack: [.album(album)]))
        #expect(nav.section == .library && nav.top == .album(album))
    }

    // MARK: sections

    @Test func everySectionIsInExactlyOneGroupAndReachable() {
        let primary = MusicSection.primarySections, more = MusicSection.moreSections
        #expect(primary == [.home, .explore, .recentlyAdded, .search, .library, .radio])
        #expect(Set(primary).isDisjoint(with: more))
        #expect(Set(primary + more) == Set(MusicSection.allCases))
        // The routes that existed before (Downloads, Devices, Listen Together, Settings) are still sections.
        for s in [MusicSection.downloads, .devices, .room, .settings] { #expect(more.contains(s)) }
        for s in MusicSection.allCases { #expect(MusicSection.from(linkName: s.linkName) == s) }
        #expect(Set(MusicSection.allCases.map(\.linkName)).count == MusicSection.allCases.count)
    }

    // MARK: context panel

    @Test func tabsAreSixInOrder() {
        #expect(MusicContextPanelTab.allCases == [.nowPlaying, .queue, .lyrics, .related, .credits, .info])
        for t in MusicContextPanelTab.allCases { #expect(!t.title.isEmpty && !t.symbol.isEmpty) }
    }

    @Test func savedPanelMemoryWithAnUnknownTabStillLoads() throws {
        // Written by a build that knows more tabs than this one: the known sections keep their choice, the unknown tab reads as Now Playing.
        let json = #"{"entries":{"home":{"isOpen":true,"tab":"lyrics"},"library":{"isOpen":true,"tab":"someFutureTab"}}}"#
        let m = MusicContextPanelMemory.decode(Data(json.utf8))
        #expect(m.entry(for: .home) == .init(isOpen: true, tab: .lyrics))
        #expect(m.entry(for: .library) == .init(isOpen: true, tab: .nowPlaying))
        // The new tab round-trips, and a memory saved before it existed still decodes unchanged.
        var saved = MusicContextPanelMemory()
        saved.set(.init(isOpen: true, tab: .credits), for: .explore)
        #expect(MusicContextPanelMemory.decode(saved.encoded()).entry(for: .explore).tab == .credits)
        let old = #"{"entries":{"home":{"isOpen":false,"tab":"info"}}}"#
        #expect(MusicContextPanelMemory.decode(Data(old.utf8)).entry(for: .home).tab == .info)
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let state = MusicContextPanelState(defaults: d)
        state.show(.credits)
        #expect(state.isOpen && state.selectedTab == .credits && state.legacyPanel == nil)
    }

    @Test func aPageRemembersItsTabButArrivingNeverOpensThePanel() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let s = MusicContextPanelState(defaults: d)
        s.enter(.home); #expect(!s.isOpen)
        s.show(.related)
        #expect(s.isOpen && s.selectedTab == .related)
        s.enter(.library)
        #expect(!s.isOpen && s.selectedTab == .nowPlaying)
        s.show(.queue)
        #expect(s.isOpen && s.selectedTab == .queue)
        s.enter(.home)
        #expect(!s.isOpen)                         // it was open here before, but arriving does not reopen it
        #expect(s.selectedTab == .related)         // the tab is still remembered
        s.toggleOpen()
        #expect(s.isOpen && s.selectedTab == .related)
        s.toggle(.related)
        #expect(!s.isOpen)
        s.enter(.library)
        #expect(!s.isOpen && s.selectedTab == .queue)
    }

    @Test func aPanelSavedOpenByAnEarlierLaunchStaysClosedUntilOpenedAgain() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let first = MusicContextPanelState(defaults: d)
        first.enter(.home); first.show(.queue)
        let second = MusicContextPanelState(defaults: d)
        second.enter(.home)
        #expect(!second.isOpen && second.selectedTab == .queue)
        second.toggleOpen(); #expect(second.isOpen)
    }

    @Test func lyricsButtonsOpenTheStripAndTheSidePanelTabStaysInsideThePanel() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let s = MusicContextPanelState(defaults: d)
        s.enter(.home)
        s.show(.lyrics)
        #expect(s.lyricsStripOpen && !s.isOpen && s.legacyPanel == .lyrics)
        // The button that opened it closes it (the bar toggles through the legacy bridge).
        s.setLegacy(nil)
        #expect(!s.lyricsStripOpen && !s.isOpen)
        s.toggle(.lyrics); #expect(s.lyricsStripOpen)
        s.toggle(.lyrics); #expect(!s.lyricsStripOpen)
        // Opening the queue while the strip is up closes the strip and opens the panel.
        s.show(.lyrics); s.setLegacy(.queue)
        #expect(!s.lyricsStripOpen && s.isOpen && s.selectedTab == .queue)
        // The panel's own Lyrics tab shows the lyrics inside the panel: no strip, the panel stays open on Lyrics.
        s.select(.lyrics)
        #expect(!s.lyricsStripOpen && s.isOpen && s.selectedTab == .lyrics)
        s.close()
        #expect(!s.isOpen)
    }

    @Test func theFloatingPanelButtonHidesWhileThePanelIsOpenBecauseThePanelHasItsOwnCloseButton() {
        #expect(MusicPanelPresentation.showsToggleButton(hasTrack: true, panelShown: false))
        #expect(!MusicPanelPresentation.showsToggleButton(hasTrack: true, panelShown: true))
        #expect(!MusicPanelPresentation.showsToggleButton(hasTrack: false, panelShown: false))
    }

    @Test func panelStatePersistsAcrossInstances() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let a = MusicContextPanelState(defaults: d)
        a.enter(.search); a.show(.info)
        let b = MusicContextPanelState(defaults: d)
        b.enter(.search)
        #expect(!b.isOpen, "arriving never opens the panel, even one saved open")
        #expect(b.selectedTab == .related, "a panel last left on the retired Info tab opens on Related")
        b.enter(.radio)
        #expect(!b.isOpen)
    }

    @Test func closingThePanelLeavesTheLyricsStripAlone() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let s = MusicContextPanelState(defaults: d)
        s.enter(.home); s.show(.queue); s.lyricsStripOpen = true
        s.closePanel()
        #expect(!s.isOpen && s.lyricsStripOpen)
    }

    @Test func aSavedOpenPanelOpensAgainOnTheFirstExplicitAction() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let a = MusicContextPanelState(defaults: d)
        a.enter(.search); a.show(.info)
        let b = MusicContextPanelState(defaults: d)
        b.enter(.search)
        #expect(!b.isOpen)
        b.show(.info)
        #expect(b.isOpen, "memory already said open, yet the person's own action must still open it")
    }

    @Test func toggleWorksOnWhatIsShownNotOnWhatIsRemembered() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let s = MusicContextPanelState(defaults: d)
        s.enter(.home); s.show(.queue)
        s.disarmOverlay()                         // window shrank: open in memory, nothing drawn
        s.toggleOpen(shown: false)
        #expect(s.isOpen && s.overlayArmed, "one press opens it")
        s.toggleOpen(shown: true)
        #expect(!s.isOpen)
    }

    @Test func showPanelOpensTheLyricsTabInsideThePanel() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let s = MusicContextPanelState(defaults: d)
        s.enter(.home); s.showPanel(.lyrics)
        #expect(s.isOpen && s.selectedTab == .lyrics && !s.lyricsStripOpen)
    }

    @Test func legacyBridgeMapsTheThreeOlderPanels() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let s = MusicContextPanelState(defaults: d)
        #expect(s.legacyPanel == nil)
        s.setLegacy(.queue); #expect(s.isOpen && s.selectedTab == .queue && s.legacyPanel == .queue)
        s.show(.related); #expect(s.legacyPanel == nil)
        s.setLegacy(nil); #expect(!s.isOpen)
    }

    // MARK: geometry

    @Test func layoutClassesChangeAtTheBreakpoints() {
        #expect(MusicLayoutClass.resolve(width: 699) == .compact)
        #expect(MusicLayoutClass.resolve(width: 700) == .medium)
        #expect(MusicLayoutClass.resolve(width: 999) == .medium)
        #expect(MusicLayoutClass.resolve(width: 1000) == .expanded)
        #expect(MusicLayoutClass.resolve(width: 1399) == .expanded)
        #expect(MusicLayoutClass.resolve(width: 1400) == .wide)
    }

    @Test func sidebarKeepsItsLabelsOnlyWhileThePageKeepsRoom() {
        // No panel: labels while the page keeps 560 pt beside the 224 pt sidebar.
        let a = MusicShellGeometry.resolve(totalWidth: 999, sidebarExpanded: true, panelOpen: false)
        #expect(a.navExpanded && a.contentWidth == 999 - a.navWidth)
        let tiny = MusicShellGeometry.resolve(totalWidth: 650, sidebarExpanded: true, panelOpen: false)
        #expect(!tiny.navExpanded && tiny.shellClass == .compact && tiny.contentClass == .compact)
        let narrow = MusicShellGeometry.resolve(totalWidth: 760, sidebarExpanded: true, panelOpen: false)
        #expect(!narrow.navExpanded && narrow.navWidth == MusicLayoutGrid.navCompactWidth)
        let chosen = MusicShellGeometry.resolve(totalWidth: 1200, sidebarExpanded: false, panelOpen: false)
        #expect(!chosen.navExpanded && MusicLayoutGrid.navCompactRange.contains(chosen.navWidth))
        // With the panel open the sidebar gives up its labels sooner, before the page is squeezed.
        let withPanel = MusicShellGeometry.resolve(totalWidth: 1000, sidebarExpanded: true, panelOpen: true)
        #expect(!withPanel.navExpanded && withPanel.panelInline)
        let roomyWithPanel = MusicShellGeometry.resolve(totalWidth: 1400, sidebarExpanded: true, panelOpen: true)
        #expect(roomyWithPanel.navExpanded && roomyWithPanel.panelInline)
    }

    @Test func contextPanelSharesTheWidthFromMediumUpAndOnlyFloatsInATinyWindow() {
        for w in [CGFloat(700), 850, 1000, 1200, 1399, 1400, 1800] {
            let g = MusicShellGeometry.resolve(totalWidth: w, sidebarExpanded: true, panelOpen: true)
            #expect(g.panelInline, "width \(w)")
            #expect(g.contentWidth == w - g.navWidth - g.panelWidth, "width \(w)")
            #expect(g.panelWidth >= 280 && g.panelWidth <= MusicLayoutGrid.contextPanelRange.upperBound, "width \(w)")
        }
        let tiny = MusicShellGeometry.resolve(totalWidth: 650, sidebarExpanded: true, panelOpen: true)
        #expect(!tiny.panelInline && tiny.contentWidth == 650 - tiny.navWidth)
        let wide = MusicShellGeometry.resolve(totalWidth: 1400, sidebarExpanded: true, panelOpen: true)
        #expect(MusicLayoutGrid.contextPanelRange.contains(wide.panelWidth))
        let closed = MusicShellGeometry.resolve(totalWidth: 1600, sidebarExpanded: true, panelOpen: false)
        #expect(!closed.panelInline && closed.contentWidth == 1600 - closed.navWidth)
    }

    @Test func thePanelGrowsWithTheWindowAndTheSidebarOrPageNeverStarveEachOther() {
        var last: CGFloat = 0
        for w in stride(from: 700.0, through: 1800.0, by: 50.0) {
            let g = MusicShellGeometry.resolve(totalWidth: CGFloat(w), sidebarExpanded: true, panelOpen: true)
            #expect(g.panelWidth >= last, "width \(w)")
            #expect(g.contentWidth >= 340, "width \(w)")
            last = g.panelWidth
        }
    }

    @Test func geometryNeverGoesNegative() {
        for w in [CGFloat(0), 10, 300, .infinity, .nan, -5] {
            let g = MusicShellGeometry.resolve(totalWidth: w, sidebarExpanded: true, panelOpen: true)
            #expect(g.contentWidth >= 0)
        }
    }

    // MARK: saved state

    @Test func destinationSidebarAndSearchAreSavedButSettingsIsNot() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let store = MusicShellStore(defaults: d)
        #expect(store.destination == nil && store.sidebarExpanded && store.sidebarAutoHide)
        store.sidebarAutoHide = false
        #expect(!store.sidebarAutoHide)
        store.destination = .radio; store.sidebarExpanded = false; store.searchQuery = "  jazz  "
        #expect(store.destination == .radio && !store.sidebarExpanded && store.searchQuery == "jazz")
        store.destination = .settings
        #expect(store.destination == .radio)
        store.searchQuery = ""
        #expect(d.object(forKey: MusicShellKeys.searchQuery) == nil)
    }

    @Test func scrollOffsetsAreTrimmedToTheNewest() {
        var offsets: [String: Double] = [:]
        var keys: [String] = []
        for i in 0..<(MusicShellStore.scrollLimit + 10) { offsets["k\(i)"] = Double(i + 1); keys.append("k\(i)") }
        let kept = MusicShellStore.trimmed(offsets, keys: keys)
        #expect(kept.count == MusicShellStore.scrollLimit)
        #expect(kept["k\(MusicShellStore.scrollLimit + 9)"] != nil && kept["k0"] == nil)
    }

    @Test func shellKeysAreClassifiedAndSearchIsWipedWithActivity() throws {
        let device = [MusicShellKeys.destination, MusicShellKeys.sidebarExpanded, MusicShellKeys.contextPanels, MusicShellKeys.scroll, MusicShellKeys.barHidden]
        for k in device { #expect(MusicDefaultsKeys.deviceSettings.contains(k)) }
        #expect(MusicDefaultsKeys.activity.contains(MusicShellKeys.searchQuery))
        let (d, cleanup) = try defaults(); defer { cleanup() }
        d.set("x", forKey: MusicShellKeys.searchQuery); d.set("radio", forKey: MusicShellKeys.destination)
        MusicDefaultsKeys.wipeActivity(d)
        #expect(d.object(forKey: MusicShellKeys.searchQuery) == nil && d.string(forKey: MusicShellKeys.destination) == "radio")
    }

    // MARK: deep links

    @Test func sectionLinksParseAndBuild() throws {
        for s in MusicSection.allCases {
            let url = try #require(MusicDeepLinks.link(section: s))
            let target = try #require(MusicDeepLinks.parse(url))
            #expect(target.kind == .section && MusicSection.from(linkName: target.id) == s)
            #expect(MusicDeepLinks.link(target) == url)
        }
        #expect(MusicDeepLinks.parse(URL(string: "streamsetu://music/open/Explore")!)?.id == "explore")
        #expect(MusicDeepLinks.parse(URL(string: "streamsetu://music/open/home")!)?.id == "home")
    }

    @Test func badSectionLinksAreRefusedAndItemLinksStillWork() {
        for s in ["streamsetu://music/open/nowhere", "streamsetu://music/open", "streamsetu://music/open/explore/extra", "streamsetu://music/open/a%2Fb"] {
            #expect(URL(string: s).flatMap { MusicDeepLinks.parse($0) } == nil, "\(s)")
        }
        #expect(MusicDeepLinks.parse(URL(string: "streamsetu://music/album/audius/abc123")!)?.kind == .album)
    }

    // MARK: sidebar helpers and info

    @Test func songLengthIsAClockAndEmptyWhenUnknown() {
        #expect(MusicInfoRows.duration(ms: 125_000) == "2:05")
        #expect(MusicInfoRows.duration(ms: 0).isEmpty)
    }

    @Test func radioSeedsAreUniqueAndLimited() {
        let t = (0..<10).map { MusicTrack(id: "\($0 % 8)", providerID: "p", title: "T\($0)", durationMs: 1, artists: []) }
        let seeds = MusicRadioSeeds.unique(t)
        #expect(seeds.count == MusicRadioSeeds.perGroup && Set(seeds.map(\.uid)).count == seeds.count)
        #expect(MusicRadioSeeds.unique(t, excluding: Set(t.map(\.uid))).isEmpty)
    }

    // MARK: player bar visibility

    @Test func barCollapsesToALineOnlyForTheInlineNowPlayingTab() {
        func p(_ open: Bool, _ tab: MusicContextPanelTab, inline: Bool, hidden: Bool = false, track: Bool = true) -> MusicBarPresentation {
            MusicBarVisibility.presentation(hasTrack: track, hidden: hidden, panelOpen: open, tab: tab, panelInline: inline)
        }
        #expect(p(true, .nowPlaying, inline: true) == .line)
        #expect(p(true, .queue, inline: true) == .full)
        #expect(p(true, .nowPlaying, inline: false) == .full)
        #expect(p(false, .nowPlaying, inline: true) == .full)
        #expect(p(true, .nowPlaying, inline: true, hidden: true) == .hidden)
        #expect(p(false, .queue, inline: false, track: false) == .hidden)
    }

    @Test func hideAndRestoreNeverTouchPlaybackState() {
        var s = MusicBarHideState()
        s.hide(); #expect(s.hidden)
        s.restore(); #expect(!s.hidden)
        s.hide(); s.trackStartedByPerson(); #expect(!s.hidden)
        s.hide(); s.stopped(); #expect(!s.hidden)
        #expect(MusicBarVisibility.showsRestoreAffordances(hasTrack: true, hidden: true))
        #expect(!MusicBarVisibility.showsRestoreAffordances(hasTrack: true, hidden: false))
        #expect(!MusicBarVisibility.showsRestoreAffordances(hasTrack: false, hidden: true))
    }

    @MainActor @Test func hiddenFlagIsKeptPerDevice() {
        let d = UserDefaults(suiteName: "music.barHidden.test")!
        d.removePersistentDomain(forName: "music.barHidden.test")
        let m = MusicBarVisibilityModel(defaults: d)
        #expect(!m.hidden)
        m.hide()
        #expect(MusicBarVisibilityModel(defaults: d).hidden)
        m.restore()
        #expect(!MusicBarVisibilityModel(defaults: d).hidden)
        #expect(MusicDefaultsKeys.deviceSettings.contains(MusicShellKeys.barHidden))
    }

    @Test func rowMarkerMatrix() {
        #expect(MusicRowMarkerState.leading(isCurrent: true, isPlaying: true, hovering: false) == .speaker)
        #expect(MusicRowMarkerState.leading(isCurrent: true, isPlaying: false, hovering: false) == .pause)
        #expect(MusicRowMarkerState.leading(isCurrent: true, isPlaying: true, hovering: true) == .play)
        #expect(MusicRowMarkerState.leading(isCurrent: false, isPlaying: true, hovering: false) == .number)
        #expect(MusicRowMarkerState.animatesGlyph(isCurrent: true, isPlaying: true, reduceMotion: false))
        #expect(!MusicRowMarkerState.animatesGlyph(isCurrent: true, isPlaying: false, reduceMotion: false))
        #expect(!MusicRowMarkerState.animatesGlyph(isCurrent: true, isPlaying: true, reduceMotion: true))
        #expect(!MusicRowMarkerState.showsFocusRing(focused: true, keyboard: false))
        #expect(MusicRowMarkerState.showsFocusRing(focused: true, keyboard: true))
    }
}
