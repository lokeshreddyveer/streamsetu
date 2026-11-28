import Foundation

// Turning what the screens already hold (songs, albums, artists, playlists, search results, graph entities) into the question the artwork resolver is asked.
// A provisional graph id is built from the provider uid with no database read, so the resolver can find the graph row when there is one.

extension MusicArtworkSubject {
    static func derive(_ t: MusicTrack) -> MusicArtworkSubject {
        var s = MusicArtworkSubject(kind: .recording, name: t.title, id: .provisional(kind: .recording, providerUID: t.uid), creator: t.artistLine.isEmpty ? nil : t.artistLine,
                                    works: [t.album?.title].compactMap { $0 }.filter { !$0.isEmpty })
        s.providerID = t.providerID; s.providerItemID = t.id
        return s
    }

    static func derive(_ a: MusicAlbum) -> MusicArtworkSubject {
        var s = MusicArtworkSubject(kind: .album, name: a.title, id: .provisional(kind: .album, providerUID: a.uid), year: MusicGraphAdapters.year(a.releaseDate),
                                    creator: a.artists.isEmpty ? nil : a.artists.map(\.name).joined(separator: ", "))
        s.providerID = a.providerID; s.providerItemID = a.id
        return s
    }

    static func derive(_ a: MusicAlbumRef, providerID: String) -> MusicArtworkSubject {
        var s = MusicArtworkSubject(kind: .album, name: a.title, id: a.id.isEmpty ? nil : .provisional(kind: .album, providerUID: providerID + ":" + a.id), year: MusicGraphAdapters.year(a.releaseDate),
                                    creator: a.artists.isEmpty ? nil : a.artists.map(\.name).joined(separator: ", "))
        s.providerID = providerID; s.providerItemID = a.id
        return s
    }

    static func derive(_ a: MusicArtist) -> MusicArtworkSubject {
        var s = MusicArtworkSubject(kind: .person, name: a.name, id: .provisional(kind: .person, providerUID: a.uid))
        s.providerID = a.providerID; s.providerItemID = a.id
        return s
    }

    static func derive(_ p: MusicPlaylist) -> MusicArtworkSubject {
        MusicArtworkSubject(kind: .playlist, name: p.name, id: .provisional(kind: .playlist, providerUID: p.uid))
    }

    static func derive(_ e: MusicEntity) -> MusicArtworkSubject {
        switch e {
        case .track(let t): derive(t)
        case .album(let a): derive(a)
        case .artist(let a): derive(a)
        case .playlist(let p): derive(p)
        }
    }

    static func derive(_ r: MusicSearchResult) -> MusicArtworkSubject? {
        switch r {
        case .track(let t): derive(t)
        case .album(let a): derive(a)
        case .artist(let a): derive(a)
        case .playlist(let p): derive(p)
        case .user: nil
        }
    }

    /// A graph entity (a person, film, album, song, genre, language...) from its snapshot.
    static func derive(_ s: MusicEntitySnapshot) -> MusicArtworkSubject {
        MusicArtworkSubject(kind: s.kind, name: s.name, id: s.id, year: s.year)
    }

    /// A card that only knows a name and that it is round (a cast member, a singer): a person with no known jobs.
    static func personNamed(_ name: String, id: MusicEntityID? = nil) -> MusicArtworkSubject { .person(name, id: id) }

    /// A graph card or chip: the kind is the id's own when it has one, else `fallback`.
    static func card(_ fallback: MusicEntityKind, name: String, entity: MusicEntityID?, year: Int? = nil, creator: String? = nil) -> MusicArtworkSubject {
        MusicArtworkSubject(kind: entity?.kind ?? fallback, name: name, id: entity, year: year, creator: creator)
    }
}
