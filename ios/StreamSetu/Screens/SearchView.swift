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
    @State private var searching = false
    @State private var opened: LibraryItem?
    @FocusState private var focused: Bool
    /// Whether the search field is open. Closing it with the cross takes you back to the screen you came from.
    @State private var presented = false
    @Environment(\.dismiss) private var dismiss
    @State private var correctedTo: String?
    @State private var recents: [String] = []
    private var recentStore: RecentSearches { RecentSearches(scope: tab.rawValue) }
    private var prompt: String { tab == .all ? "Channels, movies, series" : "Search \(tab.rawValue.lowercased())" }

    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var posterWidth: CGFloat { sizeClass == .regular ? 150 : 108 }

    var body: some View {
        @Bindable var router = router
        OptionalStack(embedded: embedded) {
            Group { if tab == .all { list } else { grid } }
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
            .miniPlayerInset()
        }
        .task(id: router.query) { await run() }
    }

    private var isBlank: Bool { router.query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Home's search: one list with a section for each kind of result.
    private var list: some View {
        List {
            if isBlank {
                EmptyState(symbol: "magnifyingglass", title: "Search your library", message: "Channels, movies, series and episodes from every playlist.")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if results.isEmpty, !searching {
                EmptyState(symbol: "questionmark.circle", title: "No results", message: "Try fewer letters or another spelling.")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let fixed = correctedTo, !isBlank {
                CorrectedNote(original: router.query, corrected: fixed).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(SearchResultKind.allCases.filter { !(results.byKind[$0] ?? []).isEmpty }, id: \.self) { kind in
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

    /// Movies, Series and Live TV search: the results as tiles in a grid, like those screens themselves.
    private var grid: some View {
        let found = tab.kinds.flatMap { results.byKind[$0] ?? [] }
        let isChannel = tab == .liveTV
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isBlank {
                    EmptyState(symbol: "magnifyingglass", title: "Search \(tab.rawValue.lowercased())", message: "Try a title, or something like “hindi movies 2024”.")
                } else if found.isEmpty, !searching {
                    EmptyState(symbol: "questionmark.circle", title: "No results", message: "Try fewer letters or another spelling.")
                }
                if let fixed = correctedTo, !isBlank { CorrectedNote(original: router.query, corrected: fixed) }
                LazyVGrid(columns: isChannel ? [GridItem(.adaptive(minimum: 92, maximum: 128), spacing: 10)]
                                             : [GridItem(.adaptive(minimum: posterWidth, maximum: posterWidth + 40), spacing: 14, alignment: .top)], spacing: isChannel ? 10 : 16) {
                    ForEach(found) { r in
                        Button { activate(r) } label: { isChannel ? AnyView(SearchChannelTile(result: r)) : AnyView(SearchPosterTile(result: r, width: posterWidth)) }
                            .buttonStyle(.press)
                    }
                }
                .padding(.horizontal, isChannel ? 12 : 16)
            }
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(_ r: SearchResult) -> some View {
        HStack(spacing: 12) {
            if r.kind == .channel { ChannelLogo(url: r.artworkURL, name: r.title, size: 44) }
            else { ArtworkImage(url: r.artworkURL, kind: .poster, contentMode: .fill, symbol: r.kind.symbol).frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 6)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).appFont(15, .medium).lineLimit(2)
                Text(r.subtitle).appFont(12).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }

    private func run() async {
        let q = router.query.trimmingCharacters(in: .whitespaces)
        guard let c = container, !q.isEmpty else { results = GlobalSearchResults(); correctedTo = nil; return }
        searching = true
        try? await Task.sleep(nanoseconds: 200_000_000)                 // type-ahead: wait for a pause
        guard !Task.isCancelled else { return }
        let tab = tab, limit = tab == .all ? 12 : 60
        // "hindi movies 2024": the year narrows the results, and "movies" is not part of the title.
        func search(_ text: String) async -> GlobalSearchResults {
            let parsed = SmartQueryParser.parse(text)
            var found = (try? await c.globalSearch.search(parsed.text.isEmpty ? text : parsed.text, tab: tab, limit: limit * (parsed.year == nil ? 1 : 3))) ?? GlobalSearchResults()
            if let y = parsed.year { found = found.keeping { $0.title.contains(String(y)) || $0.subtitle.contains(String(y)) } }
            return found
        }
        var found = await search(q)
        var fixed: String?
        if found.isEmpty, let alt = await Task.detached(operation: { c.spelling.correct(q) }).value {
            let again = await search(alt)
            if !again.isEmpty { found = again; fixed = alt }
        }
        if !Task.isCancelled { results = found; correctedTo = fixed; searching = false }
    }

    private func activate(_ r: SearchResult) {
        guard let c = container else { return }
        switch r.destination {
        case .playChannel(let id):
            if let ch = try? c.catalog.channel(id: id) { Play.channel(ch, queue: [ch], c) }
        case .movie(let id):
            if let m = try? c.catalog.movie(id: id) { opened = .movie(m) }
        case .series(let id):
            if let s = try? c.catalog.seriesItem(id: id) { opened = .series(s) }
        case .episode(let id, let seriesID):
            if let e = try? c.catalog.episode(id: id), let s = try? c.catalog.seriesItem(id: seriesID) { Play.episode(e, s, c) }
        case .programme(let channelID):
            if let ch = try? c.catalog.channel(id: channelID) { Play.channel(ch, queue: [ch], c) }
        default: break
        }
    }
}


/// A movie or series found by search, as a poster tile.
struct SearchPosterTile: View {
    let result: SearchResult
    var width: CGFloat = 108
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(url: result.artworkURL, kind: .poster, contentMode: .fill, symbol: result.kind.symbol)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
            Text(result.title).appFont(12, .semibold).lineLimit(2).multilineTextAlignment(.leading).frame(width: width, alignment: .leading)
            if !result.subtitle.isEmpty { Text(result.subtitle).appFont(11).foregroundStyle(.secondary).lineLimit(1).frame(width: width, alignment: .leading) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A channel found by search, as a small tile with its logo.
struct SearchChannelTile: View {
    let result: SearchResult
    var body: some View {
        VStack(spacing: 6) {
            ChannelLogo(url: result.artworkURL, name: result.title, size: 56)
            Text(result.title).appFont(11, .medium).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
