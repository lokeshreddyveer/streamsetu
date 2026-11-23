import SwiftUI

/// Movies and series saved to watch later, as a poster grid.
struct WatchLaterView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var titles: [LibraryItem] = []
    @State private var loaded = false
    @State private var sort: TitleSort = .recent
    @State private var editing = false
    private var width: CGFloat { sizeClass == .regular ? 150 : 108 }

    var body: some View {
        ScrollView {
            if titles.isEmpty, loaded {
                EmptyState(symbol: "bookmark", title: "Nothing saved for later", message: "Tap the bookmark on a movie or series to keep it here for later.").frame(maxWidth: .infinity, minHeight: 360)
            }
            TitleGrid(items: sort.apply(titles), editing: editing, onRemove: { t in state.toggleWatchLater(t.id, kind: t.kind); titles.removeAll { $0.id == t.id }; if titles.isEmpty { editing = false } })
            .padding(16)
        }
        .navigationTitle("Watch Later").atlasScreen("screen.ios.watchLater").themed("Watch Later")
        .editButton($editing, enabled: !titles.isEmpty)
        .listTools(sort: $sort, canClear: !titles.isEmpty, clearLabel: "Remove All from Watch Later", confirmTitle: "Remove everything from Watch Later?",
                   confirmMessage: "The titles stay in your library; they just leave this list.") {
            for t in titles { state.toggleWatchLater(t.id, kind: t.kind) }
            titles = []; editing = false
        }
        .miniPlayerInset()
        .task(id: "\(state.catalogVersion)-\(state.watchLaterIDs.count)") { await load() }
    }

    private func load() async {
        guard let c = container else { return }
        let found = await Task.detached { () -> [LibraryItem] in
            ((try? c.favoritesRepo.collectionItems(id: AppState.watchLaterListID)) ?? []).reversed().compactMap { entry -> LibraryItem? in
                if entry.kind == .series { return (try? c.catalog.seriesItem(id: entry.itemID)).flatMap { $0 }.map { .series($0) } }
                return (try? c.catalog.movie(id: entry.itemID)).flatMap { $0 }.map { .movie($0) }
            }
        }.value
        titles = found; loaded = true
    }
}

/// What an iPhone or iPad screen supplies to the shared menu.
@MainActor enum IOSTileHandlers {
    static func make(_ item: LibraryItem, container: AppContainer?, router: IOSRouter) -> TileMenuHandlers {
        var h = TileMenuHandlers(
            play: { guard let c = container else { return }; switch item { case .movie(let m): Play.movie(m, c); case .series(let s): Task { await Play.series(s, c, privately: false) } } },
            playPrivately: { guard let c = container else { return }; switch item { case .movie(let m): Play.movie(m, c, privately: true); case .series(let s): Task { await Play.series(s, c, privately: true) } } },
            open: { router.pendingAssistantItem = item })          // the root view opens the title's page
        if let cat = item.categoryID { h.openFolder = { router.pendingFolder = (item.kind, cat); router.go(item.isSeries ? .series : .movies) } }
        h.goToCast = { CastFocus.request(item.id); router.pendingAssistantItem = item }          // the title page has the cast row
        return h
    }
}

extension View {
    /// Long press: the shared tile menu, and the same items as VoiceOver actions.
    func titleTileMenu(_ item: LibraryItem, kind: TileMenu.Kind = .title) -> some View { modifier(IOSTitleTileMenu(item: item, kind: kind)) }
}

private struct IOSTitleTileMenu: ViewModifier {
    let item: LibraryItem
    let kind: TileMenu.Kind
    @Environment(\.container) private var container
    @Environment(IOSRouter.self) private var router
    func body(content: Content) -> some View { content.tileMenu(item, kind: kind, handlers: IOSTileHandlers.make(item, container: container, router: router)) }
}
