import Foundation

/// Spotify as a metadata source. It never supplies audio: a track is handed to the audio matcher as metadata only, and the matcher finds a recording on a
/// YouTube-family or other audio source.
///
/// It works in three layers, each optional and each adding to the one before:
///  1. No account, no key: any pasted open.spotify.com link (song, album, playlist, artist) is browsed through Spotify's public embed pages.
///  2. The person's own developer app (client id and secret): search, albums, artists and public playlists through the official API with an app-only token.
///  3. Sign in with that app's client id (PKCE): the person's own saved songs, albums, artists and playlists.
/// Spotify has cut back its API for new apps, so every call that is refused or removed falls back to the embed page or to an empty result, never an error.
struct SpotifyProvider: MusicMetadataProvider {
    static let providerID = "spotify"
    /// Shown where a Spotify list would be when nothing is set up.
    static let linkHint = "Paste a link to open a Spotify playlist, album or song"
    let http: MusicHTTP
    let auth: SpotifyAuth
    let embed: SpotifyEmbedClient

    init(http: MusicHTTP = MusicHTTP(), auth: SpotifyAuth? = nil) {
        self.http = http
        self.auth = auth ?? SpotifyAuth(http: http)
        self.embed = SpotifyEmbedClient(http: http)
    }

    let info = MusicProviderInfo(
        id: SpotifyProvider.providerID, name: "Spotify",
        summary: "Open any Spotify link without an account. Add your own developer key for search, or sign in for your library. Audio is matched from other services, not Spotify.",
        requiresSignIn: false,
        privacyNote: "Opening a link asks open.spotify.com for that page, so Spotify sees the link and your IP address; no account is used. If you add your own developer app, searches and the items you open go to api.spotify.com under that app, and signing in ties them to your Spotify account. You create the app and its keys yourself; nothing is built in, and keys stay in this device's Keychain.",
        homepage: "https://developer.spotify.com/dashboard")

    /// Honest about what works right now: links always, search and browsing with developer keys (or a sign in), the library only when signed in.
    var capabilities: MusicCapabilities {
        var c: MusicCapabilities = [.tracks, .albums, .artists, .playlists, .catalogue]
        let a = auth.access
        if a.hasAppKeys || a.signedIn { c.formUnion([.search, .browse]) }
        if a.signedIn { c.formUnion([.library, .users]) }
        return c
    }

    // MARK: sign in and keys

    var isSignedIn: Bool { get async { await auth.isSignedIn } }
    func signIn() async throws { try await auth.signIn() }
    func signOut() async { await auth.signOut() }
    func setClientID(_ id: String) async { await auth.setClientID(id) }
    var hasClientID: Bool { get async { await auth.clientID != nil } }
    /// Show this in Settings: the person must register exactly this address in their Spotify app.
    var redirectURI: String { get async { await auth.redirectURI } }

    /// What is set up, without waiting.
    var access: SpotifyAccessState { auth.access }
    /// Saves the person's own developer app for search and public catalogue calls, then asks Spotify whether it accepts them.
    func setAppKeys(clientID: String, secret: String) async -> Bool {
        await auth.setAppKeys(clientID: clientID, secret: secret)
        return await auth.verifyAppKeys()
    }
    func clearAppKeys() async { await auth.clearAppKeys() }
    /// The line to show in place of an empty Spotify list; nil once search is available.
    var emptyHint: String? { let a = auth.access; return a.hasAppKeys || a.signedIn ? nil : Self.linkHint }

    // MARK: transport

    private static let base = URL(string: "https://api.spotify.com/v1")

    private func request(_ method: String, _ path: String, _ query: [String: String], userOnly: Bool = false) async throws -> Data {
        guard let base = Self.base else { throw MusicError.network("bad address") }
        let token: String
        if userOnly { token = try await auth.validAccessToken() }
        else if let t = await auth.apiToken() { token = t }
        else { throw MusicError.unsupported("Spotify search needs your own developer key") }
        let url = path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
        return try await http.send(url: url, method: method, query: query,
                                   headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"], body: nil)
    }

    private func get(_ path: String, _ query: [String: String] = [:], userOnly: Bool = false) async throws -> [String: Any] {
        let data = try await request("GET", path, query, userOnly: userOnly)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw MusicError.network("unexpected reply") }
        return o
    }

    /// True when a catalogue call can be made at all (a developer key or a sign in).
    private var canUseAPI: Bool { let a = auth.access; return a.hasAppKeys || a.signedIn }

    /// Runs `op`, turning "not allowed", "not found", "not set up" and "removed" from the API into `fallback`. Network trouble still surfaces.
    private func soft<T>(_ fallback: T, _ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch MusicError.notFound { return fallback }
        catch MusicError.unsupported { return fallback }
        catch MusicError.notSignedIn, MusicError.refused { return fallback }
        catch MusicError.refused { return fallback }
    }

    /// The API when a key or sign in exists, the embed page otherwise (and whenever the API refuses). Cancellation is never swallowed.
    private func apiOrEmbed<T>(api: () async throws -> T, embed fallback: () async throws -> T) async throws -> T {
        if canUseAPI {
            do { return try await api() }
            catch MusicError.cancelled { throw MusicError.cancelled }
            catch is CancellationError { throw MusicError.cancelled }
            catch { if Task.isCancelled { throw MusicError.cancelled } }
        }
        return try await fallback()
    }

    private func embedEntity(_ kind: SpotifyLink.Kind, _ id: String) async throws -> SpotifyEmbedEntity {
        try await embed.entity(SpotifyLink(kind: kind, id: try Self.safeID(id)))
    }

    private static func safeID(_ id: String) throws -> String {
        guard !id.isEmpty, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw MusicError.notFound }
        return id
    }

    private func window(_ p: MusicPagination?, defaultLimit: Int = 30) -> (offset: Int, limit: Int) {
        if case .offset(let o, let l)? = p { return (max(0, o), min(max(1, l), 50)) }
        return (0, defaultLimit)
    }

    private func nextPage(_ d: [String: Any], offset: Int, limit: Int) -> MusicPagination? {
        d["next"] is String ? .offset(offset: offset + limit, limit: limit) : nil
    }

    private func pageQuery(_ w: (offset: Int, limit: Int)) -> [String: String] { ["offset": String(w.offset), "limit": String(w.limit)] }

    private func slice<T>(_ all: [T], _ w: (offset: Int, limit: Int)) -> MusicPage<T> {
        let items = Array(all.dropFirst(w.offset).prefix(w.limit))
        return MusicPage(items: items, totalCount: all.count, next: w.offset + w.limit < all.count ? .offset(offset: w.offset + w.limit, limit: w.limit) : nil)
    }

    // MARK: search

    /// A link or share text in the search box opens that item instead of searching.
    private func linkResult(_ query: String) async throws -> MusicSearchResult? {
        guard let link = SpotifyLink.parse(query) else { return nil }
        switch link.kind {
        case .track: return .track(try await track(id: link.id))
        case .album: return .album(try await album(id: link.id))
        case .artist: return .artist(try await artist(id: link.id))
        case .playlist: return .playlist(try await playlist(id: link.id))
        }
    }

    private func searchRaw(_ query: String, types: [String], w: (offset: Int, limit: Int)) async throws -> [String: Any] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, canUseAPI else { return [:] }
        var params = pageQuery(w); params["q"] = q; params["type"] = types.joined(separator: ",")
        // Apps created since February 2026 may ask for at most 10 results per type.
        params["limit"] = String(min(w.limit, 10))
        do { return try await get("search", params) }
        catch MusicError.notFound { return [:] }
        catch MusicError.unsupported { return [:] }
        catch MusicError.notSignedIn, MusicError.refused { return [:] }
        catch MusicError.refused { return [:] }
    }

    func search(_ query: String, types: Set<MusicSearchType>) async throws -> [MusicSearchResult] {
        if let hit = try await linkResult(query) { return [hit] }
        var names: [String] = []
        if types.contains(.track) { names.append("track") }
        if types.contains(.artist) { names.append("artist") }
        if types.contains(.album) { names.append("album") }
        if types.contains(.playlist) { names.append("playlist") }
        guard !names.isEmpty else { return [] }
        let r = try await searchRaw(query, types: names, w: (0, 10))
        var out: [MusicSearchResult] = []
        out += SpotifyMapper.items(r, "tracks").compactMap(SpotifyMapper.track).map { .track($0) }
        out += SpotifyMapper.items(r, "artists").compactMap(SpotifyMapper.artist).map { .artist($0) }
        out += SpotifyMapper.items(r, "albums").compactMap(SpotifyMapper.album).map { .album($0) }
        out += SpotifyMapper.items(r, "playlists").compactMap(SpotifyMapper.playlist).map { .playlist($0) }
        return out
    }

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        if case .track(let t)? = try await linkResult(query) { return MusicPage(items: [t], totalCount: 1) }
        let w = window(page)
        let r = try await searchRaw(query, types: ["track"], w: w)
        return MusicPage(items: SpotifyMapper.items(r, "tracks").compactMap(SpotifyMapper.track),
                         totalCount: r.dict("tracks")?.int("total"), next: nextPage(r.dict("tracks") ?? [:], offset: w.offset, limit: min(w.limit, 10)))
    }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        if case .artist(let a)? = try await linkResult(query) { return MusicPage(items: [a], totalCount: 1) }
        let w = window(page)
        let r = try await searchRaw(query, types: ["artist"], w: w)
        return MusicPage(items: SpotifyMapper.items(r, "artists").compactMap(SpotifyMapper.artist),
                         totalCount: r.dict("artists")?.int("total"), next: nextPage(r.dict("artists") ?? [:], offset: w.offset, limit: min(w.limit, 10)))
    }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        if case .album(let a)? = try await linkResult(query) { return MusicPage(items: [a], totalCount: 1) }
        let w = window(page)
        let r = try await searchRaw(query, types: ["album"], w: w)
        return MusicPage(items: SpotifyMapper.items(r, "albums").compactMap(SpotifyMapper.album),
                         totalCount: r.dict("albums")?.int("total"), next: nextPage(r.dict("albums") ?? [:], offset: w.offset, limit: min(w.limit, 10)))
    }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        if case .playlist(let p)? = try await linkResult(query) { return MusicPage(items: [p], totalCount: 1) }
        let w = window(page)
        let r = try await searchRaw(query, types: ["playlist"], w: w)
        return MusicPage(items: SpotifyMapper.items(r, "playlists").compactMap(SpotifyMapper.playlist),
                         totalCount: r.dict("playlists")?.int("total"), next: nextPage(r.dict("playlists") ?? [:], offset: w.offset, limit: min(w.limit, 10)))
    }

    // MARK: browse

    func featured() async throws -> [MusicBrowseSection] {
        guard canUseAPI else { return [] }
        var sections: [MusicBrowseSection] = []
        let playlists = try await soft([MusicPlaylist]()) {
            SpotifyMapper.items(try await get("browse/featured-playlists", ["limit": "20"]), "playlists").compactMap(SpotifyMapper.playlist)
        }
        if !playlists.isEmpty { sections.append(MusicBrowseSection(id: "featured", title: "Featured playlists", items: playlists.map { .playlist($0) })) }
        let albums = try await soft([MusicAlbum]()) {
            SpotifyMapper.items(try await get("browse/new-releases", ["limit": "20"]), "albums").compactMap(SpotifyMapper.album)
        }
        if !albums.isEmpty { sections.append(MusicBrowseSection(id: "new-releases", title: "New releases", items: albums.map { .album($0) })) }
        return sections
    }

    func genres() async throws -> [MusicBrowseGenre] {
        guard canUseAPI else { return [] }
        return try await soft([MusicBrowseGenre]()) {
            SpotifyMapper.items(try await get("browse/categories", ["limit": "50"]), "categories").compactMap { c in
                guard let id = c.str("id"), let name = c.str("name") else { return nil }
                return MusicBrowseGenre(id: id, name: name, thumbnails: SpotifyMapper.images(c, "icons"))
            }
        }
    }

    func browse(genreID: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseSection> {
        let id = try Self.safeID(genreID)
        let w = window(page, defaultLimit: 30)
        guard canUseAPI else { return .empty }
        return try await soft(MusicPage<MusicBrowseSection>.empty) {
            let r = try await get("browse/categories/\(id)/playlists", pageQuery(w))
            let list = SpotifyMapper.items(r, "playlists").compactMap(SpotifyMapper.playlist)
            guard !list.isEmpty else { return .empty }
            return MusicPage(items: [MusicBrowseSection(id: id, title: "Playlists", items: list.map { .playlist($0) })],
                             next: nextPage(r.dict("playlists") ?? [:], offset: w.offset, limit: w.limit))
        }
    }

    // MARK: tracks

    func track(id: String) async throws -> MusicTrack {
        let id = try Self.safeID(id)
        return try await apiOrEmbed(api: {
            let r = try await get("tracks/\(id)")
            guard let t = SpotifyMapper.track(r) else { throw MusicError.notFound }
            return t
        }, embed: { try await embedEntity(.track, id).singleTrack })
    }

    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack] {
        let seeds = seedTrackIDs.compactMap { try? Self.safeID($0) }.prefix(5)
        guard !seeds.isEmpty, canUseAPI else { return [] }
        return try await soft([MusicTrack]()) {
            let r = try await get("recommendations", ["seed_tracks": seeds.joined(separator: ","), "limit": String(min(max(limit, 1), 100))])
            return r.array("tracks").compactMap(SpotifyMapper.track)
        }
    }

    // MARK: albums

    func album(id: String) async throws -> MusicAlbum {
        let id = try Self.safeID(id)
        return try await apiOrEmbed(api: {
            let r = try await get("albums/\(id)")
            guard let a = SpotifyMapper.album(r) else { throw MusicError.notFound }
            return a
        }, embed: { try await embedEntity(.album, id).albumModel })
    }

    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let id = try Self.safeID(id)
        let w = window(page, defaultLimit: 50)
        return try await apiOrEmbed(api: {
            // The track list alone has no cover art, so the album itself is read too and its info is attached to each track.
            async let albumReply = get("albums/\(id)")
            async let tracksReply = get("albums/\(id)/tracks", pageQuery(w))
            let (a, t) = try await (albumReply, tracksReply)
            let ref = SpotifyMapper.albumRef(a)
            let tracks = SpotifyMapper.listItems(t).compactMap { SpotifyMapper.track($0, fallbackAlbum: ref) }
            return MusicPage(items: tracks, totalCount: t.int("total"), next: nextPage(t, offset: w.offset, limit: w.limit))
        }, embed: { slice(try await embedEntity(.album, id).trackModels, w) })
    }

    // MARK: artists

    func artist(id: String) async throws -> MusicArtist {
        let id = try Self.safeID(id)
        // An artist known only by name (from a playlist row) has no page of its own; with a key the first search hit stands in.
        if let name = SpotifyMapper.name(fromID: id) {
            guard let hit = try await searchArtists(name, page: nil).items.first else { throw MusicError.notFound }
            return hit
        }
        return try await apiOrEmbed(api: {
            let r = try await get("artists/\(id)")
            guard let a = SpotifyMapper.artist(r) else { throw MusicError.notFound }
            return a
        }, embed: { try await embedEntity(.artist, id).artistModel })
    }

    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        let id = try Self.safeID(id)
        guard SpotifyMapper.name(fromID: id) == nil else { return [] }
        let market = Locale.current.region?.identifier ?? "US"
        // The artist's embed page lists the top ten songs, which also covers apps where the API endpoint was removed.
        // A secondary list: when neither the API nor the page can give it, the artist page simply shows no top songs.
        return try await soft([MusicTrack]()) {
            try await apiOrEmbed(api: {
                let r = try await get("artists/\(id)/top-tracks", ["market": market]).array("tracks").compactMap(SpotifyMapper.track)
                if r.isEmpty { throw MusicError.notFound }
                return r
            }, embed: { try await embedEntity(.artist, id).trackModels })
        }
    }

    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let id = try Self.safeID(id)
        let w = window(page)
        guard canUseAPI, SpotifyMapper.name(fromID: id) == nil else { return .empty }
        return try await soft(MusicPage<MusicAlbum>.empty) {
            var q = pageQuery(w); q["include_groups"] = "album,single"
            let r = try await get("artists/\(id)/albums", q)
            return MusicPage(items: SpotifyMapper.listItems(r).compactMap(SpotifyMapper.album), totalCount: r.int("total"),
                             next: nextPage(r, offset: w.offset, limit: w.limit))
        }
    }

    func relatedArtists(id: String) async throws -> [MusicArtist] {
        let id = try Self.safeID(id)
        // Spotify closed this endpoint to most apps; an empty list is the expected answer there.
        guard canUseAPI, SpotifyMapper.name(fromID: id) == nil else { return [] }
        return try await soft([MusicArtist]()) { try await get("artists/\(id)/related-artists").array("artists").compactMap(SpotifyMapper.artist) }
    }

    // MARK: playlists

    func playlist(id: String) async throws -> MusicPlaylist {
        let id = try Self.safeID(id)
        return try await apiOrEmbed(api: {
            let r = try await get("playlists/\(id)")
            guard let p = SpotifyMapper.playlist(r) else { throw MusicError.notFound }
            return p
        }, embed: { try await embedEntity(.playlist, id).playlistModel })
    }

    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let id = try Self.safeID(id)
        let w = window(page, defaultLimit: 50)
        return try await apiOrEmbed(api: {
            var q = pageQuery(w)
            let r: [String: Any]
            // The list moved from /tracks to /items in 2026; the old path stays as the fallback for apps that still have it.
            do { r = try await get("playlists/\(id)/items", q) }
            catch MusicError.notFound { q["market"] = "from_token"; r = try await get("playlists/\(id)/tracks", q) }
            let rows = SpotifyMapper.listItems(r)
            // A playlist the app may not read answers without a list; the embed page still has up to 100 songs.
            guard !rows.isEmpty || r["items"] != nil else { throw MusicError.notFound }
            let tracks = rows.compactMap { row -> MusicTrack? in
                guard let t = (row["track"] as? [String: Any]) ?? (row["item"] as? [String: Any]) else { return nil }
                return SpotifyMapper.track(t)
            }
            return MusicPage(items: tracks, totalCount: r.int("total"), next: nextPage(r, offset: w.offset, limit: w.limit))
        }, embed: { slice(try await embedEntity(.playlist, id).trackModels, w) })
    }

    func user(id: String) async throws -> MusicUser? {
        let id = try Self.safeID(id)
        guard canUseAPI else { return nil }
        return try await soft(nil) {
            let r = try await get("users/\(id)")
            guard let uid = r.str("id") else { return nil }
            return MusicUser(id: uid, providerID: Self.providerID, username: uid, displayName: r.str("display_name"),
                             thumbnails: SpotifyMapper.images(r, "images"), externalURL: r.dict("external_urls")?.str("spotify"))
        }
    }

    // MARK: the person's library

    func savedTracks(page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        guard auth.access.signedIn else { return .empty }
        let w = window(page)
        var q = pageQuery(w); q["market"] = "from_token"
        let r = try await get("me/tracks", q, userOnly: true)
        let tracks = SpotifyMapper.listItems(r).compactMap { ($0["track"] as? [String: Any]).flatMap { SpotifyMapper.track($0) } }
        return MusicPage(items: tracks, totalCount: r.int("total"), next: nextPage(r, offset: w.offset, limit: w.limit))
    }

    func savedAlbums(page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        guard auth.access.signedIn else { return .empty }
        let w = window(page)
        let r = try await get("me/albums", pageQuery(w), userOnly: true)
        let albums = SpotifyMapper.listItems(r).compactMap { ($0["album"] as? [String: Any]).flatMap { SpotifyMapper.album($0) } }
        return MusicPage(items: albums, totalCount: r.int("total"), next: nextPage(r, offset: w.offset, limit: w.limit))
    }

    func savedArtists(page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        guard auth.access.signedIn else { return .empty }
        var q = ["type": "artist", "limit": "50"]
        if case .cursor(let after?, _)? = page { q["after"] = after }
        let r = try await get("me/following", q, userOnly: true)
        let block = r.dict("artists") ?? [:]
        let after = block.dict("cursors")?.str("after")
        let next: MusicPagination? = (block["next"] is String && after != nil) ? .cursor(after, limit: 50) : nil
        return MusicPage(items: SpotifyMapper.listItems(block).compactMap(SpotifyMapper.artist), totalCount: block.int("total"), next: next)
    }

    func savedPlaylists(page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        guard auth.access.signedIn else { return .empty }
        let w = window(page)
        let r = try await get("me/playlists", pageQuery(w), userOnly: true)
        return MusicPage(items: SpotifyMapper.listItems(r).compactMap(SpotifyMapper.playlist), totalCount: r.int("total"),
                         next: nextPage(r, offset: w.offset, limit: w.limit))
    }

    /// Saving and the "is it saved" check moved to /me/library (with Spotify URIs, 40 at a time) in 2026; the older per-type paths are the fallback.
    func setSaved(_ saved: Bool, trackIDs: [String]) async throws {
        guard auth.access.signedIn else { throw MusicError.notSignedIn("Spotify") }
        let ids = try trackIDs.map(Self.safeID)
        for chunk in stride(from: 0, to: ids.count, by: 40).map({ Array(ids[$0..<min($0 + 40, ids.count)]) }) {
            do { _ = try await request(saved ? "PUT" : "DELETE", "me/library", ["uris": chunk.map { "spotify:track:" + $0 }.joined(separator: ",")], userOnly: true) }
            catch MusicError.notFound { _ = try await request(saved ? "PUT" : "DELETE", "me/tracks", ["ids": chunk.joined(separator: ",")], userOnly: true) }
        }
    }

    func isSaved(trackIDs: [String]) async throws -> [Bool] {
        guard auth.access.signedIn else { return Array(repeating: false, count: trackIDs.count) }
        var out: [Bool] = []
        let ids = trackIDs.map { (try? Self.safeID($0)) ?? "" }
        for chunk in stride(from: 0, to: ids.count, by: 40).map({ Array(ids[$0..<min($0 + 40, ids.count)]) }) {
            let valid = chunk.filter { !$0.isEmpty }
            var flags: [Bool] = []
            if !valid.isEmpty {
                let data: Data
                do { data = try await request("GET", "me/library/contains", ["uris": valid.map { "spotify:track:" + $0 }.joined(separator: ",")], userOnly: true) }
                catch MusicError.notFound { data = try await request("GET", "me/tracks/contains", ["ids": valid.joined(separator: ",")], userOnly: true) }
                flags = ((try? JSONSerialization.jsonObject(with: data)) as? [Bool]) ?? Array(repeating: false, count: valid.count)
            }
            var it = flags.makeIterator()
            out += chunk.map { $0.isEmpty ? false : (it.next() ?? false) }
        }
        return out
    }
}

// MARK: mapping

/// Turns Spotify JSON into the app's models. Every field is optional on Spotify's side, so nothing here assumes a key exists.
enum SpotifyMapper {
    static let pid = SpotifyProvider.providerID

    static func items(_ root: [String: Any], _ key: String) -> [[String: Any]] { listItems(root.dict(key) ?? [:]) }

    /// Items of a paging object, with the nulls Spotify sometimes includes dropped.
    static func listItems(_ page: [String: Any]) -> [[String: Any]] {
        ((page["items"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }

    static func images(_ d: [String: Any], _ key: String = "images") -> [MusicThumbnail] {
        d.array(key).compactMap { i in
            guard let u = i.str("url") else { return nil }
            return MusicThumbnail(url: u, width: i.int("width") ?? 0, height: i.int("height") ?? 0)
        }
    }

    /// Playlist rows name their artists but not their ids. Such an artist gets an id made of the name, which `name(fromID:)` reads back.
    static let namePrefix = "name_"
    static func nameID(_ name: String) -> String {
        namePrefix + (Data(name.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
    }
    static func name(fromID id: String) -> String? {
        guard id.hasPrefix(namePrefix) else { return nil }
        var b = String(id.dropFirst(namePrefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func artistRef(_ d: [String: Any]) -> MusicArtistRef? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        return MusicArtistRef(id: id, name: name, thumbnails: images(d), externalURL: d.dict("external_urls")?.str("spotify"))
    }

    static func albumRef(_ d: [String: Any]) -> MusicAlbumRef? {
        guard let id = d.str("id"), let title = d.str("name") else { return nil }
        return MusicAlbumRef(id: id, title: title, artists: d.array("artists").compactMap(artistRef), thumbnails: images(d),
                             releaseDate: d.str("release_date"), totalTracks: d.int("total_tracks"), albumType: d.str("album_type"),
                             externalURL: d.dict("external_urls")?.str("spotify"))
    }

    static func track(_ d: [String: Any]) -> MusicTrack? { track(d, fallbackAlbum: nil) }

    static func track(_ d: [String: Any], fallbackAlbum: MusicAlbumRef?) -> MusicTrack? {
        guard (d["is_local"] as? Bool) != true, let id = d.str("id"), let title = d.str("name") else { return nil }
        if let type = d.str("type"), type != "track" { return nil }
        let album = d.dict("album").flatMap(albumRef) ?? fallbackAlbum
        let artists = d.array("artists").compactMap(artistRef)
        return MusicTrack(id: id, providerID: pid, title: title, durationMs: Int64(d.int("duration_ms") ?? 0),
                          trackNumber: d.int("track_number"), discNumber: d.int("disc_number"), artists: artists, album: album,
                          thumbnails: album?.thumbnails ?? [], explicit: (d["explicit"] as? Bool) ?? false, popularity: d.int("popularity"),
                          isrc: d.dict("external_ids")?.str("isrc"), externalURL: d.dict("external_urls")?.str("spotify"))
    }

    static func artist(_ d: [String: Any]) -> MusicArtist? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        return MusicArtist(id: id, providerID: pid, name: name, thumbnails: images(d),
                           genres: (d["genres"] as? [String]) ?? [], followers: d.dict("followers")?.int("total"),
                           externalURL: d.dict("external_urls")?.str("spotify"))
    }

    static func album(_ d: [String: Any]) -> MusicAlbum? {
        guard let id = d.str("id"), let title = d.str("name") else { return nil }
        return MusicAlbum(id: id, providerID: pid, title: title, artists: d.array("artists").compactMap(artistRef), thumbnails: images(d),
                          releaseDate: d.str("release_date"), totalTracks: d.int("total_tracks"), albumType: d.str("album_type"),
                          label: d.str("label"), externalURL: d.dict("external_urls")?.str("spotify"))
    }

    static func playlist(_ d: [String: Any]) -> MusicPlaylist? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        let count = d.dict("tracks")?.int("total") ?? d.dict("items")?.int("total")
        return MusicPlaylist(id: id, providerID: pid, name: name, summary: d.str("description"),
                             owner: d.dict("owner")?.str("display_name") ?? d.dict("owner")?.str("id"),
                             thumbnails: images(d), trackCount: count, isPublic: (d["public"] as? Bool) ?? true,
                             externalURL: d.dict("external_urls")?.str("spotify"))
    }
}
