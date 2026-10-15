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
                EmptyState(symbol: "bookmark", title: "Nothing saved yet", message: "Tap the bookmark on a movie or series to keep it here for later.")
            }
            TitleGrid(items: sort.apply(titles), editing: editing, onRemove: { t in state.toggleWatchLater(t.id, kind: t.kind); titles.removeAll { $0.id == t.id }; if titles.isEmpty { editing = false } })
            .padding(16)
        }
        .navigationTitle("Watch Later").themed("Watch Later")
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

/// The long-press menu on a movie or series: favourite, and watch later.
struct TitleMenu: View {
    let item: LibraryItem
    @Environment(AppState.self) private var state

    var body: some View {
        Button(state.isFavorite(item.id) ? "Remove from Favourites" : "Add to Favourites", systemImage: state.isFavorite(item.id) ? "heart.slash" : "heart") {
            state.toggleFavorite(item.id, kind: item.kind)
        }
        Button(state.isWatchLater(item.id) ? "Remove from Watch Later" : "Add to Watch Later", systemImage: state.isWatchLater(item.id) ? "bookmark.slash" : "bookmark") {
            state.toggleWatchLater(item.id, kind: item.kind)
        }
        CollectionMenu(itemID: item.id, kind: item.kind)
    }
}
