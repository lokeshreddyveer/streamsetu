import Foundation

/// Stalker / Ministra portals (what MAG set-top boxes talk to). The "login" is the MAC address of the box the portal has registered.
/// Stream addresses are short-lived, so they are requested at the moment of playback (see `PortalLink`).
final class StalkerProvider: SourceProvider, @unchecked Sendable {
    let source: PlaylistSource
    private let portal: String          // address the person typed, no trailing slash, "/c" removed
    private let mac: String
    private let http: HTTPClient
    private let headers: SourceHeaders
    private let mapper: StalkerMapper
    private let lock = NSLock()
    private var token: String?
    private var endpoint: String?

    static let userAgent = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG250 stbapp ver: 4 rev: 1812 Mobile Safari/533.3"

    init(source: PlaylistSource, mac: String, http: HTTPClient, headers: SourceHeaders = SourceHeaders()) {
        self.source = source; self.mac = mac; self.http = http; self.headers = headers
        portal = Self.portalBase(source.baseURL)
        mapper = StalkerMapper(source: source)
    }

    /// "http://host/stalker_portal/c/" -> "http://host/stalker_portal".
    static func portalBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/c") { s.removeLast(2) }
        return s
    }

    static func candidateEndpoints(portal: String) -> [String] { [portal + "/server/load.php", portal + "/portal.php", portal + "/stalker_portal/server/load.php"] }

    // MARK: session

    private func request(_ endpoint: String, _ query: [String: String], token: String?) throws -> URLRequest {
        var c = URLComponents(string: endpoint)
        c?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "JsHttpRequest", value: "1-xml")]
        guard let url = c?.url else { throw NetworkError.invalidURL }
        var r = http.builder.get(url, userAgent: Self.userAgent)
        r.setValue("mac=\(mac); stb_lang=en; timezone=UTC", forHTTPHeaderField: "Cookie")
        r.setValue("Model: MAG250; Link: WiFi", forHTTPHeaderField: "X-User-Agent")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        headers.apply(to: &r)
        return r
    }

    private func js(_ endpoint: String, _ query: [String: String], token: String?) async throws -> Any? {
        let data = try await http.data(try request(endpoint, query, token: token), maxBytes: 64 * 1024 * 1024)
        // Portals answer with JSON, sometimes preceded by whitespace or wrapped as {"js": ...}.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceError.invalidResponse("The portal did not answer with data.") }
        return obj["js"]
    }

    private func session() async throws -> (endpoint: String, token: String) {
        if let e = lock.withLock({ endpoint }), let t = lock.withLock({ token }) { return (e, t) }
        var last: Error = SourceError.invalidResponse("No portal answered at that address.")
        for ep in Self.candidateEndpoints(portal: portal) {
            do {
                guard let hs = try await js(ep, ["type": "stb", "action": "handshake", "token": ""], token: nil) as? [String: Any], let t = hs["token"] as? String, !t.isEmpty else { continue }
                _ = try? await js(ep, ["type": "stb", "action": "get_profile", "hd": "1", "stb_type": "MAG250", "sn": StalkerMapper.serial(mac: mac),
                                       "device_id": StalkerMapper.deviceID(mac: mac), "device_id2": StalkerMapper.deviceID(mac: mac), "client_type": "STB",
                                       "auth_second_step": "1", "num_banks": "2", "ver": "ImageDescription: 0.2.18-r14-pub-250; PORTAL version: 5.6.1; API Version: JS API version: 343",
                                       "hw_version": "1.7-BD-00", "not_valid_token": "0"], token: t)
                lock.withLock { endpoint = ep; token = t }
                return (ep, t)
            } catch { last = error }
        }
        throw last is SourceError ? last : SourceError.network((last as? NetworkError) ?? .unreadable)
    }

    private func call(_ query: [String: String]) async throws -> Any? {
        let s = try await session()
        do { return try await js(s.endpoint, query, token: s.token) }
        catch let e as NetworkError where e.isAuthFailure {
            lock.withLock { token = nil }
            let n = try await session()
            return try await js(n.endpoint, query, token: n.token)
        }
    }

    // MARK: SourceProvider

    func validate() async throws -> SourceCapabilities {
        _ = try await session()
        let ch = (try await call(["type": "itv", "action": "get_all_channels"]) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        guard !ch.isEmpty else { throw SourceError.invalidResponse("The portal accepted the box but has no channels for it. Check the MAC address.") }
        let vod = (try? await call(["type": "vod", "action": "get_categories"]) as? [[String: Any]])?.isEmpty == false
        return SourceCapabilities(live: true, movies: vod, series: false, epg: false, outputFormats: [])
    }

    func categoryFetch(_ kind: ContentKind) async throws -> CategoryFetch {
        let action: [String: String]
        switch kind {
        case .channel: action = ["type": "itv", "action": "get_genres"]
        case .movie: action = ["type": "vod", "action": "get_categories"]
        default: return CategoryFetch(categories: [], providerCount: 0, rejected: [])
        }
        let g = mapper.genres(try await call(action))
        let cats = g.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }.enumerated().map {
            CatalogCategory(id: CatalogCategory.makeID(source: source.id, kind: kind, provider: $1.key), sourceID: source.id, kind: kind, providerID: $1.key, name: $1.value, sortOrder: $0)
        }
        return CategoryFetch(categories: cats, providerCount: cats.count, rejected: [])
    }

    func channels() -> AsyncThrowingStream<[Channel], Error> {
        .producing { [self] c in
            let genres = mapper.genres(try await call(["type": "itv", "action": "get_genres"]))
            let list = ((try await call(["type": "itv", "action": "get_all_channels"]) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            for b in mapper.channels(list, genres: genres).chunked(into: 2000) { try Task.checkCancellation(); c.yield(b) }
        }
    }

    /// Pages of the portal's video list, up to a sane ceiling so a huge portal cannot stall a refresh.
    private func pages(type: String, category: String = "*") async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for p in 1...400 {
            try Task.checkCancellation()
            guard let r = try await call(["type": type, "action": "get_ordered_list", "p": "\(p)", "category": category, "sortby": "added"]) as? [String: Any],
                  let batch = r["data"] as? [[String: Any]], !batch.isEmpty else { break }
            out += batch
            let total = Int("\(r["total_items"] ?? "")") ?? 0, perPage = Int("\(r["max_page_items"] ?? "")") ?? batch.count
            if total > 0, p * max(perPage, 1) >= total { break }
        }
        return out
    }

    func movies() -> AsyncThrowingStream<[Movie], Error> {
        .producing { [self] c in
            let genres = mapper.genres(try await call(["type": "vod", "action": "get_categories"]))
            for b in mapper.movies(try await pages(type: "vod"), genres: genres, portal: portal).chunked(into: 2000) { c.yield(b) }
        }
    }

    func series() -> AsyncThrowingStream<[Series], Error> {
        .producing { [self] c in
            let genres = mapper.genres(try await call(["type": "series", "action": "get_categories"]))
            for b in mapper.series(try await pages(type: "series"), genres: genres, portal: portal).chunked(into: 2000) { c.yield(b) }
        }
    }

    func movieDetail(_ movie: Movie) async throws -> MovieDetail { MovieDetail(overview: movie.overview, backdropURL: nil, posterURL: movie.posterURL, genre: movie.genre, releaseYear: movie.releaseYear, durationSeconds: movie.durationSeconds, rating: movie.rating, extras: nil) }

    func seriesDetail(_ series: Series) async throws -> SeriesDetail {
        guard let r = try await call(["type": "series", "action": "get_ordered_list", "movie_id": series.providerID, "p": "1"]) as? [String: Any],
              let items = r["data"] as? [[String: Any]] else { throw SourceError.invalidResponse("No episodes were listed for this series.") }
        var seasons: [Season] = [], episodes: [Episode] = []
        for (i, item) in items.enumerated() {
            let part = mapper.detail(item, series: series)
            let n = Int("\(item["season_num"] ?? "")") ?? (i + 1)
            // Re-number: each listed item is one season of the series.
            let sid = "\(series.id)|season|\(n)"
            seasons.append(Season(id: sid, seriesID: series.id, number: n, name: mapper.str(item, "name")))
            for e in part.episodes { var e2 = e; e2.seasonNumber = n; e2.seasonID = sid; episodes.append(e2) }
        }
        episodes.sort { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
        var updated = series; updated.lastMetadataRefresh = Date()
        return SeriesDetail(series: updated, seasons: seasons, episodes: episodes, extras: nil)
    }

    func epgLocation() -> URL? { source.epgURL.flatMap(URL.init(string:)) }

    func streamURL(kind: ContentKind, ref: String) throws -> URL {
        guard let u = PortalLink.make(kind: kind, ref: ref) else { throw NetworkError.invalidURL }
        return u
    }

    /// Asks the portal for the real, short-lived address of a stream.
    func resolveLink(kind: ContentKind, ref: String) async throws -> URL {
        var cmd = ref, episode: String?
        if let r = ref.range(of: "#series=") { cmd = String(ref[..<r.lowerBound]); episode = String(ref[r.upperBound...]) }
        var q: [String: String] = ["type": kind == .channel ? "itv" : (episode != nil ? "vod" : "vod"), "action": "create_link", "cmd": cmd, "forced_storage": "undefined", "disable_ip_check": "0"]
        if let episode { q["series"] = episode }
        let reply = try await call(q) as? [String: Any]
        if let c = reply?["cmd"] as? String, let a = StalkerMapper.address(fromCommand: c), let url = URL(string: a), SourceURLValidator.isPlayableScheme(url) { return url }
        // Some portals play the command's own address directly.
        if let a = StalkerMapper.address(fromCommand: cmd), !a.contains("localhost"), let url = URL(string: a), SourceURLValidator.isPlayableScheme(url) { return url }
        throw SourceError.invalidResponse("The portal did not give a stream address. The box may not be allowed to watch this.")
    }

    func catchupURL(ref: String, start: Date, durationMinutes: Int, utcOffsetMinutes: Int) throws -> URL? { nil }
}
