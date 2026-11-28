import Foundation

// Spotify's public embed pages (open.spotify.com/embed/<kind>/<id>) need no account and no key. Each page carries one JSON blob (`__NEXT_DATA__`)
// that names the item and lists its songs. That is enough to browse a pasted link and to hand the songs to the audio matcher as metadata only.
// What the page does NOT carry: ISRC codes, album names for the rows of a playlist, release dates for albums, and more than 100 playlist rows.
// A track page (and some rows) does carry a short `audioPreview` clip, which is captured as the track's previewURL — a ~30 s preview, never the
// full recording (that is still matched from an audio provider). The page also holds an anonymous web player token; it is never read or used.

// MARK: - Page reader

enum SpotifyEmbedPage {
    /// The `entity` object of an embed page. A deleted, private or unknown item answers 200 with props status 404 and no state.
    static func entity(html: Data) throws -> [String: Any] {
        guard let page = String(data: html, encoding: .utf8),
              let open = page.range(of: "id=\"__NEXT_DATA__\""),
              let start = page.range(of: ">", range: open.upperBound..<page.endIndex),
              let end = page.range(of: "</script>", range: start.upperBound..<page.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(page[start.upperBound..<end.lowerBound].utf8)) as? [String: Any]
        else { throw ImportError.spotifyChanged }
        let pageProps = root.dict("props")?.dict("pageProps")
        let state = pageProps?.dict("state")
        if pageProps?.int("status") == 404 && state == nil { throw ImportError.private }
        guard let entity = state?.dict("data")?.dict("entity") else { throw ImportError.spotifyChanged }
        return entity
    }

    /// "A,\u{00A0}B" is two artists. Spotify joins the credits with a comma and a no-break space, so a single name that holds ", " ("Tyler, The Creator")
    /// stays whole. A page that uses plain ", " throughout is split there.
    static func names(fromCredit line: String?) -> [String] {
        guard let line, !line.isEmpty else { return [] }
        let parts = line.contains("\u{00A0}") ? line.components(separatedBy: ",\u{00A0}") : line.components(separatedBy: ", ")
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Cover pictures, largest meaning widest. A source with no stated width is the full size picture.
    static func covers(_ entity: [String: Any]) -> [MusicThumbnail] {
        var out: [MusicThumbnail] = []
        for s in entity.dict("coverArt")?.array("sources") ?? [] {
            guard let u = s.str("url") else { continue }
            out.append(MusicThumbnail(url: u, width: s.int("width") ?? 640, height: s.int("height") ?? 640))
        }
        for i in entity.dict("visualIdentity")?.array("image") ?? [] {
            guard let u = i.str("url") else { continue }
            out.append(MusicThumbnail(url: u, width: i.int("maxWidth") ?? 0, height: i.int("maxHeight") ?? 0))
        }
        return out
    }

    static func trackID(fromURI uri: String?) -> String? {
        guard let uri, uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst("spotify:track:".count))
        return id.isEmpty ? nil : id
    }
}

// MARK: - Browsable shape

struct SpotifyEmbedRow: Sendable, Equatable {
    var id: String
    var title: String
    var artists: [String]
    var durationMs: Int64
    var explicit: Bool
    /// A ~30 s preview clip when the row carries one (usually only a single-track page does).
    var previewURL: String? = nil
}

struct SpotifyEmbedEntity: Sendable {
    var kind: SpotifyLink.Kind
    var id: String
    var name: String
    /// Playlist owner, album artist line or "Top tracks", depending on the kind.
    var subtitle: String?
    var covers: [MusicThumbnail]
    var releaseDate: String?
    var durationMs: Int64
    var explicit: Bool
    /// Credited artists with their ids (track pages only).
    var artistRefs: [MusicArtistRef]
    var rows: [SpotifyEmbedRow]
    /// A playlist page lists at most 100 songs; with 100 on it the list may be longer.
    var mayBeTruncated: Bool
    /// A ~30 s preview clip for a single-track page, when present.
    var previewURL: String? = nil

    static func parse(html: Data, link: SpotifyLink) throws -> SpotifyEmbedEntity {
        let e = try SpotifyEmbedPage.entity(html: html)
        guard let name = e.str("name") ?? e.str("title") else { throw ImportError.spotifyChanged }
        var rows: [SpotifyEmbedRow] = []
        for t in e.array("trackList") {
            guard t.str("entityType") == "track", let id = SpotifyEmbedPage.trackID(fromURI: t.str("uri")),
                  let title = t.str("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            rows.append(SpotifyEmbedRow(id: id, title: title, artists: SpotifyEmbedPage.names(fromCredit: t.str("subtitle")),
                                        durationMs: Int64(t.int("duration") ?? 0), explicit: (t["isExplicit"] as? Bool) ?? false,
                                        previewURL: t.dict("audioPreview")?.str("url")))
        }
        let refs: [MusicArtistRef] = e.array("artists").compactMap { a in
            guard let n = a.str("name") else { return nil }
            let uri = a.str("uri") ?? ""
            let id = uri.hasPrefix("spotify:artist:") ? String(uri.dropFirst("spotify:artist:".count)) : SpotifyMapper.nameID(n)
            return MusicArtistRef(id: id, name: n, externalURL: uri.hasPrefix("spotify:artist:") ? "https://open.spotify.com/artist/\(id)" : nil)
        }
        let iso = e.dict("releaseDate")?.str("isoString")
        return SpotifyEmbedEntity(kind: link.kind, id: link.id, name: name, subtitle: e.str("subtitle"), covers: SpotifyEmbedPage.covers(e),
                                  releaseDate: iso.map { String($0.prefix(10)) }, durationMs: Int64(e.int("duration") ?? 0),
                                  explicit: (e["isExplicit"] as? Bool) ?? false, artistRefs: refs, rows: rows,
                                  mayBeTruncated: link.kind == .playlist && e.array("trackList").count >= 100,
                                  previewURL: e.dict("audioPreview")?.str("url"))
    }

    // MARK: models

    var creditNames: [String] { SpotifyEmbedPage.names(fromCredit: subtitle) }

    var albumRef: MusicAlbumRef {
        MusicAlbumRef(id: id, title: name, artists: creditNames.map { MusicArtistRef(id: SpotifyMapper.nameID($0), name: $0) }, thumbnails: covers,
                      releaseDate: releaseDate, totalTracks: rows.count, externalURL: "https://open.spotify.com/album/\(id)")
    }

    func trackModel(_ r: SpotifyEmbedRow, album: MusicAlbumRef?, thumbnails: [MusicThumbnail]) -> MusicTrack {
        MusicTrack(id: r.id, providerID: SpotifyProvider.providerID, title: r.title, durationMs: r.durationMs,
                   artists: r.artists.map { MusicArtistRef(id: SpotifyMapper.nameID($0), name: $0) }, album: album, thumbnails: thumbnails,
                   explicit: r.explicit, previewURL: r.previewURL, externalURL: "https://open.spotify.com/track/\(r.id)")
    }

    /// The song a track page describes.
    var singleTrack: MusicTrack {
        MusicTrack(id: id, providerID: SpotifyProvider.providerID, title: name, durationMs: durationMs, artists: artistRefs, thumbnails: covers,
                   explicit: explicit, previewURL: previewURL, externalURL: "https://open.spotify.com/track/\(id)")
    }

    /// The rows as tracks. An album's rows carry the album; a playlist's rows have no album on the page, so they show no cover rather than a wrong one.
    var trackModels: [MusicTrack] {
        switch kind {
        case .album: return rows.map { trackModel($0, album: albumRef, thumbnails: covers) }
        case .artist: return rows.map { trackModel($0, album: nil, thumbnails: covers) }
        case .playlist, .track: return rows.map { trackModel($0, album: nil, thumbnails: []) }
        }
    }

    var albumModel: MusicAlbum {
        MusicAlbum(id: id, providerID: SpotifyProvider.providerID, title: name, artists: albumRef.artists, thumbnails: covers, releaseDate: releaseDate,
                   totalTracks: rows.count, externalURL: "https://open.spotify.com/album/\(id)")
    }

    var artistModel: MusicArtist {
        MusicArtist(id: id, providerID: SpotifyProvider.providerID, name: name, thumbnails: covers, externalURL: "https://open.spotify.com/artist/\(id)")
    }

    var playlistModel: MusicPlaylist {
        MusicPlaylist(id: id, providerID: SpotifyProvider.providerID, name: name, summary: nil, owner: subtitle, thumbnails: covers,
                      trackCount: mayBeTruncated ? nil : rows.count, externalURL: "https://open.spotify.com/playlist/\(id)")
    }
}

// MARK: - Fetching

struct SpotifyEmbedClient: Sendable {
    var http: MusicHTTP = MusicHTTP()

    static func pageURL(_ link: SpotifyLink) -> URL? { URL(string: "https://open.spotify.com/embed/\(link.kind.rawValue)/\(link.id)") }

    func entity(_ link: SpotifyLink) async throws -> SpotifyEmbedEntity {
        guard let url = Self.pageURL(link) else { throw MusicError.notFound }
        let data = try await http.get(url, headers: ["Accept": "text/html"])
        do { return try SpotifyEmbedEntity.parse(html: data, link: link) }
        catch ImportError.private { throw MusicError.notFound }
        catch { throw MusicError.network("Spotify's page looks different from what was expected") }
    }
}
