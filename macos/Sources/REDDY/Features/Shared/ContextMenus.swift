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
        }.atlas("context.tile.collection")
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
        ChannelMenuContent(channel: channel, onPlay: onPlay, onMultiView: {
            guard let mv = container?.multiView else { return }
            switch mv.add(channel) {
            case .added, .alreadyShown: openWindow(id: "multiview")
            case .full: state.toasts.show("Multi-View is full (4 channels)", symbol: "rectangle.split.2x2")
            }
        }, onChanged: onChanged)          // the one shared builder (TileMenu.entries, kind .channel)
    }
}
