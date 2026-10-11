import SwiftUI
import Observation

@MainActor @Observable
final class LibraryModel {
    let kind: ContentKind
    var items: [LibraryItem] = []
    var categories: [CatalogCategory] = []
    var categoryID: String?
    var query = ""
    var sort: VODSort = .recentlyAdded
    var total = 0
    var loading = false
    private var generation = 0
    private let page = 60

    init(kind: ContentKind) { self.kind = kind }

    var canLoadMore: Bool { items.count < total }

    func reload(_ c: AppContainer, source: UUID?) async {
        generation += 1
        let gen = generation
        loading = true
        let r = await fetch(c, source: source, offset: 0)
        guard gen == generation else { return }
        items = r.items; total = r.total; categories = r.categories; loading = false
    }

    func loadMore(_ c: AppContainer, source: UUID?) async {
        guard canLoadMore, !loading else { return }
        let gen = generation
        loading = true
        let r = await fetch(c, source: source, offset: items.count)
        guard gen == generation else { return }
        items += r.items; loading = false
    }

    private func fetch(_ c: AppContainer, source: UUID?, offset: Int) async -> (items: [LibraryItem], total: Int, categories: [CatalogCategory]) {
        let kind = kind, category = categoryID, term = query, sort = sort, page = page
        return await Task.detached {
            let q = VODQuery(sourceID: source, categoryID: category, search: term, sort: sort, limit: page, offset: offset)
            let cats = offset == 0 ? ((try? c.catalog.categories(sourceID: source, kind: kind, includeHidden: false)) ?? []) : []
            if kind == .movie {
                return (((try? c.catalog.movies(q)) ?? []).map { .movie($0) }, (try? c.catalog.countMovies(q)) ?? 0, cats)
            }
            return (((try? c.catalog.series(q)) ?? []).map { .series($0) }, (try? c.catalog.countSeries(q)) ?? 0, cats)
        }.value
    }
}

/// Movies or Series: a poster grid with folders, sorting and search.
struct LibraryView: View {
    let kind: ContentKind
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var model: LibraryModel
    @State private var lockedPick: String?

    init(kind: ContentKind) { self.kind = kind; _model = State(initialValue: LibraryModel(kind: kind)) }

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var posterWidth: CGFloat { sizeClass == .regular ? 150 : 110 }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterWidth, maximum: posterWidth + 40), spacing: 14, alignment: .top)] }

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.items.isEmpty, !model.loading {
                    EmptyState(symbol: kind == .movie ? "film" : "rectangle.stack", title: model.query.isEmpty ? "Nothing here" : "No matches",
                               message: model.query.isEmpty ? (state.isSyncing ? "Titles appear when the playlist has been read." : "This playlist has no \(kind == .movie ? "movies" : "series") in this folder.") : nil)
                }
                if model.total > 0 { Text("\(model.total.formatted()) titles").appFont(12).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16) }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.items) { item in
                        NavigationLink(value: item) { PosterCard(item: item, width: posterWidth) }.buttonStyle(.press)
                            .task { if item.id == model.items.last?.id, let c = container { await model.loadMore(c, source: state.activeSourceID) } }
                    }
                }
                .padding(16)
                if model.loading { ProgressView().padding() }
            }
            .navigationTitle(kind == .movie ? "Movies" : "Series").themed(kind == .movie ? "Movies" : "Series")
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search \(kind == .movie ? "movies" : "series")")
            .navigationDestination(for: LibraryItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncIndicator() }
                TrailingPills {
                    Menu {
                        Picker("Sort", selection: $model.sort) { ForEach(VODSort.allCases) { Text($0.rawValue).tag($0) } }
                    } label: { Image(systemName: "arrow.up.arrow.down.circle").pillIcon() }.accessibilityLabel("Sort")
                    Menu {
                        Button { model.categoryID = nil } label: { Label("All", systemImage: model.categoryID == nil ? "checkmark" : "") }
                        Divider()
                        ForEach(model.categories) { cat in
                            Button {
                                if let p = container?.parental, p.isLocked(cat.id), p.isRestricting { lockedPick = cat.id } else { model.categoryID = cat.id }
                            } label: { Label(cat.name, systemImage: model.categoryID == cat.id ? "checkmark" : (container?.parental.isLocked(cat.id) == true ? "lock" : "")) }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").pillIcon() }.accessibilityLabel("Folders")
                }
            }
            .refreshable { state.syncAll() }
            .miniPlayerInset()
            .sheet(isPresented: Binding(get: { lockedPick != nil }, set: { if !$0 { lockedPick = nil } })) { UnlockSheet { model.categoryID = lockedPick } }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(model.categoryID ?? "")-\(model.sort.rawValue)") { if let c = container { await model.reload(c, source: state.activeSourceID) } }
        .task(id: model.query) {
            guard let c = container else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { await model.reload(c, source: state.activeSourceID) }
        }
    }
}
