import SwiftUI

/// Tabs on iPhone; the same tabs adapt to a sidebar on iPad where the system supports it.
struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @State private var visited: Set<IOSRouter.Tab> = []
    /// How tall the floating bar (and the mini player above it) is right now, so every scrolling page can leave that much room at its end.
    @State private var barHeight: CGFloat = 0
    /// What the scrolling page tells the bars (the bottom one shrinks to a pill, the top buttons fold into the title). iPhone only.
    @State private var chrome = ScrollChrome()

    /// iPhone: five screens, so Movies and Series stay on the bar instead of falling into "More". The system tab bar is not used at
    /// all (it keeps a grey strip behind a custom bar); this switches between the screens itself and draws the floating bar.
    /// A screen is created the first time it is opened and then kept, so its scroll position and open pages are remembered.
    @ViewBuilder private var compactTabs: some View {
        @Bindable var router = router
        ZStack {
            ForEach(compactOrder, id: \.self) { tab in
                if visited.contains(tab) || router.tab == tab {
                    compactScreen(tab)
                        .id(router.rootResets[tab, default: 0])          // a second tap on its own tab rebuilds it, which closes whatever was opened inside
                        .environment(\.tabActive, router.tab == tab)          // a hidden tab keeps its state but stops its timers, slideshows and polling
                        .opacity(router.tab == tab ? 1 : 0)
                        .allowsHitTesting(router.tab == tab)
                        .accessibilityHidden(router.tab != tab)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: router.tab)
        .onAppear {
            visited.insert(router.tab)
            if let container { ShowMeController.shared.opener = { id in AtlasOpener.open(id, container: container, router: router, state: state).isDone } }
        }
        .onChange(of: router.tab) { _, t in visited.insert(t); chrome.reset() }
        // Pages pushed from a tab (Settings and its sub-pages, details) do not inherit a safe-area inset placed around the tabs, so their last
        // row slid under the bar. A bottom margin on every scrolling page does reach them, and follows the bar as the mini player comes and goes.
        .contentMargins(.bottom, barHeight, for: .scrollContent)
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) { MiniPlayerBar(); CompactTabBar(selection: $router.tab) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height + 6 } action: { if !chrome.barCollapsed { barHeight = $0 } }          // the room pages leave is for the full bar; it must not change while the bar is a pill
        }
        .environment(chrome)          // after the overlay, so the bar reaches it too
    }

    /// The name of the screen, for the assistant.
    private var iosScreenName: String {
        switch router.tab {
        case .home: "Home"; case .live: "Live TV"; case .guide: "TV Guide"; case .movies: "Movies"; case .series: "Series"; case .search: "Search"
        case .library: "Library"; case .playlists: "Playlists"; case .settings: "Settings"; case .more: "More"
        }
    }

    private var compactOrder: [IOSRouter.Tab] { [.home, .live, .movies, .series, .more] }

    @ViewBuilder private func compactScreen(_ tab: IOSRouter.Tab) -> some View {
        switch tab {
        case .home: HomeView()
        case .live: LiveTVView()
        case .movies: LibraryView(kind: .movie)
        case .series: LibraryView(kind: .series)
        default: MoreTab()
        }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// An iPad window wide enough for a sidebar. A narrow Split View, Slide Over or Stage Manager window (compact width) uses the iPhone navigation; an iPhone always does.
    private var usesSidebar: Bool { UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular }

    @State private var picked = ProfilePicked.done

    var body: some View {
        @Bindable var router = router
        Group {
            if state.needsOnboarding {
                OnboardingView()
            } else {
                if usesSidebar { IPadShell(barHeight: $barHeight) } else { compactTabs }
            }
        }
        .onChange(of: usesSidebar, initial: true) { _, v in
            router.sidebar = v
            // A window that narrows (Split View, Slide Over, Stage Manager) loses the sidebar: a screen that only the sidebar had (Search, Guide, Library) has no tab in the compact layout and would be blank. More leads to all of them.
            if !v, !compactOrder.contains(router.tab) { router.tab = .more }
        }
        .loggingNotice()
        // Short messages ("Refreshing your library…") rise in at the bottom, above the tab bar.
        .overlay(alignment: .bottom) { ToastHost(center: state.toasts).padding(.bottom, barHeight + 8) }
        .background(ColorTokens.background)
        // Setu, the assistant: a round sparkles button above the bars (hidden in kids mode, on the welcome screens, and while a keyboard is up).
        .overlay {
            if let container, !state.needsOnboarding {
                AssistantBubble(container: container, bottomInset: barHeight + 8, receded: chrome.barCollapsed,
                                open: { item in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.pendingAssistantItem = item } },          // the chat sheet closes first (one sheet at a time)
                                look: { (screen: iosScreenName, item: nil, search: nil) },
                                perform: { p in
                                    switch p.kind {
                                    case .command, .playItem, .toggleList, .openAtlas: return await SearchCommandRunner.execute(p.kind, container: container, router: router, state: state)
                                    default: return await container.perform(p, state: state)
                                    }
                                })
            }
        }
        .overlay { if let container { ViewingBlockOverlay(container: container) } }
        .animation(.easeInOut(duration: 0.3), value: container?.playback.viewingBlock)
        .overlay { if let container, !picked, container.profiles.isShared { ProfilePicker(service: container.profiles) { withAnimation(.easeOut(duration: 0.3)) { picked = true } } } }
        .modifier(ThemeSync())
        .sheet(isPresented: $router.presentAdd) { AddPlaylistSheet() }
        .sheet(item: $router.pendingAssistantItem) { item in NavigationStack { DetailView(item: item).id(item.id).titleAndPersonDestinations() }.presentationDetents([.large]) }
        .fullScreenCover(isPresented: $router.showMultiView) { if let container { MultiViewScreen(model: container.multiView) } }
        .modifier(PlayerCover(active: true))
        .atlasShowMeHost()
    }
}

/// Keeps the theme's state in step with the system: Increase Contrast. Kept apart from RootView.body, which the compiler cannot type-check in reasonable time with more on it.
struct ThemeSync: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .onChange(of: contrast, initial: true) { _, c in ThemeStore.state.systemContrast = c == .increased }
    }
}

/// The app icon, as shown on the About row in More.
struct BrandMark: View {
    var body: some View {
        if let name = (Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any],
           let files = name["CFBundleIconFiles"] as? [String], let last = files.last, let image = UIImage(named: last) {
            Image(uiImage: image).resizable().clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            Image(systemName: "tv.and.mediabox").resizable().scaledToFit().foregroundStyle(ColorTokens.accentDefault)
        }
    }
}

/// Shows the full player. Only one view at a time may present it, so the main window does while no other full screen is open,
/// and a full screen (Guide, Library, Settings on iPhone) does while it is.
struct PlayerCover: ViewModifier {
    let active: Bool
    @Environment(\.container) private var container

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { active && (container?.playback.isExpanded ?? false) }, set: { if !$0 { container?.playback.isExpanded = false } })) {
            if let container { PlayerScreen(playback: container.playback) }
        }
    }
}

/// iPhone's last tab: your Library and Settings.
struct MoreTab: View {
    @Environment(IOSRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.moreStack) {
            List {
                Section {
                    NavigationLink(value: IOSRouter.MoreRoute.library) { Label("Library", systemImage: "books.vertical") }.atlas("screen.ios.tab.library")
                    NavigationLink(value: IOSRouter.MoreRoute.playlists) { Label("Playlists", systemImage: "list.bullet.rectangle") }.atlas("screen.ios.tab.playlists")
                    NavigationLink(value: IOSRouter.MoreRoute.settings) { Label("Settings", systemImage: "gearshape") }.atlas("screen.ios.tab.settings")
                }.glossRow()
            }
            .navigationTitle("More").atlasScreen("screen.ios.tab.more").themed("More", tabRoot: true)
            .miniPlayerInset()
            .titleAndPersonDestinations()
            .navigationDestination(for: IOSRouter.MoreRoute.self) { route in
                switch route {
                case .search: SearchView(embedded: true)
                case .guide: GuideView(embedded: true)
                case .library: MoreView(embedded: true)
                case .playlists: PlaylistsView(embedded: true)
                case .settings: SettingsView(embedded: true)
                }
            }
        }
    }
}

/// The iPhone's bottom bar: a slim floating pill, shorter than the system's, in the theme's colours. While the page scrolls down it gives way to a
/// small pill at the right, under the thumb, like Safari's: the current tab's icon and name. Tapping the pill brings the whole bar back.
struct CompactTabBar: View {
    @Binding var selection: IOSRouter.Tab
    @Environment(IOSRouter.self) private var router
    @Environment(AppState.self) private var state
    @Environment(ScrollChrome.self) private var chrome: ScrollChrome?
    @Namespace private var slide
    /// The last few taps on the bar, newest last. Three quick taps on the same tab refresh the library (see registerTap).
    @State private var recentTaps: [(tab: IOSRouter.Tab, at: Date)] = []
    @State private var refreshCount = 0
    private let items: [(tab: IOSRouter.Tab, title: String, symbol: String)] = [
        (.home, "Home", "house"), (.live, "Live TV", "dot.radiowaves.left.and.right"),
        (.movies, "Movies", "film"), (.series, "Series", "rectangle.stack"), (.more, "More", "ellipsis.circle"),
    ]

    var body: some View {
        let small = chrome?.barCollapsed ?? false
        ZStack(alignment: .trailing) {
            if small {
                pill.transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
            } else {
                fullBar.transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: small ? .trailing : .center)
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.impact(weight: .medium), trigger: refreshCount)
    }

    /// Three quick taps (within a second) on the same tab refresh the library: the playlist that is open, or every playlist when "all" is chosen.
    /// Taps on different tabs never count, so moving around the bar quickly cannot start a refresh of a big catalogue by accident. A refresh already
    /// running is not started again; the person is told so.
    private func registerTap(_ tab: IOSRouter.Tab) {
        let now = Date()
        recentTaps = Array((recentTaps + [(tab: tab, at: now)]).filter { now.timeIntervalSince($0.at) <= 1.0 }.suffix(3))
        guard recentTaps.count == 3, recentTaps.allSatisfy({ $0.tab == tab }) else { return }
        recentTaps = []
        if state.isSyncing {
            state.toasts.show("Your library is already refreshing.", symbol: "arrow.triangle.2.circlepath")
            return
        }
        if let id = state.activeSourceID { state.sync(id) } else { state.syncAll() }
        refreshCount += 1
        state.toasts.show("Refreshing your library…", symbol: "arrow.triangle.2.circlepath")
    }

    private var pill: some View {
        let current = items.first { $0.tab == selection } ?? items[0]
        return Button { chrome?.reset() } label: {
            Image(systemName: current.symbol).font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ColorTokens.accentDefault)
                .frame(width: 50, height: 50)
                .background(ColorTokens.card, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.press)
        .accessibilityLabel("Show the tab bar, \(current.title) is open")
        .atlas("screen.ios.tabBar")
    }

    private var fullBar: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let on = selection == item.tab
                Button {
                    registerTap(item.tab)
                    if selection == item.tab { router.reselect(item.tab); chrome?.reset() }
                    else { withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { selection = item.tab } }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: item.symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                            .symbolEffect(.bounce, value: on)
                        Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .foregroundStyle(on ? ColorTokens.accentDefault : ColorTokens.textSecondary)
                    .background {
                        if on { Capsule().fill(ColorTokens.elevated).matchedGeometryEffect(id: "selected", in: slide) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.press)
                .accessibilityLabel(item.title).accessibilityIdentifier("tab.\(item.tab)").accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                .atlas("screen.ios.tabBar")
            }
        }
        .padding(3)
        .background(ColorTokens.card, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .frame(maxWidth: 520)
    }
}
