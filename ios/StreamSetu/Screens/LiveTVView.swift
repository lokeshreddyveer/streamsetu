import SwiftUI
import Observation

@MainActor @Observable
final class LiveTVModel {
    var categories: [CatalogCategory] = []
    var channels: [Channel] = []
    var guide: [String: EPGProgram] = [:]
    var categoryID: String?
    var query = ""
    var favouritesOnly = false
    var listID: String?
    var lists: [CatalogCollection] = []
    /// Set when a search found nothing as typed and a corrected spelling did.
    var correctedTo: String?
    var loading = false
    private var generation = 0
    nonisolated static let pageLimit = 600

    func load(_ c: AppContainer, source: UUID?) async {
        generation += 1
        let gen = generation
        loading = true
        let (cats, list, now, fixed) = await Task.detached { [categoryID, query, favouritesOnly, listID] () -> ([CatalogCategory], [Channel], [String: EPGProgram], String?) in
            let cats = (try? c.catalog.categories(sourceID: source, kind: .channel, includeHidden: false)) ?? []
            var q = ChannelQuery(sourceID: source, categoryID: categoryID, favoritesOnly: favouritesOnly, search: query)
            q.limit = LiveTVModel.pageLimit
            var list = (try? c.catalog.channels(q)) ?? []
            var fixed: String?
            if list.isEmpty, listID == nil, !query.trimmingCharacters(in: .whitespaces).isEmpty, let alt = c.spelling.correct(query) {
                var q2 = q; q2.search = alt
                let again = (try? c.catalog.channels(q2)) ?? []
                if !again.isEmpty { list = again; fixed = alt }
            }
            if let listID {                                   // a named list: its channels, in the order they were added
                let ids = ((try? c.favoritesRepo.collectionItems(id: listID)) ?? []).filter { $0.kind == .channel }.map(\.itemID)
                var lq = ChannelQuery(); lq.collapseVariants = false; lq.ids = ids; lq.search = query
                let byID = Dictionary(((ids.isEmpty ? [] : (try? c.catalog.channels(lq))) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                list = ids.compactMap { byID[$0] }
            }
            let at = Date()
            let all = (try? c.epgRepo.nowNext(channelIDs: list.prefix(200).map(\.id), at: at)) ?? [:]
            return (cats, list, all.compactMapValues { $0.first { $0.isLive(at: at) } }, fixed)
        }.value
        guard gen == generation else { return }
        categories = cats; channels = list; guide = now; correctedTo = fixed; loading = false
        lists = await Task.detached { ((try? c.favoritesRepo.collections()) ?? []).filter { col in let items = (try? c.favoritesRepo.collectionItems(id: col.id)) ?? []; return items.isEmpty || items.contains { $0.kind == .channel } } }.value
    }
}

struct LiveTVView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var model = LiveTVModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(IOSRouter.self) private var router
    @State private var lockedPick: String?
    @State private var askNumber = false
    @State private var renaming: Channel?
    @State private var newName = ""
    @State private var number = ""
    /// Small tiles instead of rows. A per-device choice; tiles are the default.
    @AppStorage("liveTV.tiles") private var tiles = true
    @State private var creatingGroup = false
    @State private var groupName = ""


    private func open(_ c: Channel) { if let container { Play.channel(c, queue: model.channels, container) } }

    private var empty: some View {
        EmptyState(symbol: "dot.radiowaves.left.and.right", title: model.query.isEmpty ? "No channels" : "No matches",
                   message: model.query.isEmpty ? (state.isSyncing ? "Channels appear when the playlist has been read." : "This playlist has no live channels, or the folder is empty.") : nil)
    }

    @ViewBuilder private func menu(_ c: Channel) -> some View {
        Button(state.isFavorite(c.id) ? "Remove from Favourites" : "Add to Favourites", systemImage: "heart") { state.toggleFavorite(c.id, kind: .channel) }
        CollectionMenu(itemID: c.id, kind: .channel)
        ShareLinkButton(link: DeepLink.link(channel: c.name), name: c.name)
        Button("Rename…", systemImage: "pencil") { newName = c.name; renaming = c }
        Button("Hide Channel", systemImage: "eye.slash", role: .destructive) { try? container?.favoritesRepo.hide(c.id, kind: "channel"); state.catalogVersion += 1 }
        Button("Add to Multi-View", systemImage: "rectangle.split.2x2") {
            if container?.multiView.add(c) != .full { router.showMultiView = true } else { state.toasts.show("Multi-View is full (4 channels)", symbol: "rectangle.split.2x2") }
        }
    }

    private func pick(_ cat: CatalogCategory?) {
        guard let cat else { model.categoryID = nil; return }
        if let p = container?.parental, p.isLocked(cat.id), p.isRestricting { lockedPick = cat.id } else { model.categoryID = cat.id }
    }

    /// iPhone: a plain list with swipe-to-favourite.
    private var list: some View {
        List {
            GroupChips(model: model) { creatingGroup = true }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let fixed = model.correctedTo { CorrectedNote(original: model.query, corrected: fixed).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            if model.channels.isEmpty, !model.loading { empty.listRowBackground(Color.clear).listRowSeparator(.hidden) }
            ForEach(Array(model.channels.enumerated()), id: \.element.id) { i, c in
                Button { open(c) } label: { ChannelRow(channel: c, programme: model.guide[c.id], isPlaying: container?.playback.currentChannel?.id == c.id, isFavorite: state.isFavorite(c.id), number: i + 1) }
                    .buttonStyle(.press)
                    .swipeActions(edge: .leading) { Button { state.toggleFavorite(c.id, kind: .channel) } label: { Label(state.isFavorite(c.id) ? "Unfavourite" : "Favourite", systemImage: "heart") }.tint(.pink) }
                    .contextMenu { menu(c) }
            }
            if model.channels.count >= LiveTVModel.pageLimit {
                Text("Showing the first \(LiveTVModel.pageLimit). Pick a folder or search to narrow it down.").font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }

    /// iPad: channels as cards in as many columns as fit.
    private var grid: some View {
        ScrollView {
            GroupChips(model: model) { creatingGroup = true }
            if model.channels.isEmpty, !model.loading { empty }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                ForEach(model.channels) { c in
                    Button { open(c) } label: {
                        ChannelRow(channel: c, programme: model.guide[c.id], isPlaying: container?.playback.currentChannel?.id == c.id, isFavorite: state.isFavorite(c.id))
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.press).contextMenu { menu(c) }
                }
            }.padding(16)
            if model.channels.count >= LiveTVModel.pageLimit {
                Text("Showing the first \(LiveTVModel.pageLimit). Pick a folder or search to narrow it down.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
            }
        }
    }

    /// Channels as small tiles: logo, name and what is on now, in as many columns as fit.
    private var tileGrid: some View {
        ScrollView {
            GroupChips(model: model) { creatingGroup = true }
            if model.channels.isEmpty, !model.loading { empty }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 128), spacing: 10)], spacing: 10) {
                ForEach(model.channels) { c in
                    Button { open(c) } label: {
                        ChannelTile(channel: c, programme: model.guide[c.id], isPlaying: container?.playback.currentChannel?.id == c.id, isFavorite: state.isFavorite(c.id))
                    }
                    .buttonStyle(.press).contextMenu { menu(c) }
                }
            }.padding(12)
            if model.channels.count >= LiveTVModel.pageLimit {
                Text("Showing the first \(LiveTVModel.pageLimit). Pick a folder or search to narrow it down.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if tiles { tileGrid } else if sizeClass == .regular { grid } else { list }
            }
            .navigationTitle("Live TV").themed("Live TV")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncIndicator() }
                TrailingPills {
                    NavigationLink { SearchView(embedded: true, tab: .liveTV) } label: { Image(systemName: "magnifyingglass").pillIcon() }.accessibilityLabel("Search")
                    NavigationLink { GuideView(embedded: true) } label: { Image(systemName: "calendar").pillIcon() }.accessibilityLabel("TV Guide")
                    Button { tiles.toggle() } label: { Image(systemName: tiles ? "list.bullet" : "square.grid.3x3").pillIcon() }.accessibilityLabel(tiles ? "Show as list" : "Show as tiles")
                    Button { askNumber = true } label: { Image(systemName: "number").pillIcon() }.accessibilityLabel("Go to channel number")
                    Button { router.showMultiView = true } label: { Image(systemName: "rectangle.split.2x2").pillIcon() }.accessibilityLabel("Multi-View")
                    Button { model.favouritesOnly.toggle() } label: { Image(systemName: model.favouritesOnly ? "heart.fill" : "heart").pillIcon().foregroundStyle(model.favouritesOnly ? Color.pink : ColorTokens.textPrimary) }.accessibilityLabel("Favourites only")
                    if !model.lists.isEmpty {
                        Menu {
                            Button { model.listID = nil } label: { Label("All Channels", systemImage: model.listID == nil ? "checkmark" : "") }
                            Divider()
                            ForEach(model.lists) { l in Button { model.listID = l.id } label: { Label(l.name, systemImage: model.listID == l.id ? "checkmark" : "") } }
                        } label: { Image(systemName: "list.star").pillIcon() }.accessibilityLabel("Lists")
                    }
                    Menu {
                        Button { pick(nil) } label: { Label("All Channels", systemImage: model.categoryID == nil ? "checkmark" : "") }
                        Divider()
                        ForEach(model.categories) { cat in
                            Button { pick(cat) } label: { Label(cat.name, systemImage: model.categoryID == cat.id ? "checkmark" : (container?.parental.isLocked(cat.id) == true ? "lock" : "")) }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").pillIcon() }.accessibilityLabel("Folders")
                }
            }
            .refreshable { state.syncAll() }
            .miniPlayerInset()
            .alert("Rename Channel", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let c = renaming { try? container?.favoritesRepo.setOverride(itemID: c.id, displayName: newName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newName, categoryName: nil, epgID: nil); state.catalogVersion += 1 }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("New Group", isPresented: $creatingGroup) {
                TextField("Name, for example Cricket", text: $groupName)
                Button("Create") {
                    let name = groupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let col = try? container?.favoritesRepo.createCollection(name: name) {
                        groupName = ""
                        if let c = container { Task { await model.load(c, source: state.activeSourceID); model.listID = col.id } }
                    }
                }
                Button("Cancel", role: .cancel) { groupName = "" }
            } message: { Text("Add channels to it from a channel's menu, or from the ⋯ button while watching.") }
            .alert("Go to channel", isPresented: $askNumber) {
                TextField("Number", text: $number).keyboardType(.numberPad)
                Button("Go") { if let n = Int(number), model.channels.indices.contains(n - 1) { open(model.channels[n - 1]) }; number = "" }
                Button("Cancel", role: .cancel) { number = "" }
            } message: { Text("Channels are numbered by their place in the list on screen (1–\(model.channels.count)).") }
            .sheet(isPresented: Binding(get: { lockedPick != nil }, set: { if !$0 { lockedPick = nil } })) { UnlockSheet { model.categoryID = lockedPick } }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(model.categoryID ?? "")-\(model.favouritesOnly)-\(model.listID ?? "")") { if let c = container { await model.load(c, source: state.activeSourceID) } }
        .task(id: model.query) {
            guard let c = container else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { await model.load(c, source: state.activeSourceID) }
        }
    }
}


/// The channel groups as a row of chips: everything, favourites, and the person's own groups (Cricket, News…), plus a way to make one.
struct GroupChips: View {
    @Bindable var model: LiveTVModel
    var newGroup: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", symbol: "square.grid.2x2", on: !model.favouritesOnly && model.listID == nil) { model.favouritesOnly = false; model.listID = nil }
                chip("Favourites", symbol: "heart.fill", on: model.favouritesOnly) { model.favouritesOnly = true; model.listID = nil }
                ForEach(model.lists) { l in
                    chip(l.name, symbol: "folder", on: model.listID == l.id) { model.favouritesOnly = false; model.listID = l.id }
                }
                Button { newGroup() } label: {
                    Label("New Group", systemImage: "plus").appFont(13, .medium).padding(.horizontal, 12).frame(minHeight: 36)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).appFont(13, .medium).lineLimit(1).padding(.horizontal, 12).frame(minHeight: 36)
                .background(on ? AnyShapeStyle(ColorTokens.accentDefault) : AnyShapeStyle(.thinMaterial), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}
