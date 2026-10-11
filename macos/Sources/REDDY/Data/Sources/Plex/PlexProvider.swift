import Foundation

/// Plex Media Server: movies and shows from its libraries, using the server's own address and an access token.
final class PlexProvider: SourceProvider, @unchecked Sendable {
    let source: PlaylistSource
    private let base: String
    private let token: String
    private let http: HTTPClient
    private let headers: SourceHeaders
    private let mapper: PlexMapper

    init(source: PlaylistSource, token: String, http: HTTPClient, headers: SourceHeaders = SourceHeaders()) {
        self.source = source; self.token = token; self.http = http; self.headers = headers
        base = source.baseURL
        mapper = PlexMapper(source: source, base: source.baseURL, token: token)
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var c = URLComponents(string: base + path)
        c?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c?.url else { throw NetworkError.invalidURL }
        var r = http.builder.get(url)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        r.setValue("StreamSetu", forHTTPHeaderField: "X-Plex-Product")
        r.setValue("streamsetu-\(source.id.uuidString.lowercased())", forHTTPHeaderField: "X-Plex-Client-Identifier")
        headers.apply(to: &r)
        do {
            let data = try await http.data(r, maxBytes: 64 * 1024 * 1024)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let mc = obj["MediaContainer"] as? [String: Any] else { throw SourceError.invalidResponse("Unexpected reply from Plex.") }
            return mc
        } catch let e as NetworkError { throw e.isAuthFailure ? SourceError.authFailed : SourceError.network(e) }
    }

    private func sections(_ type: String) async throws -> [String] {
        ((try await get("/library/sections")["Directory"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == type }.compactMap { $0["key"] as? String }
    }

    private func items(section: String, type: Int) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            let mc = try await get("/library/sections/\(section)/all", ["type": "\(type)", "X-Plex-Container-Start": "\(start)", "X-Plex-Container-Size": "500"])
            let batch = (mc["Metadata"] as? [[String: Any]]) ?? []
            out += batch
            start += batch.count
            if batch.isEmpty || start >= ((mc["totalSize"] as? Int) ?? out.count) { return out }
        }
    }

    private func all(type: String, code: Int) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for key in try await sections(type) { out += try await items(section: key, type: code) }
        return out
    }

    func validate() async throws -> SourceCapabilities {
        let dirs = (try await get("/library/sections")["Directory"] as? [[String: Any]]) ?? []
        let types = Set(dirs.compactMap { $0["type"] as? String })
        guard types.contains("movie") || types.contains("show") else { throw SourceError.invalidResponse("This Plex server has no movie or show libraries for this account.") }
        return SourceCapabilities(live: false, movies: types.contains("movie"), series: types.contains("show"), epg: false, outputFormats: [])
    }

    func categoryFetch(_ kind: ContentKind) async throws -> CategoryFetch {
        let list: [[String: Any]]
        switch kind {
        case .movie: list = try await all(type: "movie", code: 1)
        case .series: list = try await all(type: "show", code: 2)
        default: return CategoryFetch(categories: [], providerCount: 0, rejected: [])
        }
        var seen = Set<String>()
        let cats = list.map { mapper.category($0, kind: kind) }.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .enumerated().map { CatalogCategory(id: $1.id, sourceID: source.id, kind: kind, providerID: $1.name, name: $1.name, sortOrder: $0) }
        return CategoryFetch(categories: cats, providerCount: cats.count, rejected: [])
    }

    func channels() -> AsyncThrowingStream<[Channel], Error> { .init { $0.finish() } }

    func movies() -> AsyncThrowingStream<[Movie], Error> {
        .producing { [self] c in for b in mapper.movies(try await all(type: "movie", code: 1)).chunked(into: 2000) { c.yield(b) } }
    }

    func series() -> AsyncThrowingStream<[Series], Error> {
        .producing { [self] c in for b in mapper.series(try await all(type: "show", code: 2)).chunked(into: 2000) { c.yield(b) } }
    }

    func movieDetail(_ movie: Movie) async throws -> MovieDetail {
        let mc = try await get("/library/metadata/\(movie.providerID)", ["includeGuids": "1"])
        let d = ((mc["Metadata"] as? [[String: Any]])?.first) ?? [:]
        return MovieDetail(overview: d["summary"] as? String, backdropURL: mapper.art(d["art"] as? String), posterURL: mapper.art(d["thumb"] as? String),
                           genre: mapper.tags(d, "Genre").first, releaseYear: d["year"] as? Int, durationSeconds: movie.durationSeconds, rating: movie.rating, extras: mapper.extras(d))
    }

    func seriesDetail(_ series: Series) async throws -> SeriesDetail {
        let info = ((try await get("/library/metadata/\(series.providerID)", ["includeGuids": "1"])["Metadata"] as? [[String: Any]])?.first) ?? [:]
        let seasonItems = ((try await get("/library/metadata/\(series.providerID)/children")["Metadata"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "season" }
        var seasons: [Season] = [], episodes: [Episode] = []
        for s in seasonItems {
            guard let key = (s["ratingKey"] as? String) ?? (s["ratingKey"] as? Int).map(String.init) else { continue }
            let n = (s["index"] as? Int) ?? 1
            seasons.append(Season(id: "\(series.id)|season|\(n)", seriesID: series.id, number: n, name: s["title"] as? String))
            let eps = (try await get("/library/metadata/\(key)/children")["Metadata"] as? [[String: Any]]) ?? []
            episodes += mapper.episodes(eps, series: series, seasonNumber: n)
        }
        episodes.sort { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
        var updated = series
        updated.overview = (info["summary"] as? String) ?? series.overview
        updated.lastMetadataRefresh = Date()
        return SeriesDetail(series: updated, seasons: seasons, episodes: episodes, extras: mapper.extras(info))
    }

    func epgLocation() -> URL? { source.epgURL.flatMap(URL.init(string:)) }

    func streamURL(kind: ContentKind, ref: String) throws -> URL {
        guard kind == .movie || kind == .episode else { throw SourceError.unsupported("live channels") }
        guard ref.hasPrefix("/"), var c = URLComponents(string: base + ref) else { throw NetworkError.invalidURL }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "X-Plex-Token", value: token)]
        guard let url = c.url else { throw NetworkError.invalidURL }
        return url
    }

    func catchupURL(ref: String, start: Date, durationMinutes: Int, utcOffsetMinutes: Int) throws -> URL? { nil }
}
