import Foundation

/// Apple's public iTunes Search and Lookup API: clean, keyless catalogue metadata. It offers no full-length audio, so tracks carry no
/// direct stream and the matcher finds the audio on another provider. The 30 second previews are deliberately left out.
/// Charts come from Apple's public marketing feed, which only names ids; the details are then read through Lookup.
struct ITunesProvider: MusicMetadataProvider {
    static let searchURL = URL(string: "https://itunes.apple.com/search")!
    static let lookupURL = URL(string: "https://itunes.apple.com/lookup")!
    static let chartsHost = "https://rss.marketingtools.apple.com"
    /// Search never serves a result past the 200th, whatever the offset.
    static let maxWindow = 200
    private let http: MusicHTTP
    private let country: @Sendable () -> String?

    /// `country` names the Apple storefront to use (two letters). It defaults to the device region, and a value Apple does not know is ignored.
    init(http: MusicHTTP = MusicHTTP(), country: @escaping @Sendable () -> String? = { Locale.current.region?.identifier }) {
        self.http = http
        self.country = country
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: "itunes", name: "Apple Music catalogue", summary: "Accurate song, album and artist details from Apple's public catalogue. Information only, no audio.",
            privacyNote: "Search words, the ids of items you open and your two-letter store country are sent to itunes.apple.com, and the country to rss.marketingtools.apple.com for charts. No account and no device id are sent.",
            homepage: "https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/")
    }
    var capabilities: MusicCapabilities { [.search, .browse, .tracks, .albums, .artists, .catalogue] }

    // MARK: transport

    /// A usable storefront code, or nil. Lower case, two letters.
    static func storefront(_ raw: String?) -> String? {
        guard let raw, raw.count == 2, raw.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return nil }
        return raw.lowercased()
    }

    /// One request with a single retry on a server error. Apple answers 403 when a client asks too fast, which is a rate limit, not a sign-in.
    private func fetch(_ url: URL, _ query: [String: String]) async throws -> [[String: Any]] {
        var attempt = 0
        while true {
            do {
                let obj = try await http.getObject(url, query: query)
                guard let rows = (obj as? [String: Any])?["results"] as? [[String: Any]] else { throw MusicError.network("unexpected reply") }
                return rows
            } catch MusicError.notSignedIn, MusicError.refused { throw MusicError.rateLimited(retryAfter: nil)
            } catch MusicError.network(let m) where m.hasPrefix("HTTP 5") && attempt == 0 {
                attempt += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Asks the person's storefront first and the default one when that gives nothing, so an item only sold elsewhere is still found.
    private func results(_ url: URL, _ query: [String: String]) async throws -> [[String: Any]] {
        guard let cc = Self.storefront(country()) else { return try await fetch(url, query) }
        var scoped = query; scoped["country"] = cc
        do {
            let rows = try await fetch(url, scoped)
            if !rows.isEmpty { return rows }
        } catch MusicError.network(let m) where m == "HTTP 400" {
            // Apple did not accept that storefront code; fall through to the default one.
        }
        return try await fetch(url, query)
    }

    /// A lookup of an id that is not a number is answered 400; to the person that is simply "not found".
    private func lookup(_ query: [String: String]) async throws -> [[String: Any]] {
        guard let id = query["id"], id.split(separator: ",").allSatisfy({ Int($0) != nil }) else { throw MusicError.notFound }
        do { return try await results(Self.lookupURL, query) } catch MusicError.network(let m) where m == "HTTP 400" { throw MusicError.notFound }
    }

    /// Apple's search ignores `offset` now (page 2 came back identical to page 1), so a page is cut from one larger reply instead:
    /// ask for everything up to the end of the wanted page, drop what the earlier pages already showed.
    private func search<T: Sendable>(_ term: String, entity: String, page: MusicPagination?, map: ([String: Any]) -> T?) async throws -> MusicPage<T> {
        let (offset, size) = itunesWindow(page)
        guard offset < Self.maxWindow else { return .empty }
        let limit = min(offset + size, Self.maxWindow)
        let rows = try await results(Self.searchURL, ["term": term, "media": "music", "entity": entity, "limit": String(limit)])
        let more = rows.count >= limit && limit < Self.maxWindow
        return MusicPage(items: rows.dropFirst(offset).prefix(size).compactMap(map), next: more ? .offset(offset: limit, limit: size) : nil)
    }

    // MARK: search

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        try await search(query, entity: "song", page: page, map: Self.mapTrack)
    }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        try await search(query, entity: "album", page: page, map: Self.mapAlbum)
    }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        try await search(query, entity: "musicArtist", page: page, map: Self.mapArtist)
    }

    // MARK: browse

    func featured() async throws -> [MusicBrowseSection] {
        let cc = Self.storefront(country()) ?? "us"
        var out: [MusicBrowseSection] = []
        if let rows = try? await chart(cc, kind: "songs"), !rows.isEmpty {
            let ids = rows.compactMap { $0.str("id") }
            // The feed has no lengths; Lookup does, and keeps the chart order through the id list.
            let detailed = (try? await lookup(["id": ids.joined(separator: ","), "entity": "song"])) ?? []
            let byID = Dictionary(detailed.compactMap(Self.mapTrack).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let tracks = rows.compactMap { row in row.str("id").flatMap { byID[$0] } ?? Self.mapChartSong(row) }
            if !tracks.isEmpty { out.append(MusicBrowseSection(id: "itunes-top-songs", title: "Top songs", items: tracks.map { .track($0) })) }
        }
        if let rows = try? await chart(cc, kind: "albums"), !rows.isEmpty {
            let albums = rows.compactMap(Self.mapChartAlbum)
            if !albums.isEmpty { out.append(MusicBrowseSection(id: "itunes-top-albums", title: "Top albums", items: albums.map { .album($0) })) }
        }
        if out.isEmpty { throw MusicError.network("Apple charts are not available right now") }
        return out
    }

    /// The marketing feed is flaky (it answers 502 now and then), so it gets one more try, and the US chart when a storefront has none.
    private func chart(_ cc: String, kind: String) async throws -> [[String: Any]] {
        var last: Error = MusicError.network("charts unavailable")
        for code in cc == "us" ? ["us", "us"] : [cc, cc, "us"] {
            guard let url = URL(string: "\(Self.chartsHost)/api/v2/\(code)/music/most-played/25/\(kind).json") else { continue }
            do {
                let obj = try await http.getObject(url)
                if let rows = ((obj as? [String: Any])?["feed"] as? [String: Any])?["results"] as? [[String: Any]], !rows.isEmpty { return rows }
            } catch { last = error }
        }
        throw last
    }

    // MARK: lookups

    func track(id: String) async throws -> MusicTrack {
        let rows = try await lookup(["id": id, "entity": "song"])
        guard let t = rows.compactMap(Self.mapTrack).first(where: { $0.id == id }) ?? rows.compactMap(Self.mapTrack).first else { throw MusicError.notFound }
        return t
    }

    func album(id: String) async throws -> MusicAlbum {
        let rows = try await lookup(["id": id])
        guard let a = rows.compactMap(Self.mapAlbum).first else { throw MusicError.notFound }
        return a
    }

    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        // Lookup returns the whole album in one reply, so paging is done here.
        let rows = try await lookup(["id": id, "entity": "song", "limit": "200"])
        let tracks = rows.compactMap(Self.mapTrack).sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
        if tracks.isEmpty, !rows.contains(where: { $0.str("wrapperType") == "collection" }) { throw MusicError.notFound }
        return Self.slice(tracks, page)
    }

    func artist(id: String) async throws -> MusicArtist {
        let rows = try await lookup(["id": id])
        guard let a = rows.compactMap(Self.mapArtist).first else { throw MusicError.notFound }
        return a
    }

    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        let rows = try await lookup(["id": id, "entity": "song", "limit": "15"])
        if rows.isEmpty { throw MusicError.notFound }
        return rows.compactMap(Self.mapTrack)
    }

    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let rows = try await lookup(["id": id, "entity": "album", "limit": "200"])
        if rows.isEmpty { throw MusicError.notFound }
        let albums = rows.compactMap(Self.mapAlbum).sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        return Self.slice(albums, page)
    }

    private static func slice<T: Sendable>(_ all: [T], _ page: MusicPagination?) -> MusicPage<T> {
        let (offset, limit) = itunesWindow(page)
        let items = Array(all.dropFirst(offset).prefix(limit))
        return MusicPage(items: items, totalCount: all.count, next: offset + limit < all.count ? .offset(offset: offset + limit, limit: limit) : nil)
    }

    // MARK: mapping

    static func mapTrack(_ d: [String: Any]) -> MusicTrack? {
        guard d.str("wrapperType") == "track" || d.str("kind") == "song" else { return nil }
        guard let id = d.str("trackId"), let title = d.str("trackName") else { return nil }
        let art = artwork(d.str("artworkUrl100"))
        let artist = MusicArtistRef(id: d.str("artistId") ?? "", name: d.str("artistName") ?? "Unknown artist", externalURL: d.str("artistViewUrl"))
        let album = d.str("collectionId").map {
            MusicAlbumRef(id: $0, title: d.str("collectionName") ?? "", artists: [artist], thumbnails: art,
                          releaseDate: date(d.str("releaseDate")), totalTracks: d.int("trackCount"), externalURL: d.str("collectionViewUrl"))
        }
        var track = MusicTrack(
            id: id, providerID: "itunes", title: title, durationMs: Int64(d.int("trackTimeMillis") ?? 0),
            trackNumber: d.int("trackNumber"), discNumber: d.int("discNumber"), artists: [artist], album: album, thumbnails: art,
            explicit: d.str("trackExplicitness") == "explicit", externalURL: d.str("trackViewUrl"), directStreams: nil)
        track.creditBundle = AppleMusicCreditMapper.trackBundle(d)
        return track
    }

    static func mapAlbum(_ d: [String: Any]) -> MusicAlbum? {
        guard d.str("wrapperType") == "collection", let id = d.str("collectionId"), let title = d.str("collectionName") else { return nil }
        let artist = MusicArtistRef(id: d.str("artistId") ?? "", name: d.str("artistName") ?? "Unknown artist", externalURL: d.str("artistViewUrl"))
        var album = MusicAlbum(id: id, providerID: "itunes", title: title, artists: [artist], thumbnails: artwork(d.str("artworkUrl100")),
                               releaseDate: date(d.str("releaseDate")), totalTracks: d.int("trackCount"), albumType: albumType(title, d.str("collectionType")),
                               label: d.str("copyright"), externalURL: d.str("collectionViewUrl"))
        album.creditBundle = AppleMusicCreditMapper.albumBundle(d)
        return album
    }

    static func mapArtist(_ d: [String: Any]) -> MusicArtist? {
        guard d.str("wrapperType") == "artist", let id = d.str("artistId"), let name = d.str("artistName") else { return nil }
        return MusicArtist(id: id, providerID: "itunes", name: name, genres: d.str("primaryGenreName").map { [$0] } ?? [], externalURL: d.str("artistLinkUrl"))
    }

    /// A chart row with no Lookup detail: enough to show and to match by title and artist.
    static func mapChartSong(_ d: [String: Any]) -> MusicTrack? {
        guard let id = d.str("id"), let title = d.str("name") else { return nil }
        let artist = MusicArtistRef(id: d.str("artistId") ?? "", name: d.str("artistName") ?? "Unknown artist", externalURL: d.str("artistUrl"))
        return MusicTrack(id: id, providerID: "itunes", title: title, durationMs: 0, artists: [artist], thumbnails: artwork(d.str("artworkUrl100")),
                          externalURL: d.str("url"), directStreams: nil)
    }

    static func mapChartAlbum(_ d: [String: Any]) -> MusicAlbum? {
        guard let id = d.str("id"), let title = d.str("name") else { return nil }
        let artist = MusicArtistRef(id: d.str("artistId") ?? "", name: d.str("artistName") ?? "Unknown artist", externalURL: d.str("artistUrl"))
        return MusicAlbum(id: id, providerID: "itunes", title: title, artists: [artist], thumbnails: artwork(d.str("artworkUrl100")),
                          releaseDate: d.str("releaseDate"), albumType: albumType(title, nil), externalURL: d.str("url"))
    }

    private static func albumType(_ title: String, _ declared: String?) -> String {
        if title.hasSuffix(" - Single") { return "Single" }
        if title.hasSuffix(" - EP") { return "EP" }
        return declared ?? "Album"
    }

    /// The reply names a 100 pixel image; the same address with a bigger size in the name gives a sharper one.
    private static func artwork(_ url: String?) -> [MusicThumbnail] {
        guard let url, url.hasPrefix("http") else { return [] }
        var out = [MusicThumbnail(url: url, width: 100, height: 100)]
        let big = url.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        if big != url { out.append(MusicThumbnail(url: big, width: 600, height: 600)) }
        return out
    }

    private static func date(_ iso: String?) -> String? { iso.map { String($0.prefix(10)) } }
}

private func itunesWindow(_ p: MusicPagination?) -> (Int, Int) {
    func clamp(_ n: Int) -> Int { min(max(n, 1), 200) }
    switch p {
    case .offset(let o, let l): return (max(o, 0), clamp(l))
    case .page(let n, let s): return (max(n - 1, 0) * clamp(s), clamp(s))
    case .cursor(let c, let l): return (max(Int(c ?? "") ?? 0, 0), clamp(l))
    case .continuation(let c): return (max(Int(c ?? "") ?? 0, 0), 30)
    case nil: return (0, 30)
    }
}
