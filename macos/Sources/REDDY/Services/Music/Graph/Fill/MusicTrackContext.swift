import Foundation

// The context line of a song row: who made it, which film it is from, who sings, who acts, which album. Library, playlists, downloads, queue,
// now-playing and the sidebar all show it, so every row says more than a title and an artist. Reads are three bounded edge lookups per song and are
// cached; a song the graph does not know yet gets `.empty` and the row falls back to the provider's own credits and album (never blank).

struct MusicTrackContext: Hashable, Sendable {
    var song: MusicEntityID
    var musicDirector: MusicConnection?
    var singers: [MusicConnection] = []
    var lyricist: MusicConnection?
    var film: MusicConnection?
    var cast: [MusicConnection] = []
    var albums: [MusicConnection] = []
    var isEmpty: Bool { musicDirector == nil && singers.isEmpty && lyricist == nil && film == nil && cast.isEmpty && albums.isEmpty }

    /// "Shankar-Jaikishan · Awaara (1951)". Parts that are not known are left out; nil when nothing is known.
    func line(fallbackArtists: String = "", fallbackAlbum: String? = nil) -> String {
        let filmCaption = film.map { MusicFillLine.filmCaption($0.name, year: $0.year) }
        let castLine = cast.prefix(2).map(\.name).joined(separator: ", ")
        let known = MusicFillLine.join([musicDirector?.name, filmCaption, castLine.isEmpty ? nil : castLine])
        if !known.isEmpty { return known }
        return MusicFillLine.join([fallbackArtists, fallbackAlbum])
    }
}

actor MusicTrackContextReader {
    private let store: any MusicGraphStoring
    private var cache: [MusicEntityID: MusicTrackContext] = [:]
    private var order: [MusicEntityID] = []
    private let capacity: Int
    init(store: any MusicGraphStoring, capacity: Int = 2_000) { self.store = store; self.capacity = max(50, capacity) }

    func context(for song: MusicEntityID) async -> MusicTrackContext {
        if let c = cache[song] { return c }
        let live = (try? await store.resolve(song)) ?? song
        var ctx = MusicTrackContext(song: live)
        let edges = (try? await store.edges(of: live, predicate: nil, direction: .outgoing, limit: 60)) ?? []
        func link(_ k: MusicConnectionKind, _ id: MusicEntityID, role: MusicRole?) async -> MusicConnection? {
            guard let s = try? await store.entity(id), s.state == .live, !MusicLinkMatrix.isVariousArtists(s.name) else { return nil }
            return MusicConnection(kind: k, target: s.id, name: s.name, role: role, imageRef: s.imageRef, year: s.year, count: 1, derived: false)
        }
        for e in edges where !e.tombstone {
            switch e.predicate {
            case .composedBy, .musicDirectedBy:
                if ctx.musicDirector == nil { ctx.musicDirector = await link(.musicDirector, e.object, role: .musicDirector) }
            case .writtenBy:
                if ctx.lyricist == nil { ctx.lyricist = await link(.lyricist, e.object, role: .lyricist) }
            case .performedBy:
                if ctx.singers.count < 3, let l = await link(.singer, e.object, role: .singer) { ctx.singers.append(l) }
            case .featuredIn:
                if ctx.film == nil { ctx.film = await link(.film, e.object, role: nil) }
            case .trackOn:
                if ctx.albums.count < 3, let l = await link(.album, e.object, role: nil) { ctx.albums.append(l) }
            default: break
            }
        }
        // The film through the album's soundtrack edge when the song itself has none.
        if ctx.film == nil {
            for a in ctx.albums.prefix(2) {
                let fe = (try? await store.edges(of: a.target, predicate: .soundtrackOf, direction: .outgoing, limit: 1)) ?? []
                if let f = fe.first, let l = await link(.film, f.object, role: nil) { ctx.film = l; break }
            }
        }
        if let f = ctx.film {
            let cast = (try? await store.edges(of: f.target, predicate: .hasCast, direction: .outgoing, limit: 8)) ?? []
            for e in cast.sorted(by: { ($0.order ?? 99) < ($1.order ?? 99) }).prefix(3) {
                if let l = await link(.actor, e.object, role: .actor) { ctx.cast.append(l) }
            }
            if ctx.musicDirector == nil {
                let fe = (try? await store.edges(of: f.target, predicate: .musicDirectedBy, direction: .outgoing, limit: 2)) ?? []
                if let m = fe.first { ctx.musicDirector = await link(.musicDirector, m.object, role: .musicDirector) }
            }
        }
        remember(live, ctx)
        if live != song { cache[song] = ctx }
        return ctx
    }

    /// Several songs at once, in order (each is one cached read).
    func contexts(for songs: [MusicEntityID]) async -> [MusicEntityID: MusicTrackContext] {
        var out: [MusicEntityID: MusicTrackContext] = [:]
        for s in songs { out[s] = await context(for: s) }
        return out
    }

    func invalidate(_ ids: Set<MusicEntityID>) { for i in ids { cache[i] = nil }; order.removeAll { ids.contains($0) } }
    func clear() { cache.removeAll(); order.removeAll() }

    private func remember(_ id: MusicEntityID, _ c: MusicTrackContext) {
        if cache.count >= capacity, let first = order.first { cache[first] = nil; order.removeFirst() }
        cache[id] = c; order.append(id)
    }
}
