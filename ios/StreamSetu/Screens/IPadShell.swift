import SwiftUI

/// The iPad's window: a sidebar of the app's destinations beside the chosen screen, instead of the iPhone's floating bar. The screens and models are the iPhone's own; only the way they are
/// reached differs. Used on a regular-width iPad window; a narrow Split View, Slide Over or Stage Manager window falls back to the iPhone navigation (see RootView).
struct IPadShell: View {
    @Environment(IOSRouter.self) private var router
    @Binding var barHeight: CGFloat
    @State private var columns = NavigationSplitViewVisibility.all
    @SceneStorage("ipad.sidebarVisibility") private var savedVisibility = "all"

    private struct Item: Identifiable { let tab: IOSRouter.Tab; let title: String; let symbol: String; var id: IOSRouter.Tab { tab } }
    private static let watch: [Item] = [
        .init(tab: .home, title: "Home", symbol: "house"), .init(tab: .live, title: "Live TV", symbol: "dot.radiowaves.left.and.right"), .init(tab: .guide, title: "Guide", symbol: "calendar"),
        .init(tab: .movies, title: "Movies", symbol: "film"), .init(tab: .series, title: "Series", symbol: "rectangle.stack"), .init(tab: .search, title: "Search", symbol: "magnifyingglass"),
    ]
    private static let yours: [Item] = [
        .init(tab: .library, title: "Library", symbol: "books.vertical"), .init(tab: .playlists, title: "Playlists", symbol: "list.bullet.rectangle"), .init(tab: .settings, title: "Settings", symbol: "gearshape"),
    ]
    private static var all: [Item] { watch + yours }

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding(get: { Self.current(router.tab) }, set: { if let t = $0 { router.go(t) } })) {
                Section { ForEach(Self.watch) { row($0) } }
                Section("Yours") { ForEach(Self.yours) { row($0) } }
            }
            .listStyle(.sidebar)
            .navigationTitle("StreamSetu")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
            .scrollContentBackground(.hidden)
            .background(ColorTokens.background)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { columns = savedVisibility == "detailOnly" ? .detailOnly : .all }
        .onChange(of: columns) { _, v in savedVisibility = v == .detailOnly ? "detailOnly" : "all" }
        .background { shortcuts }
    }

    /// "More" is the iPhone's name for the page holding Library, Playlists and Settings; the iPad has them in the sidebar, so it shows Library.
    private static func current(_ t: IOSRouter.Tab) -> IOSRouter.Tab { t == .more ? .library : t }

    private func row(_ item: Item) -> some View {
        Label(item.title, systemImage: item.symbol).tag(item.tab)
            .accessibilityAddTraits(Self.current(router.tab) == item.tab ? .isSelected : [])
    }

    /// Only the chosen screen is on screen. (Keeping the others alive behind it made each one add its buttons to the shared navigation bar.)
    private var detail: some View {
        screen(Self.current(router.tab))
            .id(Self.current(router.tab))
            .environment(\.tabActive, true)
            .contentMargins(.bottom, barHeight, for: .scrollContent)
            .overlay(alignment: .bottom) {
                // The mini player sits at the bottom of the content, never over the sidebar.
                MiniPlayerBar().padding(.horizontal, 12).padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height > 0 ? $0.size.height + 12 : 0 } action: { barHeight = $0 }
            }
    }

    @ViewBuilder private func screen(_ tab: IOSRouter.Tab) -> some View {
        switch tab {
        case .home: HomeView()
        case .live: IPadLiveTV()
        case .guide: GuideView()
        case .movies: IPadLibrary(kind: .movie)
        case .series: IPadLibrary(kind: .series)
        case .search: SearchView()
        case .library, .more: MoreView()
        case .playlists: PlaylistsView()
        case .settings: IPadSettings()
        }
    }

    /// ⌘1 to ⌘9 open the destinations in sidebar order; ⌘F opens Search.
    private var shortcuts: some View {
        Group {
            ForEach(Array(Self.all.enumerated()), id: \.offset) { i, item in
                Button(item.title) { router.go(item.tab) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("Search") { router.go(.search) }.keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
