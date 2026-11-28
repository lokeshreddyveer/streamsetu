import SwiftUI

// A tile as a card, and a shelf of tiles. People are round, films are posters, albums and soundtracks are squares; every tile opens its typed page.
// The shelf says why it is there (its reason is the subtitle) and has no "Show all" unless the row overflows.

struct MusicFillTileCard: View {
    let tile: MusicFillTile
    let hub: MusicHub
    var width: CGFloat = MusicCardGeometry.defaultWidth

    var body: some View {
        switch tile.kind {
        case .film:
            MusicGraphFilmCard(title: tile.title, subtitle: tile.subtitle, imageRef: tile.imageRef, width: width, entity: tile.entity) { open() }
        case .musicDirector, .singer, .lyricist, .actor, .person:
            MusicGraphPersonCard(name: tile.title, caption: tile.subtitle, imageRef: tile.imageRef, width: width) { open() }
        default:
            // The tile's entity says what it is (an era, a language, a mood...): without it the card was taken for an album and sent to the album cover sources.
            MusicGraphAlbumCard(title: tile.title, subtitle: tile.subtitle, imageRef: tile.imageRef, width: width, entity: tile.entity) { open() }
        }
    }

    private func open() { MusicFillRuntime.shared.open(tile, hub: hub) }
}

/// One shelf of tiles. Shelf geometry (skeleton and cards) is the graph shelf's own, so a shelf that fills in late does not move the page.
struct MusicFillShelfView: View {
    let shelf: MusicFillShelf
    let hub: MusicHub
    var phase: MusicSectionPhase = .loaded
    var limit = 16

    var body: some View {
        let isFilm = shelf.tiles.first?.kind == .film
        MusicGraphShelf(title: shelf.title, subtitle: shelf.reason, phase: phase, itemCount: shelf.tiles.count,
                        posterAspect: isFilm ? MusicGraphCardMetrics.posterAspect : nil, textLines: 2) {
            ForEach(Array(shelf.tiles.prefix(limit)), id: \.id) { MusicFillTileCard(tile: $0, hub: hub) }
        }
        .accessibilityElement(children: .contain)
    }
}


/// The screens' shared loader: builds shelves off the main actor, keeps them in memory per key, asks the completeness pass for what is missing, and
/// refreshes tiles in place when it reports a change.
@MainActor @Observable
final class MusicFillModel {
    private(set) var shelves: [MusicFillShelf] = []
    private(set) var phase: MusicSectionPhase = .idle
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(key newKey: String, force: Bool = false, build: @escaping @Sendable (any MusicGraphStoring) async -> MusicFillResult) {
        if key == newKey, !force, phase == .loaded || phase == .loading { return }
        key = newKey
        task?.cancel()
        if shelves.isEmpty { phase = .loading }
        let rt = MusicFillRuntime.shared
        let store = rt.store
        task = Task { [weak self] in
            let r = await build(store)
            guard !Task.isCancelled, let self, self.key == newKey else { return }
            // In place: tiles that exist keep their position; only art and context arrive.
            self.shelves = Self.merge(old: self.shelves, new: r.shelves)
            self.phase = self.shelves.isEmpty ? .empty : .loaded
            rt.request(r.needsCompleteness)
        }
    }

    /// Same shelf ids keep their order; new shelves go last; tiles keep their order and take the new picture and line. A shelf that is now about something
    /// else (its title or reason changed, or a "because" shelf has other seeds) is replaced whole: its old tiles do not belong under the new words.
    static func merge(old: [MusicFillShelf], new: [MusicFillShelf]) -> [MusicFillShelf] {
        guard !old.isEmpty else { return new }
        let byID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [MusicFillShelf] = []
        for o in old {
            guard let n = byID[o.id] else { out.append(o); continue }
            if o.title != n.title || o.reason != n.reason || (o.scope == .related && o.seeds != n.seeds) { out.append(n); continue }
            let tiles = Dictionary(n.tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var merged = o.tiles.map { tiles[$0.id] ?? $0 }
            let have = Set(o.tiles.map(\.id))
            merged += n.tiles.filter { !have.contains($0.id) }
            var s = n; s.tiles = merged
            out.append(s)
        }
        let known = Set(old.map(\.id))
        out += new.filter { !known.contains($0.id) }
        return out
    }
}
