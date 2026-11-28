import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What outlives the view: the history Back and Forward walk, and whether the saved destination was already restored. Leaving Music for Movies and
/// coming back builds a new `MusicMainView`; this keeps Back working across that trip.
@MainActor @Observable
final class MusicShellSession {
    static let shared = MusicShellSession()
    var history = MusicNavHistory()
    var didRestore = false
}

/// Music in the main window: first-run consent, else three regions (sidebar, page, context panel) and the player bar under them.
/// `MusicHub` holds what is open; the shell's `MusicNavHistory` is what Back and Forward walk. The regions follow the width Music is given:
/// compact sidebar under 1000 pt, the context panel beside the page from 1400 pt and over it below that.
struct MusicMainView: View {
    @Bindable var hub: MusicHub = .shared
    @State private var chrome = MusicChromeState.shared
    @State private var session = MusicShellSession.shared
    @State private var panelState = MusicContextPanelState.shared
    @State private var refreshCount = 0
    @State private var sidebarExpanded = MusicShellStore().sidebarExpanded
    /// Auto-hide: the sidebar rests as the icon rail; the full sidebar opens over the page while the pointer is on it and closes shortly after it leaves.
    @State private var sidebarAutoHide = MusicShellStore().sidebarAutoHide
    @State private var sidebarPeeking = false
    /// The side panel's width the person dragged it to (nil: automatic). Remembered between launches.
    @State private var userPanelWidth: CGFloat? = MusicPanelResizeHandle.saved()
    /// After a page change the rail does not peek open again until the pointer has left it, so clicking a rail icon never slides the sidebar out over the new page.
    @State private var peekSuppressed = false
    @State private var peekTask: Task<Void, Never>?
    /// The pointer is on the rail or on the open sidebar, and whether a menu is being tracked (a menu keeps the open sidebar from closing under it).
    @State private var pointerOverSidebar = false
    @State private var menuTracking = false
    @Environment(AppState.self) private var appState: AppState?
    @Environment(AppSettings.self) private var appSettings: AppSettings?
    private let store = MusicShellStore()

    var body: some View {
        Group {
            if hub.needsConsent { MusicConsentView(hub: hub) }
            else { shell }
        }
        .background(ThemeBackdrop().ignoresSafeArea())
        // Colours from the cover, or a Material palette, when the person chose them in Settings; "Standard" leaves the app's accent alone.
        .musicAdaptiveAccent(for: hub.player.current?.thumbnails ?? [])
        .musicMaterialTheme(for: hub.player.current?.thumbnails ?? [])
        .musicAccessibilityEnvironment()
        .onAppear {
            MusicToasts.shared.bind(appState?.toasts)
            hub.resumeAfterGate()
            hub.attach()
            if let appSettings { hub.player.userProxyActive = { appSettings.proxy.isActive } }
            hub.player.playOnStartIfEnabled()
        }
        .onChange(of: hub.linkError) { _, e in
            if let e { MusicToasts.shared.error(e); hub.linkError = nil }
        }
    }

    private var shell: some View {
        GeometryReader { geo in
            let hasTrack = hub.player.current != nil
            // With auto-hide the page always lives beside the rail; the open sidebar floats over it, so nothing under the pointer moves.
            let navPinned = sidebarExpanded && !sidebarAutoHide
            let requested = MusicShellGeometry.resolve(totalWidth: geo.size.width, sidebarExpanded: navPinned, panelOpen: panelState.isOpen && hasTrack, userPanelWidth: userPanelWidth)
            let wanted = MusicPanelPresentation.shown(isOpen: panelState.isOpen, hasTrack: hasTrack, inline: requested.panelInline, overlayArmed: panelState.overlayArmed)
            let g = MusicShellGeometry.resolve(totalWidth: geo.size.width, sidebarExpanded: navPinned, panelOpen: wanted, userPanelWidth: userPanelWidth)
            // The player bar floats over the whole window: the page and the sidebar run to the bottom edge and draw under it. Scrolling content gets a bottom margin of the bar's height so
            // its last row can be scrolled clear of the bar; there is no row, strip or colour behind the pill.
            let reserve: CGFloat = hasTrack ? MusicBarMetrics.heightFull : 0
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    MusicSidebar(hub: hub, collapsed: !g.navExpanded, canExpand: g.shellClass >= .expanded || sidebarAutoHide, width: g.navWidth, toggle: toggleSidebar, autoHide: sidebarAutoHide)
                        .onHover { if sidebarAutoHide { setSidebarHover($0) } }
                        .layoutPriority(2)
                    VStack(spacing: 0) {
                        ZStack {
                            page.frame(maxWidth: .infinity, maxHeight: .infinity).id("\(YouTubeMusicAccountBuiltIns.manager?.epoch ?? 0)-\(refreshCount)")
                            if let track = chrome.comments { commentsPanel(track) }
                        }
                        .environment(\.musicLayoutClass, g.contentClass)
                        .musicFocusRegion(Localized.string("Music content"))
                    }
                    .frame(minWidth: 0, maxWidth: .infinity).clipped()
                    // Scrolling pages leave room for the floating bar at the bottom and, on a nested page, for the Back pill at the top.
                    .environment(\.musicBottomReserve, reserve)
                    .environment(\.musicTopReserve, hub.nav.canGoBack ? MusicSpace.huge + MusicSpace.xxs : 0)
                    // Only a page opened from another page (an artist, an album, a playlist) has a Back pill, floating at its top left with nothing behind it; the main screens have none.
                    // ⌘[ and ⌘] still walk the history.
                    .overlay(alignment: .topLeading) { if hub.nav.canGoBack { MusicPageBackLink(title: backTitle, action: goBack) } }
                    // The lyrics strip: a slim card just above the floating player bar (not over the whole page) with the line before, the line being sung and the next one.
                    .overlay(alignment: .bottom) {
                        // Not drawn twice: while the side panel is open on its Lyrics tab, the same lines are already there.
                        if panelState.lyricsStripOpen && hasTrack && !hub.expandedPlayer && !MusicListeningModes.profile.hidesLyricsStrip && !(panelState.isOpen && panelState.selectedTab == .lyrics) {
                            MusicLyricsStrip(hub: hub, state: panelState, close: { panelState.lyricsStripOpen = false })
                                .musicAdaptiveAccent(for: hub.player.current?.thumbnails ?? [])
                                .padding(.bottom, reserve + MusicSpace.sm)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(MusicMotion.animation(.panel, reduce: MusicMotion.reduced), value: panelState.lyricsStripOpen)
                    // The side panel is not closed here: it is not drawn without a song (MusicPanelPresentation.shown), and its remembered state returns with the next one.
                    .onChange(of: hasTrack) { _, now in if !now { panelState.lyricsStripOpen = false } }
                    // The side panel's button floats at the top right of the page (no toolbar row): glass, round, always in the same place while a song is loaded.
                    .overlay(alignment: .topTrailing) {
                        if MusicPanelPresentation.showsToggleButton(hasTrack: hasTrack, panelShown: wanted) {
                            Button { panelState.toggleOpen(shown: wanted) } label: { Image(systemName: "sidebar.right") }
                                .musicButton(.glassIcon, size: .regular)
                                .accessibilityLabel(Localized.string("Show details panel")).musicTooltip(verbatim: Localized.string("Show details panel"))
                                .atlas("control.music.sidePanelButton")
                                .padding(.top, MusicSpace.sm).padding(.trailing, MusicSpace.md)
                        }
                    }
                    if g.panelInline {
                        MusicContextPanel(hub: hub, state: panelState, suspended: hub.expandedPlayer).frame(width: g.panelWidth)
                            .overlay(alignment: .leading) { MusicPanelResizeHandle(width: $userPanelWidth, shown: g.panelWidth, total: geo.size.width) }
                            .transition(.move(edge: .trailing))
                    }
                }
                .overlay(alignment: .trailing) { if wanted && !g.panelInline { overlayPanel(g, total: geo.size.width) } }
                // The open sidebar of auto-hide: over the page from the rail's edge, with a soft shadow, so the page does not shift. Its pin button keeps it open.
                .overlay(alignment: .leading) {
                    if sidebarAutoHide && sidebarPeeking {
                        MusicSidebar(hub: hub, collapsed: false, canExpand: true, width: MusicLayoutGrid.navExpandedWidth, toggle: toggleSidebar, autoHide: true)
                            .frame(width: MusicLayoutGrid.navExpandedWidth)
                            .background(ColorTokens.surface)
                            .overlay(alignment: .trailing) { Rectangle().fill(ColorTokens.line).frame(width: 1).allowsHitTesting(false) }
                            .shadow(color: ColorTokens.background.opacity(0.55), radius: 18, x: 6)
                            .onHover { setSidebarHover($0) }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                // With the side panel beside the page, the floating bar belongs to the page column: it never sits over the panel's own controls.
                MusicShellPlayerBarSlot(hub: hub, layout: g.shellClass, panelState: panelState, panelInline: g.panelInline && wanted)
                    // The bar belongs to the page column: it never sits over the sidebar or over the side panel.
                    .padding(.leading, g.navWidth)
                    .padding(.trailing, g.panelInline && wanted ? g.panelWidth : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: g.shellClass) { _, _ in panelState.disarmOverlay() }
            .animation(MusicMotion.animation(.panel, reduce: MusicMotion.reduced), value: wanted)
            // What the View menu needs to know, kept up to date as the window and the player change.
            .onChange(of: g.navExpanded, initial: true) { _, v in chrome.sidebarIsExpanded = v }
            .onChange(of: g.shellClass >= .expanded || sidebarAutoHide, initial: true) { _, v in chrome.canToggleSidebar = v }
            .animation(MusicMotion.animation(.panel, reduce: MusicMotion.reduced), value: sidebarPeeking)
            .onChange(of: hasTrack, initial: true) { _, v in chrome.canTogglePanel = v }
            .onChange(of: wanted, initial: true) { _, v in chrome.panelShown = v }
            .onChange(of: wanted ? min(g.panelWidth, geo.size.width) : 0, initial: true) { _, w in chrome.panelOccupiedWidth = w }
            .overlay { if hub.expandedPlayer && hub.player.current != nil { MusicExpandedPlayer(hub: hub).atlasScreen("screen.music.player") } }
        }
        .background { shortcuts }
        .overlay { palette }
        // The sidebar's dialogs live here: the open sidebar of auto-hide is removed when the pointer leaves it, and a dialog must outlive it.
        .modifier(MusicSidebarDialogsHost(hub: hub, dialogs: MusicSidebarDialogs.shared))
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in setMenuTracking(true) }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in setMenuTracking(false) }
        #endif
        .youTubeMusicAccountSheets()
        .musicDesktopSurfaces(hub: hub)
        .sheet(item: $hub.alternativesTrack) { MusicAlternativesSheet(hub: hub, track: $0).atlasScreen("screen.music.alternatives") }
        .sheet(isPresented: Binding(get: { chrome.showSettings }, set: { chrome.showSettings = $0 })) {
            MusicSettingsPage(hub: hub, route: chrome.settingsRoute, onClose: { chrome.showSettings = false })
        }
        .sheet(isPresented: Binding(get: { chrome.showOpenLink }, set: { chrome.showOpenLink = $0 })) {
            MusicOpenLinkDialog(hub: hub, isPresented: Binding(get: { chrome.showOpenLink }, set: { chrome.showOpenLink = $0 }))
        }
        .sheet(isPresented: Binding(get: { chrome.sharing != nil }, set: { if !$0 { chrome.sharing = nil } })) {
            if let subject = chrome.sharing { MusicShareDialog(hub: hub, subject: subject, isPresented: Binding(get: { chrome.sharing != nil }, set: { if !$0 { chrome.sharing = nil } })) }
        }
        .sheet(item: Binding(get: { chrome.credits }, set: { chrome.credits = $0 })) { t in MusicCreditsSheet(hub: hub, track: t, close: { chrome.credits = nil }) }
        .modifier(MusicExtraSheets(hub: hub, chrome: chrome))
        .sheet(item: Binding(get: { chrome.songInfo }, set: { chrome.songInfo = $0 })) { t in MusicSongInfoSheet(hub: hub, track: t, close: { chrome.songInfo = nil }) }
        .sheet(isPresented: Binding(get: { chrome.editMetadata != nil }, set: { if !$0 { chrome.editMetadata = nil } })) {
            if let list = chrome.editMetadata { MusicMetadataEditorSheet(hub: hub, tracks: list, close: { chrome.editMetadata = nil }) }
        }
        .sheet(isPresented: Binding(get: { chrome.identify != nil }, set: { if !$0 { chrome.identify = nil } })) {
            if let list = chrome.identify { MusicAcoustIDSheet(hub: hub, tracks: list, close: { chrome.identify = nil }) }
        }
        .sheet(isPresented: Binding(get: { chrome.editPlaylist != nil }, set: { if !$0 { chrome.editPlaylist = nil } })) {
            if let id = chrome.editPlaylist, let p = hub.library.playlist(id: id) { MusicEditPlaylistSheet(hub: hub, playlist: p) { chrome.editPlaylist = nil } }
        }
        .onAppear {
            // A person who is new to Music is offered the setup once, the first time Music opens; a person who already listens gets the quiet card in Your library instead.
            let offer = MusicSetupGate.offer(setupDone: UserDefaults.standard.bool(forKey: MusicSetupGate.doneKey), cardDismissed: UserDefaults.standard.bool(forKey: MusicSetupGate.dismissedKey),
                                             prefs: MusicTastePreferences.shared.prefs, plays: hub.library.history.count, likes: hub.library.liked.count)
            if offer == .fullFlow { chrome.setupOpen = true }
        }
        // "View lyrics" from the full-window player brings the page back first: the strip is not drawn over the full window and would otherwise pop up later.
        .onChange(of: MusicSongLyricsOpener.shared.count) { _, _ in
            guard hub.player.current != nil else { return }
            hub.expandedPlayer = false
            panelState.show(.lyrics)
        }
        .onChange(of: hub.expandedPlayer) { _, now in if now { panelState.lyricsStripOpen = false } }
        // The queue emptied under an open full window: the flag goes with it, so the next song started anywhere does not pop the full window open unasked.
        .onChange(of: hub.player.current == nil) { _, gone in if gone { hub.expandedPlayer = false } }
        .sheet(isPresented: Binding(get: { chrome.addToPlaylist != nil }, set: { if !$0 { chrome.addToPlaylist = nil } })) {
            // Every "Add to Playlist…" in Music (album header, song menus, selection bar, playlist pages) sets `chrome.addToPlaylist`; this is the one place that shows it.
            if let tracks = chrome.addToPlaylist { MusicAddToPlaylistSheet(hub: hub, tracks: tracks, dismiss: { chrome.addToPlaylist = nil }) }
        }
        .onAppear { MusicClickProbe.install(); MusicDebugLog.log("shell", "music view appeared, section \(hub.nav.section.rawValue)"); restoreIfNeeded(); startAutomation() }
        .onDisappear { saveScroll(); chrome.panelOccupiedWidth = 0; MusicSidebarDialogs.shared.dismissAll() }
        .onChange(of: hub.player.current == nil) { _, none in if none { hub.expandedPlayer = false } }
        .onChange(of: hub.nav) { old, new in MusicPerfProbe.shared.mark(.pageOpen, new.top.map { String(describing: $0).prefix(40).description } ?? new.section.rawValue); MusicDebugLog.log("nav", "\(old.section.rawValue)+\(old.stack.count) -> \(new.section.rawValue)+\(new.stack.count) top \(new.top.map { String(describing: $0).prefix(80) } ?? "-")"); trackNavigation(from: old, to: new) }
        // Library's "Recently added" link asks Recently Added to lead with the saved list; the ask lasts while that section stays selected (a page opened from it and Back keep it) and ends when another section is chosen.
        .onChange(of: hub.nav.section) { _, section in if section != .recentlyAdded { hub.recentlyAddedLeadsWithLibrary = false } }
        .onChange(of: chrome.sidebarToggleRequest) { _, _ in if chrome.canToggleSidebar { toggleSidebar() } }
        .onChange(of: chrome.panelToggleRequest) { _, _ in if chrome.canTogglePanel { panelState.toggleOpen(shown: chrome.panelShown) } }
        .onChange(of: hub.searchModel.query) { _, q in if !hub.gated { store.searchQuery = q } }
    }

    // MARK: sidebar and panel

    /// A tab's key: opens the panel on that tab (the Lyrics key shows the panel's own Lyrics tab), or closes the panel when that tab is already showing.
    private func openTab(_ tab: MusicContextPanelTab) {
        guard hub.player.current != nil else { return }
        if chrome.panelShown && panelState.selectedTab == tab { panelState.closePanel(); return }
        panelState.showPanel(tab)
    }

    private func toggleSidebar() {
        // One button, two states: auto-hide (the rail, opening on hover) and pinned open. From auto-hide it pins the sidebar open; from pinned it goes back to auto-hide.
        peekTask?.cancel()
        if sidebarAutoHide {
            sidebarAutoHide = false; sidebarExpanded = true; sidebarPeeking = false
        } else {
            sidebarAutoHide = true; sidebarPeeking = false
        }
        store.sidebarAutoHide = sidebarAutoHide
        store.sidebarExpanded = sidebarExpanded
        MusicDebugLog.log("shell", "sidebar \(sidebarAutoHide ? "auto-hide" : "pinned open")")
    }

    /// The pointer on the rail or on the open sidebar: open after a short pause (so a pass over the edge does not flash it), close shortly after the pointer leaves.
    private func setSidebarHover(_ over: Bool) {
        pointerOverSidebar = over
        peekTask?.cancel()
        guard sidebarAutoHide else { sidebarPeeking = false; return }
        if !over { peekSuppressed = false }
        if over && peekSuppressed { return }
        if !over && !MusicSidebarPeek.mayClose(menuTracking: menuTracking) { return }
        if over == sidebarPeeking { return }
        peekTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(over ? 130 : 280))
            guard !Task.isCancelled else { return }
            sidebarPeeking = over
        }
    }

    /// While a menu is open the sidebar does not close; when the menu closes with the pointer elsewhere, it closes as it would have.
    private func setMenuTracking(_ on: Bool) {
        menuTracking = on
        guard sidebarPeeking else { return }
        if on { peekTask?.cancel() } else if !pointerOverSidebar { setSidebarHover(false) }
    }

    private func overlayPanel(_ g: MusicShellGeometry, total: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            // A light veil, not a wall: the page behind keeps scrolling and taking clicks while the panel is open (Escape and the close button close it).
            MusicTokens.scrim.opacity(0.5).allowsHitTesting(false)
                .accessibilityHidden(true).atlas("control.music.contextScrim")
            MusicContextPanel(hub: hub, state: panelState, isOverlay: true, suspended: hub.expandedPlayer)
                .frame(width: min(g.panelWidth, max(0, total))).musicElevation(.overlay, cornerRadius: 0)
                .transition(.move(edge: .trailing))
        }
    }

    // MARK: history and restore

    /// A change of place: settings opens as a sheet over the page the person was on; anything else goes into the history. A step the history
    /// made itself, or the page's own Back button, is recognised and moves the index instead of adding an entry.
    private func trackNavigation(from old: MusicNav, to new: MusicNav) {
        if new.section == .settings, old.section != .settings {
            hub.nav.restore(MusicNavEntry(old))
            chrome.openSettings(.general)
            return
        }
        if old.section == .search, new.section != .search { hub.searchModel.cancel() }
        rememberCurrentPlace()
        let change = session.history.observe(MusicNavEntry(new))
        if change == .steppedBack || change == .steppedForward { applyMemory(session.history.current) }
        panelState.enter(new.section)
        if sidebarAutoHide, MusicSidebarPeek.closesOnNavigation(from: old.section, to: new.section) {
            peekTask?.cancel(); sidebarPeeking = false; peekSuppressed = true
            // Only a click on the rail needs the pointer to leave first; after a shortcut the first hover must still work.
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); peekSuppressed = false }
        }
        store.destination = new.section
        if old.section != new.section || old.top != new.top { saveScroll() }
        store.session = session.history.snapshot()
    }

    /// What the page being left remembers (scroll offset, role, filters, expanded sections), copied into its history entry so Back and Forward
    /// return to the same view.
    private func rememberCurrentPlace() {
        let key = session.history.current.scrollKey
        var m = MusicPageMemoryCenter.shared.memory(for: key)
        m.scrollOffset = MusicScrollMemory.shared.offset(for: key) ?? m.scrollOffset
        session.history.remember(m)
    }

    /// Hands an entry's memory back to the page that is about to show: the live page memory and the scroll position the list restores from.
    private func applyMemory(_ e: MusicNavEntry) {
        MusicPageMemoryCenter.shared.set(e.memory, for: e.scrollKey)
        if let y = e.memory.scrollOffset { MusicScrollMemory.shared.record(e.scrollKey, y) }
    }

    /// What Back returns to: the page before this one when it has a name, else the section.
    private var backTitle: String { hub.nav.stack.count > 1 ? Localized.string("Back") : hub.nav.section.title }

    private func goBack() {
        rememberCurrentPlace()
        guard let e = session.history.back() else { return }
        applyMemory(e)
        hub.nav.restore(e)
    }

    private func goForward() {
        rememberCurrentPlace()
        guard let e = session.history.forward() else { return }
        applyMemory(e)
        hub.nav.restore(e)
    }

    /// The first time Music shows in this launch: bring back the scroll positions and the section the person was on.
    /// Schedules, rules, triggers, key mappings and the local control door start with Music and run only while the app is open.
    private func startAutomation() {
        MusicScheduler.shared.start(hub: hub)
        #if os(macOS)
        MusicHotkeys.shared.start(hub: hub)
        MusicLocalAPI.shared.start(hub: hub)
        #endif
    }

    private func restoreIfNeeded() {
        panelState.enter(hub.nav.section)
        guard !session.didRestore else { return }
        session.didRestore = true
        for (key, y) in store.scroll { MusicScrollMemory.shared.record(key, y) }
        sidebarExpanded = store.sidebarExpanded
        sidebarAutoHide = store.sidebarAutoHide
        if hub.nav == MusicNav(), let saved = store.session, var restored = MusicNavHistory(snapshot: saved) {
            hub.forgetMissingPlaylists(in: &restored)
            session.history = restored
            applyMemory(restored.current)
            hub.nav.restore(restored.current)
            panelState.enter(restored.current.section)
        } else if hub.nav == MusicNav(), let d = store.destination, d != .home {
            hub.nav.select(d)
            session.history = MusicNavHistory(start: MusicNavEntry(section: d))
            panelState.enter(d)
            if d == .search { hub.searchModel.restorePersisted(gated: hub.gated) }
        } else {
            session.history = MusicNavHistory(start: MusicNavEntry(hub.nav))
        }
    }

    /// Keeps the scroll positions of the places in the history (and the ones saved earlier), newest last, up to a limit.
    private func saveScroll() {
        rememberCurrentPlace()
        store.session = session.history.snapshot()
        var offsets = store.scroll
        let keys = Array(offsets.keys) + session.history.scrollKeys
        for k in keys { offsets[k] = MusicScrollMemory.shared.offset(for: k) ?? offsets[k] }
        for k in session.history.scrollKeys where MusicScrollMemory.shared.offset(for: k) == nil { offsets[k] = nil }
        store.scroll = MusicShellStore.trimmed(offsets, keys: keys)
    }

    /// Cmd+K inside Music: the quick-search palette over a dimmed page.
    @ViewBuilder private var palette: some View {
        if chrome.showPalette {
            ZStack(alignment: .top) {
                MusicTokens.scrim.ignoresSafeArea().onTapGesture { chrome.showPalette = false }.atlas("control.music.mainWindowMusicmainviewpaletteOnTapGesture")
                MusicPalette(hub: hub, isPresented: Binding(get: { chrome.showPalette }, set: { chrome.showPalette = $0 }))
                    .clipShape(RoundedRectangle(cornerRadius: MusicTokens.radiusPanel, style: .continuous)).padding(.top, 60)
                    .atlasScreen("screen.music.palette")
            }
            .transition(.opacity)
        }
    }

    private func commentsPanel(_ track: MusicTrack) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .topTrailing) {
                MusicCommentsView(hub: hub, track: track).glass(radius: 0)
                Button { chrome.comments = nil } label: { Image(systemName: "xmark").font(MusicTokens.iconSmall).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle()) }
                    .buttonStyle(.plain).padding(Spacing.sm).accessibilityLabel("Close comments").musicTooltip("Close comments").atlas("control.music.mainWindowCloseComments")
            }
        }
    }

    /// Command-F jumps to Search, Command-K opens the palette, Command-[ and Command-] step back and forward, from anywhere in Music.
    private var shortcuts: some View {
        ZStack {
            Button("Search") { hub.nav.select(.search) }.keyboardShortcut("f", modifiers: .command).atlas("control.music.mainWindowSearch")
            Button("Quick Search") { chrome.showPalette.toggle() }.keyboardShortcut("k", modifiers: .command).atlas("control.music.mainWindowQuickSearch")
            Button("Back", action: goBack).keyboardShortcut("[", modifiers: .command).disabled(!session.history.canGoBack).atlas("control.music.mainWindowBack")
            Button("Forward", action: goForward).keyboardShortcut("]", modifiers: .command).disabled(!session.history.canGoForward).atlas("control.music.mainWindowForward")
            Button("Refresh") { hub.userRefreshToken = MusicHomeFeedModel.tokenAfterRefresh(hub.userRefreshToken, onHome: MusicHomeFeedModel.isShowing(hub.nav)); refreshCount += 1 }.keyboardShortcut("r", modifiers: .command).atlasCovers("control.music.musicMusicheaderbarbarButton")
            // Command-Option-1 to 5 open the panel on Now Playing, Queue, Lyrics, Related and Credits; pressed again on the tab that is showing, it closes the panel.
            ForEach(MusicPanelTabKeys.all) { k in
                Button(Localized.string(k.tab.title)) { openTab(k.tab) }
                    .keyboardShortcut(KeyEquivalent(k.key), modifiers: [.command, .option]).disabled(hub.player.current == nil)
                    .atlas("control.music.panelTabShortcut")
            }
        }
        .opacity(0).accessibilityHidden(true).allowsHitTesting(false)
    }

    @ViewBuilder private var page: some View {
        if hub.nav.top == .blacklist {
            MusicBlacklistPage(hub: hub).atlasScreen("screen.music.blacklist")
        } else if let route = hub.nav.top {
            MusicRouteView(hub: hub, route: route).id(route)
        } else {
            switch hub.nav.section {
            case .home: MusicHomePage(hub: hub).atlasScreen("screen.music.home")
            case .explore: MusicExplorePage(hub: hub).atlasScreen("screen.music.explore")
            case .recentlyAdded: MusicRecentlyAddedPage(hub: hub).atlasScreen("screen.music.recentlyAdded")
            case .search: MusicSearchPage(hub: hub).atlasScreen("screen.music.search")
            case .library: MusicLibraryPage(hub: hub).atlasScreen("screen.music.library")
            case .radio: MusicRadioPage(hub: hub).atlasScreen("screen.music.radio")
            case .downloads: MusicDownloadsPage(hub: hub).atlasScreen("screen.music.downloads")
            case .devices: MusicDevicesPage(hub: hub).atlasScreen("screen.music.devices")
            case .room: MusicRoomPage(hub: hub).atlasScreen("screen.music.room")
            case .settings: MusicSettingsPage(hub: hub).atlasScreen("screen.music.settings")
            }
        }
    }
}
