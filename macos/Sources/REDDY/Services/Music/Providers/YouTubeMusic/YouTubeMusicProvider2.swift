import Foundation

// The full YouTube Music provider: home, explore, moods, search, artist, album, playlist, radio, podcasts, lyrics and audio.
// Guest mode is complete. An account layer plugs in through `YouTubeMusicSession`; the library and history calls below throw
// `notSignedIn` until that session carries a login cookie.

/// Parsed pages kept for 5 minutes, at most 80 of them; the oldest insertion is dropped first and a refreshed key moves to the back.
final class YouTubeMusicPageCache: @unchecked Sendable {
    private struct Entry { var value: any Sendable; var at: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    let ttl: TimeInterval
    let capacity: Int
    private let now: @Sendable () -> Date

    init(ttl: TimeInterval = 300, capacity: Int = 80, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl; self.capacity = capacity; self.now = now
    }

    func get<T: Sendable>(_ key: String, as: T.Type = T.self) -> T? {
        lock.withLock {
            guard let e = entries[key] else { return nil }
            if now().timeIntervalSince(e.at) > ttl { entries[key] = nil; order.removeAll { $0 == key }; return nil }
            return e.value as? T
        }
    }

    func set(_ key: String, _ value: some Sendable) {
        lock.withLock {
            order.removeAll { $0 == key }
            order.append(key)
            entries[key] = Entry(value: value, at: now())
            while order.count > capacity, let oldest = order.first { order.removeFirst(); entries[oldest] = nil }
        }
    }

    /// Drops the key and every key that starts with `prefix:` (a playlist is cached once per variant).
    func invalidate(prefix: String) {
        lock.withLock {
            let gone = order.filter { $0 == prefix || $0.hasPrefix(prefix + ":") }
            for k in gone { entries[k] = nil }
            order.removeAll { gone.contains($0) }
        }
    }

    /// Browse data is per account, so everything goes on sign-in, sign-out and account or channel switches.
    func clear() { lock.withLock { entries.removeAll(); order.removeAll() } }
    var count: Int { lock.withLock { entries.count } }
}

struct YouTubeMusicFullProvider: MusicMetadataProvider, MusicAudioProvider, MusicLyricsProvider {
    static let providerID = YTM.providerID

    let client: YouTubeMusicClient
    let resolver: YouTubeMusicStreamResolver
    let pageCache: YouTubeMusicPageCache
    private let paging = YTMPagingState()
    private let quality: @Sendable () -> MusicQuality

    init(http: MusicHTTP = MusicHTTP(), session: YouTubeMusicSession = GuestYouTubeMusicSession(), locale: YTMLocale = YTMLocale(),
         clients: [YTMClientKey: YTMClientIdentity] = YTMClientTable.builtIn, poToken: YouTubePoTokenSource? = nil,
         disabledClients: Set<YTMClientKey> = [], solver: YTMStreamURLSolver? = nil, cache: YouTubeMusicPageCache = YouTubeMusicPageCache(),
         quality: @escaping @Sendable () -> MusicQuality = { .high }) {
        let c = YouTubeMusicClient(http: http, session: session, locale: locale, clients: clients)
        self.client = c
        self.resolver = YouTubeMusicStreamResolver(client: c, solver: solver, poToken: poToken, disabledClients: disabledClients)
        self.pageCache = cache
        self.quality = quality
    }

    /// Test and integration seam: build from an existing client.
    init(client: YouTubeMusicClient, resolver: YouTubeMusicStreamResolver, cache: YouTubeMusicPageCache = YouTubeMusicPageCache(),
         quality: @escaping @Sendable () -> MusicQuality = { .high }) {
        self.client = client; self.resolver = resolver; self.pageCache = cache; self.quality = quality
    }

    let info = MusicProviderInfo(
        id: YouTubeMusicFullProvider.providerID, name: "YouTube Music",
        summary: "Home, search, artists, albums, playlists, podcasts, lyrics and audio from YouTube Music. No account needed.",
        privacyNote: "Google sees what you search for, which pages you open, which songs you play and your IP address, the same as using YouTube Music in a browser without signing in. Nothing is sent to Google unless this is switched on.",
        homepage: "https://music.youtube.com")
    var capabilities: MusicCapabilities { [.search, .browse, .tracks, .albums, .artists, .playlists, .audio, .lyrics] }

    private func signedInOrThrow() async throws {
        guard await client.isSignedIn else { throw MusicError.notSignedIn("YouTube Music") }
    }

    // MARK: search

    /// A submitted search. It is the only search sent with the account (and so recorded in its history); the per-type calls below are anonymous.
    func search(_ query: String, types: Set<MusicSearchType>) async throws -> [MusicSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if types == [.track] {
            return YTMSearchParser.parseSongs(try await client.search(q, params: YTMSearchFilter.songs.params).root).tracks.map { .track($0) }
        }
        let results = YTMSearchParser.parseMixed(try await client.search(q).root)
        var out: [MusicSearchResult] = []
        for item in results.all {
            switch item {
            case .track(let t) where types.contains(.track): out.append(.track(t))
            case .album(let a) where types.contains(.album): out.append(.album(a))
            case .artist(let a) where types.contains(.artist): out.append(.artist(a))
            case .playlist(let p) where types.contains(.playlist): out.append(.playlist(p))
            default: break
            }
        }
        return out
    }

    /// The structured mixed search (top result, songs, albums, artists, playlists).
    func searchMixed(_ query: String, recordHistory: Bool = true) async throws -> YTMSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return YTMSearchResults() }
        return YTMSearchParser.parseMixed(try await client.search(q, mode: recordHistory ? .normal : .anonymous).root)
    }

    private func filtered(_ query: String, _ filter: YTMSearchFilter, page: MusicPagination?) async throws -> (items: [MusicBrowseItem], next: MusicPagination?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: YTMResponse
        if case .continuation(let t)? = page, let t { root = try await client.searchContinuation(t) }
        else {
            guard !q.isEmpty else { return ([], nil) }
            root = try await client.search(q, params: filter.params, mode: .anonymous)
        }
        let parsed = YTMSearchParser.parseFiltered(root.root)
        return (parsed.items, parsed.continuation.map { .continuation($0) })
    }

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: YTMResponse
        if case .continuation(let t)? = page, let t { root = try await client.searchContinuation(t) }
        else {
            guard !q.isEmpty else { return .empty }
            root = try await client.search(q, params: YTMSearchFilter.songs.params, mode: .anonymous)
        }
        let p = YTMSearchParser.parseSongs(root.root)
        return MusicPage(items: p.tracks, next: p.continuation.map { .continuation($0) })
    }

    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        let r = try await filtered(query, .artists, page: page)
        return MusicPage(items: r.items.compactMap { if case .artist(let a) = $0 { a } else { nil } }, next: r.next)
    }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let r = try await filtered(query, .albums, page: page)
        return MusicPage(items: r.items.compactMap { if case .album(let a) = $0 { a } else { nil } }, next: r.next)
    }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        let r = try await filtered(query, .communityPlaylists, page: page)
        return MusicPage(items: r.items.compactMap { if case .playlist(let p) = $0 { p } else { nil } }, next: r.next)
    }
    /// Podcast shows (as playlists with `MPSP` ids) and episodes (as podcast tracks). Unverified against the live service.
    func searchPodcasts(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseItem> {
        let r = try await filtered(query, .podcasts, page: page)
        return MusicPage(items: r.items, next: r.next)
    }

    /// Typeahead. Always anonymous, needs at least two characters.
    func suggestions(_ input: String) async throws -> YTMSuggestions {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return YTMSuggestions(queries: [], items: []) }
        return YTMSearchParser.parseSuggestions(try await client.suggestions(t).root)
    }

    // MARK: home, explore, moods

    func homePage(chip: YTMChip? = nil) async throws -> YTMHomePage {
        let key = "home:" + (chip?.params ?? "")
        if let c = pageCache.get(key, as: YTMHomePage.self) { return c }
        let page = YTMHomeParser.parseHome(try await client.browse("FEmusic_home", params: chip?.params).root)
        pageCache.set(key, page)
        return page
    }

    func homeContinuation(_ token: String) async throws -> (shelves: [YTMShelf], next: String?) {
        let r = try await client.browseContinuation(token).root
        return (YTMHomeParser.shelves(r, idPrefix: "home-more"), YTMJSON.continuationToken(in: r))
    }

    func featured() async throws -> [MusicBrowseSection] { try await homePage().shelves.map(\.browseSection) }

    /// Explore landing page. Unverified against the live service.
    func explorePage() async throws -> [YTMShelf] {
        if let c = pageCache.get("explore", as: [YTMShelf].self) { return c }
        let s = YTMHomeParser.parseExplore(try await client.browse("FEmusic_explore").root)
        pageCache.set("explore", s)
        return s
    }

    /// Charts page. With a country (an upper-case ISO code such as `IN`) it is that country's chart: its top artists, its video charts and,
    /// for India, the per-language weekly video charts. Checked live without a key; without a country the service picks one itself.
    func chartsPage(country: String? = nil) async throws -> [YTMShelf] {
        let code = country.flatMap { c -> String? in
            let u = c.uppercased()
            return u.count == 2 && u.allSatisfy({ $0.isASCII && $0.isLetter }) ? u : nil
        }
        let key = "charts:" + (code ?? "")
        if let c = pageCache.get(key, as: [YTMShelf].self) { return c }
        let root = try await client.browse("FEmusic_charts", selectedValues: code.map { [$0] }).root
        // YouTube Music charts only some countries. For any other it still answers, with a mix of other countries' lists; that is no chart for this one.
        let supported = YTMHomeParser.chartCountries(root)
        let s = (code != nil && !supported.isEmpty && !supported.contains(code!)) ? [] : YTMHomeParser.parseExplore(root)
        pageCache.set(key, s)
        return s
    }

    func moodSections() async throws -> [YTMMoodSection] {
        if let c = pageCache.get("moods", as: [YTMMoodSection].self) { return c }
        let s = YTMHomeParser.parseMoods(try await client.browse("FEmusic_moods_and_genres").root)
        pageCache.set("moods", s)
        return s
    }

    func genres() async throws -> [MusicBrowseGenre] {
        var seen = Set<String>()
        return try await moodSections().flatMap(\.tiles).filter { seen.insert($0.params).inserted }.map { MusicBrowseGenre(id: $0.params, name: $0.title) }
    }

    /// A browse id plus params read as a flat grid (mood categories, carousel "More" targets). Not paged.
    func grid(browseID: String, params: String?) async throws -> [MusicBrowseItem] {
        let key = "grid:\(browseID):\(params ?? "")"
        if let c = pageCache.get(key, as: [MusicBrowseItem].self) { return c }
        let items = YTMItems.gridItems(try await client.browse(browseID, params: params).root)
        pageCache.set(key, items)
        return items
    }

    func browse(genreID: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseSection> {
        let items = try await grid(browseID: "FEmusic_moods_and_genres_category", params: genreID)
        return MusicPage(items: items.isEmpty ? [] : [MusicBrowseSection(id: "genre-" + genreID, title: "Playlists", items: items)])
    }

    // MARK: tracks and radio

    func track(id: String) async throws -> MusicTrack {
        let page = YTMPageParser.parseNext(try await client.next(videoID: id).root)
        guard let t = page.tracks.first(where: { $0.id == id }) ?? page.tracks.first else { throw MusicError.notFound }
        return t
    }

    /// Radio from a song or a playlist seed. A dead radio (only the seed comes back) escalates once through the automix id.
    func radio(videoID: String, playlistID: String? = nil) async throws -> YTMNextPage {
        let seed = playlistID ?? "RDAMVM" + videoID
        let first = YTMPageParser.parseNext(try await client.next(videoID: videoID, playlistID: seed).root)
        if first.tracks.count > 1 { return first }
        let bare = YTMPageParser.parseNext(try await client.next(videoID: videoID).root)
        if let automix = bare.automixPlaylistID {
            let viaAutomix = YTMPageParser.parseNext(try await client.next(videoID: videoID, playlistID: automix).root)
            if viaAutomix.tracks.count > 1 { return viaAutomix }
        }
        if bare.tracks.count > 1 { return bare }
        throw MusicError.notFound
    }

    /// The next window of an endless queue: `next` from the last played video with the pinned seed; rows already queued are skipped; at most 20.
    func extendRadio(lastVideoID: String, seed: String?, alreadyQueued: Set<String>) async throws -> [MusicTrack] {
        let r = YTMPageParser.parseNext(try await client.next(videoID: lastVideoID, playlistID: seed ?? "RDAMVM" + lastVideoID).root)
        return Array(r.tracks.filter { !alreadyQueued.contains($0.id) }.prefix(20))
    }

    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack] {
        guard let seed = seedTrackIDs.first else { return [] }
        let r = try await radio(videoID: seed)
        return Array(r.tracks.filter { !seedTrackIDs.contains($0.id) }.prefix(max(0, limit)))
    }

    // MARK: albums

    func albumPage(id: String) async throws -> YTMAlbumPage {
        let key = "album:" + id
        if let c = pageCache.get(key, as: YTMAlbumPage.self) { return c }
        var page = YTMPageParser.parseAlbum(try await client.browse(id).root, browseID: id)
        if page.rows.contains(where: \.isVideo), let olak = page.audioPlaylistID,
           let audio = try? await client.browse("VL" + olak).root {
            let audioRows = YTMItems.songRows(YTMJSON.first("musicPlaylistShelfRenderer", in: audio) ?? audio, shallow: true)
            if audioRows.count == page.rows.count {
                for i in page.rows.indices where page.rows[i].isVideo {
                    page.rows[i].track.id = audioRows[i].track.id
                    page.rows[i].track.videoID = audioRows[i].track.id
                    page.rows[i].track.durationMs = audioRows[i].track.durationMs
                    page.rows[i].isVideo = false
                    page.rows[i].track.isVideo = false
                }
            }
        }
        guard !page.album.title.isEmpty || !page.rows.isEmpty else { throw MusicError.notFound }
        pageCache.set(key, page)
        return page
    }

    func album(id: String) async throws -> MusicAlbum { try await albumPage(id: id).album }
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { MusicPage(items: try await albumPage(id: id).tracks) }

    // MARK: artists

    /// Ids that are not channel ids (artists parsed from a text-only byline) are looked up by name.
    private func channelID(_ id: String) async throws -> String {
        if id.hasPrefix("UC") { return id }
        let r = try await searchArtists(id, page: nil)
        guard let a = r.items.first else { throw MusicError.notFound }
        return a.id
    }

    func artistPage(id: String) async throws -> YTMArtistPage {
        let cid = try await channelID(id)
        let key = "artist:" + cid
        if let c = pageCache.get(key, as: YTMArtistPage.self) { return c }
        var page = YTMPageParser.parseArtist(try await client.browse(cid).root, browseID: cid)
        guard !page.artist.name.isEmpty else { throw MusicError.notFound }
        // The artist page lists top songs without lengths; the full top-songs playlist has them.
        if page.topTracks.contains(where: { $0.durationMs <= 0 }), let top = page.topSongsPlaylistID,
           let full = try? await client.browse(YTMPageParser.browseID(forPlaylist: top)).root {
            let lengths = Dictionary(YTMPageParser.parsePlaylist(full, playlistID: top).tracks.map { ($0.id, $0.durationMs) }, uniquingKeysWith: { a, _ in a })
            for i in page.topTracks.indices where page.topTracks[i].durationMs <= 0 { page.topTracks[i].durationMs = lengths[page.topTracks[i].id] ?? 0 }
        }
        pageCache.set(key, page)
        return page
    }

    func artist(id: String) async throws -> MusicArtist { try await artistPage(id: id).artist }
    func artistTopTracks(id: String) async throws -> [MusicTrack] { try await artistPage(id: id).topTracks }

    func relatedArtists(id: String) async throws -> [MusicArtist] {
        try await artistPage(id: id).shelves.flatMap(\.items).compactMap { if case .artist(let a) = $0 { a } else { nil } }
    }

    /// Albums and singles. A shelf with a "More" target is read whole through that target (the full discography comes back in one reply).
    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let shelves = try await artistPage(id: id).shelves.filter { s in s.items.contains { if case .album = $0 { true } else { false } } }
        var lists = [[MusicBrowseItem]](repeating: [], count: shelves.count)
        await withTaskGroup(of: (Int, [MusicBrowseItem]).self) { g in
            for (i, s) in shelves.enumerated() {
                g.addTask {
                    if let more = s.moreBrowseID, let full = try? await self.grid(browseID: more, params: s.moreParams), !full.isEmpty { return (i, full) }
                    return (i, s.items)
                }
            }
            for await (i, items) in g { lists[i] = items }
        }
        var seen = Set<String>()
        let albums = lists.flatMap { $0 }.compactMap { item -> MusicAlbum? in if case .album(let a) = item, seen.insert(a.id).inserted { a } else { nil } }
        return MusicPage(items: albums)
    }

    func artistOverview(id: String) async throws -> MusicArtistOverview {
        let p = try await artistPage(id: id)
        let albums = (try? await artistAlbums(id: id, page: nil))?.items ?? []
        let related = p.shelves.flatMap(\.items).compactMap { if case .artist(let a) = $0 { a } else { nil } }
        return MusicArtistOverview(artist: p.artist, topTracks: p.topTracks, albums: albums, related: related)
    }

    // MARK: playlists and podcasts

    func playlistPage(id: String) async throws -> YTMPlaylistPage {
        let key = "playlist:" + id
        if let c = pageCache.get(key, as: YTMPlaylistPage.self) { return c }
        var page = YTMPageParser.parsePlaylist(try await client.browse(YTMPageParser.browseID(forPlaylist: id)).root, playlistID: id)
        // A podcast opened by its playlist id returns episodes without a header: ask for the show page, which has one.
        if !page.hasHeader, page.rows.contains(where: \.isEpisode), !id.hasPrefix("MPSP") {
            let show = "MPSP" + (id.hasPrefix("VL") ? String(id.dropFirst(2)) : id)
            if let r = try? await client.browse(show).root { page = YTMPageParser.parsePlaylist(r, playlistID: show) }
        }
        pageCache.set(key, page)
        return page
    }

    func playlist(id: String) async throws -> MusicPlaylist { try await playlistPage(id: id).playlist }

    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        if case .continuation(let t)? = page, let t {
            let p = YTMPageParser.parsePlaylistContinuation(try await client.browseContinuation(t).root)
            return MusicPage(items: p.rows.map(\.track), next: p.next == t ? nil : p.next.map { .continuation($0) })
        }
        let p = try await playlistPage(id: id)
        return MusicPage(items: p.tracks, totalCount: p.playlist.trackCount, next: p.continuation.map { .continuation($0) })
    }

    /// Every track of a playlist, using parallel token paging when the playlist is long.
    func allPlaylistTracks(id: String) async throws -> [MusicTrack] {
        let p = try await playlistPage(id: id)
        let rows = try await client.remainingPlaylistRows(firstRows: p.rows, token: p.continuation, total: p.playlist.trackCount, state: paging)
        return rows.map(\.track)
    }

    func podcastShow(id: String) async throws -> YTMPlaylistPage { try await playlistPage(id: id.hasPrefix("MPSP") ? id : "MPSP" + id) }

    // MARK: library and history (account only)

    func savedTracks(page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        try await signedInOrThrow()
        return try await playlistTracks(id: "FEmusic_liked_videos", page: page)
    }
    func savedAlbums(page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        MusicPage(items: try await client.libraryGrid("FEmusic_liked_albums").compactMap { if case .album(let a) = $0 { a } else { nil } })
    }
    func savedArtists(page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        MusicPage(items: try await client.libraryGrid("FEmusic_library_corpus_track_artists").compactMap { if case .artist(let a) = $0 { a } else { nil } })
    }
    func savedPlaylists(page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> {
        MusicPage(items: try await client.libraryGrid("FEmusic_liked_playlists").compactMap { if case .playlist(let p) = $0 { p } else { nil } })
    }
    func history() async throws -> [YTMHistoryBucket] {
        try await signedInOrThrow()
        return YTMPageParser.parseHistory(try await client.browse("FEmusic_history").root)
    }

    // MARK: lyrics

    func lyrics(videoID: String) async throws -> MusicLyrics? {
        let next = YTMPageParser.parseNext(try await client.next(videoID: videoID).root)
        guard let browseID = next.lyricsBrowseID else { return nil }
        if let timed = try? await client.browse(browseID, mode: .anonymous, client: .iosMusic) {
            let lines = YTMPageParser.parseTimedLyrics(timed.root)
            if !lines.isEmpty { return MusicLyrics(synced: lines, plain: lines.map(\.text).joined(separator: "\n"), sourceName: "YouTube Music") }
        }
        guard let plain = YTMPageParser.parsePlainLyrics(try await client.browse(browseID).root) else { return nil }
        return MusicLyrics(synced: nil, plain: plain.text, sourceName: plain.source)
    }

    func lyrics(for track: MusicTrack) async throws -> MusicLyrics? {
        guard let vid = track.videoID ?? (track.providerID == YTM.providerID ? track.id : nil) else { return nil }
        return try await lyrics(videoID: vid)
    }

    // MARK: audio

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if let vid = track.videoID ?? (track.providerID == YTM.providerID ? track.id : nil) {
            return [MusicAudioSource(id: vid, providerID: YTM.providerID, title: track.title, artist: track.artistLine, album: track.album?.title,
                                     durationMs: track.durationMs > 0 ? track.durationMs : nil, thumbnails: track.thumbnails,
                                     externalURL: "https://music.youtube.com/watch?v=\(vid)", confidence: 1.0)]
        }
        // While YouTube is refusing this connection as a bot, a guest's searches are not sent either (a signed-in account is never held back).
        if YouTubeBotGate.shared.isClosed, !(await client.isSignedIn) { throw MusicError.rateLimited(retryAfter: YouTubeBotGate.shared.secondsLeft) }
        let songs = try await searchTracks(YouTubeAudio.query(for: track), page: nil).items
        let candidates = songs.map {
            YouTubeCandidate(videoID: $0.id, title: $0.title, channel: $0.artists.first.map { a in a.name + " - Topic" },
                             durationMs: $0.durationMs > 0 ? $0.durationMs : nil, thumbnail: $0.thumbnails.first?.url)
        }
        var ranked = YouTubeAudio.rank(candidates, for: track, providerID: Self.providerID)
        for i in ranked.indices { ranked[i].artist = songs.first { $0.id == ranked[i].id }?.artistLine ?? ranked[i].artist }
        return ranked
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        let r = try await resolver.resolve(videoID: source.id, title: source.title, quality: quality(),
                                           durationSeconds: Double(source.durationMs ?? 0) / 1000)
        return r.streams
    }

    /// Call when playback of a resolved URL fails with 403 so the next resolve skips the web client's answer for 30 minutes.
    func reportPlaybackFailure(videoID: String) async { await resolver.reportPlaybackFailure(videoID: videoID) }

    func clearCaches() { pageCache.clear() }
}

extension YouTubeMusicFullProvider: MusicStreamEvicting {
    /// A stream that failed in playback is dropped from the resolver's address cache, so the retry asks YouTube again.
    func evictStreams(for source: MusicAudioSource) async { await resolver.invalidate(videoID: source.id) }
}
