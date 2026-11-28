import Foundation

/// The person's own Subsonic or Navidrome music server (up to three), as one source: search and browse, the library with its stars and
/// playlists, similar-song radio, audio (optionally converted by the server), cover art and play reporting. It is dormant until a server is
/// added: no server means no network call and no error. The password is in the Keychain and only a salted hash of it is ever sent.
struct SubsonicProvider: MusicMetadataProvider, MusicAudioProvider, MusicScrobbleProvider {
    static let providerID = SubsonicAuth.providerID
    static let addServerNote = "Add a server to start"

    private let http: MusicHTTP
    private let serverList: @Sendable () -> [SubsonicServer]
    private let passwordFor: @Sendable (String) -> String?
    private let transcodeSetting: @Sendable () -> SubsonicTranscode

    init(http: MusicHTTP = MusicHTTP(),
         servers: @escaping @Sendable () -> [SubsonicServer] = { SubsonicServers.load() },
         password: @escaping @Sendable (String) -> String? = { MusicKeychain.shared.read($0) },
         transcode: @escaping @Sendable () -> SubsonicTranscode = { SubsonicTranscode.load() }) {
        self.http = http; self.serverList = servers; self.passwordFor = password; self.transcodeSetting = transcode
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: Self.providerID, name: "Subsonic / Navidrome",
            summary: "Your own music server: your library, stars and playlists. Works with Navidrome, Subsonic, Airsonic and other servers that speak the Subsonic protocol.",
            requiresSignIn: true,
            privacyNote: "Only the servers you add are contacted, and only after you add them. Each request carries your user name and a salted hash made from your password; the password itself stays in this device's Keychain and is never sent. Search words, the ids of songs you open and the songs you play are sent to your server.",
            homepage: "https://www.navidrome.org")
    }
    var capabilities: MusicCapabilities { [.search, .browse, .tracks, .albums, .artists, .playlists, .audio, .scrobble, .library] }
    var isSignedIn: Bool { get async { !sessions().isEmpty } }
    var statusNote: String? { sessions().isEmpty ? Self.addServerNote : nil }

    func signIn() async throws { throw MusicError.unsupported("Add your server in Settings.") }
    func signOut() async { SubsonicServers.removeAll() }

    // MARK: sessions and requests

    private func sessions() -> [SubsonicSession] { SubsonicServers.sessions(serverList(), password: { passwordFor(SubsonicServers.passwordAccount($0)) }) }

    private func requireSessions() throws -> [SubsonicSession] {
        let s = sessions()
        if s.isEmpty { throw MusicError.notSignedIn("Subsonic") }
        return s
    }

    private func resolve(_ id: String) throws -> (session: SubsonicSession, raw: String) {
        guard let parts = SubsonicID.split(id) else { throw MusicError.notFound }
        guard let s = try requireSessions().first(where: { $0.serverID == parts.server }) else { throw MusicError.notFound }
        return (s, parts.raw)
    }

    private func call(_ s: SubsonicSession, _ method: String, _ items: [(String, String)] = []) async throws -> [String: Any] {
        guard let url = s.url(method, items) else { throw MusicError.network("bad address") }
        do {
            return try SubsonicReply.envelope(try await http.getObject(url))
        } catch let e as MusicError {
            throw e
        } catch {
            throw MusicError.network("could not reach the server")
        }
    }

    /// Runs one read on every server at the same time and joins the rows in server order. It fails only when every server failed.
    private func everywhere<T: Sendable>(_ body: @escaping @Sendable (SubsonicSession, SubsonicMapper) async throws -> [T]) async throws -> [T] {
        let all = try requireSessions()
        var results = [[T]?](repeating: nil, count: all.count)
        var firstError: Error?
        await withTaskGroup(of: (Int, [T]?, Error?).self) { group in
            for (i, s) in all.enumerated() {
                group.addTask {
                    do { return (i, try await body(s, SubsonicMapper(session: s)), nil) } catch { return (i, nil, error) }
                }
            }
            for await (i, rows, err) in group {
                results[i] = rows
                if let err, firstError == nil { firstError = err }
            }
        }
        if results.allSatisfy({ $0 == nil }), let e = firstError { throw e }
        return results.compactMap { $0 }.flatMap { $0 }
    }

    /// Offset and size from any pagination shape; a missing value means the first page of 30. Servers cap a page at 500.
    static func window(_ p: MusicPagination?) -> (offset: Int, limit: Int) {
        func clamp(_ n: Int) -> Int { min(max(n, 1), 500) }
        switch p {
        case .offset(let o, let l): return (max(o, 0), clamp(l))
        case .page(let n, let s): return (max(n - 1, 0) * clamp(s), clamp(s))
        case .cursor(let c, let l): return (max(Int(c ?? "") ?? 0, 0), clamp(l))
        case .continuation(let c): return (max(Int(c ?? "") ?? 0, 0), 30)
        case nil: return (0, 30)
        }
    }

    /// One page asked of every server with the same window. There is a next page while any server filled its share.
    private func paged<T: Sendable>(_ page: MusicPagination?, _ fetch: @escaping @Sendable (SubsonicSession, SubsonicMapper, Int, Int) async throws -> (items: [T], raw: Int)) async throws -> MusicPage<T> {
        let (offset, limit) = Self.window(page)
        let counts = Locked<[Int]>([])
        let items = try await everywhere { s, m in
            let r = try await fetch(s, m, offset, limit)
            counts.withLock { $0.append(r.raw) }
            return r.items
        }
        return MusicPage(items: items, next: counts.value.contains { $0 >= limit } ? .offset(offset: offset + limit, limit: limit) : nil)
    }

    /// A whole listing the server cannot page, cut to the asked window here.
    private func sliced<T: Sendable>(_ all: [T], _ page: MusicPagination?) -> MusicPage<T> {
        let (offset, limit) = Self.window(page)
        return MusicPage(items: Array(all.dropFirst(offset).prefix(limit)), totalCount: all.count, next: offset + limit < all.count ? .offset(offset: offset + limit, limit: limit) : nil)
    }

    // MARK: search

    private func search<T: Sendable>(_ query: String, kind: String, _ page: MusicPagination?, _ map: @escaping @Sendable (SubsonicMapper, [String: Any]) -> T?) async throws -> MusicPage<T> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }
        return try await paged(page) { s, m, offset, limit in
            var items: [(String, String)] = [("query", q)]
            for k in ["artist", "album", "song"] {
                items.append((k + "Count", k == kind ? String(limit) : "0"))
                if k == kind { items.append((k + "Offset", String(offset))) }
            }
            let rows = SubsonicRows.rows(try await call(s, "search3", items), "searchResult3", kind)
            return (rows.compactMap { map(m, $0) }, rows.count)
        }
    }

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { try await search(query, kind: "song", page) { $0.song($1) } }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> { try await search(query, kind: "artist", page) { $0.artist($1) } }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> { try await search(query, kind: "album", page) { $0.album($1) } }

    /// The server has no playlist search, so the person's playlists are filtered by name here.
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        let needle = MusicText.normalize(query)
        guard !needle.isEmpty else { return .empty }
        let all = try await everywhere { s, m in
            SubsonicRows.rows(try await call(s, "getPlaylists"), "playlists", "playlist").compactMap(m.playlist)
        }
        return sliced(all.filter { MusicText.normalize($0.name).contains(needle) }, page)
    }

    // MARK: browse

    private func albumList(_ type: String, size: Int, offset: Int = 0, genre: String? = nil) async throws -> [MusicAlbum] {
        try await everywhere { s, m in
            var items: [(String, String)] = [("type", type), ("size", String(size)), ("offset", String(offset))]
            if let genre { items.append(("genre", genre)) }
            return SubsonicRows.rows(try await call(s, "getAlbumList2", items), "albumList2", "album").compactMap(m.album)
        }
    }

    func featured() async throws -> [MusicBrowseSection] {
        _ = try requireSessions()
        var out: [MusicBrowseSection] = []
        for (type, title) in [("newest", "Recently added"), ("recent", "Recently played"), ("frequent", "Most played"), ("alphabeticalByName", "Albums A to Z")] {
            let albums = (try? await albumList(type, size: 12)) ?? []
            if !albums.isEmpty { out.append(MusicBrowseSection(id: "subsonic-" + type, title: title, items: albums.map { .album($0) })) }
        }
        let starred = (try? await starredSongs()) ?? []
        if !starred.isEmpty { out.append(MusicBrowseSection(id: "subsonic-starred", title: "Starred songs", items: starred.prefix(25).map { .track($0) })) }
        if out.isEmpty { throw MusicError.network("your server returned nothing to browse") }
        return out
    }

    func genres() async throws -> [MusicBrowseGenre] {
        let names = try await everywhere { s, _ in
            SubsonicRows.rows(try await call(s, "getGenres"), "genres", "genre").compactMap { $0.str("value") }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }.sorted().map { MusicBrowseGenre(id: $0, name: $0) }
    }

    func browse(genreID: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseSection> {
        let (offset, limit) = Self.window(page)
        let albums = try await albumList("byGenre", size: limit, offset: offset, genre: genreID)
        let section = MusicBrowseSection(id: "subsonic-genre-" + genreID, title: genreID, items: albums.map { .album($0) })
        return MusicPage(items: albums.isEmpty ? [] : [section], next: albums.count >= limit ? .offset(offset: offset + limit, limit: limit) : nil)
    }

    // MARK: details

    func track(id: String) async throws -> MusicTrack {
        let (s, raw) = try resolve(id)
        guard let d = try await call(s, "getSong", [("id", raw)]).dict("song"), let t = SubsonicMapper(session: s).song(d) else { throw MusicError.notFound }
        return t
    }

    /// Songs like the first seed that this server can place: the track version of the call, then the older one.
    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack] {
        guard let seed = seedTrackIDs.first else { return [] }
        let (s, raw) = try resolve(seed)
        let m = SubsonicMapper(session: s), count = String(min(max(limit, 1), 100))
        var rows = SubsonicRows.rows(try await call(s, "getSimilarSongs2", [("id", raw), ("count", count)]), "similarSongs2", "song")
        if rows.isEmpty { rows = SubsonicRows.rows(try await call(s, "getSimilarSongs", [("id", raw), ("count", count)]), "similarSongs", "song") }
        return rows.compactMap(m.song).filter { $0.id != seed }
    }

    func album(id: String) async throws -> MusicAlbum {
        let (s, raw) = try resolve(id)
        guard let d = try await call(s, "getAlbum", [("id", raw)]).dict("album"), let a = SubsonicMapper(session: s).album(d) else { throw MusicError.notFound }
        return a
    }

    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let (s, raw) = try resolve(id)
        let m = SubsonicMapper(session: s)
        let d = try await call(s, "getAlbum", [("id", raw)]).dict("album") ?? [:]
        return sliced(d.array("song").compactMap(m.song), page)
    }

    func artist(id: String) async throws -> MusicArtist {
        let (s, raw) = try resolve(id)
        let m = SubsonicMapper(session: s)
        guard let d = try await call(s, "getArtist", [("id", raw)]).dict("artist"), var a = m.artist(d) else { throw MusicError.notFound }
        if let bio = try? await call(s, "getArtistInfo2", [("id", raw)]).dict("artistInfo2")?.str("biography") {
            let plain = Self.plainText(bio)
            if !plain.isEmpty { a.bio = plain }
        }
        return a
    }

    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        let (s, raw) = try resolve(id)
        guard let name = try await call(s, "getArtist", [("id", raw)]).dict("artist")?.str("name") else { throw MusicError.notFound }
        let m = SubsonicMapper(session: s)
        return SubsonicRows.rows(try await call(s, "getTopSongs", [("artist", name), ("count", "20")]), "topSongs", "song").compactMap(m.song)
    }

    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let (s, raw) = try resolve(id)
        let m = SubsonicMapper(session: s)
        let d = try await call(s, "getArtist", [("id", raw)]).dict("artist") ?? [:]
        let albums = d.array("album").compactMap(m.album).sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        return sliced(albums, page)
    }

    func relatedArtists(id: String) async throws -> [MusicArtist] {
        let (s, raw) = try resolve(id)
        let m = SubsonicMapper(session: s)
        let rows = SubsonicRows.rows(try await call(s, "getArtistInfo2", [("id", raw), ("count", "10")]), "artistInfo2", "similarArtist")
        return rows.compactMap(m.artist)
    }

    func playlist(id: String) async throws -> MusicPlaylist {
        let (s, raw) = try resolve(id)
        guard let d = try await call(s, "getPlaylist", [("id", raw)]).dict("playlist"), let p = SubsonicMapper(session: s).playlist(d) else { throw MusicError.notFound }
        return p
    }

    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let (s, raw) = try resolve(id)
        let m = SubsonicMapper(session: s)
        let d = try await call(s, "getPlaylist", [("id", raw)]).dict("playlist") ?? [:]
        return sliced(d.array("entry").compactMap(m.song), page)
    }

    /// Biographies come with small links in angle brackets; only the words are kept.
    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: library and stars

    private func starredSongs() async throws -> [MusicTrack] {
        try await everywhere { s, m in SubsonicRows.rows(try await call(s, "getStarred2"), "starred2", "song").compactMap(m.song) }
    }

    /// The library is what the server holds; the stars are the favourites drawn on top of it. Songs here are the starred ones.
    func savedTracks(page: MusicPagination?) async throws -> MusicPage<MusicTrack> { sliced(try await starredSongs(), page) }

    func savedAlbums(page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        try await paged(page) { s, m, offset, limit in
            let rows = SubsonicRows.rows(try await call(s, "getAlbumList2", [("type", "alphabeticalByName"), ("size", String(limit)), ("offset", String(offset))]), "albumList2", "album")
            return (rows.compactMap(m.album), rows.count)
        }
    }

    func savedArtists(page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        let all = try await everywhere { s, m in SubsonicRows.indexedArtists(try await call(s, "getArtists")).compactMap(m.artist) }
        return sliced(all, page)
    }

    func savedPlaylists(page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        let all = try await everywhere { s, m in SubsonicRows.rows(try await call(s, "getPlaylists"), "playlists", "playlist").compactMap(m.playlist) }
        return sliced(all, page)
    }

    /// Stars or unstars songs, one call per server that owns some of them.
    func setSaved(_ saved: Bool, trackIDs: [String]) async throws {
        for (s, raws) in try group(trackIDs) {
            _ = try await call(s, saved ? "star" : "unstar", raws.map { ("id", $0) })
        }
    }

    func isSaved(trackIDs: [String]) async throws -> [Bool] {
        let all = try requireSessions()
        var starred = Set<String>()
        for s in all where trackIDs.contains(where: { SubsonicID.split($0)?.server == s.serverID }) {
            for d in SubsonicRows.rows(try await call(s, "getStarred2"), "starred2", "song") { if let id = d.str("id") { starred.insert(SubsonicID.make(s.serverID, id)) } }
        }
        return trackIDs.map { starred.contains($0) }
    }

    private func group(_ ids: [String]) throws -> [(SubsonicSession, [String])] {
        let all = try requireSessions()
        return all.compactMap { s in
            let raws = ids.compactMap { SubsonicID.split($0) }.filter { $0.server == s.serverID }.map(\.raw)
            return raws.isEmpty ? nil : (s, raws)
        }
    }

    // MARK: playlists the person edits

    /// A new playlist on one server (the first, or the one the songs belong to) holding the given songs of that server.
    @discardableResult
    func createPlaylist(name: String, tracks: [MusicTrack] = []) async throws -> MusicPlaylist? {
        let all = try requireSessions()
        let target = tracks.compactMap { SubsonicID.split($0.id)?.server }.first.flatMap { sid in all.first { $0.serverID == sid } } ?? all[0]
        let songs = tracks.compactMap { SubsonicID.split($0.id) }.filter { $0.server == target.serverID }.map { ("songId", $0.raw) }
        let root = try await call(target, "createPlaylist", [("name", name)] + songs)
        return root.dict("playlist").flatMap(SubsonicMapper(session: target).playlist)
    }

    func renamePlaylist(id: String, name: String) async throws {
        let (s, raw) = try resolve(id)
        _ = try await call(s, "updatePlaylist", [("playlistId", raw), ("name", name)])
    }

    func addTracks(_ tracks: [MusicTrack], toPlaylist id: String) async throws {
        let (s, raw) = try resolve(id)
        let songs = tracks.compactMap { SubsonicID.split($0.id) }.filter { $0.server == s.serverID }.map { ("songIdToAdd", $0.raw) }
        guard !songs.isEmpty else { return }
        _ = try await call(s, "updatePlaylist", [("playlistId", raw)] + songs)
    }

    /// Takes out the entries at these positions (counted from 0 in the order the playlist lists them).
    func removeEntries(at positions: [Int], fromPlaylist id: String) async throws {
        let (s, raw) = try resolve(id)
        guard !positions.isEmpty else { return }
        _ = try await call(s, "updatePlaylist", [("playlistId", raw)] + positions.sorted().map { ("songIndexToRemove", String($0)) })
    }

    func deletePlaylist(id: String) async throws {
        let (s, raw) = try resolve(id)
        _ = try await call(s, "deletePlaylist", [("id", raw)])
    }

    // MARK: audio

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if track.providerID == Self.providerID {
            return [Self.source(from: track, confidence: 1)]
        }
        // A song from another source may also be in the person's own library: look for it by title and artist.
        let query = ([track.title] + track.artists.prefix(1).map(\.name)).joined(separator: " ")
        let found = (try? await searchTracks(query, page: .offset(offset: 0, limit: 10)).items) ?? []
        return found.compactMap { c -> MusicAudioSource? in
            let score = Self.matchScore(track, c)
            return score >= 0.7 ? Self.source(from: c, confidence: score) : nil
        }.sorted { $0.confidence > $1.confidence }
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        let (session, raw) = try resolve(source.id)
        let d = try await call(session, "getSong", [("id", raw)]).dict("song") ?? [:]
        guard let stream = SubsonicMapper(session: session).stream(for: d, raw: raw, transcode: transcodeSetting()) else { throw MusicError.noPlayableSource(source.title) }
        return [stream]
    }

    /// The loudness the server reports for a song (its ReplayGain, track gain first), in LUFS, or nil when it reports none.
    func loudnessLUFS(for track: MusicTrack) async -> Double? {
        guard track.providerID == Self.providerID, let (s, raw) = try? resolve(track.id) else { return nil }
        let d = try? await call(s, "getSong", [("id", raw)]).dict("song")
        return SubsonicReplayGain(d?.dict("replayGain"))?.lufs
    }

    private static func source(from t: MusicTrack, confidence: Float) -> MusicAudioSource {
        MusicAudioSource(id: t.id, providerID: providerID, title: t.title, artist: t.artists.first?.name, album: t.album?.title,
                         durationMs: t.durationMs > 0 ? t.durationMs : nil, thumbnails: t.thumbnails, externalURL: nil, confidence: confidence, streams: nil)
    }

    /// 0...1 closeness of a library song to the wanted one: title first, then artist, then length. A weak title never passes.
    static func matchScore(_ want: MusicTrack, _ got: MusicTrack) -> Float {
        let title = MusicTextMatch.similarity(MusicTextMatch.coreTokens(want.title), MusicTextMatch.coreTokens(got.title))
        guard title >= 0.8 else { return 0 }
        let artist = MusicTextMatch.similarity(MusicTextMatch.tokens(MusicTextMatch.normalize(want.artistLine)), MusicTextMatch.tokens(MusicTextMatch.normalize(got.artistLine)))
        let length = MusicTextMatch.durationScore(want.durationMs, got.durationMs > 0 ? got.durationMs : nil)
        return min(1, 0.55 * title + 0.3 * artist + 0.15 * length)
    }

    // MARK: play reporting

    /// A finished listen, with the time it started in milliseconds. Only songs of this source are reported.
    func scrobble(_ s: MusicScrobble) async throws {
        guard s.track.providerID == Self.providerID else { return }
        let (session, raw) = try resolve(s.track.id)
        _ = try await call(session, "scrobble", [("id", raw), ("time", String(Int64(s.timestamp.timeIntervalSince1970 * 1000))), ("submission", "true")])
    }

    func nowPlaying(_ track: MusicTrack) async {
        guard track.providerID == Self.providerID, let (session, raw) = try? resolve(track.id) else { return }
        _ = try? await call(session, "scrobble", [("id", raw), ("submission", "false")])
    }
}
