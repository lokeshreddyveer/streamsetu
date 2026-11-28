import SwiftUI

// Search, entity-typed: a Best match card, type filter chips, a "Did you mean" line, and the people, films, soundtracks and albums of the graph, with the
// full works of a person or film under the best match. It sits above the provider results of the existing search page and shows nothing when the graph and
// the starter roster have nothing for the query.

@MainActor @Observable
final class MusicSearchEntityModel {
    private(set) var result: MusicSearchEntityResult?
    var filter: MusicSearchEntityFilter = .all
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var query = ""

    func update(_ q: String, library: [String]) {
        guard q != query else { return }
        query = q
        task?.cancel()
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { result = nil; return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let r = await MusicSearchEntities.search(q, store: MusicFillRuntime.shared.store, extraNames: library, wording: MusicFillRuntime.shared.wording)
            guard !Task.isCancelled, let self, self.query == q else { return }
            self.result = r
            if !r.availableFilters.contains(self.filter) { self.filter = .all }
            MusicFillRuntime.shared.request(([r.best?.entity].compactMap { $0 }) + r.rows(.all).prefix(8).map(\.entity))
        }
    }
    func cancel() { task?.cancel() }
}

/// What the graph adds to a search that the sources' own results do not show: people (music directors, actors, lyricists) and films, and the works of
/// a best match that is not already in those results. Everything the sources return (songs, albums, soundtracks, playlists, artists) is shown ONCE, in
/// the page's own groups under the same type chips; this section no longer has chips, groups or a "Did you mean" of its own.
struct MusicSearchEntitySection: View {
    let hub: MusicHub
    let query: String
    /// The names the sources' results already hold, folded: a graph row with one of these names would be the same thing twice.
    var providerNames: Set<String> = []
    @State private var model = MusicSearchEntityModel()

    var body: some View {
        // A task on an empty view never runs, so a zero-height line always exists to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if let r = model.result, !r.isEmpty { content(r) }
        }
        .task(id: query) { model.update(query, library: hub.library.liked.prefix(300).map(\.title)) }
        .onDisappear { model.cancel() }
    }

    private func isNew(_ row: MusicSearchEntityRow) -> Bool { !providerNames.contains(MusicText.normalize(row.title)) }

    @ViewBuilder private func content(_ r: MusicSearchEntityResult) -> some View {
        let best = r.best.flatMap { isNew($0) ? $0 : nil }
        let groups = r.groups.filter { [.people, .films].contains($0.filter) }.map { (filter: $0.filter, rows: $0.rows.filter(isNew)) }.filter { !$0.rows.isEmpty }
        if best != nil || !groups.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.lg) {
                if let best { bestMatch(best, works: r.works) }
                ForEach(groups, id: \.filter) { g in shelf(g.filter, g.rows) }
                if best != nil, let w = r.works { works(w) }
            }
        }
    }

    static func title(_ f: MusicSearchEntityFilter) -> String {
        switch f {
        case .all: Localized.string("All")
        case .songs: Localized.string("Songs")
        case .albums: Localized.string("Albums")
        case .soundtracks: Localized.string("Soundtracks")
        case .films: Localized.string("Films")
        case .people: Localized.string("People")
        case .musicDirectors: Localized.string("Music directors")
        case .singers: Localized.string("Singers")
        case .lyricists: Localized.string("Lyricists")
        case .actors: Localized.string("Actors")
        case .playlists: Localized.string("Playlists")
        }
    }

    private func tile(_ row: MusicSearchEntityRow) -> MusicFillTile {
        MusicFillTile(entity: row.entity, kind: row.tileKind, title: row.title, subtitle: row.subtitle, imageRef: row.imageRef, role: row.role, year: nil)
    }

    private func bestMatch(_ row: MusicSearchEntityRow, works: MusicLinkSet?) -> some View {
        HStack(alignment: .center, spacing: MusicSpace.lg) {
            MusicFillTileCard(tile: tile(row), hub: hub, width: MusicCardSize.large.width)
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(verbatim: Localized.string("Best match")).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                Text(verbatim: row.title).musicText(.section).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                Text(verbatim: row.subtitle).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                if let w = works {
                    Text(verbatim: summary(w)).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(2)
                    Button { MusicFillRuntime.shared.follow(.radio(seed: row.entity), hub: hub) } label: { Label(Localized.string("Start radio"), systemImage: "dot.radiowaves.left.and.right") }
                        .musicButton(.secondary, size: .compact).accessibilityLabel(Localized.string("Start a radio from %@", row.title)).atlas("control.music.searchBestMatchRadio")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func summary(_ w: MusicLinkSet) -> String {
        [(w.links(.film).count, "film", "films"), (w.links(.album).count, "album", "albums"), (w.links(.song).count, "song", "songs")].filter { $0.0 > 0 }
            .map { Localized.plural($0.0, one: "%@ " + $0.1, other: "%@ " + $0.2) }.joined(separator: " · ")
    }

    private func shelf(_ f: MusicSearchEntityFilter, _ rows: [MusicSearchEntityRow]) -> some View {
        MusicShelf(title: Self.title(f)) {
            ForEach(rows, id: \.id) { MusicFillTileCard(tile: tile($0), hub: hub) }
        }
    }

    /// The best match's works, from the link matrix: its films, albums and songs as shelves.
    @ViewBuilder private func works(_ w: MusicLinkSet) -> some View {
        let r = MusicFillResolver(store: MusicFillRuntime.shared.store, wording: MusicFillRuntime.shared.wording)
        ForEach([MusicConnectionKind.film, .soundtrack, .album, .song], id: \.self) { k in
            let ls = w.links(k).filter { k != .album || !w.links(.soundtrack).contains($0) }.prefix(16)
            if ls.count >= 2 {
                MusicShelf(title: Localized.string("%1$@: %2$@", w.sourceName, Self.kindTitle(k))) {
                    ForEach(Array(ls), id: \.id) { MusicFillTileCard(tile: r.tile($0), hub: hub) }
                }
            }
        }
    }

    static func kindTitle(_ k: MusicConnectionKind) -> String {
        switch k { case .film: Localized.string("Films"); case .soundtrack: Localized.string("Soundtracks"); case .album: Localized.string("Albums"); default: Localized.string("Songs") }
    }
}
