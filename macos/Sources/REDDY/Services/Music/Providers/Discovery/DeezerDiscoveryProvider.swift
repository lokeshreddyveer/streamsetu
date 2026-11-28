import Foundation

/// Deezer's public charts: top tracks, albums, artists and playlists. No key, no account. Audio is never taken from here (Deezer only gives
/// 30 second previews); a played track is matched on a real audio source by the resolver.
struct DeezerDiscoveryProvider: MusicMetadataProvider, MusicRegionalDiscovery, MusicLanguagePlaylistSearch {
    static let id = "discover-deezer"
    static let base = URL(string: "https://api.deezer.com")!
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        .discovery(id: Self.id, name: "Deezer charts", summary: "What is popular right now: top songs, albums, artists and playlists.", host: "api.deezer.com")
    }
    var capabilities: MusicCapabilities { [.browse, .catalogue] }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        let obj = try await http.getObject(Self.base.appendingPathComponent(path), query: query)
        guard let d = obj as? [String: Any] else { throw MusicError.network("unexpected reply") }
        if d["error"] != nil { throw MusicError.notFound }
        return d
    }

    func featured() async throws -> [MusicBrowseSection] {
        async let t = try? get("chart/0/tracks", ["limit": "25"])
        async let a = try? get("chart/0/albums", ["limit": "25"])
        async let r = try? get("chart/0/artists", ["limit": "25"])
        async let p = try? get("chart/0/playlists", ["limit": "25"])
        let (tr, al, ar, pl) = await (t, a, r, p)
        var out: [MusicBrowseSection] = []
        // Deezer's chart/0 is the worldwide chart, whatever country was asked for: it says so.
        func add(_ id: String, _ title: String, _ items: [MusicBrowseItem]) { if !items.isEmpty { out.append(MusicBrowseSection(id: id, title: title, items: items, scope: .global)) } }
        add("deezer-tracks", "Top songs right now", Self.tracks(tr).map { .track($0) })
        add("deezer-albums", "Top albums", Self.albums(al).map { .album($0) })
        add("deezer-artists", "Top artists", Self.artists(ar).map { .artist($0) })
        add("deezer-playlists", "Popular playlists", Self.playlists(pl).map { .playlist($0) })
        if out.isEmpty { throw MusicError.network("no chart answered") }
        return out
    }

    /// Deezer publishes one chart, the worldwide one, so a country is answered with it, labelled as global (never as the country's).
    func featured(region: String) async throws -> [MusicBrowseSection] { try await featured() }

    /// Deezer's own genres whose charts Explore lists, by Deezer's genre id. The genre's name is read from Deezer when the shelf loads, so a wrong id can never carry another genre's name.
    static let chartGenreIDs: [Int] = [132, 116, 152, 113, 165, 85, 106, 466, 144, 129, 84, 98, 464, 169, 153, 197, 81, 173]

    enum GenreChartKind: String, Sendable { case albums, artists }

    /// The worldwide chart of one genre: the genre's name and its top albums or artists.
    func genreChart(_ genreID: Int, kind: GenreChartKind) async throws -> (name: String, items: [MusicBrowseItem]) {
        async let info = try? get("genre/\(genreID)")
        async let chart = try? get("chart/\(genreID)/\(kind.rawValue)", ["limit": "25"])
        let (i, c) = await (info, chart)
        let name = (i?["name"] as? String) ?? ""
        let items: [MusicBrowseItem] = kind == .albums ? Self.albums(c).map { .album($0) } : Self.artists(c).map { .artist($0) }
        guard !name.isEmpty, !items.isEmpty else { throw MusicError.notFound }
        return (name, items)
    }

    /// Public playlists whose own title names the language ("Telugu Hits"), at least 20 songs long: the search is open to everyone, so the rest is noise.
    func languagePlaylists(_ language: MusicLanguage) async throws -> [MusicPlaylist] {
        let reply = try await get("search/playlist", ["q": language.englishName + " hits", "limit": "25"])
        return Self.playlists(reply).filter { ($0.trackCount ?? 0) >= 20 && $0.name.localizedCaseInsensitiveContains(language.englishName) }
    }

    // MARK: details for the cards above

    func album(id: String) async throws -> MusicAlbum {
        guard let a = Self.mapAlbum(try await get("album/" + id)) else { throw MusicError.notFound }
        return a
    }
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let a = try await album(id: id)
        let ref = MusicAlbumRef(id: a.id, title: a.title, artists: a.artists, thumbnails: a.thumbnails)
        let items = Self.tracks(try await get("album/\(id)/tracks", ["limit": "100"])).map { t -> MusicTrack in var t = t; t.album = ref; t.thumbnails = a.thumbnails; return t }
        return MusicPage(items: items)
    }
    func artist(id: String) async throws -> MusicArtist {
        guard let a = Self.mapArtist(try await get("artist/" + id)) else { throw MusicError.notFound }
        return a
    }
    func artistTopTracks(id: String) async throws -> [MusicTrack] { Self.tracks(try await get("artist/\(id)/top", ["limit": "30"])) }
    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        MusicPage(items: Self.albums(try await get("artist/\(id)/albums", ["limit": "50"])))
    }
    func playlist(id: String) async throws -> MusicPlaylist {
        guard let p = Self.mapPlaylist(try await get("playlist/" + id)) else { throw MusicError.notFound }
        return p
    }
    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        MusicPage(items: Self.tracks(try await get("playlist/\(id)/tracks", ["limit": "100"])))
    }

    // MARK: parsing

    private static func rows(_ d: [String: Any]?) -> [[String: Any]] { d?.array("data") ?? [] }
    static func tracks(_ d: [String: Any]?) -> [MusicTrack] { rows(d).compactMap(mapTrack) }
    static func albums(_ d: [String: Any]?) -> [MusicAlbum] { rows(d).compactMap(mapAlbum) }
    static func artists(_ d: [String: Any]?) -> [MusicArtist] { rows(d).compactMap(mapArtist) }
    static func playlists(_ d: [String: Any]?) -> [MusicPlaylist] { rows(d).compactMap(mapPlaylist) }

    private static func images(_ d: [String: Any], _ prefix: String) -> [MusicThumbnail] {
        var out: [MusicThumbnail] = []
        for (suffix, side) in [("_medium", 250), ("_big", 500), ("_xl", 1000)] {
            if let u = d.str(prefix + suffix), u.hasPrefix("http") { out.append(MusicThumbnail(url: u, width: side, height: side)) }
        }
        return out
    }

    static func mapTrack(_ d: [String: Any]) -> MusicTrack? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        let artist = d.dict("artist").flatMap(mapArtist)
        let alb = d.dict("album").flatMap(mapAlbum)
        let refArtist = artist.map { MusicArtistRef(id: $0.id, name: $0.name, thumbnails: $0.thumbnails, externalURL: $0.externalURL) }
        let albumRef = alb.map { MusicAlbumRef(id: $0.id, title: $0.title, artists: refArtist.map { [$0] } ?? [], thumbnails: $0.thumbnails) }
        var track = MusicTrack(id: id, providerID: DeezerDiscoveryProvider.id, title: title, durationMs: Int64(d.int("duration") ?? 0) * 1000,
                               artists: refArtist.map { [$0] } ?? [], album: albumRef, thumbnails: alb?.thumbnails ?? [],
                               explicit: (d["explicit_lyrics"] as? Bool) ?? false, popularity: d.int("rank"), externalURL: d.str("link"))
        track.creditBundle = DeezerCreditMapper.trackBundle(d)
        return track
    }
    static func mapAlbum(_ d: [String: Any]) -> MusicAlbum? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        let artist = d.dict("artist").flatMap(mapArtist)
        return MusicAlbum(id: id, providerID: DeezerDiscoveryProvider.id, title: title,
                          artists: artist.map { [MusicArtistRef(id: $0.id, name: $0.name, thumbnails: $0.thumbnails)] } ?? [],
                          thumbnails: images(d, "cover"), releaseDate: d.str("release_date"), totalTracks: d.int("nb_tracks"), albumType: d.str("record_type"), externalURL: d.str("link"))
    }
    static func mapArtist(_ d: [String: Any]) -> MusicArtist? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        return MusicArtist(id: id, providerID: DeezerDiscoveryProvider.id, name: name, thumbnails: images(d, "picture"), followers: d.int("nb_fan"), externalURL: d.str("link"))
    }
    static func mapPlaylist(_ d: [String: Any]) -> MusicPlaylist? {
        guard let id = d.str("id"), let name = d.str("title") else { return nil }
        return MusicPlaylist(id: id, providerID: DeezerDiscoveryProvider.id, name: name, summary: d.str("description"), owner: d.dict("user")?.str("name"),
                             thumbnails: images(d, "picture"), trackCount: d.int("nb_tracks"), externalURL: d.str("link"))
    }
}
