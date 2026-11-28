import SwiftUI

// Listen Now's connected shelves: "Films with soundtracks you saved", "Because you played X: more albums by its composer", "Music directors you play",
// "Singers you play", "Actors in songs you like". The feed model builds them (`MusicHomeFeedModel.loadGraph`); this view only draws them, in the same
// shelf frame as every other Listen Now shelf, and refreshes the pictures in place when the graph learns more.

struct MusicConnectedHomeBlock: View {
    let hub: MusicHub
    let model: MusicHomeFeedModel
    @State private var rt = MusicFillRuntime.shared
    @Environment(\.musicLayoutClass) private var layoutClass

    /// A block this long would run on for a screen and a half: at most this many shelves.
    static let limit = 5

    /// Films first, then the composer's other albums, then the people (the order the page reads best in); shelves the graph adds later come last.
    static func rank(_ id: String) -> Int {
        switch id {
        case "fill.personal.films": 0
        case "fill.related.byComposer": 1
        case "fill.personal.musicDirectors": 2
        case "fill.personal.singers": 3
        case "fill.personal.actors": 4
        default: 9
        }
    }

    /// The shelves to draw: at least three tiles each, in reading order, and a shelf whose tiles mostly repeat an earlier one is dropped.
    static func shown(_ shelves: [MusicFillShelf]) -> [MusicFillShelf] {
        let sorted = shelves.enumerated().sorted { a, b in
            let ra = rank(a.element.id), rb = rank(b.element.id)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        var seen = Set<String>(), out: [MusicFillShelf] = []
        for s in sorted where s.tiles.count >= HomeEngine.minItems {
            let names = s.tiles.map { MusicText.normalize($0.title) }
            if Double(names.filter(seen.contains).count) / Double(names.count) >= 0.6 { continue }
            seen.formUnion(names)
            out.append(s)
            if out.count == limit { break }
        }
        return out
    }

    /// A person the listener hid (from a person page or a song's menu) is not offered again as a singer, composer or actor tile; a hidden artist with no source id is matched by name.
    nonisolated static func withoutHidden(_ shelves: [MusicFillShelf], hidden: MusicHiddenSet) -> [MusicFillShelf] {
        guard !hidden.artists.isEmpty || !hidden.names.isEmpty else { return shelves }
        let people: Set<MusicFillTileKind> = [.musicDirector, .singer, .lyricist, .actor, .person]
        return shelves.map { shelf in
            var s = shelf
            s.tiles = shelf.tiles.filter { !(people.contains($0.kind) && (hidden.names.contains(MusicText.normalize($0.title)) || hidden.artists.contains(MusicText.normalize($0.title)))) }
            return s
        }
    }

    var body: some View {
        let shelves = Self.shown(Self.withoutHidden(model.graph, hidden: MusicHiddenRecommendations.shared.set))
        let spec = MusicHomeLayout.spec(for: layoutClass)
        VStack(alignment: .leading, spacing: spec.sectionGap) {
            ForEach(shelves) { shelf in
                MusicShelf(title: shelf.title) {
                    ForEach(Array(shelf.tiles.prefix(16)), id: \.id) { MusicFillTileCard(tile: $0, hub: hub, width: spec.tileWidth) }
                }
                .cardWidth(spec.tileWidth).detail(shelf.reason)
                .accessibilityElement(children: .contain)
            }
            if shelves.isEmpty, model.graphPhase == .loading { MusicHomeShelfSkeleton() }
        }
        .task(id: "\(rt.revision)|\(model.composing)") {   // runs again when a compose that was in the way ends
            // Pictures and names arrived in the graph: rebuild its shelves in place (the first build is made with the feed).
            // Not while the feed itself is being composed (its own build for the new seed would race this one); the task id makes it run again when that ends.
            guard rt.revision > 0, !model.composing, let seed = model.feed?.seed else { return }
            await model.loadGraph(hub: hub, seed: seed, force: false)
        }
    }
}
