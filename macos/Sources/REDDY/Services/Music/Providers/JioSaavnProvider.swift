import Foundation

/// JioSaavn through its public web API, used for catalogue metadata only.
///
/// The service no longer publishes a plain, full-length audio address anywhere (search, song, album, artist, playlist and home replies
/// were all checked): the only audio fields are encrypted, and the one open address, the caller-tune preview, is a clip of under twenty
/// seconds. The encrypted fields are never read or decoded, and the clip is never offered as a stream. So tracks from here carry no
/// stream, are never presented as directly playable, and the matcher finds their audio on another source. If the service ever
/// publishes a plain `media_url`, `streams(media:)` picks it up with no other change.
struct JioSaavnProvider: MusicMetadataProvider, MusicAudioProvider {
    static let base = URL(string: "https://www.jiosaavn.com/api.php")!
    /// Largest page the search calls serve; asking for more still returns this many.
    static let maxPage = 40
    private let http: MusicHTTP

    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: "jiosaavn", name: "JioSaavn", summary: "Large Indian and international catalogue, with Hindi, Tamil, Telugu and more. Information only: the service offers no open audio link, so the audio comes from another source.",
            privacyNote: "Search words and the ids of items you open are sent to www.jiosaavn.com, the same web API its own website uses. No account and no device id are sent.",
            homepage: "https://www.jiosaavn.com")
    }
    var capabilities: MusicCapabilities { [.search, .browse, .tracks, .albums, .artists, .playlists, .catalogue] }

    // MARK: transport

    /// One call to the web API. Failures arrive as HTTP 200 with a `status: failure` or `error` body, so those are mapped here.
    private func call(_ name: String, _ extra: [String: String] = [:], headers: [String: String] = [:]) async throws -> [String: Any] {
        var q = ["__call": name, "_format": "json", "_marker": "0", "api_version": "4", "ctx": "web6dot0"]
        for (k, v) in extra { q[k] = v }
        var attempt = 0
        while true {
            do {
                let obj = try await http.getObject(Self.base, query: q, headers: headers)
                guard let d = obj as? [String: Any] else { throw MusicError.network("unexpected reply") }
                if let err = d["error"] as? [String: Any] { throw MusicError.network(err.str("msg") ?? "the service refused the request") }
                if d.str("status") == "failure" { throw MusicError.notFound }
                return d
            } catch MusicError.notSignedIn, MusicError.refused {
                throw MusicError.network("JioSaavn refused the request")
            } catch MusicError.network(let m) where m.hasPrefix("HTTP 5") && attempt == 0 {
                attempt += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func search<T: Sendable>(_ call: String, _ query: String, page: MusicPagination?, map: ([String: Any]) -> T?) async throws -> MusicPage<T> {
        let (pageNo, size) = saavnWindow(page)
        let d = try await self.call(call, ["q": query, "p": String(pageNo), "n": String(size)])
        guard d["results"] is [Any] else { throw MusicError.network("unexpected reply") }
        let rows = d.array("results")
        let total = d.int("total")
        let items = rows.compactMap(map)
        let more = rows.count >= size && (total.map { pageNo * size < $0 } ?? true)
        return MusicPage(items: items, totalCount: total, next: more ? .page(pageNo + 1, size: size) : nil)
    }

    // MARK: search

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        try await search("search.getResults", query, page: page, map: Self.mapSong)
    }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        try await search("search.getAlbumResults", query, page: page, map: Self.mapAlbum)
    }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        try await search("search.getArtistResults", query, page: page, map: Self.mapArtist)
    }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        try await search("search.getPlaylistResults", query, page: page, map: Self.mapPlaylist)
    }

    // MARK: browse

    func featured() async throws -> [MusicBrowseSection] {
        let sections = Self.mapLaunchData(try await call("webapi.getLaunchData"))
        if sections.isEmpty { throw MusicError.network("JioSaavn returned nothing to browse") }
        return sections
    }

    // MARK: regional lists (read-only, metadata only)

    /// The web home page's lists for one or more languages. The service reads the languages from its own `L` setting (the same value its
    /// website stores), sent here as that one value; with none it answers in Hindi.
    func launchData(languages: [String]) async throws -> [String: Any] {
        let names = languages.filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter && $0.isASCII } }
        return try await call("webapi.getLaunchData", headers: names.isEmpty ? [:] : ["Cookie": "L=" + names.joined(separator: ",")])
    }

    /// The songs of a chart or editorial list (a page of at most `limit`).
    func listSongs(id: String, limit: Int = 30) async throws -> [MusicTrack] {
        let d = try await call("playlist.getDetails", ["listid": id, "n": String(min(max(limit, 1), Self.maxPage)), "p": "1"])
        guard d.str("id") != nil else { throw MusicError.notFound }
        return Self.songs(in: d)
    }

    // MARK: details

    func track(id: String) async throws -> MusicTrack {
        let d = try await call("song.getDetails", ["pids": id])
        guard let row = d.array("songs").first, let t = Self.mapSong(row) else { throw MusicError.notFound }
        return t
    }

    func album(id: String) async throws -> MusicAlbum {
        guard let a = Self.mapAlbum(try await call("content.getAlbumDetails", ["albumid": id])) else { throw MusicError.notFound }
        return a
    }

    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let (pageNo, size) = saavnWindow(page)
        let d = try await call("content.getAlbumDetails", ["albumid": id, "p": String(pageNo), "n": String(size)])
        // An unknown id comes back as a sample object with an empty id and a placeholder song; it must not look like an album.
        guard d.str("id") != nil else { throw MusicError.notFound }
        return Self.window(Self.songs(in: d), total: d.int("list_count"), pageNo: pageNo, size: size)
    }

    func artist(id: String) async throws -> MusicArtist {
        guard let a = Self.mapArtist(try await call("artist.getArtistPageDetails", ["artistId": id])) else { throw MusicError.notFound }
        return a
    }

    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        let d = try await call("artist.getArtistPageDetails", ["artistId": id, "n_song": "20", "n_album": "10"])
        guard d.str("artistId") != nil else { throw MusicError.notFound }
        return d.array("topSongs").compactMap(Self.mapSong)
    }

    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let (pageNo, size) = saavnWindow(page)
        // This call counts pages from 0, unlike search.
        let d = try await call("artist.getArtistMoreAlbum", ["artistId": id, "page": String(pageNo - 1), "category": "latest", "sort_order": "desc"])
        guard let box = d.dict("topAlbums") else { throw MusicError.notFound }
        let albums = box.array("albums").compactMap(Self.mapAlbum)
        let total = box.int("total")
        let more = (box["last_page"] as? Bool) == false && !albums.isEmpty
        return MusicPage(items: albums, totalCount: total, next: more ? .page(pageNo + 1, size: size) : nil)
    }

    func playlist(id: String) async throws -> MusicPlaylist {
        let d = try await call("playlist.getDetails", ["listid": id, "n": "1"])
        guard let p = Self.mapPlaylist(d) else { throw MusicError.notFound }
        return p
    }

    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let (pageNo, size) = saavnWindow(page)
        let d = try await call("playlist.getDetails", ["listid": id, "p": String(pageNo), "n": String(size)])
        guard d.str("id") != nil else { throw MusicError.notFound }
        return Self.window(Self.songs(in: d), total: d.int("list_count"), pageNo: pageNo, size: size)
    }

    // MARK: audio

    /// Nothing here is searched or fetched: with no open audio link there is no source to offer, and the matcher moves on at once.
    /// A track of this provider that does carry a plain stream (see the note at the top) is still returned as it is.
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        guard track.providerID == "jiosaavn", let s = track.directStreams, !s.isEmpty else { return [] }
        return [MusicAudioSource(id: track.id, providerID: "jiosaavn", title: track.title, artist: track.artists.first?.name, album: track.album?.title,
                                 durationMs: track.durationMs > 0 ? track.durationMs : nil, thumbnails: track.thumbnails,
                                 externalURL: track.externalURL, confidence: 1, streams: s)]
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        throw MusicError.noPlayableSource(source.title)
    }

    // MARK: mapping

    static func songs(in d: [String: Any]) -> [MusicTrack] {
        (d.array("songs") + d.array("list")).compactMap(mapSong)
    }

    private static func window<T: Sendable>(_ items: [T], total: Int?, pageNo: Int, size: Int) -> MusicPage<T> {
        // The service pages by itself; if a reply ever holds more than a page, cut it here so a page is never oversized.
        if items.count > size {
            let start = (pageNo - 1) * size
            let cut = Array(items.dropFirst(start).prefix(size))
            return MusicPage(items: cut, totalCount: items.count, next: start + size < items.count ? .page(pageNo + 1, size: size) : nil)
        }
        let more = items.count >= size && (total.map { pageNo * size < $0 } ?? false)
        return MusicPage(items: items, totalCount: total, next: more ? .page(pageNo + 1, size: size) : nil)
    }

    static func mapSong(_ d: [String: Any]) -> MusicTrack? {
        guard let id = d.str("id"), let rawTitle = d.str("title") ?? d.str("song") else { return nil }
        let more = d.dict("more_info") ?? [:]
        let thumbs = images(d.str("image"))
        let albumName = (more.str("album") ?? d.str("album")).map(clean)
        let albumID = more.str("album_id") ?? d.str("albumid")
        let streams = streams(media: d.str("media_url") ?? more.str("media_url"))
        var track = MusicTrack(
            id: id, providerID: "jiosaavn", title: clean(rawTitle), durationMs: Int64(more.int("duration") ?? d.int("duration") ?? 0) * 1000,
            artists: artistRefs(d, more), album: albumID.map { MusicAlbumRef(id: $0, title: albumName ?? "", thumbnails: thumbs) },
            thumbnails: thumbs, explicit: d.str("explicit_content") == "1", popularity: d.int("play_count"),
            externalURL: d.str("perma_url"), directStreams: streams.isEmpty ? nil : streams)
        track.creditBundle = JioSaavnCreditMapper.trackBundle(d)
        return track
    }

    /// A plain full-length address, only when the reply names one on the service's own audio host. Preview clips and the encrypted
    /// fields are not read at all.
    static func streams(media: String?) -> [MusicStream] {
        guard let m = media, let url = URL(string: m), let host = url.host?.lowercased(), url.scheme == "http" || url.scheme == "https",
              host == "saavncdn.com" || host.hasSuffix(".saavncdn.com"), !m.contains("_p.mp4"), !host.hasPrefix("preview.") else { return [] }
        let secure = m.hasPrefix("http://") ? "https://" + m.dropFirst("http://".count) : m
        return [MusicStream(url: secure, codec: "aac", container: "mp4", proto: .progressive, bitrate: bitrate(in: secure) ?? 160)]
    }

    private static func bitrate(in url: String) -> Int? {
        let name = (url.split(separator: "/").last.map(String.init) ?? "").split(separator: "?").first.map(String.init) ?? ""
        let stem = name.split(separator: ".").first.map(String.init) ?? ""
        return [320, 160, 96, 48, 128].first { stem.hasSuffix("_\($0)") }
    }

    private static func artistRefs(_ d: [String: Any], _ more: [String: Any]) -> [MusicArtistRef] {
        let map = more.dict("artistMap") ?? [:]
        let primary = map.array("primary_artists")
        let refs: [MusicArtistRef] = primary.compactMap { a in
            guard let name = a.str("name") else { return nil }
            let n = clean(name).trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? nil : MusicArtistRef(id: a.str("id") ?? "", name: n, thumbnails: images(a.str("image")), externalURL: a.str("perma_url"))
        }
        if !refs.isEmpty { return refs }
        let flat = d.str("primary_artists") ?? more.str("primary_artists") ?? d.str("music") ?? more.str("music")
        if let flat {
            let names = flat.split(separator: ",").map { clean(String($0)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !names.isEmpty { return names.map { MusicArtistRef(id: "", name: $0) } }
        }
        let sub = (d.str("subtitle") ?? "").components(separatedBy: " - ").first.map(clean) ?? ""
        return [MusicArtistRef(id: "", name: sub.isEmpty ? "Unknown artist" : sub)]
    }

    static func mapAlbum(_ d: [String: Any]) -> MusicAlbum? {
        guard let id = d.str("id") ?? d.str("albumid"), let title = d.str("title") ?? d.str("name") else { return nil }
        let more = d.dict("more_info") ?? [:]
        let count = more.int("song_count") ?? d.int("song_count") ?? d.int("list_count")
        var album = MusicAlbum(id: id, providerID: "jiosaavn", title: clean(title), artists: artistRefs(d, more), thumbnails: images(d.str("image")),
                               releaseDate: more.str("release_date") ?? d.str("release_date") ?? d.str("year"),
                               totalTracks: count.flatMap { $0 > 0 ? $0 : nil },
                               albumType: "Album", label: more.str("label"), externalURL: d.str("perma_url"))
        album.creditBundle = JioSaavnCreditMapper.albumBundle(d)
        return album
    }

    static func mapArtist(_ d: [String: Any]) -> MusicArtist? {
        guard let id = d.str("artistId") ?? d.str("id"), let name = d.str("name") ?? d.str("title") else { return nil }
        return MusicArtist(id: id, providerID: "jiosaavn", name: clean(name), thumbnails: images(d.str("image")),
                           followers: d.int("follower_count") ?? d.dict("more_info")?.int("follower_count"), bio: bio(d.str("bio")),
                           externalURL: d.str("perma_url"))
    }

    /// The artist page sends its biography as a JSON text holding a list of paragraphs.
    private static func bio(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8), let parts = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0.str("text") }.map(clean).joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    static func mapPlaylist(_ d: [String: Any]) -> MusicPlaylist? {
        guard let id = d.str("id") ?? d.str("listid"), let name = d.str("title") ?? d.str("listname") else { return nil }
        let more = d.dict("more_info") ?? [:]
        let counted = more.int("song_count") ?? d.int("list_count") ?? d.int("count") ?? songCount(in: d.str("subtitle"))
        return MusicPlaylist(id: id, providerID: "jiosaavn", name: clean(name), summary: d.str("header_desc") ?? d.str("subtitle"),
                             owner: more.str("firstname") ?? d.str("firstname"), thumbnails: images(d.str("image")),
                             trackCount: counted.flatMap { $0 > 0 ? $0 : nil }, externalURL: d.str("perma_url"))
    }

    /// Search rows say "100 Songs" in the subtitle instead of giving a number.
    private static func songCount(in subtitle: String?) -> Int? {
        guard let subtitle, subtitle.lowercased().hasSuffix("songs") || subtitle.lowercased().hasSuffix("song") else { return nil }
        return Int(subtitle.prefix { $0.isNumber })
    }

    /// The home page modules the web app shows, mapped section by section; modules in an unknown shape are skipped.
    static func mapLaunchData(_ d: [String: Any]) -> [MusicBrowseSection] {
        let titles = d.dict("modules") ?? [:]
        let modules: [(String, String)] = [("new_trending", "Trending now"), ("new_albums", "New releases"), ("top_playlists", "Top playlists"), ("charts", "Charts")]
        return modules.compactMap { key, fallback in
            let items = d.array(key).compactMap { row -> MusicBrowseItem? in
                switch row.str("type") {
                case "song": return mapSong(row).map { .track($0) }
                case "album": return mapAlbum(row).map { .album($0) }
                case "playlist", "mix", "chart": return mapPlaylist(row).map { .playlist($0) }
                case "artist": return mapArtist(row).map { .artist($0) }
                default: return nil
                }
            }
            let title = titles.dict(key)?.str("title").map(clean) ?? fallback
            return items.isEmpty ? nil : MusicBrowseSection(id: "jiosaavn-" + key, title: title, items: items)
        }
    }

    /// The service names a 150 pixel image (50 for artists); the same address with a bigger size in the name gives a sharper one.
    /// Its stock "default artist" pictures are not real artwork and are left out.
    private static func images(_ url: String?) -> [MusicThumbnail] {
        guard let url, url.hasPrefix("http"), !url.contains("-default-") else { return [] }
        let small = url.replacingOccurrences(of: "50x50", with: "150x150")
        let big = small.replacingOccurrences(of: "150x150", with: "500x500")
        var out = [MusicThumbnail(url: small, width: 150, height: 150)]
        if big != small { out.append(MusicThumbnail(url: big, width: 500, height: 500)) }
        return out
    }

    /// The service sends HTML entities in titles.
    static func clean(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }
}

/// Page number (from 1) and size from any pagination shape.
private func saavnWindow(_ p: MusicPagination?) -> (Int, Int) {
    func clamp(_ n: Int) -> Int { min(max(n, 1), JioSaavnProvider.maxPage) }
    switch p {
    case .page(let n, let s): return (max(n, 1), clamp(s))
    case .offset(let o, let l): let s = clamp(l); return (max(o, 0) / s + 1, s)
    case .cursor(let c, let l): let s = clamp(l); return (max(Int(c ?? "") ?? 1, 1), s)
    case .continuation(let c): return (max(Int(c ?? "") ?? 1, 1), 30)
    case nil: return (1, 30)
    }
}
