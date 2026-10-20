import SwiftUI
import Observation

@MainActor @Observable
final class LibraryModel {
    let kind: ContentKind
    var items: [LibraryItem] = []
    var categories: [CatalogCategory] = []
    var categoryID: String?
    var query = ""
    /// Everything, only favourites, or only what was saved to watch later.
    enum Shelf: String, CaseIterable { case all, favourites, watchLater, unwatched, unwatchedFavourites, thisMonth, newEpisodes }
    var shelf: Shelf = .all
    var sort: VODSort = .recentlyAdded
    /// The Filter sheet's choices (the folder stays in [categoryID]), and the languages and qualities this list really has.
    var filter = LibraryFilter()
    private(set) var filterOptions = LibraryFilterOptions()
    private var optionsKey = ""
    var total = 0
    var loading = false
    private var generation = 0
    private let page = 60

    init(kind: ContentKind) { self.kind = kind }

    var canLoadMore: Bool { items.count < total }

    /// Set when a search found nothing as typed and a corrected spelling did: the words actually searched for.
    var correctedTo: String?
    /// What was understood from a sentence typed in the search box ("Telugu · 2024 · under 2 h"); empty when the search is just a title.
    private(set) var understood: [String] = []
    /// Titles found because of somebody in them, with who ("Cast: Mahesh Babu").
    private(set) var matchNotes: [String: String] = [:]

    func reload(_ c: AppContainer, source: UUID?) async {
        generation += 1
        let gen = generation
        loading = true
        let sentence = NaturalQuery.parse(query)
        var r = await fetch(c, source: source, offset: 0, term: query, natural: true)
        var natural = sentence.isStructured
        if r.items.isEmpty, natural {          // the sentence found nothing: the words as a plain title search, so a name that looks like a filter still works
            r = await fetch(c, source: source, offset: 0, term: query, natural: false)
            natural = false
        }
        var fixed: String?
        let typed = query
        if r.items.isEmpty, !typed.trimmingCharacters(in: .whitespaces).isEmpty,
           let alt = await Task.detached(operation: { c.spelling.correct(typed) }).value {
            let again = await fetch(c, source: source, offset: 0, term: alt, natural: false)
            if !again.items.isEmpty { r = again; fixed = alt }
        }
        guard gen == generation else { return }
        items = r.items; total = r.total; categories = r.categories; correctedTo = fixed; loading = false
        understood = natural ? sentence.summary : []
        let words = natural ? sentence.text : (fixed ?? query), shown = items.map { (id: $0.id, title: $0.title) }
        matchNotes = words.trimmingCharacters(in: .whitespaces).isEmpty ? [:] : await Task.detached { PeopleIndex(db: c.db).matchNotes(term: words, items: shown) }.value
        let key = "\(source?.uuidString ?? "")-\(r.categories.count)"
        if key != optionsKey, !items.isEmpty || filter.isActive == false {
            optionsKey = key
            let kind = kind
            filterOptions = await Task.detached { (try? c.catalog.filterOptions(sourceID: source, kind: kind)) ?? LibraryFilterOptions() }.value
        }
    }

    func loadMore(_ c: AppContainer, source: UUID?) async {
        guard canLoadMore, !loading else { return }
        let gen = generation
        loading = true
        let r = await fetch(c, source: source, offset: items.count, term: correctedTo ?? query, natural: !understood.isEmpty)
        guard gen == generation else { return }
        items += r.items; loading = false
    }

    private func fetch(_ c: AppContainer, source: UUID?, offset: Int, term: String, natural: Bool) async -> (items: [LibraryItem], total: Int, categories: [CatalogCategory]) {
        let kind = kind, category = categoryID, sort = sort, page = page, shelf = shelf, filter = filter
        let sentence = natural ? NaturalQuery.parse(term) : NaturalQuery(text: term)           // "telugu movies 2024 under 2 hours": language, year and length are filters
        let parsed = SmartQueryParser.parse(term)           // "hindi movies 2024": the year is a filter and "movies" is not part of the title
        return await Task.detached {
            var q = VODQuery(sourceID: source, categoryID: category, search: sentence.isStructured ? sentence.text : parsed.text, sort: sort, limit: page, offset: offset)
            q.year = sentence.isStructured ? sentence.year : parsed.year
            filter.apply(to: &q, kind: kind)
            if sentence.isStructured {          // what the sentence said fills in what the filters left open
                q.language = q.language ?? sentence.language; q.decade = q.decade ?? sentence.decade; q.quality = q.quality ?? sentence.quality
                q.minRating = q.minRating ?? sentence.minRating; q.maxMinutes = sentence.maxMinutes; q.minMinutes = sentence.minMinutes
                if sentence.unwatched { q.unwatchedOnly = true }
                if sentence.started { q.watch = .started }
                if sentence.favorites { q.favoritesOnly = true }
                if let d = sentence.addedWithinDays { q.addedWithinDays = d }
            }
            switch shelf {
            case .all: break
            case .favourites: q.favoritesOnly = true
            case .unwatched: q.unwatchedOnly = true
            case .unwatchedFavourites: q.unwatchedOnly = true; q.favoritesOnly = true
            case .thisMonth: q.addedWithinDays = 30
            case .newEpisodes: q.newEpisodesOnly = true
            case .watchLater:
                let saved = ((try? c.favoritesRepo.collectionItems(id: AppState.watchLaterListID)) ?? []).filter { $0.kind == kind }.map(\.itemID).reversed()
                q.ids = saved.isEmpty ? ["-none-"] : Array(saved)
            }
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
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @State private var model: LibraryModel
    @State private var lockedPick: String?
    @State private var featured: [LibraryItem] = []

    init(kind: ContentKind) { self.kind = kind; _model = State(initialValue: LibraryModel(kind: kind)) }


    @Environment(\.horizontalSizeClass) private var sizeClass
    private var posterWidth: CGFloat { sizeClass == .regular ? 150 : 110 }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterWidth, maximum: posterWidth + 40), spacing: 14, alignment: .top)] }

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.items.isEmpty, !model.loading {
                    EmptyState(symbol: model.shelf == .watchLater ? "bookmark" : model.shelf == .favourites ? "heart" : model.shelf == .unwatched ? "eye.slash" : model.shelf == .unwatchedFavourites ? "heart.slash" : model.shelf == .thisMonth ? "calendar.badge.plus" : model.shelf == .newEpisodes ? "sparkles.tv" : (kind == .movie ? "film" : "rectangle.stack"), title: model.query.isEmpty ? (model.shelf == .watchLater ? "Nothing saved yet" : model.shelf == .favourites ? "No favourites yet" : model.shelf == .unwatched ? "Everything has been played" : model.shelf == .unwatchedFavourites ? "No unwatched favourites" : model.shelf == .thisMonth ? "Nothing new this month" : model.shelf == .newEpisodes ? "No new episodes" : "Nothing here") : "No matches",
                               message: model.query.isEmpty ? (state.isSyncing ? "Titles appear when the playlist has been read." : "This playlist has no \(kind == .movie ? "movies" : "series") in this folder.") : nil)
                }
                // The same slideshow as Home, only of movies (or only of series); hidden while searching or inside one folder.
                if !featured.isEmpty, model.query.isEmpty, model.categoryID == nil, model.shelf == .all { FeaturedBanner(items: featured, height: sizeClass == .regular ? 300 : 220).padding(.top, 4) }
                ShelfChips(selection: $model.shelf, kind: kind)
                if !model.understood.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Understood as").appFont(12).foregroundStyle(.secondary)
                            ForEach(model.understood, id: \.self) { Text($0).appFont(12, .medium).padding(.horizontal, 9).padding(.vertical, 4).background(.thinMaterial, in: Capsule()) }
                        }.padding(.horizontal, 16)
                    }.padding(.top, 4)
                }
                if let fixed = model.correctedTo { CorrectedNote(original: model.query, corrected: fixed).padding(.top, 4) }
                if model.total > 0 { Text("\(model.total.formatted()) titles").appFont(12).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16) }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.items) { item in
                        NavigationLink(value: item) { PosterCard(item: item, width: posterWidth, note: model.matchNotes[item.id]) }.buttonStyle(.press).contextMenu { TitleMenu(item: item) }
                            .task { if item.id == model.items.last?.id, let c = container { await model.loadMore(c, source: state.activeSourceID) } }
                    }
                }
                .padding(16)
                if model.loading { ProgressView().padding() }
            }
            .navigationTitle(kind == .movie ? "Movies" : "Series").themed(kind == .movie ? "Movies" : "Series")
            .navigationDestination(for: LibraryItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncIndicator() }
                TrailingPills {
                    NavigationLink { SearchView(embedded: true, tab: kind == .movie ? .movies : .series) } label: { Image(systemName: "magnifyingglass").pillIcon() }.accessibilityLabel("Search")
                    Menu {
                        Picker("Sort", selection: $model.sort) { ForEach(VODSort.allCases) { Text($0.rawValue).tag($0) } }
                        LibraryFilterMenus(kind: kind, filter: $model.filter, options: model.filterOptions)
                    } label: { Image(systemName: model.filter.isActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle").pillIcon() }
                    .accessibilityLabel(model.filter.isActive ? "Sort and filter, \(model.filter.count) filters on" : "Sort and filter")
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
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(model.categoryID ?? "")-\(String(describing: model.filter))-\(model.sort.rawValue)-\(model.shelf.rawValue)-\(state.watchLaterIDs.count)-\(state.favoriteIDs.count)") { if let c = container { await model.reload(c, source: state.activeSourceID) } }
        .onAppear { state.reloadWatched() }
        .onChange(of: router.pendingFolder?.id, initial: true) { _, _ in
            if let pending = router.pendingFolder, pending.kind == kind { model.categoryID = pending.id; router.pendingFolder = nil }
        }
        .task(id: "featured-\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") {
            guard let c = container else { return }
            let source = state.activeSourceID, kind = kind
            featured = await Task.detached { (try? c.discover.featured(sourceID: source, kinds: [kind], count: 6, seed: FeaturedPicker.launchSeed ^ (kind == .movie ? 0x51 : 0xA3))) ?? [] }.value
        }
        .task(id: model.query) {
            guard let c = container else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { await model.reload(c, source: state.activeSourceID) }
        }
    }
}


/// All, Favourites, Watch Later and the smart lists (New Episodes, Unwatched, Unwatched Favourites, Added in 30 Days) as a row of chips under the banner.
struct ShelfChips: View {
    @Binding var selection: LibraryModel.Shelf
    var kind: ContentKind = .movie

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", "square.grid.2x2", .all)
                chip("Favourites", "heart.fill", .favourites)
                chip("Watch Later", "bookmark.fill", .watchLater)
                if kind == .series { chip("New Episodes", "sparkles.tv", .newEpisodes) }
                chip("Unwatched", "eye.slash", .unwatched)
                chip("Unwatched Favourites", "heart.slash", .unwatchedFavourites)
                chip("Added in 30 Days", "calendar.badge.plus", .thisMonth)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func chip(_ title: String, _ symbol: String, _ shelf: LibraryModel.Shelf) -> some View {
        let on = selection == shelf
        return Button { selection = shelf } label: {
            Label(title, systemImage: symbol).appFont(13, .medium).lineLimit(1).padding(.horizontal, 12).frame(minHeight: 36)
                .background(on ? AnyShapeStyle(ColorTokens.accentDefault) : AnyShapeStyle(.thinMaterial), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}
