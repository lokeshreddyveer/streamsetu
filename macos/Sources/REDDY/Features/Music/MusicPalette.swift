import SwiftUI

/// What choosing a Music result from the app-wide search does: songs play, albums and artists open their page.
@MainActor
enum MusicSearchOpener {
    static func open(_ t: MusicSearchTarget, hub: MusicHub = .shared) {
        switch t {
        case .track(let track): hub.play([track], at: 0)
        case .album(let a): hub.open(.album(a))
        case .artist(let a): hub.open(.artist(a), nameSearch: hub.searchModel.query)
        }
    }
}

/// The pure rules of the palette, so they can be tested without a screen.
enum MusicPaletteRules {
    static let debounce = Duration.milliseconds(300)
    static let minimumCharacters = 2

    static func trimmed(_ q: String) -> String { q.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Search starts at two characters; below that the palette says "type to search" and shows no rows.
    static func shouldSearch(_ q: String) -> Bool { trimmed(q).count >= minimumCharacters }
    /// A reply is shown only if it belongs to the text now in the box.
    static func isCurrent(reply: String, now: String) -> Bool { trimmed(reply) == trimmed(now) }
    /// Moves the highlight and wraps round at both ends. Starts at none, so Return submits the search.
    static func move(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let c = current else { return delta > 0 ? 0 : count - 1 }
        return ((c + delta) % count + count) % count
    }
}

/// Cmd+K inside Music: a quick search of the active source. Results come pre-ranked by the source and are not filtered again, so a result whose title lacks the
/// query text is not hidden. Enter on a song plays it, on anything else opens its page; Enter on "Search for ..." runs the full search page.
@MainActor
struct MusicPalette: View {
    let hub: MusicHub
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var results: [MusicSearchResult] = []
    @State private var loading = false
    @State private var shown = ""
    @State private var highlight: Int?
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent

    private enum Row: Identifiable {
        case result(MusicSearchResult), completion(String, history: Bool)
        var id: String {
            switch self {
            case .result(let r): "r-" + Self.key(r)
            case .completion(let t, let h): "c-\(h)-" + t
            }
        }
        static func key(_ r: MusicSearchResult) -> String {
            switch r { case .track(let t): "t" + t.uid; case .artist(let a): "a" + a.uid; case .album(let a): "b" + a.uid; case .playlist(let p): "p" + p.uid; case .user(let u): "u" + u.id }
        }
    }

    private var rows: [Row] {
        var out = results.map(Row.result)
        let q = MusicPaletteRules.trimmed(query)
        guard MusicPaletteRules.shouldSearch(q), !loading else { return out }
        let past = hub.searchModel.recents.items.filter { $0.localizedCaseInsensitiveContains(q) && $0.caseInsensitiveCompare(q) != .orderedSame }.prefix(3)
        out += past.map { Row.completion($0, history: true) }
        out.append(.completion(q, history: false))
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ColorTokens.textSecondary)
                TextField("Search songs, albums and artists", text: $query)
                    .textFieldStyle(.plain).font(Typography.body).focused($focused)
                    .onSubmit { activate(highlight.flatMap { rows.indices.contains($0) ? rows[$0] : nil }) }
                    .accessibilityLabel("Search Music")
            }.padding(12)
            Divider()
            ScrollView { list }.frame(maxHeight: 380)
        }
        .frame(width: 520)
        .background(ColorTokens.background)
        .onAppear { focused = true }
        .onChange(of: query) { _, new in schedule(new) }
        .onDisappear { task?.cancel() }
        #if os(macOS)
        .onKeyPress(.downArrow) { highlight = MusicPaletteRules.move(highlight, by: 1, count: rows.count); return .handled }
        .onKeyPress(.upArrow) { highlight = MusicPaletteRules.move(highlight, by: -1, count: rows.count); return .handled }
        #endif
        .onExitCommand { isPresented = false }
    }

    @ViewBuilder private var list: some View {
        if !MusicPaletteRules.shouldSearch(query) {
            Text("Type to search").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(20)
        } else if loading {
            VStack(spacing: 8) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(ColorTokens.line).frame(height: 40).padding(.horizontal, 12) } }.padding(.vertical, 10)
                .accessibilityLabel("Searching")
        } else if results.isEmpty {
            VStack(spacing: 4) {
                Text("Nothing quick. Try a full search.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.top, 14)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in rowView(r, index: i) }
            }.padding(.bottom, 8)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Results").font(Typography.eyebrow).foregroundStyle(ColorTokens.textTertiary).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in rowView(r, index: i) }
            }.padding(.bottom, 8)
        }
    }

    private func rowView(_ r: Row, index: Int) -> some View {
        // Hover does not move the highlight, so a stray hover never changes what Return does.
        Button { activate(r) } label: {
            HStack(spacing: 10) {
                switch r {
                case .result(let res): resultLabel(res)
                case .completion(let t, let history):
                    Image(systemName: history ? "clock.arrow.circlepath" : "magnifyingglass").frame(width: 40).foregroundStyle(ColorTokens.textSecondary)
                    Text(history ? t : "Search for \"\(t)\"").font(Typography.row).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(highlight == index ? accent.opacity(0.18) : .clear)).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).atlas("control.music.musicMusicpaletterowviewButton")
    }

    @ViewBuilder private func resultLabel(_ r: MusicSearchResult) -> some View {
        let (title, meta, thumbs, round, explicit): (String, String, [MusicThumbnail], Bool, Bool) = {
            switch r {
            case .track(let t): (t.title, [t.artistLine, t.album?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), t.thumbnails, false, t.explicit)
            case .album(let a): (a.title, "Album · " + MusicHeroText.cardCredit(a.artists), a.thumbnails, false, false)
            case .artist(let a): (a.name, "Artist", a.thumbnails, true, false)
            case .playlist(let p): (p.name, "Playlist" + (p.trackCount.flatMap { $0 > 0 ? " · " + Localized.plural($0, one: "%@ song", other: "%@ songs") : nil } ?? ""), p.thumbnails, false, false)
            case .user(let u): (u.displayName ?? u.username, "Profile", u.thumbnails, true, false)
            }
        }()
        MusicArtwork(thumbs, size: 40, corner: round ? 20 : 6, subject: MusicArtworkSubject.derive(r))
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title).font(Typography.rowMedium).lineLimit(1)
                if explicit { Text("E").font(.system(size: 9, weight: .bold)).padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 2).fill(ColorTokens.line)).accessibilityLabel("Explicit") }
            }
            Text(meta).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
        }
        Spacer(minLength: 0)
    }

    // MARK: behaviour

    /// Loading shows at once (skeleton rows), the search itself waits 300 ms after the last key, and a stale reply is dropped.
    private func schedule(_ text: String) {
        task?.cancel()
        highlight = nil
        guard MusicPaletteRules.shouldSearch(text) else { results = []; loading = false; shown = ""; return }
        loading = true
        task = Task {
            try? await Task.sleep(for: MusicPaletteRules.debounce)
            if Task.isCancelled { return }
            let q = MusicPaletteRules.trimmed(text)
            let found: [MusicSearchResult]
            if let p = hub.registry.activeMetadata { found = (try? await p.search(q, types: [.track, .artist, .album, .playlist])) ?? [] } else { found = [] }
            guard !Task.isCancelled, MusicPaletteRules.isCurrent(reply: q, now: query) else { return }
            results = found; shown = q; loading = false
        }
    }

    private func activate(_ row: Row?) {
        let q = MusicPaletteRules.trimmed(query)
        guard let row else {
            if MusicPaletteRules.shouldSearch(q) { runFullSearch(q) }
            return
        }
        switch row {
        case .completion(let t, _): runFullSearch(t)
        case .result(let r):
            switch r {
            case .track(let t): hub.play([t], at: 0)
            case .album(let a): hub.open(.album(a))
            case .artist(let a): hub.open(.artist(a))
            case .playlist(let p): hub.open(.playlist(p))
            case .user(let u): hub.open(.user(u))
            }
            close()
        }
    }

    private func runFullSearch(_ q: String) {
        hub.nav.select(.search)
        hub.searchModel.query = q
        hub.searchModel.submit()
        close()
    }

    private func close() { query = ""; results = []; isPresented = false }
}
