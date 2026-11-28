import Foundation

// Pure grouping for Downloads, the sidebar's Recent group and Radio's entity seeds. Plain values in, plain values out.

// MARK: Downloads grouped by film or album

/// One downloaded song, with what the graph and the provider know about it.
struct MusicDownloadRowInfo: Hashable, Sendable {
    var uid: String
    var title: String
    var artistLine: String
    var providerID: String
    var albumID: String?
    var albumTitle: String?
    var thumbURL: String?
    var context: MusicTrackContext?
}

struct MusicDownloadGroup: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case film, album, singles }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var thumbURL: String?
    /// The page the header opens: the film or the album, by id. Nil for singles.
    var entity: MusicEntityID?
    var rows: [MusicDownloadRowInfo]
}

enum MusicDownloadGrouping {
    /// Groups by film when the graph knows the film, else by album (provider album id), else "Singles". Order: groups with more songs first, then by
    /// title; songs keep their download order inside a group. A group of one song under a film or album still shows its header (real metadata).
    static func group(_ rows: [MusicDownloadRowInfo], singlesTitle: String = "Singles") -> [MusicDownloadGroup] {
        var order: [String] = []
        var map: [String: MusicDownloadGroup] = [:]
        for r in rows {
            let key: String, kind: MusicDownloadGroup.Kind, title: String, sub: String, entity: MusicEntityID?
            if let f = r.context?.film {
                key = "film|" + f.target.rawValue; kind = .film; title = MusicFillLine.filmCaption(f.name, year: f.year)
                sub = MusicFillLine.join([r.context?.musicDirector?.name]); entity = f.target
            } else if let id = r.albumID, !id.isEmpty, let t = r.albumTitle, !t.isEmpty {
                key = "album|" + r.providerID + ":" + id; kind = .album; title = t
                sub = MusicFillLine.join([r.context?.musicDirector?.name ?? firstArtist(r.artistLine)])
                entity = r.context?.albums.first?.target ?? .provisional(kind: .release, providerUID: r.providerID + ":" + id)
            } else {
                key = "singles"; kind = .singles; title = singlesTitle; sub = ""; entity = nil
            }
            if map[key] == nil {
                map[key] = MusicDownloadGroup(id: key, kind: kind, title: title, subtitle: sub, thumbURL: r.thumbURL, entity: entity, rows: [])
                order.append(key)
            }
            map[key]!.rows.append(r)
            if map[key]!.thumbURL == nil { map[key]!.thumbURL = r.thumbURL }
        }
        let firstIndex = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { map[$0] }.sorted { a, b in
            if (a.kind == .singles) != (b.kind == .singles) { return b.kind == .singles }
            if a.rows.count != b.rows.count { return a.rows.count > b.rows.count }
            return firstIndex[a.id]! < firstIndex[b.id]!
        }
    }

    private static func firstArtist(_ line: String) -> String? {
        let a = line.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return (a?.isEmpty ?? true) || MusicLinkMatrix.isVariousArtists(a ?? "") ? nil : a
    }
}

// MARK: Radio seeded from entities

/// What a radio started from an entity plays and why. The seed songs are graph ids; the app turns the first playable one into the queue's seed song.
struct MusicRadioPlan: Hashable, Sendable {
    var entity: MusicEntityID
    var title: String
    /// "Radio from Shankar-Jaikishan: songs they composed" - shown on the Now on radio card and under the station tile.
    var explanation: String
    var seedSongs: [MusicEntityID]
}

enum MusicRadioEntitySeeds {
    static let seedLimit = 12

    /// Songs for a radio from any entity, by what it is: a person's credited songs (an actor's through their films), a film's or soundtrack's songs, an
    /// album's or playlist's tracks, a song itself. Empty when the graph has no songs yet (the app then searches the name and the completeness pass runs).
    static func plan(for id: MusicEntityID, store: any MusicGraphStoring, wording: MusicFillWording = .english) async -> MusicRadioPlan? {
        let set = await MusicLinkMatrix.read(id, store: store)
        guard !set.sourceName.isEmpty else { return nil }
        var songs: [MusicEntityID] = set.links(.song).map(\.target)
        var how: String
        switch set.sourceKind {
        case .song: songs = [set.source]; how = wording.s("songs like this one")
        case .musicDirector, .artist, .singer, .lyricist: how = wording.s("songs they are credited on")
        case .actor: how = wording.s("songs from their films")
        case .film: how = wording.s("songs from this film")
        case .album, .soundtrack: how = wording.s("songs from this album")
        case .playlist: how = wording.s("songs in this playlist")
        case .radio: how = wording.s("songs like these")
        }
        if songs.isEmpty {
            // an actor, or anyone with films but no songs yet: the songs of up to three of their films
            for f in set.links(.film).prefix(3) {
                songs += (await MusicLinkMatrix.read(f.target, store: store)).links(.song).map(\.target)
                if songs.count >= seedLimit { break }
            }
            if !songs.isEmpty, set.sourceKind != .actor { how = wording.s("songs from their films") }
        }
        var seen = Set<MusicEntityID>()
        let unique = songs.filter { seen.insert($0).inserted }.prefix(seedLimit)
        return MusicRadioPlan(entity: set.source, title: set.sourceName, explanation: wording.f("Radio from %1$@: %2$@", set.sourceName, how), seedSongs: Array(unique))
    }
}
