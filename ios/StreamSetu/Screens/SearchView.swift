import SwiftUI

/// One search over everything in the library: channels, movies, series and episodes.
struct SearchView: View {
    var embedded = false
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @State private var results = GlobalSearchResults()
    @State private var searching = false
    @State private var opened: LibraryItem?
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var router = router
        OptionalStack(embedded: embedded) {
            List {
                if router.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "Search your library", message: "Channels, movies, series and episodes from every playlist.")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if results.isEmpty, !searching {
                    EmptyState(symbol: "questionmark.circle", title: "No results", message: "Try fewer letters or another spelling.")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
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
            .navigationTitle("Search").themed("Search")
            .searchable(text: $router.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Channels, movies, series")
            .searchFocused($focused)
            .onAppear { if embedded { focused = true } }
            .navigationDestination(item: $opened) { DetailView(item: $0) }
            .miniPlayerInset()
        }
        .task(id: router.query) { await run() }
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
        guard let c = container, !q.isEmpty else { results = GlobalSearchResults(); return }
        searching = true
        try? await Task.sleep(nanoseconds: 200_000_000)                 // type-ahead: wait for a pause
        guard !Task.isCancelled else { return }
        let found = (try? await c.globalSearch.search(q, tab: .all, limit: 12)) ?? GlobalSearchResults()
        if !Task.isCancelled { results = found; searching = false }
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
