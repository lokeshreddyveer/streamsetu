import Foundation

/// SoundCloud through its public web interface: search, uploads, sets, profiles and full length audio, with no account. It is unofficial and can
/// stop working when SoundCloud changes its site, so every failure is calm (an empty list or a skipped song) and logged. Uploads that cannot be
/// played in full (previews, blocked, protected) are left out of lists and skipped quietly when played.
struct SoundCloudProvider: MusicMetadataProvider, MusicAudioProvider {
    static let providerID = "soundcloud"
    let client: SoundCloudClient
    let extras: SoundCloudExtras

    init(client: SoundCloudClient = .shared, extras: SoundCloudExtras = .shared) {
        self.client = client
        self.extras = extras
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: Self.providerID, name: "SoundCloud", summary: "Mixes, remixes and independent uploads. No account needed.",
            privacyNote: "Search words and the ids of tracks you open are sent to SoundCloud, together with your IP address. This uses SoundCloud's public web interface, which is unofficial.",
            homepage: "https://soundcloud.com")
    }
    var capabilities: MusicCapabilities { [.search, .tracks, .albums, .artists, .playlists, .audio] }

    // MARK: paging

    /// Offset, size and (for a follow-on page) the address SoundCloud gave for it.
    static func window(_ p: MusicPagination?) -> (offset: Int, limit: Int, cursor: String?) {
        func clamp(_ n: Int) -> Int { min(max(n, 1), 50) }
        switch p {
        case .offset(let o, let l): return (max(o, 0), clamp(l), nil)
        case .page(let n, let s): return (max(n - 1, 0) * clamp(s), clamp(s), nil)
        case .cursor(let c, let l):
            if let c, c.hasPrefix("http") { return (0, clamp(l), c) }
            return (max(Int(c ?? "") ?? 0, 0), clamp(l), nil)
        case .continuation(let c): return (max(Int(c ?? "") ?? 0, 0), 30, nil)
        case nil: return (0, 30, nil)
        }
    }

    func fetchRows(_ path: String, _ query: [String: String] = [:], page: MusicPagination?) async throws -> (rows: [[String: Any]], next: MusicPagination?) {
        let w = Self.window(page)
        let data: Data
        if let c = w.cursor, let u = URL(string: c) {
            data = try await client.data(url: u)
        } else {
            var q = query
            q["limit"] = String(w.limit); q["linked_partitioning"] = "1"
            if w.offset > 0 { q["offset"] = String(w.offset) }
            data = try await client.data(path: path, query: q)
        }
        guard let obj = SoundCloudJSON.any(data) else { throw MusicError.network("unexpected reply") }
        return (SoundCloudJSON.rows(obj), SoundCloudJSON.nextHref(obj).map { MusicPagination.cursor($0, limit: w.limit) })
    }

    /// Maps tracks, remembers their full replies, notes which cannot be played and (for lists) leaves those out.
    func mapped(_ list: [SCTrack], dropUnplayable: Bool) async -> [MusicTrack] {
        var out: [MusicTrack] = []
        for t in list {
            let a = SoundCloudAvailability.of(t)
            if !t.isStub {
                await extras.remember(t)
                SoundCloudAvailabilityBook.shared.note(trackID: t.id, a)
            }
            if dropUnplayable, !a.isPlayable {
                MusicDebugLog.log("soundcloud", "left out track \(t.id): \(a)")
                continue
            }
            if let m = SoundCloudMapping.track(t) { out.append(m) }
        }
        return out
    }

    // MARK: search

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let r = try await fetchRows("search/tracks", ["q": query], page: page)
        return MusicPage(items: await mapped(r.rows.compactMap { SoundCloudJSON.track($0) }, dropUnplayable: true), next: r.next)
    }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        let r = try await fetchRows("search/users", ["q": query], page: page)
        return MusicPage(items: r.rows.compactMap { SoundCloudJSON.user($0) }.map(SoundCloudMapping.artist), next: r.next)
    }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        let r = try await fetchRows("search/playlists_without_albums", ["q": query], page: page)
        return MusicPage(items: r.rows.compactMap { SoundCloudJSON.playlist($0) }.map(SoundCloudMapping.playlist), next: r.next)
    }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let r = try await fetchRows("search/albums", ["q": query], page: page)
        return MusicPage(items: r.rows.compactMap { SoundCloudJSON.playlist($0) }.map(SoundCloudMapping.album), next: r.next)
    }

    // MARK: details

    /// A pasted soundcloud.com address becomes the real item through SoundCloud's resolve call.
    func resolve(token: String) async throws -> SCResolved {
        guard let url = SoundCloudLink.url(forToken: token) else { throw MusicError.notFound }
        let data = try await client.data(path: "resolve", query: ["url": url.absoluteString])
        guard let r = SoundCloudJSON.resolved(SoundCloudJSON.object(data)) else {
            MusicDebugLog.log("soundcloud", "resolve gave nothing readable")
            throw MusicError.notFound
        }
        return r
    }

    func track(id: String) async throws -> MusicTrack {
        let scTrack: SCTrack
        if SoundCloudLink.isToken(id) {
            guard case .track(let t) = try await resolve(token: id) else { throw MusicError.notFound }
            scTrack = t
        } else {
            scTrack = try await extras.track(id: id)
        }
        // A track opened on purpose is shown even when it cannot be played; the player then says why.
        guard let m = (await mapped([scTrack], dropUnplayable: false)).first else { throw MusicError.notFound }
        return m
    }

    func artist(id: String) async throws -> MusicArtist {
        if SoundCloudLink.isToken(id) {
            guard case .user(let u) = try await resolve(token: id) else { throw MusicError.notFound }
            return SoundCloudMapping.artist(u)
        }
        let data = try await client.data(path: "users/\(Self.escape(id))")
        guard let u = SoundCloudJSON.user(SoundCloudJSON.object(data)) else { throw MusicError.notFound }
        return SoundCloudMapping.artist(u)
    }

    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        let r: (rows: [[String: Any]], next: MusicPagination?)
        do { r = try await fetchRows("users/\(Self.escape(id))/toptracks", page: .offset(offset: 0, limit: 20)) }
        catch { r = try await fetchRows("users/\(Self.escape(id))/tracks", page: .offset(offset: 0, limit: 20)) }
        return await mapped(r.rows.compactMap { SoundCloudJSON.track($0) }, dropUnplayable: true)
    }

    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let r = try await fetchRows("users/\(Self.escape(id))/albums", page: page)
        return MusicPage(items: r.rows.compactMap { SoundCloudJSON.playlist($0) }.map(SoundCloudMapping.album), next: r.next)
    }

    private func setReply(_ id: String) async throws -> SCPlaylist {
        if SoundCloudLink.isToken(id) {
            guard case .playlist(let p) = try await resolve(token: id) else { throw MusicError.notFound }
            return p
        }
        let data = try await client.data(path: "playlists/\(Self.escape(id))")
        guard let p = SoundCloudJSON.playlist(SoundCloudJSON.object(data)) else { throw MusicError.notFound }
        return p
    }

    func playlist(id: String) async throws -> MusicPlaylist { SoundCloudMapping.playlist(try await setReply(id)) }
    func album(id: String) async throws -> MusicAlbum { SoundCloudMapping.album(try await setReply(id)) }
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { try await playlistTracks(id: id, page: page) }

    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let p = try await setReply(id)
        let w = Self.window(page)
        let slice = Array(p.tracks.dropFirst(w.offset).prefix(w.limit))
        let full = await hydrate(slice)
        let items = await mapped(full, dropUnplayable: true)
        let total = p.trackCount ?? p.tracks.count
        return MusicPage(items: items, totalCount: total, next: w.offset + w.limit < p.tracks.count ? .offset(offset: w.offset + w.limit, limit: w.limit) : nil)
    }

    /// Playlists list most tracks as bare ids; this fetches them in batches and keeps the order. A batch that fails leaves its tracks out.
    func hydrate(_ list: [SCTrack]) async -> [SCTrack] {
        let missing = list.filter(\.isStub).map(\.id)
        guard !missing.isEmpty else { return list }
        var byID: [String: SCTrack] = [:]
        for chunk in stride(from: 0, to: missing.count, by: 30).map({ Array(missing[$0..<min($0 + 30, missing.count)]) }) {
            guard let data = try? await client.data(path: "tracks", query: ["ids": chunk.joined(separator: ",")]) else {
                MusicDebugLog.log("soundcloud", "could not fetch \(chunk.count) tracks of a set")
                continue
            }
            for row in SoundCloudJSON.rows(SoundCloudJSON.any(data)) { if let t = SoundCloudJSON.track(row) { byID[t.id] = t } }
        }
        return list.compactMap { $0.isStub ? byID[$0.id] : $0 }
    }

    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack] {
        guard let seed = seedTrackIDs.first else { return [] }
        let list = try await relatedTracks(to: seed, limit: limit)
        return Array(list.prefix(max(1, limit)))
    }

    /// SoundCloud's own "related tracks" of an upload, without the ones that cannot be played.
    func relatedTracks(to trackID: String, limit: Int = 30) async throws -> [MusicTrack] {
        let r = try await fetchRows("tracks/\(Self.escape(trackID))/related", page: .offset(offset: 0, limit: limit))
        return await mapped(r.rows.compactMap { SoundCloudJSON.track($0) }, dropUnplayable: true)
    }

    static func escape(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id }

    // MARK: audio

    /// A SoundCloud row is its own source. Songs from other sources are never claimed here: they reach SoundCloud only through the alternatives list.
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        guard track.providerID == Self.providerID else { return [] }
        return [MusicAudioSource(id: track.id, providerID: Self.providerID, title: track.title, artist: track.artistLine, album: nil,
                                 durationMs: track.durationMs > 0 ? track.durationMs : nil, thumbnails: track.thumbnails, externalURL: track.externalURL, confidence: 1)]
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams?.filter({ $0.expiresAt.map { $0 > Date() } ?? true }), !s.isEmpty { return s }
        return try await resolveStreams(trackID: source.id, title: source.title)
    }

    /// Fresh audio addresses for one upload. Throws `noPlayableSource` (never an alarm) when it cannot be played in full.
    func resolveStreams(trackID: String, title: String) async throws -> [MusicStream] {
        var t = try await extras.track(id: trackID)
        for round in 0..<2 {
            let a = SoundCloudAvailability.of(t)
            SoundCloudAvailabilityBook.shared.note(trackID: trackID, a)
            if case .unavailable(let reason) = a {
                MusicDebugLog.log("soundcloud", "track \(trackID) not played: \(reason.rawValue)")
                throw MusicError.noPlayableSource(title)
            }
            let found = try await resolveAddresses(for: t)
            if !found.isEmpty { return found }
            if round == 0 { t = try await extras.track(id: trackID, forceFresh: true) }
        }
        SoundCloudAvailabilityBook.shared.note(trackID: trackID, .unavailable(.resolveFailed))
        MusicDebugLog.log("soundcloud", "track \(trackID): every listed audio address failed")
        throw MusicError.noPlayableSource(title)
    }

    private func resolveAddresses(for t: SCTrack) async throws -> [MusicStream] {
        var out: [MusicStream] = []
        for c in SoundCloudStreams.candidates(from: t.transcodings) {
            guard let u = URL(string: c.url), SoundCloudClient.isTrusted(u) else { continue }
            do {
                let data = try await client.data(url: u, query: t.trackAuthorization.map { ["track_authorization": $0] } ?? [:])
                guard let address = SoundCloudStreams.address(fromReply: data) else {
                    MusicDebugLog.log("soundcloud", "track \(t.id): transcoding answered without an address")
                    continue
                }
                if SoundCloudStreams.isPreviewURL(address) {
                    MusicDebugLog.log("soundcloud", "track \(t.id): preview detected")
                    continue
                }
                out.append(SoundCloudStreams.stream(address: address, from: c))
                if out.count >= 2 { break }
            } catch MusicError.notFound {
                MusicDebugLog.log("soundcloud", "track \(t.id): a listed transcoding is gone (404)")
            } catch MusicError.cancelled {
                throw MusicError.cancelled
            } catch let e as MusicError {
                if case .refused = e { throw e }
                MusicDebugLog.log("soundcloud", "track \(t.id): transcoding failed")
            }
        }
        return out
    }
}
