import SwiftUI

/// One search over everything in the library: channels, movies, series and episodes.
struct SearchView: View {
    var embedded = false
    /// What to search: everything (Home), or only movies, only series or only channels (opened from those screens).
    var tab: SearchTab = .all
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @State private var results = GlobalSearchResults()
    /// Idle, loading, results, empty or failed: the screen says which. A failed search keeps the results already shown.
    @State private var phase = SearchPhase.idle
    @State private var retryTick = 0
    @State private var opened: LibraryItem?
    @State private var openedCollection: CatalogCollection?
    @FocusState private var focused: Bool
    /// Whether the search field is open. Closing it with the cross takes you back to the screen you came from.
    @State private var presented = false
    @Environment(\.dismiss) private var dismiss
    @State private var correctedTo: String?
    @State private var recents: [String] = []
    private var recentStore: RecentSearches { RecentSearches(scope: tab.rawValue) }
    private var prompt: String { tab == .all ? "Channels, movies, series" : "Search \(tab.rawValue.lowercased())" }

    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        @Bindable var router = router
        OptionalStack(embedded: embedded) {
            list
            .navigationTitle("Search").navigationBarTitleDisplayMode(vertical == .compact ? .inline : .automatic).themed("Search")
            .searchable(text: $router.query, isPresented: $presented, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            .searchSuggestions {
                if router.query.isEmpty {
                    ForEach(recents, id: \.self) { r in Label(r, systemImage: "clock.arrow.circlepath").searchCompletion(r) }
                    if !recents.isEmpty { Button("Clear Recent Searches", role: .destructive) { recentStore.clear(); recents = [] } }
                }
            }
            .onSubmit(of: .search) { recentStore.add(router.query); recents = recentStore.list() }
            .searchFocused($focused)
            .onAppear { recents = recentStore.list(); if tab != .all { router.query = "" }; if embedded { presented = true; focused = true } }
            .onChange(of: presented) { _, open in if !open, embedded { dismiss() } }
            .onDisappear { if tab != .all { recentStore.add(router.query); router.query = "" } }
            .navigationDestination(item: $opened) { DetailView(item: $0) }
            .navigationDestination(item: $openedCollection) { CollectionDetailView(collection: $0) }
            .miniPlayerInset()
        }
        .task(id: "\(router.query)|\(retryTick)") { await run() }
    }

    private var isBlank: Bool { router.query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Home's search: one list with a section for each kind of result.
    private var list: some View {
        List {
            if !isBlank, let container {
                ForEach(SearchCommands.parse(router.query)) { cmd in
                    Button { SearchCommandRunner.run(cmd, container: container, router: router, state: state) } label: {
                        Label(cmd.title, systemImage: cmd.symbol).appFont(15, .medium).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.press).listRowBackground(ColorTokens.surface)
                }
            }
            if !isBlank, let container { SmartPicksCard(container: container, query: router.query, open: { opened = $0 }).listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)) }
            if isBlank {
                EmptyState(symbol: "magnifyingglass", title: "Search your library", message: "Channels, movies, series and episodes from every playlist.")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                SearchIdeasPanel(pick: { router.query = $0 }).listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if phase == .empty {
                EmptyState(symbol: "questionmark.circle", title: "No results", message: "Try fewer letters or another spelling.")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if phase == .loading, results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if phase == .failed { failureNote.listRowBackground(Color.clear).listRowSeparator(.hidden) }
            if let fixed = correctedTo, !isBlank {
                CorrectedNote(original: router.query, corrected: fixed).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if !isBlank, let top = results.exactMatch(for: router.query) {
                Section("Top Match") { Button { activate(top) } label: { row(top, showKind: true) }.buttonStyle(.press) }.listRowBackground(ColorTokens.surface)
            }
            ForEach(SearchResultKind.allCases.filter { tab.kinds.contains($0) && !(results.byKind[$0] ?? []).isEmpty }, id: \.self) { kind in
                Section(kind.groupTitle) {
                    ForEach(results.byKind[kind] ?? []) { r in
                        Button { activate(r) } label: { row(r) }.buttonStyle(.press)
                    }
                }.listRowBackground(ColorTokens.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)      // scrolling the results pulls the keyboard away so they can be seen, also in landscape
    }

    private func row(_ r: SearchResult, showKind: Bool = false) -> some View {
        ReflowStack {
            if r.kind == .channel { ChannelLogo(url: r.artworkURL, name: r.title, size: 44) }
            else { ArtworkImage(url: r.artworkURL, kind: .poster, contentMode: .fill, symbol: r.kind.symbol).frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 6)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).appFont(15, .medium).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                Text(showKind && !r.subtitle.isEmpty ? "\(r.kind.typeLabel) · \(r.subtitle)" : (showKind ? r.kind.typeLabel : r.subtitle)).appFont(12).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }

    private var failureNote: some View {
        VStack(spacing: 8) {
            Label("The search could not be completed.", systemImage: "exclamationmark.triangle").appFont(14, .medium).foregroundStyle(.secondary)
            Button("Retry") { retryTick += 1 }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    private func run() async {
        let q = router.query.trimmingCharacters(in: .whitespaces)
        guard let c = container, !q.isEmpty else { results = GlobalSearchResults(); correctedTo = nil; phase = .idle; return }
        phase = .loading
        try? await Task.sleep(nanoseconds: 200_000_000)                 // type-ahead: wait for a pause
        guard !Task.isCancelled else { return }
        let tab = tab, limit = tab == .all ? 12 : 60
        // "hindi movies 2024": the year narrows the results, and "movies" is not part of the title.
        func search(_ text: String) async throws -> GlobalSearchResults {
            let parsed = SmartQueryParser.parse(text)
            var found = try await c.globalSearch.search(parsed.text.isEmpty ? text : parsed.text, tab: tab, limit: limit * (parsed.year == nil ? 1 : 3))
            if let y = parsed.year { found = found.keeping { $0.title.contains(String(y)) || $0.subtitle.contains(String(y)) } }
            return found
        }
        do {
            var found = try await search(q)
            var fixed: String?
            if found.isEmpty, let alt = await Task.detached(operation: { c.spelling.correct(q) }).value {
                let again = try await search(alt)
                if !again.isEmpty { found = again; fixed = alt }
            }
            if !Task.isCancelled { results = found; correctedTo = fixed; phase = SearchPhase.finish(found) }
        } catch is CancellationError {
            return                                                       // a newer search replaced this one
        } catch {
            if !Task.isCancelled { phase = .failed }    // the results already shown stay on screen
        }
    }

    private func activate(_ r: SearchResult) {
        guard let c = container else { return }
        switch r.destination.phoneAction {
        case .playChannel(let id):
            if let ch = try? c.catalog.channel(id: id) { Play.channel(ch, queue: [ch], c) }
        case .openMovie(let id):
            if let m = try? c.catalog.movie(id: id) { opened = .movie(m) }
        case .openSeries(let id):
            if let s = try? c.catalog.seriesItem(id: id) { opened = .series(s) }
        case .playEpisode(let id, let seriesID):
            if let e = try? c.catalog.episode(id: id), let s = try? c.catalog.seriesItem(id: seriesID) { Play.episode(e, s, c) }
        case .playProgramme(let channelID):
            if let ch = try? c.catalog.channel(id: channelID) { Play.channel(ch, queue: [ch], c) }
        case .showFolder(let tab, let kind, let categoryID):
            // The folder opens in the screen that shows its kind, with that folder chosen; this search is closed so the person lands there.
            router.pendingFolder = (kind, categoryID)
            if embedded { dismiss() }
            router.go(tab)
        case .unavailable:
            break                                                        // never shown: the search returns no folder of a kind that has none
        case .showCollection(let id):
            Task {
                let found = await Task.detached { (try? c.favoritesRepo.collections())?.first { $0.id == id } }.value
                if let found { openedCollection = found } else { state.toasts.show("That collection no longer exists", symbol: "square.stack") }
            }
        }
    }
}

