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
    /// True once this screen has set itself up (opened the field, cleared a per-tab query). Coming back from a title page must not do either again: the query stays and the field is not reopened by itself.
    @State private var didSetUp = false
    /// True while this screen is the one on top (false once a title page is pushed over it).
    @State private var isTop = false
    /// Idle, loading, results, empty or failed: the screen says which. A failed search keeps the results already shown.
    @State private var phase = SearchPhase.idle
    @State private var retryTick = 0
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
            .navigationTitle("Search").navigationBarTitleDisplayMode(vertical == .compact ? .inline : .automatic).themed("Search").atlasScreen("screen.ios.tab.search")
            .searchable(text: $router.query, isPresented: $presented, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            .searchSuggestions {
                if router.query.isEmpty {
                    ForEach(recents, id: \.self) { r in Label(r, systemImage: "clock.arrow.circlepath").searchCompletion(r) }
                    if !recents.isEmpty { Button("Clear Recent Searches", role: .destructive) { recentStore.clear(); recents = [] }.atlasCovers("screen.ios.tab.search") }
                }
            }
            .onSubmit(of: .search) { recentStore.add(router.query); recents = recentStore.list() }
            .searchFocused($focused)
            .onAppear {
                isTop = true
                recents = recentStore.list()
                guard !didSetUp else { return }                         // back from a title page: nothing is reset or reopened
                didSetUp = true
                if tab != .all { router.query = "" }
                if embedded { presented = true; focused = true }
            }
            .onChange(of: presented) { _, open in
                // Closing the field with the cross clears the text; a title page opening over this screen keeps it. Only the first is "go back": dismiss() pops whatever is on top, so it is
                // never called while a title page is open (the text is still there then).
                guard !open, embedded, isTop, router.query.isEmpty else { return }
                dismiss()
            }
            .onDisappear {
                isTop = false
                focused = false                                         // the field lets go of the keyboard when a page opens over it
                if tab != .all, !router.query.isEmpty { recentStore.add(router.query) }
            }
            .titleAndPersonDestinations(ownsStack: !embedded)      // embedded: the stack it is pushed into (Home, Library, More) already has them
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
                    }.buttonStyle(.press).atlasCovers("screen.ios.tab.search").glossRow()
                }
            }
            if !isBlank, let container { AtlasPaletteList(query: router.query, platform: AtlasAssistant.platform, appStore: AtlasAssistant.appStore, showAsk: !container.parental.kidsMode, open: { _ = AtlasOpener.open($0, container: container, router: router, state: state) }, show: { ShowMeController.shared.start(entryID: $0); ShowMeController.shared.openCurrentScreen() }, ask: { AssistantLauncher.shared.ask($0) }).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            if !isBlank, let container { SmartPicksCard(container: container, query: router.query, open: { _ in }, useLinks: true).listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)) }
            if isBlank {
                EmptyState(symbol: "magnifyingglass", title: "Search your library", message: "Channels, movies, series and episodes from every playlist.")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                SearchIdeasPanel(pick: { router.query = $0 }).listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if phase == .empty {
                EmptyState(symbol: "questionmark.circle", title: "No results", message: "Try fewer letters or another spelling.")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if phase == .loading, results.isEmpty {
                BrandLoader(size: 32).frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if phase == .failed { failureNote.listRowBackground(Color.clear).listRowSeparator(.hidden) }
            if let fixed = correctedTo, !isBlank {
                CorrectedNote(original: router.query, corrected: fixed).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if !isBlank, let top = results.exactMatch(for: router.query) {
                Section("Top Match") { resultLink(top, showKind: true) }.glossRow()
            }
            ForEach(SearchResultKind.allCases.filter { tab.kinds.contains($0) && !(results.byKind[$0] ?? []).isEmpty }, id: \.self) { kind in
                Section(kind.groupTitle) {
                    ForEach(results.byKind[kind] ?? []) { r in
                        resultLink(r)
                    }
                }.glossRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)      // scrolling the results pulls the keyboard away so they can be seen, also in landscape
    }

        /// A title or collection is a navigation link (value-based, like Home and Library); anything else acts in place.
    @ViewBuilder private func resultLink(_ r: SearchResult, showKind: Bool = false) -> some View {
        switch r.destination.phoneAction {
        case .openMovie(let id): NavigationLink(value: TitleRef(id: id, isSeries: false)) { row(r, showKind: showKind) }.buttonStyle(.press).atlasCovers("screen.ios.tab.search")
        case .openSeries(let id): NavigationLink(value: TitleRef(id: id, isSeries: true)) { row(r, showKind: showKind) }.buttonStyle(.press).atlasCovers("screen.ios.tab.search")
        case .showCollection(let id): NavigationLink(value: CollectionRef(id: id)) { row(r, showKind: showKind) }.buttonStyle(.press).atlasCovers("screen.ios.tab.search")
        default: Button { activate(r) } label: { row(r, showKind: showKind) }.buttonStyle(.press).atlasCovers("screen.ios.tab.search")
        }
    }

    private func row(_ r: SearchResult, showKind: Bool = false) -> some View {
        ReflowStack {
            if r.kind == .channel { ChannelLogo(url: r.artworkURL, name: r.title, size: 44) }
            else { ArtworkImage(url: r.artworkURL, kind: .poster, contentMode: .fill, symbol: r.kind.symbol, tile: .init(title: r.title)).frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(alignment: .topTrailing) { if let rt = r.rating { RatingBadge(value: rt).scaleEffect(0.85, anchor: .topTrailing).padding(2) } } }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).appFont(15, .medium).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                Text(showKind && !r.subtitle.isEmpty ? "\(r.kind.typeLabel) · \(r.subtitle)" : (showKind ? r.kind.typeLabel : r.subtitle)).appFont(12).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
            .prioritizesArtwork(r.ratingTileIDs)
            .modifier(SearchResultMenuModifier(result: r, handlers: { IOSTileHandlers.make($0, container: container, router: router) }, playChannel: { ch in if let c = container { Play.channel(ch, queue: [ch], c) } }))
    }

    private var failureNote: some View {
        VStack(spacing: 8) {
            Label("The search could not be completed.", systemImage: "exclamationmark.triangle").appFont(14, .medium).foregroundStyle(.secondary)
            Button("Retry") { retryTick += 1 }.buttonStyle(.bordered).atlasCovers("screen.ios.tab.search")
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
        // The answer arrives in stages (titles, then episodes, folders and collections, then the guide). Each stage is shown as it comes, replacing the list with everything found so far; rows
        // already shown keep their place. The results of the previous query stay on screen until the first stage has something to show, so the list never goes blank while typing.
        func search(_ text: String, publishing: Bool = true) async throws -> GlobalSearchResults {
            let parsed = SmartQueryParser.parse(text)
            var last = GlobalSearchResults()
            for try await update in c.globalSearch.updates(parsed.text.isEmpty ? text : parsed.text, tab: tab, limit: limit * (parsed.year == nil ? 1 : 3)) {
                var found = update.results
                if let y = parsed.year { found = found.keeping { $0.title.contains(String(y)) || $0.subtitle.contains(String(y)) } }
                last = found
                if publishing, !update.isFinal, !found.isEmpty, !Task.isCancelled { results = found }
            }
            try Task.checkCancellation()          // a cancelled stream ends quietly: a newer query replaced this one, and what was gathered is not a complete answer
            return last
        }
        do {
            var found = try await search(q)
            var fixed: String?
            if found.isEmpty, let alt = await Task.detached(operation: { c.spelling.correct(q) }).value {
                let again = try await search(alt, publishing: false)
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
        case .openMovie, .openSeries, .showCollection:
            break                                                        // these rows are navigation links
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
        }
    }
}

