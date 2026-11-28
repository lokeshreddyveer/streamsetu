import Foundation

/// Audius is a free, keyless, artist-owned catalogue. Its API is served by "discovery" hosts; the directory at api.audius.co lists them.
/// Today the directory names only api.audius.co itself, so that address is also the built-in fallback when the directory cannot be read.
/// A host is dropped only when it fails on the server side or the network; a bad id (a 4xx answer) never costs a host.
actor AudiusHostPool {
    static let directory = URL(string: "https://api.audius.co")!
    static let fallback = ["https://api.audius.co"]
    private let http: MusicHTTP
    private var hosts: [String] = []

    init(http: MusicHTTP) { self.http = http }

    func current() async -> String {
        if hosts.isEmpty { await load() }
        return hosts.first ?? Self.fallback[0]
    }

    func drop(_ host: String) { hosts.removeAll { $0 == host } }

    private func load() async {
        let obj = try? await http.getObject(Self.directory)
        let list = ((obj as? [String: Any])?["data"] as? [String]) ?? []
        let usable = list.filter { $0.hasPrefix("https://") }.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.shuffled()
        hosts = usable.isEmpty ? Self.fallback : usable
    }
}

struct AudiusProvider: MusicMetadataProvider, MusicAudioProvider {
    static let appName = "StreamSetu"
    private let http: MusicHTTP
    private let pool: AudiusHostPool

    init(http: MusicHTTP = MusicHTTP()) {
        self.http = http
        self.pool = AudiusHostPool(http: http)
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: "audius", name: "Audius", summary: "Free music uploaded directly by independent artists. No account needed.",
            privacyNote: "Search words and the ids of tracks you open are sent to an Audius server chosen from api.audius.co, together with the app name \"StreamSetu\". Nothing else is sent: no account, no device id.",
            homepage: "https://audius.co")
    }
    var capabilities: MusicCapabilities { [.search, .browse, .tracks, .albums, .artists, .playlists, .audio] }

    // MARK: transport with host failover

    /// Turns what the shared HTTP helper throws into something the person can act on. A 4xx from Audius means the id is malformed or unknown.
    static func classify(_ error: Error) -> (error: MusicError, dropHost: Bool) {
        guard let e = error as? MusicError else { return (.network((error as NSError).localizedDescription), true) }
        switch e {
        case .notFound, .cancelled: return (e, false)
        case .notSignedIn, .refused: return (.network("Audius refused the request"), true)
        case .rateLimited: return (e, true)
        case .network(let m):
            if let code = Int(m.replacingOccurrences(of: "HTTP ", with: "")), (400..<500).contains(code) { return (.notFound, false) }
            return (e, true)
        default: return (e, false)
        }
    }

    private func fetch(_ path: String, _ query: [String: String] = [:]) async throws -> (data: Any, host: String) {
        var q = query
        q["app_name"] = Self.appName
        var last: MusicError = .network("no Audius server available")
        for _ in 0..<3 {
            let host = await pool.current()
            guard let url = URL(string: host + path) else { throw MusicError.network("bad address") }
            do {
                let obj = try await http.getObject(url, query: q)
                guard let data = (obj as? [String: Any])?["data"] else { throw MusicError.network("unexpected reply") }
                return (data, host)
            } catch {
                let (mapped, drop) = Self.classify(error)
                if !drop { throw mapped }
                await pool.drop(host); last = mapped
            }
        }
        throw last
    }

    private func list(_ path: String, _ query: [String: String] = [:]) async throws -> (rows: [[String: Any]], host: String) {
        let r = try await fetch(path, query)
        guard let rows = r.data as? [[String: Any]] else { throw MusicError.network("unexpected reply") }
        return (rows, r.host)
    }

    private func paged<T: Sendable>(_ path: String, _ extra: [String: String], page: MusicPagination?, rowsAt key: String? = nil,
                                    map: ([String: Any], String) -> T?) async throws -> MusicPage<T> {
        let (offset, limit) = audiusWindow(page)
        var q = extra
        q["offset"] = String(offset); q["limit"] = String(limit)
        let rows: [[String: Any]], h: String
        if let key {
            let r = try await fetch(path, q)
            guard let dict = r.data as? [String: Any] else { throw MusicError.network("unexpected reply") }
            rows = dict.array(key); h = r.host
        } else {
            (rows, h) = try await list(path, q)
        }
        return MusicPage(items: rows.compactMap { map($0, h) }, next: rows.count >= limit ? .offset(offset: offset + limit, limit: limit) : nil)
    }

    // MARK: search

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        try await paged("/v1/tracks/search", ["query": query], page: page, map: Self.mapTrack)
    }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        try await paged("/v1/users/search", ["query": query], page: page) { d, _ in Self.mapArtist(d) }
    }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        try await paged("/v1/playlists/search", ["query": query], page: page) { d, _ in Self.mapPlaylist(d) }
    }
    /// The playlist search never returns albums, so albums come from the combined search with the albums filter.
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        try await paged("/v1/search/full", ["query": query, "kind": "albums"], page: page, rowsAt: "albums") { d, _ in Self.mapAlbum(d) }
    }

    // MARK: browse

    func featured() async throws -> [MusicBrowseSection] {
        var out: [MusicBrowseSection] = []
        let trending = try await list("/v1/tracks/trending", ["limit": "30"])
        let tracks = trending.rows.compactMap { Self.mapTrack($0, host: trending.host) }
        if !tracks.isEmpty { out.append(MusicBrowseSection(id: "audius-trending", title: "Trending now", items: tracks.map { .track($0) })) }
        if let r = try? await list("/v1/tracks/trending/underground", ["limit": "20"]) {
            let under = r.rows.compactMap { Self.mapTrack($0, host: r.host) }
            if !under.isEmpty { out.append(MusicBrowseSection(id: "audius-underground", title: "Underground trending", items: under.map { .track($0) })) }
        }
        if let r = try? await list("/v1/playlists/trending", ["limit": "20"]) {
            let pl = r.rows.compactMap { Self.mapPlaylist($0) }
            if !pl.isEmpty { out.append(MusicBrowseSection(id: "audius-playlists", title: "Trending playlists", items: pl.map { .playlist($0) })) }
        }
        if let r = try? await list("/v1/playlists/trending", ["limit": "20", "type": "album"]) {
            let al = r.rows.compactMap { Self.mapAlbum($0) }
            if !al.isEmpty { out.append(MusicBrowseSection(id: "audius-albums", title: "Trending albums", items: al.map { .album($0) })) }
        }
        if out.isEmpty { throw MusicError.network("Audius returned nothing to browse") }
        return out
    }

    // MARK: details

    func track(id: String) async throws -> MusicTrack {
        let r = try await fetch("/v1/tracks/\(Self.escape(id))")
        guard let d = r.data as? [String: Any], let t = Self.mapTrack(d, host: r.host) else { throw MusicError.notFound }
        return t
    }

    func artist(id: String) async throws -> MusicArtist {
        guard let d = try await fetch("/v1/users/\(Self.escape(id))").data as? [String: Any], let a = Self.mapArtist(d) else { throw MusicError.notFound }
        return a
    }

    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        let r = try await list("/v1/users/\(Self.escape(id))/tracks", ["sort": "plays", "limit": "20"])
        return r.rows.compactMap { Self.mapTrack($0, host: r.host) }
    }

    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        try await paged("/v1/users/\(Self.escape(id))/albums", [:], page: page) { d, _ in Self.mapAlbum(d) }
    }

    private func playlistRow(_ id: String) async throws -> [String: Any] {
        let raw = try await fetch("/v1/playlists/\(Self.escape(id))").data
        guard let d = (raw as? [[String: Any]])?.first ?? (raw as? [String: Any]) else { throw MusicError.notFound }
        return d
    }

    func playlist(id: String) async throws -> MusicPlaylist {
        guard let p = Self.mapPlaylist(try await playlistRow(id)) else { throw MusicError.notFound }
        return p
    }

    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        // This endpoint returns the whole playlist at once, so paging is done here.
        let (offset, limit) = audiusWindow(page)
        let r = try await list("/v1/playlists/\(Self.escape(id))/tracks")
        let all = r.rows.compactMap { Self.mapTrack($0, host: r.host) }
        let slice = Array(all.dropFirst(offset).prefix(limit))
        return MusicPage(items: slice, totalCount: all.count, next: offset + limit < all.count ? .offset(offset: offset + limit, limit: limit) : nil)
    }

    func album(id: String) async throws -> MusicAlbum {
        guard let a = Self.mapAlbum(try await playlistRow(id)) else { throw MusicError.notFound }
        return a
    }

    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        try await playlistTracks(id: id, page: page)
    }

    // MARK: audio

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if track.providerID == "audius", let s = track.directStreams, !s.isEmpty {
            return [Self.source(from: track, confidence: 1)]
        }
        let q = ([track.title] + track.artists.prefix(1).map(\.name)).joined(separator: " ")
        let found = try await searchTracks(q, page: .offset(offset: 0, limit: 10)).items
        // Independent uploads are often covers, so a wrong match is likelier here than elsewhere: the title has to match properly.
        return found.compactMap { c -> MusicAudioSource? in
            guard c.directStreams != nil else { return nil }
            let score = audiusMatchScore(track, c)
            return score >= 0.5 ? Self.source(from: c, confidence: score) : nil
        }.sorted { $0.confidence > $1.confidence }
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        let h = await pool.current()
        return Self.streams(forTrackID: source.id, host: h)
    }

    private static func source(from t: MusicTrack, confidence: Float) -> MusicAudioSource {
        MusicAudioSource(id: t.id, providerID: "audius", title: t.title, artist: t.artists.first?.name, album: nil,
                         durationMs: t.durationMs > 0 ? t.durationMs : nil, thumbnails: t.thumbnails, externalURL: t.externalURL,
                         confidence: confidence, streams: t.directStreams)
    }

    // MARK: mapping (static so tests can feed canned JSON)

    private static func escape(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id }

    static func streams(forTrackID id: String, host: String) -> [MusicStream] {
        // The stream endpoint answers 302 to the creator node and that answers 307 to storage; both are https and the final file takes
        // ranged requests (206, audio/mpeg, 320 kbps), so the player can be given the first address directly.
        let url = "\(host)/v1/tracks/\(escape(id))/stream?app_name=\(appName)"
        return [MusicStream(url: url, codec: "mp3", container: "mp3", proto: .progressive, bitrate: 320)]
    }

    static func mapTrack(_ d: [String: Any], host: String) -> MusicTrack? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        let user = d.dict("user") ?? [:]
        let artist = MusicArtistRef(id: user.str("id") ?? "", name: user.str("name") ?? user.str("handle") ?? "Unknown artist",
                                    thumbnails: thumbs(user.dict("profile_picture")), externalURL: link(user.str("handle").map { "/" + $0 }))
        var art = thumbs(d.dict("artwork"))
        if art.isEmpty { art = artist.thumbnails }
        let playable = isPlayable(d)
        var track = MusicTrack(
            id: id, providerID: "audius", title: title, durationMs: Int64(d.int("duration") ?? 0) * 1000,
            artists: [artist], album: nil, thumbnails: art, explicit: (d.str("parental_warning_type") ?? "").lowercased().contains("explicit"),
            popularity: d.int("play_count"), isrc: d.str("isrc"), externalURL: link(d.str("permalink")),
            directStreams: playable ? streams(forTrackID: id, host: host) : nil)
        track.creditBundle = AudiusCreditMapper.trackBundle(d)
        return track
    }

    /// Deleted, not yet streamable, or gated behind a purchase or follow: these have no open stream, so they must not claim one.
    static func isPlayable(_ d: [String: Any]) -> Bool {
        if (d["is_streamable"] as? Bool) == false || (d["is_delete"] as? Bool) == true { return false }
        if (d["is_stream_gated"] as? Bool) == true { return false }
        if let access = d.dict("access"), (access["stream"] as? Bool) == false { return false }
        return true
    }

    static func mapArtist(_ d: [String: Any]) -> MusicArtist? {
        guard let id = d.str("id") else { return nil }
        guard let name = d.str("name") ?? d.str("handle") else { return nil }
        return MusicArtist(id: id, providerID: "audius", name: name, thumbnails: thumbs(d.dict("profile_picture")),
                           followers: d.int("follower_count"), bio: d.str("bio"), externalURL: link(d.str("permalink")))
    }

    static func mapPlaylist(_ d: [String: Any]) -> MusicPlaylist? {
        guard let id = d.str("id"), let name = d.str("playlist_name") ?? d.str("name") else { return nil }
        if (d["is_delete"] as? Bool) == true { return nil }
        return MusicPlaylist(id: id, providerID: "audius", name: name, summary: d.str("description"),
                             owner: d.dict("user")?.str("name"), thumbnails: thumbs(d.dict("artwork")),
                             trackCount: d.int("track_count"), isPublic: !((d["is_private"] as? Bool) ?? false),
                             externalURL: link(d.str("permalink")))
    }

    static func mapAlbum(_ d: [String: Any]) -> MusicAlbum? {
        guard let id = d.str("id"), let name = d.str("playlist_name") ?? d.str("name") else { return nil }
        if (d["is_delete"] as? Bool) == true { return nil }
        let user = d.dict("user") ?? [:]
        let artist = MusicArtistRef(id: user.str("id") ?? "", name: user.str("name") ?? user.str("handle") ?? "Unknown artist",
                                    thumbnails: thumbs(user.dict("profile_picture")))
        return MusicAlbum(id: id, providerID: "audius", title: name, artists: [artist], thumbnails: thumbs(d.dict("artwork")),
                          releaseDate: d.str("release_date").map { String($0.prefix(10)) }, totalTracks: d.int("track_count"),
                          albumType: "Album", externalURL: link(d.str("permalink")))
    }

    private static func thumbs(_ d: [String: Any]?) -> [MusicThumbnail] {
        guard let d else { return [] }
        return d.compactMap { k, v -> MusicThumbnail? in
            guard let u = v as? String, u.hasPrefix("http") else { return nil }
            let parts = k.split(separator: "x").compactMap { Int($0) }
            return MusicThumbnail(url: u, width: parts.first ?? 0, height: parts.last ?? 0)
        }.sorted { $0.width < $1.width }
    }

    private static func link(_ permalink: String?) -> String? { permalink.map { "https://audius.co" + $0 } }
}

/// Offset and size from any pagination shape; a missing value means the first page of 30.
private func audiusWindow(_ p: MusicPagination?) -> (Int, Int) {
    func clamp(_ n: Int) -> Int { min(max(n, 1), 100) }
    switch p {
    case .offset(let o, let l): return (max(o, 0), clamp(l))
    case .page(let n, let s): return (max(n - 1, 0) * clamp(s), clamp(s))
    case .cursor(let c, let l): return (max(Int(c ?? "") ?? 0, 0), clamp(l))
    case .continuation(let c): return (max(Int(c ?? "") ?? 0, 0), 30)
    case nil: return (0, 30)
    }
}

private func audiusNormalise(_ s: String) -> String {
    s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
        .split(separator: " ").joined(separator: " ")
}

/// 0...1 closeness of a search hit to the wanted track: title first, then artist, then length.
private func audiusMatchScore(_ want: MusicTrack, _ got: MusicTrack) -> Float {
    let wt = audiusNormalise(want.title), gt = audiusNormalise(got.title)
    var s: Float = 0
    if !wt.isEmpty, wt == gt { s += 0.6 } else if !wt.isEmpty, !gt.isEmpty, gt.contains(wt) || wt.contains(gt) { s += 0.4 }
    let wa = audiusNormalise(want.artistLine), ga = audiusNormalise(got.artistLine)
    if !wa.isEmpty, !ga.isEmpty, wa.contains(ga) || ga.contains(wa) { s += 0.25 }
    if want.durationMs > 0, got.durationMs > 0 {
        let diff = abs(want.durationMs - got.durationMs)
        if diff <= 3000 { s += 0.15 } else if diff <= 10000 { s += 0.08 }
    }
    return min(s, 1)
}
