import SwiftUI

/// "Add to Collection" submenu shared by channels, movies and series.
struct CollectionMenu: View {
    let itemID: String
    let kind: ContentKind
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    var body: some View {
        let cols = (try? container?.favoritesRepo.collections()) ?? []
        Menu("Add to Collection") {
            ForEach(cols) { c in
                Button(c.name) { try? container?.favoritesRepo.add(itemID: itemID, kind: kind, toCollection: c.id); state.toasts.show("Added to \(c.name)", symbol: "square.stack.fill") }
            }
            if !cols.isEmpty { Divider() }
            Button("New Collection…") { NewCollectionPrompt.run { name in
                if let col = try? container?.favoritesRepo.createCollection(name: name) {
                    try? container?.favoritesRepo.add(itemID: itemID, kind: kind, toCollection: col.id)
                    state.toasts.show("Added to \(col.name)", symbol: "square.stack.fill")
                }
            } }
        }
    }
}

@MainActor enum NewCollectionPrompt {
    static func run(_ done: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Collection"
        alert.informativeText = "Group channels, movies and series your own way."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { done(field.stringValue) }
    }
}

struct ChannelContextMenu: View {
    let channel: Channel
    var onPlay: () -> Void
    var onChanged: () -> Void = {}
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Play", action: onPlay)
        Button("Watch Privately", systemImage: "eye.slash") { container?.playback.play(channel: channel, privately: true) }
        Button(state.isFavorite(channel.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(channel.id, kind: .channel); onChanged() }
        CollectionMenu(itemID: channel.id, kind: .channel)
        ShareLinkButton(link: DeepLink.link(channel: channel.name), name: channel.name)
        Button("Add to Multi-View") {
            guard let mv = container?.multiView else { return }
            switch mv.add(channel) {
            case .added, .alreadyShown: openWindow(id: "multiview")
            case .full: state.toasts.show("Multi-View is full (4 channels)", symbol: "rectangle.split.2x2")
            }
        }
        Divider()
        Button("Hide Channel") { try? container?.favoritesRepo.hide(channel.id, kind: "channel"); state.catalogVersion += 1; onChanged() }
    }
}

struct MovieContextMenu: View {
    let movie: Movie
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    var body: some View {
        Button("Play") { container?.playback.play(movie: movie) }
        Button("Watch Privately", systemImage: "eye.slash") { container?.playback.play(movie: movie, privately: true) }
        Button("Details") { router.open(movie: movie) }
        Button(state.isFavorite(movie.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(movie.id, kind: .movie) }
        Button(state.isWatchLater(movie.id) ? "Remove from Watch Later" : "Add to Watch Later") { state.toggleWatchLater(movie.id, kind: .movie) }
        QueueMenu(item: .movie(movie))
        FavoriteOrderMenu(item: .movie(movie))
        CollectionMenu(itemID: movie.id, kind: .movie)
        ShareLinkButton(link: DeepLink.link(movie: movie.title), name: movie.title)
        Divider()
        Button("Hide") { try? container?.favoritesRepo.hide(movie.id, kind: "movie"); state.catalogVersion += 1 }
    }
}

struct SeriesContextMenu: View {
    let series: Series
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    var body: some View {
        Button("Watch Privately", systemImage: "eye.slash") { if let c = container { PlayActions(container: c, toasts: state.toasts).playSeries(series, privately: true) } }
        Button("Details") { router.open(series: series) }
        Button(state.isFavorite(series.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(series.id, kind: .series) }
        Button(state.isWatchLater(series.id) ? "Remove from Watch Later" : "Add to Watch Later") { state.toggleWatchLater(series.id, kind: .series) }
        QueueMenu(item: .series(series))
        FavoriteOrderMenu(item: .series(series))
        CollectionMenu(itemID: series.id, kind: .series)
        ShareLinkButton(link: DeepLink.link(series: series.title), name: series.title)
        Divider()
        Button("Hide") { try? container?.favoritesRepo.hide(series.id, kind: "series"); state.catalogVersion += 1 }
    }
}

/// "Play Next" and "Add to Queue" (or "Remove from Queue") for a title, in its context menu.
struct QueueMenu: View {
    let item: LibraryItem
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    var body: some View {
        if let q = container?.watchQueue {
            if q.contains(item.id) {
                Button("Remove from Queue") { q.remove(item.id) }
            } else {
                Button("Play Next") { q.add(item, next: true); state.toasts.show("“\(item.title)” plays next", symbol: "text.line.first.and.arrowtriangle.forward") }
                Button("Add to Queue") { q.add(item); state.toasts.show("Added “\(item.title)” to the queue", symbol: "text.badge.plus") }
            }
        }
    }
}

/// "Move to Front" and "Move to End" for a title that is a favourite: the order the favourites are shown in is the person's own.
struct FavoriteOrderMenu: View {
    let item: LibraryItem
    @Environment(AppState.self) private var state
    var body: some View {
        if state.isFavorite(item.id) {
            Button("Move to Front of Favorites") { state.moveFavorite(item.id, kind: item.kind, toFront: true) }
            Button("Move to End of Favorites") { state.moveFavorite(item.id, kind: item.kind, toFront: false) }
        }
    }
}
