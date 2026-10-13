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
        Button(state.isFavorite(channel.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(channel.id, kind: .channel); onChanged() }
        CollectionMenu(itemID: channel.id, kind: .channel)
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
        Button("Details") { router.open(movie: movie) }
        Button(state.isFavorite(movie.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(movie.id, kind: .movie) }
        Button(state.isWatchLater(movie.id) ? "Remove from Watch Later" : "Add to Watch Later") { state.toggleWatchLater(movie.id, kind: .movie) }
        CollectionMenu(itemID: movie.id, kind: .movie)
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
        Button("Details") { router.open(series: series) }
        Button(state.isFavorite(series.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(series.id, kind: .series) }
        Button(state.isWatchLater(series.id) ? "Remove from Watch Later" : "Add to Watch Later") { state.toggleWatchLater(series.id, kind: .series) }
        CollectionMenu(itemID: series.id, kind: .series)
        Divider()
        Button("Hide") { try? container?.favoritesRepo.hide(series.id, kind: "series"); state.catalogVersion += 1 }
    }
}
