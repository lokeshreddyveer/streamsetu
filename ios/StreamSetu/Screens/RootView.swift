import SwiftUI

/// Tabs on iPhone; the same tabs adapt to a sidebar on iPad where the system supports it.
struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @Environment(\.colorSchemeContrast) private var contrast
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
                        .environment(\.tabActive, router.tab == tab)          // a hidden tab keeps its state but stops its timers, slideshows and polling
                        .opacity(router.tab == tab ? 1 : 0)
                        .allowsHitTesting(router.tab == tab)
                        .accessibilityHidden(router.tab != tab)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: router.tab)
        .onAppear { visited.insert(router.tab) }
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

    @State private var opening = !OpeningPlayed.done
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
        .background(ColorTokens.background)
        .overlay {
            if let container, !state.needsOnboarding {
                AssistantBubble(container: container, bottomInset: barHeight + 10,
                                open: { item in router.pendingAssistantItem = item },
                                look: { (screen: iosScreenName, item: nil, search: router.query) },
                                perform: { p in
                                    switch p.kind {
                                    case .command, .playItem, .toggleList: return await SearchCommandRunner.execute(p.kind, container: container, router: router, state: state)
                                    default: return await container.perform(p, state: state)
                                    }
                                })
            }
        }
        .overlay { if let container { ViewingBlockOverlay(container: container) } }
        .animation(.easeInOut(duration: 0.3), value: container?.playback.viewingBlock)
        .overlay { if let container, !picked, container.profiles.isShared { ProfilePicker(service: container.profiles) { withAnimation(.easeOut(duration: 0.3)) { picked = true } } } }
        .overlay { if opening { OpeningAnimation { BrandMark() } onDone: { opening = false } } }
        .onChange(of: contrast, initial: true) { _, c in ThemeStore.state.systemContrast = c == .increased }
        .sheet(isPresented: $router.presentAdd) { AddPlaylistSheet() }
        .sheet(item: $router.pendingAssistantItem) { item in NavigationStack { DetailView(item: item) }.presentationDetents([.large]) }
        .fullScreenCover(isPresented: $router.showMultiView) { if let container { MultiViewScreen(model: container.multiView) } }
        .modifier(PlayerCover(active: true))
    }
}

/// First launch: nothing is built in, so the only thing to do is add a playlist.
struct OnboardingView: View {
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var restore = ICloudRestore()

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            BrandMark().frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text("StreamSetu").font(.system(size: 30, weight: .bold))
                Text("A bridge to your own TV. Add a playlist you are allowed to use and everything is kept on this device.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            FirstRunSteps().frame(maxWidth: 340)
            Button { router.presentAdd = true } label: { Label("Add a Playlist", systemImage: "plus").frame(maxWidth: 280) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { if let container { Task { await restore.start(container: container, state: state) } } } label: {
                HStack(spacing: 8) { if restore.phase == .looking { ProgressView() }; Label("Restore from iCloud", systemImage: "icloud.and.arrow.down") }.frame(maxWidth: 280)
            }
            .buttonStyle(.bordered).controlSize(.large).disabled(restore.phase == .looking)
            if restore.phase != .idle {
                Text(restore.detail).font(.footnote).foregroundStyle(restore.phase == .nothingFound ? .orange : .secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            Text("M3U or JSON links and files, or a login for Xtream, Jellyfin, Emby, Plex, HDHomeRun or TVHeadend. No content is included.").font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background)
    }
}

/// The app icon, as shown on the welcome screen.
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
        NavigationStack(path: $router.morePath) {
            List {
                Section {
                    NavigationLink(value: IOSRouter.MoreRoute.library) { Label("Library", systemImage: "books.vertical") }
                    NavigationLink(value: IOSRouter.MoreRoute.playlists) { Label("Playlists", systemImage: "list.bullet.rectangle") }
                    NavigationLink(value: IOSRouter.MoreRoute.settings) { Label("Settings", systemImage: "gearshape") }
                }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("More").themed("More", tabRoot: true)
            .miniPlayerInset()
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
    @Environment(ScrollChrome.self) private var chrome: ScrollChrome?
    @Namespace private var slide
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
    }

    private var pill: some View {
        let current = items.first { $0.tab == selection } ?? items[0]
        return Button { chrome?.reset() } label: {
            HStack(spacing: 6) {
                Image(systemName: current.symbol).font(.system(size: 15, weight: .medium))
                Text(current.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(ColorTokens.accentDefault)
            .padding(.horizontal, 14).frame(height: 34)
            .background(ColorTokens.card, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .accessibilityLabel("Show the tab bar, \(current.title) is open")
    }

    private var fullBar: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let on = selection == item.tab
                Button { withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { selection = item.tab } } label: {
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
                .accessibilityLabel(item.title).accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(ColorTokens.card, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .frame(maxWidth: 520)
    }
}
