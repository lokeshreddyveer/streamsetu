import Foundation

// Adapters make a running plugin look like any built-in provider. Plugin data comes back as JSON with the same field names as the Core models;
// it is read leniently (missing optional fields get their defaults, bad items are dropped) and every address is forced to https.

// MARK: - JSON mapping

enum PluginJSON {
    static func parse(_ data: Data) throws -> Any {
        guard let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw MusicError.plugin("the plugin returned something that is not JSON") }
        return o
    }

    static func https(_ s: String?) -> String? {
        guard let s, s.count <= 2000, let c = URLComponents(string: s), c.scheme?.lowercased() == "https", c.host?.isEmpty == false else { return nil }
        return s
    }
    static func i64(_ d: [String: Any], _ k: String) -> Int64? {
        if let n = d[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.int64Value }
        if let s = d[k] as? String { return Int64(s) }
        return nil
    }
    static func flag(_ d: [String: Any], _ k: String) -> Bool? { (d[k] as? NSNumber).map { $0.boolValue } }

    static func thumbs(_ any: Any?) -> [MusicThumbnail] {
        guard let arr = any as? [Any] else { return [] }
        return arr.prefix(12).compactMap { item in
            if let s = item as? String { return https(s).map { MusicThumbnail(url: $0) } }
            guard let d = item as? [String: Any], let u = https(d.str("url")) else { return nil }
            return MusicThumbnail(url: u, width: d.int("width") ?? 0, height: d.int("height") ?? 0)
        }
    }
    static func artistRef(_ d: [String: Any]) -> MusicArtistRef? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        return MusicArtistRef(id: id, name: name, thumbnails: thumbs(d["thumbnails"]), externalURL: https(d.str("externalURL")))
    }
    static func albumRef(_ d: [String: Any]) -> MusicAlbumRef? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        return MusicAlbumRef(id: id, title: title, artists: d.array("artists").compactMap(artistRef), thumbnails: thumbs(d["thumbnails"]),
                             releaseDate: d.str("releaseDate"), totalTracks: d.int("totalTracks"), albumType: d.str("albumType"), externalURL: https(d.str("externalURL")))
    }
    static func stream(_ d: [String: Any]) -> MusicStream? {
        guard let url = https(d.str("url")) else { return nil }
        var headers: [String: String] = [:]
        for (k, v) in (d.dict("headers") ?? [:]) { if let s = v as? String { headers[k] = s } }
        return MusicStream(url: url, codec: d.str("codec") ?? "unknown", container: d.str("container") ?? "unknown",
                           proto: d.str("proto").flatMap(MusicStreamProtocol.init(rawValue:)) ?? .progressive,
                           bitrate: d.int("bitrate"), sampleRate: d.int("sampleRate"), headers: headers,
                           expiresAt: (d["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
    static func track(_ d: [String: Any], providerID: String) -> MusicTrack? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        let streams = d.array("directStreams").compactMap(stream)
        return MusicTrack(id: id, providerID: providerID, title: title, durationMs: i64(d, "durationMs") ?? 0, trackNumber: d.int("trackNumber"),
                          discNumber: d.int("discNumber"), artists: d.array("artists").compactMap(artistRef), album: d.dict("album").flatMap(albumRef),
                          thumbnails: thumbs(d["thumbnails"]), explicit: flag(d, "explicit") ?? false, popularity: d.int("popularity"), isrc: d.str("isrc"),
                          externalURL: https(d.str("externalURL")), directStreams: streams.isEmpty ? nil : streams)
    }
    static func artist(_ d: [String: Any], providerID: String) -> MusicArtist? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        return MusicArtist(id: id, providerID: providerID, name: name, thumbnails: thumbs(d["thumbnails"]), genres: (d["genres"] as? [String]) ?? [],
                           followers: d.int("followers"), bio: d.str("bio"), externalURL: https(d.str("externalURL")))
    }
    static func album(_ d: [String: Any], providerID: String) -> MusicAlbum? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        return MusicAlbum(id: id, providerID: providerID, title: title, artists: d.array("artists").compactMap(artistRef), thumbnails: thumbs(d["thumbnails"]),
                          releaseDate: d.str("releaseDate"), totalTracks: d.int("totalTracks"), albumType: d.str("albumType"), label: d.str("label"), externalURL: https(d.str("externalURL")))
    }
    static func playlist(_ d: [String: Any], providerID: String) -> MusicPlaylist? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        return MusicPlaylist(id: id, providerID: providerID, name: name, summary: d.str("summary"), owner: d.str("owner"), thumbnails: thumbs(d["thumbnails"]),
                             trackCount: d.int("trackCount"), isPublic: flag(d, "isPublic") ?? true, externalURL: https(d.str("externalURL")))
    }
    static func user(_ d: [String: Any], providerID: String) -> MusicUser? {
        guard let id = d.str("id"), let name = d.str("username") else { return nil }
        return MusicUser(id: id, providerID: providerID, username: name, displayName: d.str("displayName"), thumbnails: thumbs(d["thumbnails"]), externalURL: https(d.str("externalURL")))
    }
    static func genre(_ d: [String: Any]) -> MusicBrowseGenre? {
        guard let id = d.str("id"), let name = d.str("name") else { return nil }
        return MusicBrowseGenre(id: id, name: name, thumbnails: thumbs(d["thumbnails"]))
    }
    /// A browse item carries `type`: track, album, artist or playlist.
    static func browseItem(_ d: [String: Any], providerID: String) -> MusicBrowseItem? {
        switch d.str("type") {
        case "track": return track(d, providerID: providerID).map { .track($0) }
        case "album": return album(d, providerID: providerID).map { .album($0) }
        case "artist": return artist(d, providerID: providerID).map { .artist($0) }
        case "playlist": return playlist(d, providerID: providerID).map { .playlist($0) }
        default: return nil
        }
    }
    static func section(_ d: [String: Any], providerID: String) -> MusicBrowseSection? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        let items = d.array("items").compactMap { browseItem($0, providerID: providerID) }
        return items.isEmpty ? nil : MusicBrowseSection(id: id, title: title, items: items)
    }
    static func audioSource(_ d: [String: Any], providerID: String) -> MusicAudioSource? {
        guard let id = d.str("id"), let title = d.str("title") else { return nil }
        let streams = d.array("streams").compactMap(stream)
        let conf = (d["confidence"] as? NSNumber)?.floatValue ?? 0.5
        return MusicAudioSource(id: id, providerID: providerID, title: title, artist: d.str("artist"), album: d.str("album"), durationMs: i64(d, "durationMs"),
                                thumbnails: thumbs(d["thumbnails"]), externalURL: https(d.str("externalURL")), confidence: min(1, max(0, conf)), streams: streams.isEmpty ? nil : streams)
    }
    static func lyrics(_ d: [String: Any], fallbackName: String) -> MusicLyrics? {
        let synced = d.array("synced").compactMap { l -> MusicLyricLine? in
            guard let t = i64(l, "timeMs"), let s = l["text"] as? String else { return nil }
            return MusicLyricLine(timeMs: t, text: s)
        }
        let l = MusicLyrics(synced: synced.isEmpty ? nil : synced.sorted { $0.timeMs < $1.timeMs }, plain: d.str("plain"), sourceName: d.str("sourceName") ?? fallbackName)
        return l.isEmpty ? nil : l
    }
    static func pagination(_ any: Any?) -> MusicPagination? {
        guard let d = any as? [String: Any], let kind = d.str("kind") else { return nil }
        switch kind {
        case "offset": return .offset(offset: d.int("offset") ?? 0, limit: d.int("limit") ?? 30)
        case "cursor": return .cursor(d.str("cursor"), limit: d.int("limit") ?? 30)
        case "page": return .page(d.int("page") ?? 1, size: d.int("size") ?? 30)
        case "continuation": return .continuation(d.str("token"))
        default: return nil
        }
    }
    /// `{items, totalCount, next}`; a bare array is accepted as a single last page.
    static func page<T: Sendable>(_ any: Any, map: ([String: Any]) -> T?) -> MusicPage<T> {
        if let arr = any as? [[String: Any]] { return MusicPage(items: arr.compactMap(map)) }
        guard let d = any as? [String: Any] else { return .empty }
        return MusicPage(items: d.array("items").compactMap(map), totalCount: d.int("totalCount"), next: pagination(d["next"]))
    }

    // MARK: toward the plugin

    static func fragment(_ v: some Encodable) -> String {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        guard let d = try? e.encode(v) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }
    static func fragment(page: MusicPagination?) -> String {
        guard let page else { return "null" }
        let o: [String: Any]
        switch page {
        case .offset(let off, let limit): o = ["kind": "offset", "offset": off, "limit": limit]
        case .cursor(let c, let limit): o = ["kind": "cursor", "cursor": c as Any? ?? NSNull(), "limit": limit]
        case .page(let p, let size): o = ["kind": "page", "page": p, "size": size]
        case .continuation(let t): o = ["kind": "continuation", "token": t as Any? ?? NSNull()]
        }
        return jsonText(o)
    }
    static func fragment(source s: MusicAudioSource) -> String {
        var o: [String: Any] = ["id": s.id, "providerID": s.providerID, "title": s.title, "confidence": Double(s.confidence)]
        if let a = s.artist { o["artist"] = a }
        if let a = s.album { o["album"] = a }
        if let d = s.durationMs { o["durationMs"] = d }
        if let u = s.externalURL { o["externalURL"] = u }
        return jsonText(o)
    }
    static func fragment(scrobble s: MusicScrobble) -> String {
        "{\"timestamp\":\(Int64(s.timestamp.timeIntervalSince1970)),\"playedMs\":\(s.playedMs),\"track\":\(fragment(s.track))}"
    }
    static func jsonText(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }
    static func args(_ fragments: String...) -> String { "[" + fragments.joined(separator: ",") + "]" }
}

// MARK: - Shared core

struct PluginAdapterCore: Sendable {
    let manifest: MusicPluginManifest
    let host: MusicPluginHost
    let capability: MusicPluginCapability

    var adapterID: String { manifest.adapterID(for: capability) }

    var info: MusicProviderInfo {
        let hosts = manifest.permissions.networkHosts
        var note = hosts.isEmpty ? "This plugin cannot reach the internet. " : "This plugin may contact: \(hosts.joined(separator: ", ")). "
        note += "Audio and artwork addresses it returns are loaded from wherever it points. It runs sandboxed on this device and was written by a third party."
        let suffix = adapterID == manifest.id ? "" : " (\(capability.rawValue))"
        return MusicProviderInfo(id: adapterID, name: manifest.name + suffix, summary: manifest.summary, version: manifest.version, kind: .plugin,
                                 requiresSignIn: manifest.permissions.signIn, privacyNote: note, homepage: manifest.homepage)
    }

    func json(_ method: String, _ args: String = "[]") async throws -> Any {
        try PluginJSON.parse(try await host.callRaw(method, argsJSON: args))
    }
    func object(_ method: String, _ args: String) async throws -> [String: Any] {
        guard let d = try await json(method, args) as? [String: Any] else { throw MusicError.notFound }
        return d
    }
    func list<T: Sendable>(_ method: String, _ args: String, map: ([String: Any]) -> T?) async throws -> [T] {
        guard let arr = try await json(method, args) as? [[String: Any]] else { return [] }
        return arr.compactMap(map)
    }
    func page<T: Sendable>(_ method: String, _ args: String, map: ([String: Any]) -> T?) async throws -> MusicPage<T> {
        PluginJSON.page(try await json(method, args), map: map)
    }

    func isSignedIn() async -> Bool {
        guard manifest.permissions.signIn else { return true }
        guard let any = try? await json("isLoggedIn") else { return false }
        return (any as? Bool) ?? false
    }
    func signIn() async throws {
        guard manifest.permissions.signIn else { throw MusicError.unsupported("sign in") }
        _ = try await json("login", "[{}]")
    }
    func signOut() async {
        guard manifest.permissions.signIn else { return }
        _ = try? await json("logout")
    }
}

/// Shared conformance plumbing for the four adapters.
protocol PluginBackedProvider: MusicProvider { var core: PluginAdapterCore { get } }
extension PluginBackedProvider {
    var info: MusicProviderInfo { core.info }
    var isSignedIn: Bool { get async { await core.isSignedIn() } }
    func signIn() async throws { try await core.signIn() }
    func signOut() async { await core.signOut() }
}

// MARK: - Metadata

struct PluginMetadataAdapter: MusicMetadataProvider, PluginBackedProvider {
    let core: PluginAdapterCore
    var capabilities: MusicCapabilities { core.manifest.permissions.signIn ? [.metadata, .library] : .metadata }
    private var pid: String { core.adapterID }
    private typealias J = PluginJSON

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let p = pid; return try await core.page("searchTracks", J.args(J.fragment(query), J.fragment(page: page))) { J.track($0, providerID: p) }
    }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        let p = pid; return try await core.page("searchArtists", J.args(J.fragment(query), J.fragment(page: page))) { J.artist($0, providerID: p) }
    }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let p = pid; return try await core.page("searchAlbums", J.args(J.fragment(query), J.fragment(page: page))) { J.album($0, providerID: p) }
    }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        let p = pid; return try await core.page("searchPlaylists", J.args(J.fragment(query), J.fragment(page: page))) { J.playlist($0, providerID: p) }
    }
    func featured() async throws -> [MusicBrowseSection] {
        let p = pid; return try await core.list("featured", "[]") { J.section($0, providerID: p) }
    }
    func genres() async throws -> [MusicBrowseGenre] { try await core.list("genres", "[]") { J.genre($0) } }
    func browse(genreID: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseSection> {
        let p = pid; return try await core.page("browse", J.args(J.fragment(genreID), J.fragment(page: page))) { J.section($0, providerID: p) }
    }
    func track(id: String) async throws -> MusicTrack {
        let d = try await core.object("getTrack", J.args(J.fragment(id)))
        guard let t = J.track(d, providerID: pid) else { throw MusicError.notFound }
        return t
    }
    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack] {
        let p = pid; return try await core.list("recommendations", J.args(J.fragment(seedTrackIDs), J.fragment(limit))) { J.track($0, providerID: p) }
    }
    func album(id: String) async throws -> MusicAlbum {
        let d = try await core.object("getAlbum", J.args(J.fragment(id)))
        guard let a = J.album(d, providerID: pid) else { throw MusicError.notFound }
        return a
    }
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let p = pid; return try await core.page("albumTracks", J.args(J.fragment(id), J.fragment(page: page))) { J.track($0, providerID: p) }
    }
    func artist(id: String) async throws -> MusicArtist {
        let d = try await core.object("getArtist", J.args(J.fragment(id)))
        guard let a = J.artist(d, providerID: pid) else { throw MusicError.notFound }
        return a
    }
    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        let p = pid; return try await core.list("artistTopTracks", J.args(J.fragment(id))) { J.track($0, providerID: p) }
    }
    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let p = pid; return try await core.page("artistAlbums", J.args(J.fragment(id), J.fragment(page: page))) { J.album($0, providerID: p) }
    }
    func relatedArtists(id: String) async throws -> [MusicArtist] {
        let p = pid; return (try? await core.list("relatedArtists", J.args(J.fragment(id))) { J.artist($0, providerID: p) }) ?? []
    }
    func playlist(id: String) async throws -> MusicPlaylist {
        let d = try await core.object("getPlaylist", J.args(J.fragment(id)))
        guard let x = J.playlist(d, providerID: pid) else { throw MusicError.notFound }
        return x
    }
    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let p = pid; return try await core.page("playlistTracks", J.args(J.fragment(id), J.fragment(page: page))) { J.track($0, providerID: p) }
    }
    func user(id: String) async throws -> MusicUser? {
        guard let d = try await core.json("getUser", J.args(J.fragment(id))) as? [String: Any] else { return nil }
        return J.user(d, providerID: pid)
    }
    func savedTracks(page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let p = pid; return try await core.page("savedTracks", J.args(J.fragment(page: page))) { J.track($0, providerID: p) }
    }
    func savedAlbums(page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let p = pid; return try await core.page("savedAlbums", J.args(J.fragment(page: page))) { J.album($0, providerID: p) }
    }
    func savedArtists(page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        let p = pid; return try await core.page("savedArtists", J.args(J.fragment(page: page))) { J.artist($0, providerID: p) }
    }
    func savedPlaylists(page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        let p = pid; return try await core.page("savedPlaylists", J.args(J.fragment(page: page))) { J.playlist($0, providerID: p) }
    }
    func setSaved(_ saved: Bool, trackIDs: [String]) async throws {
        _ = try await core.json("setSaved", J.args(saved ? "true" : "false", J.fragment(trackIDs)))
    }
    func isSaved(trackIDs: [String]) async throws -> [Bool] {
        let any = try await core.json("isSaved", J.args(J.fragment(trackIDs)))
        let flags = (any as? [Any])?.map { ($0 as? Bool) ?? false } ?? []
        return flags.count == trackIDs.count ? flags : Array(repeating: false, count: trackIDs.count)
    }
}

// MARK: - Audio, lyrics, scrobble

struct PluginAudioAdapter: MusicAudioProvider, PluginBackedProvider {
    let core: PluginAdapterCore
    var capabilities: MusicCapabilities { .audio }
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        let p = core.adapterID
        return try await core.list("sources", PluginJSON.args(PluginJSON.fragment(track))) { PluginJSON.audioSource($0, providerID: p) }
    }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        try await core.list("streams", PluginJSON.args(PluginJSON.fragment(source: source))) { PluginJSON.stream($0) }
    }
}

struct PluginLyricsAdapter: MusicLyricsProvider, PluginBackedProvider {
    let core: PluginAdapterCore
    var capabilities: MusicCapabilities { .lyrics }
    func lyrics(for track: MusicTrack) async throws -> MusicLyrics? {
        guard let d = try await core.json("lyrics", PluginJSON.args(PluginJSON.fragment(track))) as? [String: Any] else { return nil }
        return PluginJSON.lyrics(d, fallbackName: core.manifest.name)
    }
}

struct PluginScrobbleAdapter: MusicScrobbleProvider, PluginBackedProvider {
    let core: PluginAdapterCore
    var capabilities: MusicCapabilities { .scrobble }
    func scrobble(_ s: MusicScrobble) async throws {
        _ = try await core.json("scrobble", PluginJSON.args(PluginJSON.fragment(scrobble: s)))
    }
    func nowPlaying(_ track: MusicTrack) async {
        _ = try? await core.json("nowPlaying", PluginJSON.args(PluginJSON.fragment(track)))
    }
}

enum MusicPluginAdapters {
    /// One adapter per declared capability, in the order metadata, audio, lyrics, scrobble.
    static func make(manifest: MusicPluginManifest, host: MusicPluginHost) -> [any MusicProvider] {
        MusicPluginCapability.allCases.filter { manifest.capabilities.contains($0) }.map { cap in
            let core = PluginAdapterCore(manifest: manifest, host: host, capability: cap)
            switch cap {
            case .metadata: return PluginMetadataAdapter(core: core)
            case .audio: return PluginAudioAdapter(core: core)
            case .lyrics: return PluginLyricsAdapter(core: core)
            case .scrobble: return PluginScrobbleAdapter(core: core)
            }
        }
    }
}
