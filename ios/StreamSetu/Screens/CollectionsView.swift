import SwiftUI

/// "Add to Collection" for any channel, movie or series. Collections double as named favourite lists for channels.
struct CollectionMenu: View {
    let itemID: String
    let kind: ContentKind
    /// What this is called on screen: a Group for channels, a Collection for movies and series.
    private var noun: String { kind == .channel ? "Group" : "Collection" }
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let cols = (try? container?.favoritesRepo.collections()) ?? []
        Menu {
            ForEach(cols) { c in Button(c.name) { add(c) } }
            if !cols.isEmpty { Divider() }
            Button("New \(noun)…", systemImage: "plus") { naming = true }
        } label: { Label("Add to \(noun)", systemImage: kind == .channel ? "folder.badge.plus" : "square.stack") }
        .alert("New \(noun)", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                if let col = try? container?.favoritesRepo.createCollection(name: newName.trimmingCharacters(in: .whitespaces)) { add(col) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func add(_ c: CatalogCollection) {
        try? container?.favoritesRepo.add(itemID: itemID, kind: kind, toCollection: c.id)
        state.catalogVersion += 1
        state.toasts.show("Added to \(c.name)", symbol: "square.stack.fill")
    }
}

struct CollectionsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var collections: [CatalogCollection] = []
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        List {
            if collections.isEmpty {
                EmptyState(symbol: "square.stack", title: "No collections yet", message: "Group channels, movies and series your own way. Channels in a collection also appear as a list in Live TV.").listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(collections) { c in
                NavigationLink { CollectionDetailView(collection: c) } label: { LibraryRow(symbol: "square.stack.fill", tint: .indigo, title: c.name, count: nil) }
                    .swipeActions { Button(role: .destructive) { try? container?.favoritesRepo.deleteCollection(id: c.id); reload() } label: { Label("Delete", systemImage: "trash") } }
            }
        }
        .navigationTitle("Collections").themed("Collections")
        .toolbar { TrailingPills { Button { naming = true } label: { Image(systemName: "plus").pillIcon() }.accessibilityLabel("New collection") } }
        .alert("New Collection", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") { _ = try? container?.favoritesRepo.createCollection(name: newName.trimmingCharacters(in: .whitespaces)); newName = ""; reload() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .listTools(sort: nil, canClear: !collections.isEmpty, clearLabel: "Delete All Collections", confirmTitle: "Delete all collections?",
                   confirmMessage: "Every collection is deleted. The movies, series and channels in them stay in your library.") {
            for col in collections { try? container?.favoritesRepo.deleteCollection(id: col.id) }
            reload(); state.catalogVersion += 1
        }
        .task(id: state.catalogVersion) { reload() }
    }

    private func reload() { collections = (try? container?.favoritesRepo.collections()) ?? [] }
}

struct CollectionDetailView: View {
    let collection: CatalogCollection
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var channels: [Channel] = []
    @State private var titles: [LibraryItem] = []
    @State private var name = ""
    @State private var renaming = false
    @State private var sort: TitleSort = .recent
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if channels.isEmpty, titles.isEmpty { EmptyState(symbol: "square.stack", title: "Empty", message: "Add items from their menus.") }
                if !channels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ListHeader(title: "Channels", count: channels.count)
                        ChannelTileGrid(channels: sort.apply(channels), editing: editing, onPlay: { ch in if let container { Play.channel(ch, queue: channels, container) } }, onRemove: { remove($0.id) })
                    }
                }
                if !titles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ListHeader(title: "Movies and Series", count: titles.count)
                        TitleGrid(items: sort.apply(titles), editing: editing, onRemove: { remove($0.id) })
                    }
                }
            }.padding(16)
        }
        .navigationTitle(collection.name).themed(collection.name)
        .editButton($editing, enabled: !channels.isEmpty || !titles.isEmpty)
        .toolbar { TrailingPills { Button("Rename") { name = collection.name; renaming = true } } }
        .listTools(sort: $sort, canClear: !channels.isEmpty || !titles.isEmpty, clearLabel: "Remove Everything from This Collection", confirmTitle: "Empty this collection?",
                   confirmMessage: "Everything in “\(collection.name)” is removed from it. The collection stays, and nothing leaves your library.") {
            for ch in channels { try? container?.favoritesRepo.remove(itemID: ch.id, fromCollection: collection.id) }
            for t in titles { try? container?.favoritesRepo.remove(itemID: t.id, fromCollection: collection.id) }
            channels = []; titles = []; state.catalogVersion += 1
        }
        .alert("Rename Collection", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") { try? container?.favoritesRepo.renameCollection(id: collection.id, name: name); state.catalogVersion += 1 }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: state.catalogVersion) { await load() }
    }

    private func remove(_ id: String) { try? container?.favoritesRepo.remove(itemID: id, fromCollection: collection.id); channels.removeAll { $0.id == id }; titles.removeAll { $0.id == id }; state.catalogVersion += 1 }

    private func load() async {
        guard let c = container else { return }
        let cid = collection.id
        let (ch, ti) = await Task.detached { () -> ([Channel], [LibraryItem]) in
            let items = (try? c.favoritesRepo.collectionItems(id: cid)) ?? []
            let cids = items.filter { $0.kind == .channel }.map(\.itemID)
            var q = ChannelQuery(); q.collapseVariants = false; q.ids = cids
            let byID = Dictionary(((cids.isEmpty ? [] : (try? c.catalog.channels(q))) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let chans = cids.compactMap { byID[$0] }
            var titles: [LibraryItem] = []
            for i in items where i.kind == .movie { if let m = try? c.catalog.movie(id: i.itemID) { titles.append(.movie(m)) } }
            for i in items where i.kind == .series { if let s = try? c.catalog.seriesItem(id: i.itemID) { titles.append(.series(s)) } }
            return (chans, titles)
        }.value
        channels = ch; titles = ti
    }
}
