import Foundation

// The album page's shelves built locally from the graph: other editions, more by the artist, and "Appears on" (the playlists and compilations the
// album's songs are on). Related albums come from the recommender (`relatedSoundtracks`), which the album page already shows; these three add to it.

enum MusicAlbumConnections {
    static let limit = 14

    /// A local playlist the library holds: its id, name and the uids of its songs.
    struct LocalPlaylist: Hashable, Sendable { var id: String; var name: String; var songUIDs: Set<String> }

    static func build(album id: MusicEntityID, store: any MusicGraphStoring, songUIDs: [String: MusicEntityID] = [:], localPlaylists: [LocalPlaylist] = [],
                      wording: MusicFillWording = .english) async -> MusicFillResult {
        let r = MusicFillResolver(store: store, wording: wording)
        let live = (try? await store.resolve(id)) ?? id
        guard let snap = try? await store.entity(live) else { return .empty }
        var shelves: [MusicFillShelf] = [], needs: [MusicEntityID] = []
        let set = await MusicLinkMatrix.read(live, store: store)

        // Other editions: albums that are editions of the same album (release group), plus albums of the same film in other languages (dubs).
        var editions: [MusicEntityID] = []
        let out = (try? await store.edges(of: live, predicate: .editionOf, direction: .outgoing, limit: 8)) ?? []
        // The album concept a release is an edition of is the album itself, not another edition of it.
        let concepts = Set(out.map(\.object))
        for g in out {
            editions += ((try? await store.edges(of: g.object, predicate: .editionOf, direction: .incoming, limit: 40)) ?? []).map(\.subject)
        }
        editions += ((try? await store.edges(of: live, predicate: .editionOf, direction: .incoming, limit: 40)) ?? []).map(\.subject)
        // Soundtrack releases MusicBrainz links as translated versions of this one (or that this one translates), each worded as what the link says.
        var versionLine: [MusicEntityID: String] = [:]
        for e in ((try? await store.edges(of: live, predicate: .relatedAlbum, direction: .both, limit: 40)) ?? []) where !e.tombstone {
            guard let k = e.attributes.versionKind, k == .translatedSoundtrack || k == .dub else { continue }
            let other = e.subject == live ? e.object : e.subject
            let isTranslation = e.subject == other
            versionLine[other] = k == .dub ? (isTranslation ? "Dubbed soundtrack" : "Original soundtrack") : (isTranslation ? "Translated soundtrack" : "Original-language soundtrack")
            editions.append(other)
        }
        // The same film's soundtrack albums count as editions only when they are in ANOTHER language (a dub); the film's score album or a sequel's soundtrack is a different
        // album, found under "Related soundtracks".
        for f in set.links(.film).prefix(2) {
            for other in ((try? await store.edges(of: f.target, predicate: .soundtrackOf, direction: .incoming, limit: 20)) ?? []).map(\.subject) where other != live {
                if let o = try? await store.entity(other), let l = o.lang, !l.isEmpty, l != snap.lang { editions.append(other) }
            }
        }
        func tiles(_ ids: [MusicEntityID], exclude: Set<MusicEntityID>, caption: ((MusicEntitySnapshot) -> String)? = nil) async -> [MusicFillTile] {
            var seen = exclude, out: [MusicFillTile] = []
            let hidden = Set(MusicAlbumPrefs.load().hidden)   // an edition the person hid is not offered here either
            for e in ids where !hidden.contains(e.rawValue) && seen.insert(e).inserted {
                guard let (t, n) = await r.tile(e, kind: .album) else { continue }
                var tile = t
                if let c = caption, let s = try? await store.entity(t.entity) { tile.subtitle = c(s) }
                out.append(tile); if n { needs.append(t.entity) }
                if out.count == limit { break }
            }
            return out
        }
        let ed = await tiles(editions, exclude: concepts.union([live])) { s in MusicFillLine.join([versionLine[s.id].map { wording.s($0) }, MusicFillLanguage.name(s.lang), s.year.map(String.init), s.subkind.flatMap { $0 == "album" ? nil : $0.capitalized }]) }
        if !ed.isEmpty { shelves.append(MusicFillShelf(id: "album.editions", title: wording.s("Other editions"), reason: wording.s("The same album in other releases and languages"), scope: .related, tiles: ed)) }

        // More by the artist: albums of the album's artists and music directors that are not this album or an edition.
        // Every edition (not only the ones the shelf above had room for) and the parent album are this album: none of them is "more by the artist" or somewhere it "appears on".
        let editionIDs = Set(editions).union(concepts).union([live])
        var more: [MusicEntityID] = []
        var madeBy: [(name: String, albums: Set<MusicEntityID>)] = []
        for p in (set.links(.musicDirector) + set.links(.artist).filter { !$0.derived }).prefix(3) {
            let theirs = (await MusicLinkMatrix.read(p.target, store: store)).links(.album).filter { !$0.derived }.map(\.target)
            more += theirs
            madeBy.append((p.name, Set(theirs)))
        }
        let mt = await tiles(more, exclude: editionIDs)
        // The shelf is named after one person only when every album on it is theirs; albums of several people get the plain title.
        let shown = Set(mt.map(\.entity))
        let contributors = madeBy.filter { !$0.albums.isDisjoint(with: shown) }
        let artistName = contributors.count == 1 && shown.isSubset(of: contributors[0].albums) ? contributors[0].name : nil
        if !mt.isEmpty { shelves.append(MusicFillShelf(id: "album.moreByArtist", title: artistName.map { wording.f("More by %@", $0) } ?? wording.s("More by the artist"),
                                                       reason: wording.s("Other albums credited to the same people"), scope: .related, tiles: mt)) }

        // Appears on: compilations and other albums the songs are on, and playlists (graph and local) that hold them.
        let tracks = (try? await store.edges(of: live, predicate: .trackOn, direction: .incoming, limit: 80)) ?? []
        var onAlbums: [MusicEntityID: Int] = [:], onPlaylists: [MusicEntityID: Int] = [:]
        for t in tracks.prefix(40) {
            for e in (try? await store.edges(of: t.subject, predicate: nil, direction: .both, limit: 60)) ?? [] where !e.tombstone {
                if e.predicate == .trackOn, e.subject == t.subject, e.object != live, !editionIDs.contains(e.object) { onAlbums[e.object, default: 0] += 1 }
                if e.predicate == .playlistContains, e.object == t.subject { onPlaylists[e.subject, default: 0] += 1 }
            }
        }
        let rankedAlbums = onAlbums.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let at = await tiles(rankedAlbums, exclude: editionIDs) { s in MusicFillLine.join([s.subkind == "compilation" ? wording.s("Compilation") : wording.s("Album"), s.year.map(String.init)]) }
        var pt: [MusicFillTile] = []
        for (pid, _) in onPlaylists.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(limit) {
            if let (t, _) = await r.tile(pid, kind: .playlist) { pt.append(t) }
        }
        // The playlists of this Mac that hold songs of the album: tiles that open the playlist itself (the graph has no page for them).
        let local = localPlaylists.filter { !$0.songUIDs.isDisjoint(with: Set(songUIDs.keys)) }
        let localTiles = local.prefix(limit).map {
            MusicFillTile(entity: .provisional(kind: .playlist, providerUID: "local:" + $0.id), kind: .playlist, title: $0.name, subtitle: wording.s("Your playlist"),
                          imageRef: nil, role: nil, year: nil, localPlaylistID: $0.id)
        }
        let appears = at + pt + localTiles
        if !appears.isEmpty {
            shelves.append(MusicFillShelf(id: "album.appearsOn", title: wording.s("Appears on"),
                                          reason: wording.s("Compilations and playlists that include songs from this album"), scope: .related, tiles: appears))
        }
        _ = snap
        // More by the artist first, what the songs appear on next, and the other editions of this very album last: they are the same cover again.
        func rank(_ id: String) -> Int { id == "album.moreByArtist" ? 0 : (id.contains("appears") ? 1 : 2) }
        shelves.sort { rank($0.id) < rank($1.id) }
        return MusicFillResult(shelves: shelves.filter { !$0.tiles.isEmpty }, needsCompleteness: Array(Set(needs)).sorted())
    }
}
