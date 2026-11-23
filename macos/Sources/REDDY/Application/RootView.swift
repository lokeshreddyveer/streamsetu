import SwiftUI
import CoreSpotlight
import AppKit

struct RootView: View {
    let coordinator: AppCoordinator
    @State private var picked = ProfilePicked.done
    @State private var confirmFresh = false
    @State private var inventory = DatabaseRecovery.Inventory()

    var body: some View {
        // The opening sits beside the content, not on it, and is owned by OpeningCoordinator (one per process), so neither the content
        // changing from "starting" to "ready" nor the window being rebuilt can restart it or keep it on screen.
        ZStack {
            content
            OpeningOverlay().zIndex(10)
        }
        .onChange(of: destination, initial: true) { _, d in
            guard d != .starting else { return }
            OpeningCoordinator.shared.destinationReady(ok: d == .ready, hasSources: !(coordinator.state?.sources.isEmpty ?? true))
        }
    }

    private enum Destination { case starting, ready, failed }
    private var destination: Destination {
        switch coordinator.phase { case .starting: .starting; case .ready: .ready; case .failed: .failed }
    }

    private func choosing(_ c: AppContainer) -> Bool { !picked && c.profiles.isShared }

    @ViewBuilder private var content: some View {
        switch coordinator.phase {
        case .starting:
            BrandLoader(size: 56, label: "Opening your library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background).preferredColorScheme(.dark)
        case .failed(let message):
            VStack(spacing: Spacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(ColorTokens.warning)
                Text("StreamSetu couldn't open its library").font(Typography.title)
                Text(message).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: 480).multilineTextAlignment(.center)
                HStack {
                    SecondaryButton(title: "Show Data Folder", symbol: "folder") { WindowManager.revealInFinder(StorageService.applicationSupport) }
                    SecondaryButton(title: "Start Fresh…", symbol: "trash") { inventory = coordinator.inventoryOfDamagedLibrary(); confirmFresh = true }
                    PrimaryButton(title: "Repair Library", symbol: "wrench.and.screwdriver") { Task { await coordinator.recoverLibrary(keepPersonalData: true) } }
                }
                Text("Repair keeps your playlists, favourites, lists, profiles, locks and watch history and reads the channels again from your playlists. The damaged library is never deleted: it is kept in the Recovery folder.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).frame(maxWidth: 480).multilineTextAlignment(.center)
                    .confirmationDialog("Start with an empty library?", isPresented: $confirmFresh, titleVisibility: .visible) {
                        Button("Start Fresh", role: .destructive) { Task { await coordinator.recoverLibrary(keepPersonalData: false) } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your playlists, favourites, lists, profiles, folder locks, watch history and resume points will no longer be in the app. Passwords stay in your Keychain, but you will need to add the playlists again.\n\nIn the damaged library: " + inventory.lines.joined(separator: ", ") + ".\n\nThe old library is kept in the Recovery folder, so it can still be recovered by hand.")
                    }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background).preferredColorScheme(.dark)
        case .ready:
            if let container = coordinator.container, let state = coordinator.state {
                MainShell(router: coordinator.router, keys: coordinator.keys, container: container, state: state, services: coordinator.services, hosts: coordinator.hosts)
                    .overlay { if choosing(container) { ProfilePicker(service: container.profiles) { withAnimation(.easeOut(duration: 0.3)) { picked = true } } } }
                    .overlay { ViewingBlockOverlay(container: container) }
                    .animation(.easeInOut(duration: 0.3), value: container.playback.viewingBlock)
            }
        }
    }
}

/// The bottom bar with its own observation of the playback session (position, volume, state), kept out of `MainShell.body`.
private struct BottomPlayerHost: View {
    let playback: PlaybackCoordinator
    let program: EPGProgram?
    let surface: PrimaryPlayerSurface
    let onTitle: () -> Void

    var body: some View {
        if let bar = BottomPlayerAdapter.state(playback, program: program) {
            ReddyBottomPlayer(state: bar,
                              onTitle: onTitle,
                              onTogglePlay: { if bar.failed { playback.retryNow() } else { playback.togglePause() } },
                              onToggleMute: { playback.isMuted.toggle() },
                              onVolume: { playback.isMuted = false; playback.volume = $0 },
                              onSeek: { playback.seek(to: $0) },
                              onExpand: { playback.isExpanded = true },          // the bar hands over to the popup; it disappears while the popup is up
                              onStop: { playback.stop() },
                              videoPlayback: bar.isLive || !PlayerSurfaceModel.barHoldsVideo(surface) ? nil : playback,
                              onSkip: { playback.seek(by: $0) })
        }
    }
}

struct MainShell: View {
    let router: AppRouter
    let keys: PlayerKeyMonitor
    let container: AppContainer
    let state: AppState
    let services: ServiceNavigation
    let hosts: ServiceHostRegistry
    @State private var servicePrefs = ServicePreferences.load()
    @State private var switchingProfile = false
    @State private var addingProfile = false
    @State private var program: EPGProgram?
    @State private var nextProgram: EPGProgram?
    @State private var folderQuery = ""
    @State private var width: CGFloat = 1440
    @State private var search: GlobalSearchModel
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(router: AppRouter, keys: PlayerKeyMonitor, container: AppContainer, state: AppState, services: ServiceNavigation = ServiceNavigation(), hosts: ServiceHostRegistry = ServiceHostRegistry()) {
        self.router = router; self.keys = keys; self.container = container; self.state = state; self.services = services; self.hosts = hosts
        _search = State(initialValue: GlobalSearchModel(service: container.globalSearch))
    }

    var body: some View {
        @Bindable var router = router
        let playback = container.playback
        let surface = playback.primarySurface
        ZStack {
            if state.needsOnboarding {
                OnboardingView().atlasScreen("screen.onboarding")
            } else {
                VStack(spacing: 0) {
                    topBar
                        .zIndex(3)
                    HStack(spacing: 0) {
                        // The native sidebar and screens belong to StreamSetu; while a service shows, the destination state (not a flag of its own) removes them.
                        if services.navExpanded { sidebar }
                        ZStack {
                            mainContent
                            // Results replace the content while searching. The screen underneath stays alive, so clearing the
                            // search returns to exactly where you were; playback is never touched.
                            if router.isSearching {
                                searchResultsPage
                            }
                        }
                    }
                    .zIndex(1)
                    if services.navExpanded, PlayerSurfaceModel.showsBar(surface), playback.current != nil {          // no native bar under a service's page
                        // The bar reads position, volume and state itself, so a playback tick redraws the bar and not this whole shell.
                        BottomPlayerHost(playback: playback, program: program, surface: surface, onTitle: { openPlayingItem(playback) })
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : AnimationTokens.standard, value: surface)
                overlays
            }
            if !state.needsOnboarding && services.navExpanded {          // the Setu button would sit over the service's own controls
                AssistantBubble(container: container, bottomInset: max(20, PlayerSurfaceModel.reservedBottom(surface, isLive: playback.isLive)),
                                open: { PlayActions.open($0, router: router) },
                                look: { (screen: assistantScreenName, item: router.movie.map { .movie($0) } ?? router.series.map { .series($0) }, search: router.searchQuery) },
                                perform: { p in
                                    switch p.kind {
                                    case .command, .playItem, .toggleList, .openAtlas: return await SearchCommandRunner.execute(p.kind, container: container, router: router, state: state)
                                    default: return await container.perform(p, state: state)
                                    }
                                })
            }
            VStack { Spacer(); HStack { Spacer(); ToastHost(center: state.toasts) } }.padding(.bottom, services.navExpanded && PlayerSurfaceModel.showsBar(surface) ? PlayerSurfaceModel.reservedBottom(surface, isLive: playback.isLive) + 8 : 12)
        }
        // The root shell owns the top edge: the bar starts at the window's top in every window state, so it is never pushed
        // by the title bar's safe-area inset, and it is never inside a scroll view.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1024, minHeight: 680)
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .background(WindowChrome(barHeight: LayoutTokens.headerHeight))
        .overlay(alignment: .topLeading) { TrafficLights().ignoresSafeArea(.container, edges: .top) }
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
        .background(ServiceGuards(services: services, hosts: hosts, router: router, playback: playback, lock: container.appLock))
        .onChange(of: AtlasNavRequests.shared.window) { _, id in if let id { openWindow(id: id); AtlasNavRequests.shared.window = nil } }          // Setu opening a window
        .onChange(of: container.settings.hideEmptyFolders) { _, _ in state.reloadFolders() }
        .onChange(of: router.selection) { _, _ in router.clearSearch(); search.clear() }
        .onChange(of: state.activeSourceID) { _, new in container.screens.removeAll { $0.source != new }; container.filterOptionsStore.invalidate(); folderQuery = ""; router.closeDetail(); router.clearSearch(); search.clear() }
        .onOpenURL { handleOpen($0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in          // a Spotlight result for a screen or a setting
            if let id = AtlasSpotlight.atlasID(fromActivityIdentifier: activity.userInfo?[CSSearchableItemActivityIdentifier] as? String), let url = DeepLink.link(atlas: id) { handleOpen(url) }
        }
        .onChange(of: container.appLock.isLocked) { _, locked in if locked { container.screens.clear() }; if !locked, let url = container.appLock.takeHeldLink() { handleOpen(url) } }          // what was opened while locked runs now
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay { if dropTargeted { dropHint.allowsHitTesting(false).transition(.opacity).zIndex(20) } }
        .animation(AnimationTokens.standard, value: dropTargeted)
        .onChange(of: router.sidebarCollapsed) { _, c in container.settings.sidebarWasCollapsed = c }
        .onChange(of: container.settings.rememberFolders) { _, on in router.rememberFolders = on }
        .onAppear {
            ShowMeController.shared.opener = { id in AtlasOpener.open(id, container: container, router: router, state: state).isDone }
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
        .onReceive(NotificationCenter.default.publisher(for: StreamingServicesSettingsModel.preferencesDidChange)) { _ in servicePrefs = ServicePreferences.load() }
        .atlasShowMeHost()
    }

    /// The native screen, or the service that replaced it (the destination state decides; nothing else).
    @ViewBuilder private var mainContent: some View {
        Group {
            if services.navExpanded {
                ContentRouter()
                    .id(state.activeSourceID)       // a playlist switch rebuilds the screen: nothing carries over
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = services.activeService {
                // One host view for every embedded service; a disabled one shows the native unavailable screen. Both were checked by the same capability gate in `select`.
                if let model = hosts.model(for: id) {
                    ServiceHostView(model: model, onReturn: { services.returnToStreamSetu() }).id(id).transition(.opacity)
                } else if let def = hosts.registry.definition(for: id), def.presentation == .integrationUnavailable {
                    IntegrationUnavailableView(definition: def, onReturn: { services.returnToStreamSetu() }).id(id).transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : AnimationTokens.standard, value: services.active)
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
        if container.appLock.isLocked { return false }
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL, LocalMedia.isVideo(url.lastPathComponent) { FilesPlayer.open(url, container: container); return }
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
        switch container.appLock.disposition(for: url) {        // nothing a link or a file asks for happens behind the lock
        case .runNow: break
        case .holdUntilUnlocked: container.appLock.hold(url); return
        case .drop: return
        }
        if url.isFileURL, LocalMedia.isVideo(url.lastPathComponent) { FilesPlayer.open(url, container: container); return }
        if url.isFileURL {
            if let p = PendingAdd.fromFile(url) { present(p) } else { state.toasts.show("StreamSetu can't open that kind of file.", symbol: "exclamationmark.triangle", kind: .warning) }
            return
        }
        guard let link = DeepLink.parse(url) else { state.toasts.show("That link isn't one StreamSetu understands.", symbol: "link.badge.plus", kind: .warning); return }
        let playback = container.playback
        switch link {
        case .addPlaylist(let address, let name): present(.address(address, name: name))
        case .openTab(let tab): router.navigate(tab)
        case .openService(let service): services.select(service)          // refused where the platform or profile does not allow it
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
        case .playMovie(let title): playMovie(titled: title)
        case .findSeries(let title): router.navigate(.series); router.searchQuery = title; search.term = title; search.schedule()
        case .atlas(let id): _ = AtlasOpener.open(id, container: container, router: router, state: state)
        }
    }

    private func playMovie(titled title: String) {
        let sid = state.activeSourceID, c = container
        Task { @MainActor in
            let found = await Task.detached { () -> Movie? in
                let list = (try? c.catalog.movies(VODQuery(sourceID: sid, search: title, limit: 50))) ?? []
                let wanted = MetadataNormalizer.normalize(title)
                return list.first(where: { MetadataNormalizer.normalize($0.title) == wanted }) ?? list.first
            }.value
            if let movie = found { c.playback.play(movie: movie) }
            else { state.toasts.show("No movie named “\(title)”.", symbol: "magnifyingglass", kind: .warning) }
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
            playlistName: state.libraryName,
            playlists: (state.canCombinePlaylists ? [PlaylistEntry(id: AppState.allPlaylistsID, name: "All Playlists")] : []) + state.sources.filter(\.enabled).map { PlaylistEntry(id: $0.id, name: $0.name) },
            activePlaylistID: state.showsAllPlaylists ? AppState.allPlaylistsID : state.activeSourceID,
            playlistMenuOpen: router.playlistMenuOpen,
            folderSectionTitle: tab == .home ? "Folders" : tab == .liveTV || tab == .guide ? "Groups" : "Folders")
        return ReddySidebar(state: vs, folderQuery: $folderQuery,
                            onSelect: { router.select($0) },
                            onToggleCollapse: { withAnimation(.smooth(duration: 0.28)) { router.sidebarCollapsed.toggle() } },
                            onTogglePlaylistMenu: { router.accountMenuOpen = false; router.playlistMenuOpen.toggle() },
                            onSwitchPlaylist: { router.playlistMenuOpen = false; if $0 == AppState.allPlaylistsID { state.switchToAllPlaylists() } else { state.switchPlaylist($0) } },
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
        let n = container.profiles.isShared ? container.profiles.active.name : (state.libraryName ?? "R")
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
            VStack { HStack { Spacer(); ReddyAccountMenu(name: state.libraryName ?? "StreamSetu",
                                                         onChannelManager: { router.closeMenus(); router.modal = .channelManager },
                                                         onAbout: { router.closeMenus(); router.modal = .about },
                                                         restricted: container.parental.hasPIN ? (container.parental.isUnlocked ? .unlocked : .locked) : nil,
                                                         onRestricted: { router.closeMenus(); if container.parental.isUnlocked { container.parental.lockNow() } else { router.modal = .unlockRestricted } },
                                                         profiles: container.profiles.profiles, activeProfileID: container.profiles.activeID, canAddProfile: container.profiles.canAdd,
                                                         onPickProfile: { p in
                                                             router.closeMenus()
                                                             if container.profiles.switchTo(p.id) == .needsPIN { switchingProfile = true }     // the picker asks for the PIN
                                                         },
                                                         onAddProfile: { router.closeMenus(); addingProfile = true }) }.padding(.trailing, 14); Spacer() }
                .padding(.top, LayoutTokens.headerHeight - 4).zIndex(4).transition(.opacity)
        }
        Color.clear.frame(width: 0, height: 0).sheet(isPresented: $addingProfile) { AddProfileSheet(service: container.profiles) }
        if switchingProfile { ProfilePicker(service: container.profiles) { withAnimation(.easeOut(duration: 0.3)) { switchingProfile = false } }.zIndex(12) }
        if let m = router.movie { scrim { router.closeDetail() } ; TitleDialogHost { MovieDetailView(movie: m).id(m.id).atlasScreen("screen.title.movie") }.transition(TitleDialogMotion.transition).zIndex(6) }
        if let s = router.series { scrim { router.closeDetail() } ; TitleDialogHost { SeriesDetailView(series: s).id(s.id).atlasScreen("screen.title.series") }.transition(TitleDialogMotion.transition).zIndex(6) }
        if let modal = router.modal { modalView(modal) }
        if PlayerSurfaceModel.showsExpanded(container.playback.primarySurface) { scrim { container.playback.isExpanded = false }; expandedPlayer.zIndex(8) }
    }

    private func scrim(_ close: @escaping () -> Void) -> some View {
        Color.black.opacity(0.55).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close).zIndex(5)
    }

    @ViewBuilder private func modalView(_ modal: ModalRoute) -> some View {
        scrim { router.modal = nil }
        Group {
            switch modal {
            case .playlists: PlaylistManager().atlasScreen("screen.playlists")
            case .addPlaylist: AddPlaylistDialog()
            case .about: AboutDialog()
            case .unlockRestricted: UnlockDialog()
            case .channelManager: ReddyDialog(title: "Channel manager", width: 940, onClose: { router.modal = nil }) { ChannelCommandCenterView().atlasScreen("screen.settings.channelManager").frame(height: 640) }
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
                                      onToggleFullscreen: { p.isFullscreen = true }, onChannelList: nil)
            }
            .atlas("control.player.expanded")
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
        case .movie: if let m = try? c.catalog.movie(id: req.itemID) { router.open(movie: m) } else { p.isExpanded = true }
        case .episode, .series:
            let sid = req.seriesID ?? req.itemID
            if let s = try? c.catalog.seriesItem(id: sid) { router.open(series: s) }
        default: p.isExpanded = true
        }
    }

    /// The name of the screen, for the assistant.
    private var assistantScreenName: String {
        if router.isSearching { return "Search results" }
        if router.movie != nil { return "A movie's page" }
        if router.series != nil { return "A series' page" }
        switch router.selection { case .shortcut(let sc): return router.tab.title + ": " + sc.title; case .folder: return router.tab.title + ": a folder" }
    }

    private func setQuery(_ q: String) {
        router.searchQuery = q
        search.term = q
        search.schedule()
    }

    /// What the top bar's pinned items and Services list read and call. Every choice goes through `services.select`, the one capability gate.
    private var servicesNav: ServicesNavigationBinding {
        ServicesNavigationBinding(
            listed: services.services,
            pinned: servicePrefs.pinned, recents: servicePrefs.recents, active: services.activeService,
            availability: { hosts.registry.definition(for: $0)?.availability ?? .registered },
            select: { id in
                guard services.select(id) else { return }
                servicePrefs.noteOpened(id); servicePrefs.save(); router.closeMenus()
            },
            togglePin: { id in
                if servicePrefs.isPinned(id) { servicePrefs.unpin(id) } else { servicePrefs.pin(id) }
                servicePrefs.save(); NotificationCenter.default.post(name: StreamingServicesSettingsModel.preferencesDidChange, object: nil)
            },
            move: { id, i in servicePrefs.move(id, to: i); servicePrefs.save() },
            canReload: { id in services.activeService == id && hosts.model(for: id) != nil },
            reload: { id in if services.activeService == id { hosts.model(for: id)?.reload() } },
            canClearData: { id in hosts.registry.definition(for: id)?.presentation == .embedded },
            clearData: { id in
                guard let def = hosts.registry.definition(for: id) else { return }
                Task { await ServiceDataClearing.confirmAndClear(id, name: def.displayName, hosts: hosts) }
            })
    }

    private var topBar: some View {
        @Bindable var router = router
        return ReddyTopBar(state: TopBarState(tab: router.tab, initials: initials, accountMenuOpen: router.accountMenuOpen, width: width,
                                               destination: services.active, services: [], servicesDisabled: services.isBlocked,
                                               showsServicesMenu: true, servicesNav: servicesNav),
            query: Binding(get: { router.searchQuery }, set: { setQuery($0) }),
            focusToken: router.topSearchFocus,
            titleOpen: router.movie != nil || router.series != nil,
            onSubmit: { submitSearch() },
            onResultsFocus: { router.searchResultsFocus += 1 },
            onAsk: { askSetu($0) },
            onSelectTab: { router.navigate($0) },
            onToggleAccount: { router.playlistMenuOpen = false; router.accountMenuOpen.toggle() },
            onSelectService: { servicesNav.select($0) },
            onSelectStreamSetu: { services.returnToStreamSetu() })
    }

    private var searchResultsPage: some View {
        SearchResultsPage(model: search, focusToken: router.searchResultsFocus, isFavorite: { state.isFavorite($0) }, onActivate: activate,
                          onAsk: { askSetu($0) }, onOpenAtlas: { openAtlas($0) }, onShowAtlas: { showAtlas($0) })
            .atlasScreen("screen.searchResults")
    }

    /// Return in the top search: a question goes to Setu; otherwise the best library result; with no library result, the best screen or setting; with nothing at all, Setu.
    private func submitSearch() {
        let q = router.searchQuery.trimmingCharacters(in: .whitespaces)
        let kids = container.parental.kidsMode
        if !kids, AtlasPaletteSource.isQuestion(q) { askSetu(q); return }
        if let r = search.selected ?? search.visible.first { activate(r); return }
        guard search.searched, !q.isEmpty else { return }
        if let row = AtlasPaletteSource.rows(for: q, engine: Atlas.engine, platform: .mac, appStore: AtlasAssistant.appStore, limit: 1).first { row.canOpen ? openAtlas(row.id) : showAtlas(row.id); return }
        if !kids { askSetu(q) }
    }

    private func askSetu(_ q: String) {
        router.clearSearch(); search.clear()
        AssistantLauncher.shared.ask(q.trimmingCharacters(in: .whitespaces))
    }

    private func openAtlas(_ id: String) {
        router.clearSearch(); search.clear()
        _ = AtlasOpener.open(id, container: container, router: router, state: state)
    }

    /// Opens the screen the entry lives on, then points at it.
    private func showAtlas(_ id: String) {
        router.clearSearch(); search.clear()
        guard ShowMeController.shared.start(entryID: id) else { return }
        ShowMeController.shared.openCurrentScreen()
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
        if container.appLock.isLocked { return false }          // locked: the keys do nothing (and are not swallowed)
        if let w = event.window, let main = NSApp.mainWindow, w !== main, services.activeService != nil { return false }          // a popover or panel over a service owns its own keys
        if event.keyCode == 53 {                               // Esc closes the topmost layer first (the popup sits above everything else)
            if playback.isExpanded && !playback.isFullscreen { playback.isExpanded = false; return true }
            if router.isSearching { router.clearSearch(); search.clear(); return true }
            if router.modal != nil { router.modal = nil; return true }
            if router.movie != nil || router.series != nil { router.closeDetail(); return true }
            if router.accountMenuOpen || router.playlistMenuOpen { router.closeMenus(); return true }
        }
        let ctx = PlayerShortcutContext(hasPlayback: playback.current != nil, isFullscreen: playback.isFullscreen, isLive: playback.isLive, switcherOpen: playback.showChannelSwitcher, numberEntryActive: !playback.numberEntry.isEmpty, isExpanded: playback.isExpanded)
        if ServiceKeyRouting.bypassesNativeKeys(serviceActive: services.activeService != nil, popupPlayerUp: playback.isExpanded) { return false }          // plain keys belong to the service's page, unless the popup player is up over it
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
}

/// Where plain keys (Space, arrows, letters, Escape) go. Esc first closes a native layer that is open (popup, search, dialog, menu); every other plain key goes to the web page while a service shows, so typing, Space, arrows and the page's own full-screen exit work. Keys with Command are menu commands and are never seen here.
enum ServiceKeyRouting {
    static func bypassesNativeKeys(serviceActive: Bool, popupPlayerUp: Bool) -> Bool { serviceActive && !popupPlayerUp }
}

/// What must happen around an outside service, as plain functions so each rule is tested without a window.
@MainActor enum ServiceGuardActions {
    /// A service was selected: dialogs and sheets that would stay over it close, the popup player goes back to its bar, full screen ends, and the app's own player pauses (it is not resumed by itself).
    static func serviceEntered(router: AppRouter, collapsePlayer: () -> Void, pausePlayer: () -> Void) {
        router.closeDetail(); router.modal = nil; router.closeMenus()
        collapsePlayer(); pausePlayer()
    }
    /// The app's own player started: the service's sound stops.
    static func playerStarted(pauseServiceMedia: () -> Void) { pauseServiceMedia() }
    /// A Kids profile or the lock came on, or the person began a search: back to StreamSetu (which also stops the service's media).
    static func leave(services: ServiceNavigation, pauseServiceMedia: () -> Void) { services.returnToStreamSetu(); pauseServiceMedia() }
}

/// Keeps an outside service from running where it should not.
private struct ServiceGuards: View {
    let services: ServiceNavigation
    let hosts: ServiceHostRegistry
    let router: AppRouter
    let playback: PlaybackCoordinator
    let lock: AppLock
    var body: some View {
        Color.clear
            .onChange(of: playback.isActive) { _, active in if active { ServiceGuardActions.playerStarted(pauseServiceMedia: { hosts.pauseAll() }) } }
            .onChange(of: playback.currentChannel?.id) { _, _ in if playback.isActive { ServiceGuardActions.playerStarted(pauseServiceMedia: { hosts.pauseAll() }) } }
            .onChange(of: services.isBlocked) { _, blocked in if blocked { ServiceGuardActions.leave(services: services, pauseServiceMedia: { hosts.pauseAll() }) } }
            .onChange(of: lock.isLocked) { _, locked in if locked { ServiceGuardActions.leave(services: services, pauseServiceMedia: { hosts.pauseAll() }) } }
            // typing in the top search shows native results, so the app returns to StreamSetu first: the selected item and the content always agree
            .onChange(of: router.isSearching) { _, searching in if searching, services.activeService != nil { ServiceGuardActions.leave(services: services, pauseServiceMedia: { hosts.pauseAll() }) } }
            .onChange(of: services.activeService) { _, now in
                hosts.pauseAll(except: now)          // media stops on every switch and on returning to StreamSetu; nothing resumes by itself
                if now != nil { ServiceGuardActions.serviceEntered(router: router, collapsePlayer: { playback.isExpanded = false; playback.isFullscreen = false }, pausePlayer: { if playback.isActive { playback.pause() } }) }
            }
    }
}
