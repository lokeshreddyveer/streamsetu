import SwiftUI

/// Search the whole catalog from inside the player. A menu narrows it to All, Movies, Series or Live TV (All to start with).
/// A channel, movie or episode starts at once; a series starts with its first episode (a title with saved progress resumes where it was).
struct PlayerSearchSheet: View {
    var onChannel: (Channel) -> Void
    var onMovie: (Movie) -> Void
    var onEpisode: (Episode, Series) -> Void
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var tab: SearchTab = .all
    @State private var results = GlobalSearchResults()
    @State private var searching = false
    @FocusState private var focused: Bool

    private static let choices: [SearchTab] = [.all, .movies, .series, .liveTV]

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type a title, a channel or something like “hindi movies 2024”.").foregroundStyle(.secondary).listRowBackground(Color.clear)
            } else if found.isEmpty {
                Text(searching ? "Searching…" : "No results. Try fewer letters or another spelling.").foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            ForEach(found) { r in
                Button { activate(r) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: r.kind.symbol).frame(width: 22).foregroundStyle(ColorTokens.accentDefault)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).lineLimit(1)
                            if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        // The search box and the menu stay pinned at the top. The keyboard covers the bottom of the list instead of pushing everything up, so they never leave the screen, also in landscape.
        .safeAreaInset(edge: .top, spacing: 0) { header }
        #if os(iOS)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .scrollDismissesKeyboard(.immediately)      // scrolling the results pulls the keyboard away so there is room to see them
        .environment(\.defaultMinListRowHeight, 40)
        #endif
        .frame(minWidth: 380, minHeight: 420)
        .task { focused = true }
        .task(id: "\(query)|\(tab.rawValue)") { await run() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the catalog", text: $query).textFieldStyle(.plain).focused($focused).submitLabel(.search).onSubmit { focused = false }
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear") }
            Picker("Search in", selection: $tab) { ForEach(Self.choices) { Text($0 == .all ? "All" : $0.rawValue).tag($0) } }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            Button("Close") { dismiss() }
        }
        .padding(12).background(.regularMaterial)
    }

    /// Only movies, series, channels and episodes: they are what can be played from here.
    private var found: [SearchResult] {
        let kinds: [SearchResultKind] = [.channel, .movie, .series, .episode]
        return kinds.filter { tab.kinds.contains($0) || (tab == .all) }.flatMap { results.byKind[$0] ?? [] }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let c = container, !q.isEmpty else { results = GlobalSearchResults(); searching = false; return }
        searching = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let t = tab
        let parsed = SmartQueryParser.parse(q)
        var r = (try? await c.globalSearch.search(parsed.text.isEmpty ? q : parsed.text, tab: t, limit: t == .all ? 12 : 60)) ?? GlobalSearchResults()
        if let y = parsed.year { r = r.keeping { $0.title.contains(String(y)) || $0.subtitle.contains(String(y)) } }
        if !Task.isCancelled { results = r; searching = false }
    }

    private func activate(_ r: SearchResult) {
        guard let c = container else { return }
        switch r.destination {
        case .playChannel(let id), .programme(let id):
            if let ch = try? c.catalog.channel(id: id) { onChannel(ch); dismiss() }
        case .movie(let id):
            if let m = try? c.catalog.movie(id: id) { onMovie(m); dismiss() }
        case .episode(let id, let seriesID):
            if let e = try? c.catalog.episode(id: id), let s = try? c.catalog.seriesItem(id: seriesID) { onEpisode(e, s); dismiss() }
        case .series(let id):
            Task {
                guard let s = try? c.catalog.seriesItem(id: id), let d = try? await c.details.series(id: id) else { return }
                let progress = d.episodes.compactMap { e in (try? c.historyRepo.progress(for: e.id)).flatMap { $0 }.map { (e, $0) } }
                let resume = progress.filter { !$0.1.completed && $0.1.positionSeconds > 30 }.max { $0.1.updatedAt < $1.1.updatedAt }?.0
                let first = d.episodes.min { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
                if let e = resume ?? first { onEpisode(e, s); dismiss() }
            }
        default: break
        }
    }
}
