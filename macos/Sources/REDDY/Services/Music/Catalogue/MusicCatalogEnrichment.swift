import Foundation

// Catalogue sources (JioSaavn, Apple, Spotify metadata, chart lists) are behind the scenes only. Nothing here ever produces a page, a row or a
// label of its own: each function takes what a PLAYABLE source showed and returns it improved (right spelling, year, label, cover, order,
// missing songs mapped to playable copies, duplicate names merged). With the catalogue silent every function returns its input unchanged.

// MARK: artists

enum MusicArtistCanon {
    private static let noise: Set<String> = ["official", "topic", "vevo", "music"]

    /// One key for every spelling of a name: "Sid Sriram", "Sid Sri Ram" and "Sid Sree Ram" share it. Spaces do not count.
    static func key(_ name: String) -> String {
        MusicText.normalize(MusicCandidateRules.latin(name)).split(separator: " ").map(String.init).filter { !noise.contains($0) }
            .map { MusicTransliterationKey.key(word: $0) }.joined()
    }

    /// Duplicate artist entities (the same person from two sources or spelled two ways) become one: the first keeps its identity, gets the widest
    /// pictures, any missing biography or genres, and the spelling `preferred` gives (the catalogue's) when it names the same person.
    static func merge(_ list: [MusicArtist], preferredNames: [String] = []) -> [MusicArtist] {
        var order: [String] = []
        var byKey: [String: MusicArtist] = [:]
        for a in list {
            let k = key(a.name)
            guard !k.isEmpty else { order.append("raw:" + a.uid); byKey["raw:" + a.uid] = a; continue }
            if var cur = byKey[k] {
                cur.thumbnails = (cur.thumbnails + a.thumbnails).sorted { $0.width > $1.width }
                if cur.bio == nil { cur.bio = a.bio }
                if cur.followers == nil { cur.followers = a.followers }
                cur.genres = Array(Set(cur.genres + a.genres)).sorted()
                byKey[k] = cur
            } else { order.append(k); byKey[k] = a }
        }
        return order.compactMap { k in
            guard var a = byKey[k] else { return nil }
            if let name = preferredNames.first(where: { key($0) == key(a.name) }) { a.name = name }
            return a
        }
    }
}

// MARK: albums and films

struct MusicAlbumEnrichment: Sendable {
    var album: MusicAlbum
    var tracks: [MusicTrack]
    /// Songs the playable list lacked and that were added from their playable twins.
    var added: Int
    var removedDuplicates: Int
}

enum MusicAlbumMerge {
    static func key(_ t: MusicTrack) -> String { MusicCatalogCanon.make(from: t).key }

    /// Combines the album a playable source showed with the catalogue's version of it.
    /// - The catalogue's title is used when it is the same name spelled differently; year, label and a better cover fill in.
    /// - Duplicate and bad uploads (the same song twice) collapse to the copy whose running time is closest to the catalogue's.
    /// - Songs follow the catalogue's order with its disc and track numbers; songs missing from the playable list are added in place from
    ///   `twins` (catalogue uid to playable track); songs the catalogue does not know stay after them in their old order.
    static func merge(album: MusicAlbum, tracks: [MusicTrack], catalogueAlbum: MusicAlbum, catalogueTracks: [MusicTrack], twins: [String: MusicTrack]) -> MusicAlbumEnrichment {
        var a = album
        if MusicTransliterationKey.sameKey(a.title, catalogueAlbum.title) || MusicText.normalize(a.title).isEmpty { a.title = catalogueAlbum.title }
        if a.releaseDate == nil || a.releaseDate?.isEmpty == true { a.releaseDate = catalogueAlbum.releaseDate }
        if a.label == nil { a.label = catalogueAlbum.label }
        if a.albumType == nil { a.albumType = catalogueAlbum.albumType }
        a.totalTracks = catalogueTracks.isEmpty ? a.totalTracks : catalogueTracks.count
        a.thumbnails = bestCover(a.thumbnails, catalogueAlbum.thumbnails)
        if a.artists.isEmpty { a.artists = catalogueAlbum.artists }

        let wanted = Dictionary(catalogueTracks.map { (key($0), $0) }, uniquingKeysWith: { f, _ in f })
        var kept: [String: MusicTrack] = [:]
        var removed = 0
        var leftover: [MusicTrack] = []
        for t in tracks {
            let k = key(t)
            if let have = kept[k] {
                removed += 1
                let target = wanted[k]?.durationMs ?? 0
                if target > 0, abs(t.durationMs - target) < abs(have.durationMs - target) { kept[k] = t }
            } else if wanted[k] != nil { kept[k] = t } else { kept[k] = t; leftover.append(t) }
        }
        var out: [MusicTrack] = []
        var added = 0
        var placed = Set<String>()
        var placedUIDs = Set<String>()
        let keptByUID = Dictionary(kept.values.map { ($0.uid, $0) }, uniquingKeysWith: { f, _ in f })
        for (i, c) in catalogueTracks.enumerated() {
            let k = key(c)
            guard placed.insert(k).inserted else { continue }
            var t: MusicTrack
            if let have = kept[k] { t = have }
            else if let twin = twins[c.uid] {
                // The catalogue may spell the song another way; its twin can be a song the list already has.
                if let existing = keptByUID[twin.uid] { t = existing } else if placedUIDs.contains(twin.uid) { continue } else { t = twin; added += 1 }
            } else { continue }
            guard placedUIDs.insert(t.uid).inserted else { continue }
            t.discNumber = c.discNumber ?? t.discNumber
            out.append(t)
        }
        for t in leftover where !placed.contains(key(t)) && !placedUIDs.contains(t.uid) { out.append(t) }
        // Track numbers count from 1 on each disc (a second disc does not carry on from the first); a song with no disc stays on the disc before it.
        var perDisc: [Int: Int] = [:], disc = 1
        out = out.map { t in
            var x = withAlbum(t, a)
            disc = t.discNumber ?? disc
            perDisc[disc, default: 0] += 1
            x.trackNumber = perDisc[disc]
            return x
        }
        // A playable song the catalogue did not list keeps its place after the listed ones.
        return MusicAlbumEnrichment(album: a, tracks: out, added: added, removedDuplicates: removed)
    }

    private static func withAlbum(_ t: MusicTrack, _ a: MusicAlbum) -> MusicTrack {
        var x = t
        // An album id means something only to its own source: the page's album id goes on a song of that source, never on another source's copy (it would send
        // "Go to album" to the wrong service). Such a song keeps no id; the page still lists it under this album.
        let ownID = x.album?.id.isEmpty == false ? x.album?.id : nil
        x.album = MusicAlbumRef(id: ownID ?? (x.providerID == a.providerID ? a.id : ""), title: a.title, artists: a.artists, thumbnails: a.thumbnails, releaseDate: a.releaseDate,
                                totalTracks: a.totalTracks, albumType: a.albumType, externalURL: x.album?.externalURL)
        return x
    }

    /// The widest picture wins; an unstated width loses to a stated one, and a video frame loses to anything else.
    static func bestCover(_ own: [MusicThumbnail], _ catalogue: [MusicThumbnail]) -> [MusicThumbnail] {
        func rank(_ t: MusicThumbnail) -> Int { MusicCatalogArtwork.isVideoFrame(t.url) ? -1 : t.width }
        let all = own + catalogue
        guard let best = all.max(by: { rank($0) < rank($1) }) else { return own }
        return rank(best) > (own.map(rank).max() ?? -2) ? [best] + own.filter { $0 != best } : own
    }
}

/// Films as the album entity: songs grouped under the film they came from, in the order they first appear.
enum MusicFilmGrouping {
    struct Group: Sendable { var film: String?; var tracks: [MusicTrack] }

    static func fromLine(_ film: String) -> String { "From " + film }

    static func group(_ tracks: [MusicTrack], film: (MusicTrack) -> String?) -> [Group] {
        var order: [String] = []
        var groups: [String: Group] = [:]
        for t in tracks {
            let name = film(t)
            let k = name.map { MusicTransliterationKey.key($0) } ?? ""
            if groups[k] == nil { order.append(k); groups[k] = Group(film: name, tracks: []) }
            groups[k]?.tracks.append(t)
        }
        return order.compactMap { groups[$0] }
    }
}

/// An artist's releases, duplicates merged and split into albums, singles and films, newest first.
enum MusicDiscography {
    struct Section: Sendable { var title: String; var albums: [MusicAlbum] }

    static func group(_ albums: [MusicAlbum], catalogue: [MusicAlbum] = []) -> [Section] {
        var seen: [String: MusicAlbum] = [:]
        var order: [String] = []
        for a in albums {
            let k = MusicTransliterationKey.key(a.title)
            if var cur = seen[k] {
                cur.thumbnails = MusicAlbumMerge.bestCover(cur.thumbnails, a.thumbnails)
                if cur.releaseDate == nil { cur.releaseDate = a.releaseDate }
                seen[k] = cur
            } else { order.append(k); seen[k] = a }
        }
        var list = order.compactMap { seen[$0] }
        for i in list.indices {
            if let c = catalogue.first(where: { MusicTransliterationKey.sameKey($0.title, list[i].title) }) {
                if MusicTransliterationKey.sameKey(c.title, list[i].title) { list[i].title = c.title }
                if list[i].releaseDate == nil { list[i].releaseDate = c.releaseDate }
                if list[i].label == nil { list[i].label = c.label }
                list[i].thumbnails = MusicAlbumMerge.bestCover(list[i].thumbnails, c.thumbnails)
            }
        }
        func year(_ a: MusicAlbum) -> Int { a.releaseDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } ?? 0 }
        list.sort { year($0) > year($1) }
        func isSingle(_ a: MusicAlbum) -> Bool {
            let t = (a.albumType ?? "").lowercased()
            return t == "single" || t == "ep" || ((a.totalTracks ?? 99) <= 3 && t != "album")
        }
        var out: [Section] = []
        let albumsOnly = list.filter { !isSingle($0) }, singles = list.filter(isSingle)
        if !albumsOnly.isEmpty { out.append(Section(title: "Albums", albums: albumsOnly)) }
        if !singles.isEmpty { out.append(Section(title: "Singles and EPs", albums: singles)) }
        return out
    }

    /// Top songs: the catalogue's popularity decides when it gave one, else the order given.
    static func topSongs(_ tracks: [MusicTrack], popularity: [String: Int] = [:]) -> [MusicTrack] {
        tracks.enumerated().sorted { a, b in
            let x = popularity[MusicAlbumMerge.key(a.element)] ?? a.element.popularity ?? -1, y = popularity[MusicAlbumMerge.key(b.element)] ?? b.element.popularity ?? -1
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: orchestration (talks to the catalogue and the audio sources, shows nothing)

extension MusicCatalogMatcher {
    /// The catalogue's version of an album or film, found by title (and artist when known). Nil when the catalogue is silent or nothing fits.
    func catalogueAlbum(title: String, artist: String?) async -> (album: MusicAlbum, tracks: [MusicTrack])? {
        let providers = await environmentCatalogue()
        let q = ([title] + (artist.map { [$0] } ?? [])).joined(separator: " ")
        for p in providers {
            guard let page = try? await MusicStreamResolver.withDeadline(Self.expansionBudget, { try await p.searchAlbums(q, page: nil) }) else { continue }
            // With the album's artist known, only an album by that artist can be it: another artist's "Greatest Hits" that shares one song must not be taken for it. An album the
            // catalogue lists with no artist at all is not ruled out.
            let candidates = page.items.filter { a in
                guard let artist, !artist.isEmpty, !a.artists.isEmpty else { return true }
                return a.artists.contains { MusicTransliterationKey.similarity(artist, $0.name) >= 0.7 }
            }
            let hit = candidates.max { MusicTransliterationKey.similarity(title, $0.title) < MusicTransliterationKey.similarity(title, $1.title) }
            guard let hit, MusicTransliterationKey.similarity(title, hit.title) >= 0.85 else { continue }
            guard let tracks = try? await MusicStreamResolver.withDeadline(Self.expansionBudget, { try await p.albumTracks(id: hit.id, page: nil).items }), !tracks.isEmpty else { continue }
            return (hit, tracks)
        }
        return nil
    }

    /// An album shown from a playable source, enriched from the catalogue. Songs missing from the playable list are looked up on the audio
    /// sources (3 at a time, verified) and added in place; ones with no verified copy are left out.
    func enrichAlbum(_ album: MusicAlbum, tracks: [MusicTrack]) async -> MusicAlbumEnrichment {
        let plain = MusicAlbumEnrichment(album: album, tracks: tracks, added: 0, removedDuplicates: 0)
        guard let cat = await catalogueAlbum(title: album.title, artist: album.artists.first?.name) else { return plain }
        let have = Set(tracks.map(MusicAlbumMerge.key))
        // The catalogue may hold another edition (a dub, a different cut): with no song in common it is left alone.
        guard cat.tracks.contains(where: { have.contains(MusicAlbumMerge.key($0)) }) else { return plain }
        let missing = cat.tracks.filter { !have.contains(MusicAlbumMerge.key($0)) }
        var twins: [String: MusicTrack] = [:]
        if !missing.isEmpty {
            let found = await playable(missing, budget: 10)
            for (t, w) in zip(missing, found) { if let w { twins[t.uid] = w } }
        }
        return MusicAlbumMerge.merge(album: album, tracks: tracks, catalogueAlbum: cat.album, catalogueTracks: cat.tracks, twins: twins)
    }

    /// A catalogue chart or curated list as a shelf or playlist page: only songs with a verified playable copy, under the list's own name.
    func resolveShelf(_ section: MusicBrowseSection) async -> MusicBrowseSection? {
        let tracks = section.items.compactMap { i -> MusicTrack? in if case .track(let t) = i { t } else { nil } }
        guard !tracks.isEmpty else { return nil }
        // The chart pipeline: each song as its best verified playable version (own row, official audio, album track, lyric or official video).
        let rt = MusicCatalogRuntime.shared
        let resolved = await rt.charts.playableSection(section, matcher: rt.matcher === self ? nil : self, budget: 8)
        let shown = resolved.items.compactMap { i -> MusicTrack? in if case .track(let t) = i { t } else { nil } }
        guard !shown.isEmpty else { return nil }
        var out = section; out.items = shown.map { .track($0) }
        return out
    }

    /// An artist page from a playable source, with the name, pictures, biography and top songs improved from the catalogue.
    func enrichArtist(_ overview: MusicArtistOverview) async -> MusicArtistOverview {
        let providers = await environmentCatalogue()
        var out = overview
        for p in providers {
            guard let page = try? await MusicStreamResolver.withDeadline(Self.expansionBudget, { try await p.searchArtists(overview.artist.name, page: nil) }),
                  let hit = page.items.first(where: { MusicArtistCanon.key($0.name) == MusicArtistCanon.key(overview.artist.name) }) else { continue }
            out.artist = MusicArtistCanon.merge([overview.artist, hit], preferredNames: [hit.name]).first ?? overview.artist
            if let cat = try? await MusicStreamResolver.withDeadline(Self.expansionBudget, { try await p.artistOverview(id: hit.id) }) {
                out.albums = overview.albums
                let pop = Dictionary(cat.topTracks.compactMap { t in t.popularity.map { (MusicAlbumMerge.key(t), $0) } }, uniquingKeysWith: { f, _ in f })
                out.topTracks = MusicDiscography.topSongs(overview.topTracks, popularity: pop)
                out.related = overview.related.isEmpty ? [] : MusicArtistCanon.merge(overview.related)
            }
            break
        }
        return out
    }
}
