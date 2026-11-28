import Foundation

// Home's connected shelves (G9). Each shelf says why it is there:
//   personal  - "Music directors you play", "Singers you play", "Actors in songs you like", "Films with soundtracks you saved",
//               "Because you played <song>: more albums by <composer>"        (from the device-local affinity; absent with no history)
//   starter   - the language's music directors, singers and soundtracks, the era's films    (a starting list; always present)
// India stays India: the languages and eras come from the person's own plays first and India's film languages after, whatever the chart country is.
// Choice is seeded by the feed's seed (see `MusicHomeFeedModel`): a visit within five minutes gives the same shelves; Refresh draws a new seed.

struct MusicConnectedHomeInput: Sendable {
    var affinity: MusicAffinityVector
    /// The chart country (`IN`); only used to word the reasons, never to swap India's shelves for a worldwide list.
    var region: String
    /// The language the Home chip chose, as a graph language key (`hi`), or nil for all.
    var language: String?
    /// Languages of the person's own plays, strongest first (graph language keys or names).
    var preferredLanguages: [String]
    var seed: UInt64
    /// Songs the person played last, newest first, as graph ids (for the "Because you played" shelf).
    var recentSongs: [MusicEntityID] = []
    /// Songs the "Because you played" shelf showed in the last few visits: they are tried last, so the shelf does not name the same song every time.
    var avoidSongs: Set<MusicEntityID> = []
    /// Songs the person marked Never Play or whose artist they hid: never the song "Because you played" is built around, however much it was played (unlike `avoidSongs`,
    /// which only moves a song to the end of the list).
    var excludeSongs: Set<MusicEntityID> = []
}

enum MusicConnectedHome {
    /// A shelf shorter than this is not shown (a shelf of two cards is not a shelf); the starter shelves are always longer.
    static let minimumTiles = 3
    static let shelfLimit = 14

    /// `count` of the strongest keys, drawn with a chance in proportion to their weight and the page's seed: favourites come up most, but the same page seed gives the same
    /// shelf and a new visit or Refresh gives a different mix.
    static func varied(_ top: [(id: MusicEntityID, weight: Double)], seed: UInt64, name: String, count: Int) -> [(id: MusicEntityID, weight: Double)] {
        var rng = HomeRandom.child(of: seed, name)
        return HomeRandom.sample(top, count: count, weight: { max(0.01, $0.weight) }, using: &rng)
    }

    static func build(_ input: MusicConnectedHomeInput, store: any MusicGraphStoring, wording: MusicFillWording = .english) async -> MusicFillResult {
        let r = MusicFillResolver(store: store, wording: wording)
        var shelves: [MusicFillShelf] = []
        var needs: [MusicEntityID] = []
        var used = Set<String>()

        func add(_ s: MusicFillShelf, needs n: [MusicEntityID]) {
            guard s.tiles.count >= minimumTiles, used.insert(s.id).inserted else { return }
            shelves.append(s); needs.append(contentsOf: n)
        }

        // personal shelves
        let a = input.affinity
        if !a.isEmpty {
            // Music directors you play
            var tiles: [MusicFillTile] = [], n: [MusicEntityID] = []
            for t in varied(a.top(.composer, count: shelfLimit * 3), seed: input.seed, name: "directors", count: shelfLimit) {
                if let (tile, miss) = await r.tile(t.id, kind: .musicDirector, role: .musicDirector) { tiles.append(tile); if miss { n.append(tile.entity) } }
            }
            add(MusicFillShelf(id: "fill.personal.musicDirectors", title: wording.s("Music directors you play"),
                               reason: wording.s("Because you played their songs"), scope: .personal, tiles: tiles, seeds: a.top(.composer, count: 4).map(\.id)), needs: n)

            // Singers you play
            tiles = []; n = []
            for t in varied(a.top(.singer, count: shelfLimit * 3), seed: input.seed, name: "singers", count: shelfLimit) {
                if let (tile, miss) = await r.tile(t.id, kind: .singer, role: .singer) { tiles.append(tile); if miss { n.append(tile.entity) } }
            }
            add(MusicFillShelf(id: "fill.personal.singers", title: wording.s("Singers you play"),
                               reason: wording.s("Because you played their songs"), scope: .personal, tiles: tiles, seeds: a.top(.singer, count: 4).map(\.id)), needs: n)

            // Actors in songs you like: the cast of the films whose songs you play
            let topFilms = a.top(.film, count: 8).map(\.id)
            var actors: [MusicEntityID: Int] = [:]
            var order: [MusicEntityID] = []
            for f in topFilms {
                let cast = (try? await store.edges(of: f, predicate: .hasCast, direction: .outgoing, limit: 12)) ?? []
                for e in cast.sorted(by: { ($0.order ?? 99) < ($1.order ?? 99) }).prefix(6) {
                    if actors[e.object] == nil { order.append(e.object) }
                    actors[e.object, default: 0] += 1
                }
            }
            tiles = []; n = []
            let ranked = order.sorted(by: { (actors[$0] ?? 0) != (actors[$1] ?? 0) ? (actors[$0] ?? 0) > (actors[$1] ?? 0) : $0 < $1 }).prefix(shelfLimit * 3)
            let weighted: [(id: MusicEntityID, weight: Double)] = ranked.map { (id: $0, weight: Double(actors[$0] ?? 1)) }
            for t in varied(weighted, seed: input.seed, name: "actors", count: shelfLimit) {
                if let (tile, miss) = await r.tile(t.id, kind: .actor, role: .actor) { tiles.append(tile); if miss { n.append(tile.entity) } }
            }
            add(MusicFillShelf(id: "fill.personal.actors", title: wording.s("Actors in songs you like"),
                               reason: wording.s("They star in films whose songs you play"), scope: .personal, tiles: tiles, seeds: topFilms), needs: n)

            // Films with soundtracks you saved
            tiles = []; n = []
            for t in varied(a.top(.savedFilm, count: shelfLimit * 3), seed: input.seed, name: "films", count: shelfLimit) {
                if let (tile, miss) = await r.tile(t.id, kind: .film) { tiles.append(tile); if miss { n.append(tile.entity) } }
            }
            add(MusicFillShelf(id: "fill.personal.films", title: wording.s("Films with soundtracks you saved"),
                               reason: wording.s("Because you liked or saved songs from them"), scope: .personal, tiles: tiles, seeds: topFilms), needs: n)

            // Films from songs the person played several times (not saved, and not a single play by autoplay or radio): a separate shelf that says so.
            tiles = []; n = []
            let savedFilms = Set(a.top(.savedFilm, count: 60).map(\.id))
            let repeated = a.top(.film, count: shelfLimit * 4).filter { $0.weight >= 0.9 && !savedFilms.contains($0.id) }
            for t in varied(repeated, seed: input.seed, name: "filmsPlayed", count: shelfLimit) {
                if let (tile, miss) = await r.tile(t.id, kind: .film) { tiles.append(tile); if miss { n.append(tile.entity) } }
            }
            add(MusicFillShelf(id: "fill.personal.filmsPlayed", title: wording.s("Films from songs you play"),
                               reason: wording.s("You have played songs from them several times"), scope: .personal, tiles: tiles, seeds: topFilms), needs: n)

            // Because you played X: other albums by its composer. The first played song with a composer and at least `minimumTiles` other albums.
            // The song is drawn from the strongest and the latest plays (stronger more likely), and any song shown lately is tried last.
            var candidates: [(id: MusicEntityID, weight: Double)] = a.top(.recording, count: 12)
            for (i, s) in input.recentSongs.prefix(8).enumerated() where !candidates.contains(where: { $0.id == s }) { candidates.append((id: s, weight: max(0.1, 1.0 - Double(i) * 0.1))) }
            let drawn = varied(candidates, seed: input.seed, name: "because", count: candidates.count).map(\.id).filter { !input.excludeSongs.contains($0) }
            let seeds = drawn.filter { !input.avoidSongs.contains($0) } + drawn.filter { input.avoidSongs.contains($0) }
            var tried = Set<MusicEntityID>()
            for song in seeds where tried.insert(song).inserted {
                guard let snap = try? await store.entity((try? await store.resolve(song)) ?? song) else { continue }
                let songLinks = await MusicLinkMatrix.read(snap.id, store: store)
                guard let composer = songLinks.links(.musicDirector).first else { continue }
                let own = Set(songLinks.links(.album).map(\.target))
                let works = await MusicLinkMatrix.read(composer.target, store: store)
                let albums = works.links(.album).filter { !own.contains($0.target) }.prefix(shelfLimit)
                let ts = albums.map { l -> MusicFillTile in
                    var t = r.tile(l, caption: nil); t.subtitle = MusicFillLine.join([wording.s("Album"), l.year.map(String.init)]); return t
                }
                let s = MusicFillShelf(id: "fill.related.byComposer", title: wording.f("Because you played %1$@: more albums by %2$@", snap.name, composer.name),
                                       reason: wording.f("%@ also made these", composer.name), scope: .related, tiles: Array(ts), seeds: [snap.id, composer.target])
                if s.tiles.count >= minimumTiles { add(s, needs: ts.filter { $0.imageRef == nil }.map(\.entity)); break }
            }
        }

        return MusicFillResult(shelves: shelves, needsCompleteness: Array(Set(needs)).sorted())
    }
}
