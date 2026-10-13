import SwiftUI
import AppKit

struct RootView: View {
    let coordinator: AppCoordinator

    var body: some View {
        switch coordinator.phase {
        case .starting:
            VStack(spacing: Spacing.lg) { Image(systemName: "play.tv.fill").font(.system(size: 44)).foregroundStyle(ColorTokens.accentDefault); ProgressView(); Text("Opening your library…").foregroundStyle(ColorTokens.textSecondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background).preferredColorScheme(.dark)
        case .failed(let message):
            VStack(spacing: Spacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(ColorTokens.warning)
                Text("StreamSetu couldn't open its library").font(Typography.title)
                Text(message).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: 480).multilineTextAlignment(.center)
                HStack {
                    SecondaryButton(title: "Show Data Folder", symbol: "folder") { WindowManager.revealInFinder(StorageService.applicationSupport) }
                    PrimaryButton(title: "Reset Library and Retry", symbol: "arrow.counterclockwise") { Task { await coordinator.resetDatabaseAndRetry() } }
                }
                Text("Resetting removes the cached library only. Logins stay in your Keychain and sources can be added again.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background).preferredColorScheme(.dark)
        case .ready:
            if let container = coordinator.container, let state = coordinator.state {
                MainShell(router: coordinator.router, keys: coordinator.keys, container: container, state: state)
            }
        }
    }
}

struct MainShell: View {
    let router: AppRouter
    let keys: PlayerKeyMonitor
    let container: AppContainer
    let state: AppState
    @State private var program: EPGProgram?
    @State private var nextProgram: EPGProgram?
    @State private var folderQuery = ""
    @State private var width: CGFloat = 1440
    @State private var search: GlobalSearchModel
    @State private var dropTargeted = false

    init(router: AppRouter, keys: PlayerKeyMonitor, container: AppContainer, state: AppState) {
        self.router = router; self.keys = keys; self.container = container; self.state = state
        _search = State(initialValue: GlobalSearchModel(service: container.globalSearch))
    }

    var body: some View {
        @Bindable var router = router
        let playback = container.playback
        ZStack {
            if state.needsOnboarding {
                OnboardingView()
            } else {
                VStack(spacing: 0) {
                    ReddyTopBar(state: TopBarState(tab: router.tab, initials: initials, accountMenuOpen: router.accountMenuOpen, width: width),
                                query: Binding(get: { router.searchQuery }, set: { setQuery($0) }),
                                focusToken: router.topSearchFocus,
                                onSubmit: { if let r = search.selected ?? search.visible.first { activate(r) } },
                                onResultsFocus: { router.searchResultsFocus += 1 },
                                onSelectTab: { router.navigate($0) },
                                onToggleAccount: { router.playlistMenuOpen = false; router.accountMenuOpen.toggle() })
                        .zIndex(3)
                    HStack(spacing: 0) {
                        sidebar
                        ZStack {
                            ContentRouter()
                                .id(state.activeSourceID)       // a playlist switch rebuilds the screen: nothing carries over
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Results replace the content while searching. The screen underneath stays alive, so clearing the
                            // search returns to exactly where you were; playback is never touched.
                            if router.isSearching {
                                SearchResultsPage(model: search, focusToken: router.searchResultsFocus, isFavorite: { state.isFavorite($0) }, onActivate: activate)
                            }
                        }
                    }
                    .zIndex(1)
                    if LivePlayerLayout.shouldShowMiniPlayer(onLiveTV: router.tab == .liveTV, isLive: playback.isLive, livePreviewVisible: playback.livePreviewVisible, hasPlayback: playback.current != nil),
                       let bar = BottomPlayerAdapter.state(playback, program: program) {
                        ReddyBottomPlayer(state: bar,
                                          onTitle: { openPlayingItem(playback) },
                                          onTogglePlay: { if bar.failed { playback.retryNow() } else { playback.togglePause() } },
                                          onToggleMute: { playback.isMuted.toggle() },
                                          onVolume: { playback.isMuted = false; playback.volume = $0 },
                                          onSeek: { playback.seek(to: $0) },
                                          onExpand: { playback.isExpanded = true },
                                          onStop: { playback.stop() },
                                          videoPlayback: bar.isLive ? nil : playback,
                                          onSkip: { playback.seek(by: $0) })
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(AnimationTokens.standard, value: playback.current != nil && !(router.tab == .liveTV && playback.isLive))
                overlays
            }
            VStack { Spacer(); HStack { Spacer(); ToastHost(center: state.toasts) } }.padding(.bottom, LivePlayerLayout.shouldShowMiniPlayer(onLiveTV: router.tab == .liveTV, isLive: playback.isLive, livePreviewVisible: playback.livePreviewVisible, hasPlayback: playback.current != nil) ? BottomPlayerLayout.height(isLive: playback.isLive) + 8 : 12)
        }
        // The root shell owns the top edge: the bar starts at the window's top in every window state, so it is never pushed
        // by the title bar's safe-area inset, and it is never inside a scroll view.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1024, minHeight: 680)
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .background(WindowChrome(barHeight: LayoutTokens.headerHeight))
        .background(ThemeBackdrop().ignoresSafeArea())
        .environment(state).environment(router).environment(container.settings)
        // Panels, menus and dialogs fade and settle instead of popping in. Opacity and a slight scale only: nothing moves the layout.
        .animation(AnimationTokens.page, value: router.modal)
        .animation(AnimationTokens.page, value: router.movie?.id)
        .animation(AnimationTokens.page, value: router.series?.id)
        .animation(AnimationTokens.hover, value: router.accountMenuOpen)
        .animation(AnimationTokens.hover, value: router.playlistMenuOpen)
        .animation(AnimationTokens.page, value: router.isSearching)
        .environment(\.container, container).environment(\.artwork, container.artwork)
        .reddyTheme(container.settings)
        .loggingNotice()
        .onChange(of: router.tab) { _, _ in folderQuery = "" }
        .onChange(of: container.settings.hideEmptyFolders) { _, _ in state.reloadFolders() }
        .onChange(of: router.selection) { _, _ in router.clearSearch(); search.clear() }
        .onChange(of: state.activeSourceID) { _, _ in folderQuery = ""; router.closeDetail(); router.clearSearch(); search.clear() }
        .onOpenURL { handleOpen($0) }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay { if dropTargeted { dropHint.allowsHitTesting(false).transition(.opacity).zIndex(20) } }
        .animation(AnimationTokens.standard, value: dropTargeted)
        .onChange(of: router.sidebarCollapsed) { _, c in container.settings.sidebarWasCollapsed = c }
        .onChange(of: container.settings.rememberFolders) { _, on in router.rememberFolders = on }
        .onAppear {
            router.rememberFolders = container.settings.rememberFolders
            if router.isSearching { search.term = router.searchQuery; search.schedule() }
        }
        .onChange(of: playback.isFullscreen) { _, on in container.fullscreen.request(on) }
        .task(id: playback.currentChannel?.id) { await loadProgram(playback) }
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60_000_000_000); await loadProgram(playback) } }
        .onAppear {
            keys.handler = { event in handleKey(event, playback) }
            keys.install()
        }
        .onDisappear { keys.remove() }
    }

    // MARK: links and drops

    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 38, weight: .light))
            Text("Drop a playlist here").font(Typography.title)
            Text("An .m3u or .m3u8 file, or a playlist link").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        }
        .padding(40).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ColorTokens.accentDefault.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.35))
    }

    /// Fills the Add Playlist form (never adds anything by itself).
    private func present(_ p: PendingAdd) {
        router.pendingAdd = p
        if !state.needsOnboarding { router.modal = .addPlaylist }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let p = PendingAdd.fromFile(url) ?? PendingAdd.fromText(url.absoluteString) { present(p) }
                        else { state.toasts.show("That isn't a playlist file or link.", symbol: "exclamationmark.triangle", kind: .warning) }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in
                        if let p = PendingAdd.fromText(text) { present(p) }
                        else { state.toasts.show("That text isn't a playlist link.", symbol: "exclamationmark.triangle", kind: .warning) }
                    }
                }
            }
        }
        return handled
    }

    /// `streamsetu://…` links (also reachable from Shortcuts' "Open URL") and playlist files opened with StreamSetu.
    private func handleOpen(_ url: URL) {
        if url.isFileURL {
            if let p = PendingAdd.fromFile(url) { present(p) } else { state.toasts.show("StreamSetu can't open that kind of file.", symbol: "exclamationmark.triangle", kind: .warning) }
            return
        }
        guard let link = DeepLink.parse(url) else { state.toasts.show("That link isn't one StreamSetu understands.", symbol: "link.badge.plus", kind: .warning); return }
        let playback = container.playback
        switch link {
        case .addPlaylist(let address, let name): present(.address(address, name: name))
        case .openTab(let tab): router.navigate(tab)
        case .search(let q): router.searchQuery = q; search.term = q; search.schedule()
        case .sleep(let m): playback.startSleepTimer(minutes: m); state.toasts.show("Sleep timer set for \(m) minutes.", symbol: "moon.zzz")
        case .remote(let c):
            switch c {
            case .pause: playback.pause()
            case .resume: playback.resume()
            case .stop: playback.stop()
            case .next: playback.isLive ? playback.nextChannel() : playback.playNextEpisode()
            case .previous: playback.isLive ? playback.previousChannelInList() : playback.seek(to: 0)
            case .last: playback.lastChannel()
            }
        case .playChannel(let name): playChannel(named: name)
        }
    }

    private func playChannel(named name: String) {
        let sid = state.activeSourceID, c = container
        Task { @MainActor in
            let found = await Task.detached { () -> (Channel, [Channel])? in
                let list = (try? c.catalog.channels(ChannelQuery(sourceID: sid, search: name, collapseVariants: true, limit: 200))) ?? []
                let wanted = MetadataNormalizer.normalize(name)
                guard let best = list.first(where: { MetadataNormalizer.normalize($0.name) == wanted }) ?? list.first else { return nil }
                return (best, list)
            }.value
            if let (channel, queue) = found { c.playback.play(channel: channel, queue: queue); router.navigate(.liveTV) }
            else { state.toasts.show("No channel named “\(name)”.", symbol: "magnifyingglass", kind: .warning) }
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        let tab = router.tab
        let vs = SidebarViewState(
            title: tab == .guide ? "TV Guide" : tab.title,
            pinned: SidebarModel.pinned(for: tab),
            folders: state.folderEntries(for: tab),
            selection: router.selection,
            collapsed: router.sidebarCollapsed,
            playlistName: state.activeSource?.name,
            playlists: state.sources.filter(\.enabled).map { PlaylistEntry(id: $0.id, name: $0.name) },
            activePlaylistID: state.activeSourceID,
            playlistMenuOpen: router.playlistMenuOpen,
            folderSectionTitle: tab == .home ? "Folders" : tab == .liveTV || tab == .guide ? "Groups" : "Folders")
        return ReddySidebar(state: vs, folderQuery: $folderQuery,
                            onSelect: { router.select($0) },
                            onToggleCollapse: { withAnimation(.smooth(duration: 0.28)) { router.sidebarCollapsed.toggle() } },
                            onTogglePlaylistMenu: { router.accountMenuOpen = false; router.playlistMenuOpen.toggle() },
                            onSwitchPlaylist: { router.playlistMenuOpen = false; state.switchPlaylist($0) },
                            onAddPlaylist: { router.playlistMenuOpen = false; router.modal = .addPlaylist },
                            onReorder: { state.reorderFolders(tab: tab, entryIDs: $0) },
                            onHideFolder: { state.hideFolder($0) },
                            lockedFolderIDs: container.parental.lockedCategoryIDs,
                            parentalAvailable: container.parental.hasPIN,
                            parentalUnlocked: container.parental.isUnlocked,
                            onLockFolder: { id, locked in
                                if locked || container.parental.isUnlocked { container.parental.setFolder(id, locked: locked) } else { router.modal = .unlockRestricted }
                            })
            .zIndex(2)
    }

    private var initials: String {
        let n = state.activeSource?.name ?? "R"
        return String(n.prefix(2)).uppercased()
    }

    // MARK: overlays

    @ViewBuilder private var overlays: some View {
        @Bindable var router = router
        if router.accountMenuOpen || router.playlistMenuOpen {
            Color.clear.contentShape(Rectangle()).onTapGesture { router.closeMenus() }
                .padding(.top, router.accountMenuOpen ? 0 : LayoutTokens.headerHeight)
                .padding(.leading, router.playlistMenuOpen ? LayoutTokens.sidebarWidth : 0)
                .zIndex(2)
        }
        if router.accountMenuOpen {
            VStack { HStack { Spacer(); ReddyAccountMenu(name: state.activeSource?.name ?? "StreamSetu",
                                                         onPlaylists: { router.closeMenus(); router.modal = .playlists },
                                                         onChannelManager: { router.closeMenus(); router.modal = .channelManager },
                                                         onAbout: { router.closeMenus(); router.modal = .about },
                                                         restricted: container.parental.hasPIN ? (container.parental.isUnlocked ? .unlocked : .locked) : nil,
                                                         onRestricted: { router.closeMenus(); if container.parental.isUnlocked { container.parental.lockNow() } else { router.modal = .unlockRestricted } }) }.padding(.trailing, 14); Spacer() }
                .padding(.top, LayoutTokens.headerHeight - 4).zIndex(4).transition(.opacity)
        }
        if let m = router.movie { scrim { router.closeDetail() } ; MovieDetailView(movie: m).dialogFrame().transition(.opacity.combined(with: .scale(scale: 0.98))).zIndex(6) }
        if let s = router.series { scrim { router.closeDetail() } ; SeriesDetailView(series: s).dialogFrame().transition(.opacity.combined(with: .scale(scale: 0.98))).zIndex(6) }
        if let modal = router.modal { modalView(modal) }
        if container.playback.isExpanded { scrim { container.playback.isExpanded = false }; expandedPlayer.zIndex(8) }
    }

    private func scrim(_ close: @escaping () -> Void) -> some View {
        Color.black.opacity(0.55).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close).zIndex(5)
    }

    @ViewBuilder private func modalView(_ modal: ModalRoute) -> some View {
        scrim { router.modal = nil }
        Group {
            switch modal {
            case .playlists: PlaylistManager()
            case .addPlaylist: AddPlaylistDialog()
            case .about: AboutDialog()
            case .unlockRestricted: UnlockDialog()
            case .channelManager: ReddyDialog(title: "Channel manager", width: 940, onClose: { router.modal = nil }) { ChannelCommandCenterView().frame(height: 640) }
            }
        }
        .zIndex(7).transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var expandedPlayer: some View {
        let p = container.playback
        return ReddyDialog(title: "Now Playing", width: 880, onClose: { p.isExpanded = false }) {
            ZStack {
                Color.black
                VideoSurface(playback: p, owner: .expanded)
                PlayerControlsOverlay(playback: p, program: program, nextProgram: nextProgram,
                                      onToggleFullscreen: { p.restoreExpandedAfterFullscreen = true; p.isExpanded = false; p.isFullscreen = true }, onChannelList: nil)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .transition(.opacity)
    }

    // MARK: behaviour

    private func openPlayingItem(_ p: PlaybackCoordinator) {
        guard let req = p.current else { return }
        let c = container
        switch req.kind {
        case .movie: if let m = try? c.catalog.movie(id: req.itemID) { router.open(movie: m) }
        case .episode, .series:
            let sid = req.seriesID ?? req.itemID
            if let s = try? c.catalog.seriesItem(id: sid) { router.open(series: s) }
        default: p.isExpanded = true
        }
    }

    private func setQuery(_ q: String) {
        router.searchQuery = q
        search.term = q
        search.schedule()
    }

    private func activate(_ result: SearchResult) {
        router.clearSearch(); search.clear()
        SearchActions.perform(result, container: container, router: router, state: state)
    }

    private func loadProgram(_ playback: PlaybackCoordinator) async {
        guard let id = playback.currentChannel?.id else { program = nil; nextProgram = nil; return }
        let list = await Task.detached { [container] in (try? container.epgRepo.nowNext(channelIDs: [id], at: Date()))?[id] ?? [] }.value
        program = list.first { $0.isLive() }
        nextProgram = list.first { $0.start > Date() }
    }

    /// Plain-key shortcuts. Only called when the user is not typing in a text field (see PlayerKeyMonitor).
    private func handleKey(_ event: NSEvent, _ playback: PlaybackCoordinator) -> Bool {
        if event.keyCode == 53 {                               // Esc closes the topmost layer first
            if router.isSearching { router.clearSearch(); search.clear(); return true }
            if router.modal != nil { router.modal = nil; return true }
            if router.movie != nil || router.series != nil { router.closeDetail(); return true }
            if router.accountMenuOpen || router.playlistMenuOpen { router.closeMenus(); return true }
            if playback.isExpanded { playback.isExpanded = false; return true }
        }
        let ctx = PlayerShortcutContext(hasPlayback: playback.current != nil, isFullscreen: playback.isFullscreen, isLive: playback.isLive, switcherOpen: playback.showChannelSwitcher, numberEntryActive: !playback.numberEntry.isEmpty)
        guard let command = PlayerShortcuts.resolve(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, ctx) else { return false }
        switch command {
        case .togglePause: playback.togglePause()
        case .toggleFullscreen: playback.isFullscreen.toggle()
        case .toggleMute: playback.isMuted.toggle()
        case .exitFullscreen: playback.isFullscreen = false
        case .seek(let d): playback.seek(by: d)
        case .adjustVolume(let d): playback.isMuted = false; playback.volume = min(1, max(0, playback.volume + d))
        case .channelUp: playback.previousChannelInList()
        case .channelDown: playback.nextChannel()
        case .digit(let d): playback.appendDigit(d)
        case .numberCommit: playback.commitNumberEntry()
        case .numberCancel: playback.cancelNumberEntry()
        case .toggleSwitcher: playback.toggleChannelSwitcher()
        case .closeSwitcher: playback.closeChannelSwitcher()
        case .switcherCommit: playback.commitChannelSwitcher()
        case .switcherMove(let d): playback.moveChannelSwitcher(by: d)
        }
        return true
    }
}

private extension View {
    /// Rounded, hairline-edged frame for the details dialogs.
    func dialogFrame() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ColorTokens.glassEdge.opacity(0.7), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
            .accessibilityAddTraits(.isModal)
    }
}
