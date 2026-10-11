import SwiftUI

/// "Add to Collection" for any channel, movie or series. Collections double as named favourite lists for channels.
struct CollectionMenu: View {
    let itemID: String
    let kind: ContentKind
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let cols = (try? container?.favoritesRepo.collections()) ?? []
        Menu {
            ForEach(cols) { c in Button(c.name) { add(c) } }
            if !cols.isEmpty { Divider() }
            Button("New Collection…", systemImage: "plus") { naming = true }
        } label: { Label("Add to Collection", systemImage: "square.stack") }
        .alert("New Collection", isPresented: $naming) {
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
                NavigationLink { CollectionDetailView(collection: c) } label: { Label(c.name, systemImage: "square.stack") }
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
        .navigationDestination(for: LibraryItem.self) { DetailView(item: $0) }
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

    var body: some View {
        List {
            if channels.isEmpty, titles.isEmpty { EmptyState(symbol: "square.stack", title: "Empty", message: "Add items from their menus.").listRowBackground(Color.clear) }
            if !channels.isEmpty {
                Section("Channels") {
                    ForEach(channels) { c in
                        Button { if let container { Play.channel(c, queue: channels, container) } } label: { ChannelRow(channel: c) }.buttonStyle(.press)
                            .swipeActions { Button(role: .destructive) { remove(c.id) } label: { Label("Remove", systemImage: "minus.circle") } }
                    }
                }.listRowBackground(ColorTokens.surface)
            }
            if !titles.isEmpty {
                Section("Movies and Series") {
                    ForEach(titles) { t in
                        NavigationLink(value: t) { HStack(spacing: 12) {
                            ArtworkImage(url: t.posterURL, kind: .poster, contentMode: .fill, symbol: "film").frame(width: 40, height: 58).clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(t.title).lineLimit(2)
                        } }
                        .swipeActions { Button(role: .destructive) { remove(t.id) } label: { Label("Remove", systemImage: "minus.circle") } }
                    }
                }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle(collection.name).themed(collection.name)
        .toolbar { TrailingPills { Button("Rename") { name = collection.name; renaming = true } } }
        .alert("Rename Collection", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") { try? container?.favoritesRepo.renameCollection(id: collection.id, name: name); state.catalogVersion += 1 }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: state.catalogVersion) { await load() }
    }

    private func remove(_ id: String) { try? container?.favoritesRepo.remove(itemID: id, fromCollection: collection.id); state.catalogVersion += 1 }

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
