import Foundation

/// Fills in missing posters, backdrops, summaries, years and ratings from The Movie Database, using the person's own API key.
/// Only gaps are filled: whatever the playlist already provides is never replaced. The key lives in the credential vault and is
/// sent only to api.themoviedb.org; nothing about the library leaves the Mac except the title (and year) being looked up.
final class MetadataMatchService: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    enum MatchError: LocalizedError, Equatable {
        case noKey, invalidKey, rateLimited, offline, unreadable
        var errorDescription: String? {
            switch self {
            case .noKey: "Add your TMDB API key first."
            case .invalidKey: "TMDB did not accept this key. Check that you copied the whole key."
            case .rateLimited: "TMDB asked us to slow down. Try again in a few minutes."
            case .offline: "TMDB could not be reached."
            case .unreadable: "TMDB sent a reply that could not be read."
            }
        }
    }

    struct Progress: Sendable, Equatable { var done = 0, total = 0, matched = 0 }
    struct Outcome: Sendable, Equatable { var looked = 0, matched = 0, unmatched = 0, remaining = 0 }

    static let keyRef = "tmdb-api-key"
    static let attribution = "This product uses the TMDB API but is not endorsed or certified by TMDB."
    static let imageBase = "https://image.tmdb.org/t/p/"
    /// Titles that found nothing are tried again after this long (the database may have gained them since).
    static let retryAfter: TimeInterval = 30 * 86400

    private let db: DatabaseManager
    private let credentials: CredentialStore
    private let fetch: Fetch
    private let pause: UInt64
    private let host: String

    init(db: DatabaseManager, credentials: CredentialStore, host: String = "api.themoviedb.org", pause: UInt64 = 120_000_000, fetch: @escaping Fetch) {
        self.db = db; self.credentials = credentials; self.host = host; self.pause = pause; self.fetch = fetch
    }

    convenience init(db: DatabaseManager, credentials: CredentialStore, http: HTTPClient) {
        self.init(db: db, credentials: credentials) { try await http.data($0, maxBytes: 2_000_000) }
    }

    // MARK: key

    var hasKey: Bool { ((try? credentials.load(ref: Self.keyRef)) ?? nil)?.password?.isEmpty == false }

    func saveKey(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { try credentials.delete(ref: Self.keyRef) } else { try credentials.save(Credentials(username: "tmdb", password: k), ref: Self.keyRef) }
    }

    func removeKey() throws { try credentials.delete(ref: Self.keyRef) }

    /// A person's real filmography from TMDB: their films and series, most popular first. Used by Ask AI so answers come from facts, not from an AI's memory.
    func filmography(of name: String) async throws -> AskLibrary.TMDBFilmography? {
        let found = try await get("/3/search/person", query: [URLQueryItem(name: "query", value: name), URLQueryItem(name: "include_adult", value: "false")])
        guard let top = ((try? JSONSerialization.jsonObject(with: found)) as? [String: Any])?["results"] as? [[String: Any]],
              let person = top.first(where: { ($0["known_for_department"] as? String) == "Acting" }) ?? top.first, let id = person["id"] as? Int else { return nil }
        var credits: [(title: String, year: Int?, isShow: Bool, pop: Double)] = []
        for (path, isShow) in [("/3/person/\(id)/movie_credits", false), ("/3/person/\(id)/tv_credits", true)] {
            guard let data = try? await get(path, query: []), let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let rows = ((j["cast"] as? [[String: Any]]) ?? []) + ((j["crew"] as? [[String: Any]]) ?? []).filter { ($0["job"] as? String) == "Director" }
            for r in rows {
                guard let t = (r[isShow ? "name" : "title"] as? String), !t.isEmpty else { continue }
                let y = ((r[isShow ? "first_air_date" : "release_date"] as? String) ?? "").prefix(4)
                credits.append((t, Int(y), isShow, (r["popularity"] as? Double) ?? 0))
            }
        }
        guard !credits.isEmpty else { return nil }
        return AskLibrary.TMDBFilmography(name: (person["name"] as? String) ?? name, credits: credits.sorted { $0.pop > $1.pop }.prefix(120).map { ($0.title, $0.year, $0.isShow) })
    }

    /// Asks TMDB to confirm the key works.
    func verifyKey() async throws { _ = try await get("/3/configuration", query: []) }

    // MARK: matching

    struct Candidate: Sendable, Equatable { let id: String; let isSeries: Bool; let title: String; let year: Int? }

    /// Items with no poster that haven't been looked up (or whose lookup found nothing long enough ago).
    func pending(limit: Int, now: Date = Date()) throws -> (items: [Candidate], total: Int) {
        let cutoff = now.addingTimeInterval(-Self.retryAfter).timeIntervalSince1970
        return try db.read { c in
            let cond = "(poster_url IS NULL OR poster_url='') AND id NOT IN (SELECT item_id FROM metadata_matches WHERE tmdb_id IS NOT NULL OR matched_at > \(cutoff))"
            let total = try c.scalarInt("SELECT (SELECT COUNT(*) FROM movies WHERE \(cond)) + (SELECT COUNT(*) FROM series WHERE \(cond))")
            var out: [Candidate] = try c.query("SELECT id, title, release_year FROM movies WHERE \(cond) ORDER BY added_at DESC LIMIT ?", [limit]) {
                Candidate(id: $0.string(0), isSeries: false, title: $0.string(1), year: $0.optInt(2)) }
            if out.count < limit {
                out += try c.query("SELECT id, title, release_year FROM series WHERE \(cond) ORDER BY added_at DESC LIMIT ?", [limit - out.count]) {
                    Candidate(id: $0.string(0), isSeries: true, title: $0.string(1), year: $0.optInt(2)) }
            }
            return (out, total)
        }
    }

    /// Looks up to `limit` items. Stops on cancellation and on key/rate-limit problems (which would fail every remaining item).
    func run(limit: Int = 300, progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Outcome {
        guard hasKey else { throw MatchError.noKey }
        let (items, total) = try pending(limit: limit)
        var out = Outcome(), p = Progress(done: 0, total: items.count)
        for item in items {
            try Task.checkCancellation()
            let hit = try await lookup(item)
            try store(item, hit)
            out.looked += 1
            if hit != nil { out.matched += 1 } else { out.unmatched += 1 }
            p.done += 1; p.matched = out.matched; progress(p)
            if pause > 0 { try await Task.sleep(nanoseconds: pause) }
        }
        out.remaining = max(0, total - items.count)
        return out
    }

    struct Hit: Equatable, Sendable { let tmdbID: Int; let overview: String?; let poster: String?; let backdrop: String?; let year: Int?; let rating: String? }

    func lookup(_ item: Candidate) async throws -> Hit? {
        let (text, year) = TitleCleaner.query(item.title, year: item.year)
        guard !text.isEmpty else { return nil }
        var q = [URLQueryItem(name: "query", value: text), URLQueryItem(name: "include_adult", value: "false")]
        if let year { q.append(URLQueryItem(name: item.isSeries ? "first_air_date_year" : "year", value: String(year))) }
        let data = try await get(item.isSeries ? "/3/search/tv" : "/3/search/movie", query: q)
        guard let reply = try? JSONDecoder().decode(SearchReply.self, from: data) else { throw MatchError.unreadable }
        return Self.best(reply.results, for: text, year: year)
    }

    /// Accepts a result only when its title equals the wanted one (and the year is within one, when both are known). A wrong poster
    /// is worse than a missing one.
    static func best(_ results: [SearchResult], for text: String, year: Int?) -> Hit? {
        let want = MetadataNormalizer.normalize(text)
        for r in results {
            let names = [r.title, r.name, r.original_title, r.original_name].compactMap { $0 }.map(MetadataNormalizer.normalize)
            guard names.contains(want) else { continue }
            let ry = (r.release_date ?? r.first_air_date).flatMap { Int($0.prefix(4)) }
            if let year, let ry, abs(year - ry) > 1 { continue }
            return Hit(tmdbID: r.id, overview: r.overview.flatMap { $0.isEmpty ? nil : $0 },
                       poster: r.poster_path.map { imageBase + "w500" + $0 }, backdrop: r.backdrop_path.map { imageBase + "w1280" + $0 },
                       year: ry, rating: r.vote_average.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil })
        }
        return nil
    }

    struct SearchReply: Decodable { let results: [SearchResult] }
    struct SearchResult: Decodable {
        let id: Int
        let title: String?, name: String?, original_title: String?, original_name: String?
        let overview: String?, poster_path: String?, backdrop_path: String?
        let release_date: String?, first_air_date: String?
        let vote_average: Double?
    }

    private func store(_ item: Candidate, _ hit: Hit?) throws {
        try db.write { c in
            if let h = hit {
                let table = item.isSeries ? "series" : "movies"
                try c.execute("""
                    UPDATE \(table) SET poster_url=COALESCE(NULLIF(poster_url,''),?), backdrop_url=COALESCE(NULLIF(backdrop_url,''),?),
                        overview=COALESCE(NULLIF(overview,''),?), release_year=COALESCE(release_year,?), rating=COALESCE(NULLIF(rating,''),?) WHERE id=?
                    """, [h.poster, h.backdrop, h.overview, h.year, h.rating, item.id])
            }
            try c.execute("INSERT OR REPLACE INTO metadata_matches(item_id, kind, tmdb_id, matched_at) VALUES(?,?,?,?)",
                          [item.id, item.isSeries ? "series" : "movie", hit?.tmdbID, Date()])
        }
    }

    // MARK: details (trailers, cast, ...)

    /// Details for a movie or series, from the saved copy when it is recent, otherwise from TMDB (and then saved). The title is
    /// matched to TMDB the same careful way as artwork; nil when there is no key, no confident match, or no connection and no copy.
    func details(for item: Candidate, maxAge: TimeInterval = 14 * 86400, now: Date = Date()) async -> TitleDetails? {
        let saved: (json: String, at: Double)? = try? db.read { c in
            try c.queryOne("SELECT json, fetched_at FROM title_details WHERE item_id = ?", [item.id]) { ($0.string(0), $0.double(1)) }
        }
        let cached = saved.flatMap { try? JSONDecoder().decode(TitleDetails.self, from: Data($0.json.utf8)) }
        if let cached, let saved, now.timeIntervalSince1970 - saved.at < maxAge { return cached }
        guard hasKey else { return cached }
        do {
            var id: Int? = try db.read { c in try c.queryOne("SELECT tmdb_id FROM metadata_matches WHERE item_id = ? AND tmdb_id IS NOT NULL", [item.id]) { $0.optInt(0) } } ?? nil
            if id == nil, let hit = try await lookup(item) { id = hit.tmdbID; try store(item, hit) }
            guard let id else { return cached }
            let path = item.isSeries ? "/3/tv/\(id)" : "/3/movie/\(id)"
            let append = item.isSeries ? "videos,credits,recommendations,content_ratings" : "videos,credits,recommendations,release_dates"
            let data = try await get(path, query: [URLQueryItem(name: "append_to_response", value: append), URLQueryItem(name: "language", value: "en-US")])
            guard let d = TitleDetailsParser.parse(data, isSeries: item.isSeries), let json = try? JSONEncoder().encode(d) else { return cached }
            let text = String(decoding: json, as: UTF8.self)
            try db.write { try $0.execute("INSERT OR REPLACE INTO title_details(item_id, json, fetched_at) VALUES(?, ?, ?)", [item.id, text, now.timeIntervalSince1970]) }
            return d
        } catch { return cached }
    }

    func forgetMatches() throws { try db.write { try $0.execute("DELETE FROM metadata_matches") } }

    // MARK: network

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        guard let key = ((try? credentials.load(ref: Self.keyRef)) ?? nil)?.password, !key.isEmpty else { throw MatchError.noKey }
        var comps = URLComponents(); comps.scheme = "https"; comps.host = host; comps.path = path
        var items = query
        let bearer = key.hasPrefix("eyJ") || key.count > 40          // v4 "read access token" vs v3 key
        if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        comps.queryItems = items.isEmpty ? nil : items
        guard let url = comps.url else { throw MatchError.unreadable }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        do { return try await fetch(req) }
        catch let e as NetworkError { throw Self.map(e) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MatchError.offline }                          // never surface the error text: it can contain the request URL
    }

    private static func map(_ e: NetworkError) -> MatchError {
        switch e {
        case .http(let status, _): status == 401 || status == 403 ? .invalidKey : status == 429 ? .rateLimited : .offline
        case .cancelled: .offline
        default: .offline
        }
    }
}

/// Turns a provider title ("EN - The Matrix (1999) 4K") into something TMDB can search for.
enum TitleCleaner {
    static func query(_ title: String, year: Int?) -> (text: String, year: Int?) {
        var s = title
        var found = year
        if found == nil, let r = s.range(of: #"[\(\[]((?:19|20)\d{2})[\)\]]"#, options: .regularExpression) {
            found = Int(s[r].filter(\.isNumber))
        }
        s = s.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*\|[A-Za-z]{2,3}\|\s*"#, with: "", options: .regularExpression)           // "|FR| "
        s = s.replacingOccurrences(of: #"^\s*[A-Za-z]{2,3}\s*[-:|]\s+"#, with: "", options: .regularExpression)       // "EN - "
        let drop: Set<String> = ["4k", "uhd", "fhd", "hd", "sd", "hevc", "multi", "sub", "subs", "dubbed", "1080p", "720p", "2160p", "hdr", "hdr10"]
        let words = s.split(whereSeparator: { $0.isWhitespace }).filter { !drop.contains($0.lowercased()) }
        return (words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -:|.")), found)
    }
}
