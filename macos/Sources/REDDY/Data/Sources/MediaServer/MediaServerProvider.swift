import Foundation

enum MediaServerFlavor: String, Sendable {
    case jellyfin, emby
    /// Emby serves its API under /emby; Jellyfin at the root.
    var prefix: String { self == .emby ? "/emby" : "" }
}

struct MediaSession: Codable, Sendable, Equatable {
    var token: String
    var userID: String
    var encoded: String { "\(token)|\(userID)" }
    init(token: String, userID: String) { self.token = token; self.userID = userID }
    init?(encoded: String?) {
        guard let p = encoded?.split(separator: "|", maxSplits: 1).map(String.init), p.count == 2, !p[0].isEmpty else { return nil }
        token = p[0]; userID = p[1]
    }
}

/// Jellyfin and Emby: movies and series from the server's libraries. The login is exchanged for an access token, which is kept in the
/// Keychain next to it and renewed by itself when the server stops accepting it.
final class MediaServerProvider: SourceProvider, @unchecked Sendable {
    let source: PlaylistSource
    private let base: String
    private let flavor: MediaServerFlavor
    private let user: String
    private let pass: String
    private let http: HTTPClient
    private let credentials: CredentialStore
    private let headers: SourceHeaders
    private let mapper: MediaServerMapper
    private let lock = NSLock()
    private var session: MediaSession?

    init(source: PlaylistSource, flavor: MediaServerFlavor, user: String, pass: String, session: MediaSession?, http: HTTPClient,
         credentials: CredentialStore, headers: SourceHeaders = SourceHeaders()) {
        self.source = source; self.flavor = flavor; self.user = user; self.pass = pass; self.session = session
        self.http = http; self.credentials = credentials; self.headers = headers
        base = source.baseURL + flavor.prefix
        mapper = MediaServerMapper(source: source, base: source.baseURL + flavor.prefix)
    }

    // MARK: session

    private var deviceID: String { "streamsetu-\(source.id.uuidString.lowercased())" }
    private func authHeader(token: String? = nil) -> String {
        "MediaBrowser Client=\"StreamSetu\", Device=\"StreamSetu\", DeviceId=\"\(deviceID)\", Version=\"1.0\"" + (token.map { ", Token=\"\($0)\"" } ?? "")
    }

    /// Logs in and remembers the access token.
    func authenticate() async throws -> MediaSession {
        guard let url = URL(string: base + "/Users/AuthenticateByName") else { throw NetworkError.invalidURL }
        var r = http.builder.get(url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(authHeader(), forHTTPHeaderField: "X-Emby-Authorization")
        r.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["Username": user, "Pw": pass])
        headers.apply(to: &r)
        let data: Data
        do { data = try await http.data(r, maxBytes: 2 * 1024 * 1024) }
        catch let e as NetworkError { throw e.isAuthFailure ? SourceError.authFailed : SourceError.network(e) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = obj["AccessToken"] as? String,
              let uid = (obj["User"] as? [String: Any])?["Id"] as? String else { throw SourceError.authFailed }
        let s = MediaSession(token: token, userID: uid)
        lock.withLock { session = s }
        if let ref = source.credentialRef { try? credentials.save(Credentials(username: user, password: pass, url: s.encoded), ref: ref) }
        return s
    }

    private func currentSession() async throws -> MediaSession {
        if let s = lock.withLock({ session }) { return s }
        return try await authenticate()
    }

    private func get(_ path: String, _ query: [String: String] = [:], maxBytes: Int64 = 32 * 1024 * 1024, retried: Bool = false) async throws -> [String: Any] {
        let s = try await currentSession()
        var c = URLComponents(string: base + path)
        c?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c?.url else { throw NetworkError.invalidURL }
        var r = http.builder.get(url)
        r.setValue(s.token, forHTTPHeaderField: "X-Emby-Token")
        r.setValue(authHeader(token: s.token), forHTTPHeaderField: "X-Emby-Authorization")
        headers.apply(to: &r)
        do {
            let data = try await http.data(r, maxBytes: maxBytes)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceError.invalidResponse("Unexpected reply from the server.") }
            return obj
        } catch let e as NetworkError {
            if e.isAuthFailure, !retried { lock.withLock { session = nil }; _ = try await authenticate(); return try await get(path, query, maxBytes: maxBytes, retried: true) }
            throw e.isAuthFailure ? SourceError.authFailed : SourceError.network(e)
        }
    }

    /// Every item of one type, a page at a time.
    private func items(type: String, fields: String) async throws -> [[String: Any]] {
        let s = try await currentSession()
        var out: [[String: Any]] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            let page = try await get("/Users/\(s.userID)/Items", ["IncludeItemTypes": type, "Recursive": "true", "Fields": fields,
                                                                  "SortBy": "SortName", "StartIndex": "\(start)", "Limit": "500"])
            let batch = (page["Items"] as? [[String: Any]]) ?? []
            out += batch
            let total = (page["TotalRecordCount"] as? Int) ?? out.count
            start += batch.count
            if batch.isEmpty || start >= total { return out }
        }
    }

    // MARK: SourceProvider

    func validate() async throws -> SourceCapabilities {
        let s = try await authenticate()
        let movies = try await get("/Users/\(s.userID)/Items", ["IncludeItemTypes": "Movie", "Recursive": "true", "Limit": "1"])
        let series = try await get("/Users/\(s.userID)/Items", ["IncludeItemTypes": "Series", "Recursive": "true", "Limit": "1"])
        return SourceCapabilities(live: false, movies: ((movies["TotalRecordCount"] as? Int) ?? 0) > 0, series: ((series["TotalRecordCount"] as? Int) ?? 0) > 0,
                                  epg: false, outputFormats: [])
    }

    private static let listFields = "Overview,Genres,CommunityRating,ProductionYear,Container,DateCreated,PremiereDate"

    func categoryFetch(_ kind: ContentKind) async throws -> CategoryFetch {
        let list: [[String: Any]]
        switch kind {
        case .movie: list = try await items(type: "Movie", fields: "Genres")
        case .series: list = try await items(type: "Series", fields: "Genres")
        default: return CategoryFetch(categories: [], providerCount: 0, rejected: [])
        }
        let cats = mapper.categories(list.map { mapper.category($0, kind: kind) }, kind: kind)
        return CategoryFetch(categories: cats, providerCount: cats.count, rejected: [])
    }

    func channels() -> AsyncThrowingStream<[Channel], Error> { .init { $0.finish() } }

    func movies() -> AsyncThrowingStream<[Movie], Error> {
        .producing { [self] c in for b in mapper.movies(try await items(type: "Movie", fields: Self.listFields)).chunked(into: 2000) { c.yield(b) } }
    }

    func series() -> AsyncThrowingStream<[Series], Error> {
        .producing { [self] c in for b in mapper.series(try await items(type: "Series", fields: Self.listFields)).chunked(into: 2000) { c.yield(b) } }
    }

    private static let detailFields = "Overview,Genres,People,ProviderIds,RemoteTrailers,OfficialRating,CommunityRating,ProductionYear,RunTimeTicks,Container"

    func movieDetail(_ movie: Movie) async throws -> MovieDetail {
        let s = try await currentSession()
        let d = try await get("/Users/\(s.userID)/Items/\(movie.providerID)", ["Fields": Self.detailFields])
        return MovieDetail(overview: d["Overview"] as? String, backdropURL: mapper.movies([d]).first?.backdropURL, posterURL: mapper.movies([d]).first?.posterURL,
                           genre: (d["Genres"] as? [String])?.first, releaseYear: mapper.year(d), durationSeconds: mapper.seconds(d), rating: mapper.rating(d),
                           extras: mapper.extras(d))
    }

    func seriesDetail(_ series: Series) async throws -> SeriesDetail {
        let s = try await currentSession()
        let info = try await get("/Users/\(s.userID)/Items/\(series.providerID)", ["Fields": Self.detailFields])
        let eps = try await get("/Shows/\(series.providerID)/Episodes", ["UserId": s.userID, "Fields": "Overview,RunTimeTicks,Container"])
        let built = mapper.episodes((eps["Items"] as? [[String: Any]]) ?? [], series: series)
        var updated = series
        updated.overview = (info["Overview"] as? String) ?? series.overview
        updated.lastMetadataRefresh = Date()
        return SeriesDetail(series: updated, seasons: built.seasons, episodes: built.episodes, extras: mapper.extras(info))
    }

    func epgLocation() -> URL? { source.epgURL.flatMap(URL.init(string:)) }

    func streamURL(kind: ContentKind, ref: String) throws -> URL {
        guard kind == .movie || kind == .episode else { throw SourceError.unsupported("live channels") }
        guard let token = lock.withLock({ session?.token }) else { throw SourceError.credentialsMissing }
        let parts = ref.split(separator: ".", maxSplits: 1).map(String.init)
        let id = parts[0], ext = parts.count > 1 ? parts[1] : "mp4"
        var c = URLComponents(string: "\(base)/Videos/\(id)/stream.\(ext)")
        c?.queryItems = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "MediaSourceId", value: id),
                         URLQueryItem(name: "DeviceId", value: deviceID), URLQueryItem(name: "api_key", value: token)]
        guard let url = c?.url else { throw NetworkError.invalidURL }
        return url
    }

    func catchupURL(ref: String, start: Date, durationMinutes: Int, utcOffsetMinutes: Int) throws -> URL? { nil }
}
