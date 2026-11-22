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
    private let inflight = InflightDetails()

    init(db: DatabaseManager, credentials: CredentialStore, host: String = "api.themoviedb.org", pause: UInt64 = 120_000_000, fetch: @escaping Fetch) {
        self.db = db; self.credentials = credentials; self.host = host; self.pause = pause; self.fetch = fetch
    }

    convenience init(db: DatabaseManager, credentials: CredentialStore, http: HTTPClient) {
        self.init(db: db, credentials: credentials) { try await http.data($0, maxBytes: 2_000_000) }
    }

    /// Nothing from TMDB is kept longer than 180 days (called at launch and before every matching run): saved details (cast, recommendations, trailers) older than that are deleted, and
    /// whatever a lookup filled into a movie or series row (poster, backdrop, summary, year, rating) is taken back, only where the row still holds exactly what TMDB gave (a value the playlist
    /// itself supplied is never touched). The title then looks as the playlist has it, and can be looked up again. The weekly trending list has the same cap in its own cache.
    static let maxKeepDays = 180
    private static let fillable: [String: String] = ["poster_url": "poster_url", "backdrop_url": "backdrop_url", "overview": "overview", "release_year": "release_year", "rating": "rating"]
    @discardableResult func purgeExpired(now: Date = Date()) -> Int {
        let cutoff = now.timeIntervalSince1970 - Double(Self.maxKeepDays) * 86400
        return (try? db.write { c in
            try c.execute("DELETE FROM title_details WHERE fetched_at < ?", [cutoff])
            var n = c.changes
            let old: [(String, String, Bool, String?)] = try c.query("SELECT item_id, kind, tmdb_id IS NOT NULL, filled FROM metadata_matches WHERE matched_at < ?", [cutoff]) { ($0.string(0), $0.string(1), $0.bool(2), $0.optString(3)) }
            for (id, kind, matched, filled) in old {
                let table = kind == "series" ? "series" : "movies"
                if let filled, let dict = (try? JSONSerialization.jsonObject(with: Data(filled.utf8))) as? [String: String] {
                    for (col, val) in dict where Self.fillable[col] != nil {
                        if col == "release_year" { try c.execute("UPDATE \(table) SET release_year=NULL WHERE id=? AND release_year=CAST(? AS INTEGER)", [id, val]) }
                        else { try c.execute("UPDATE \(table) SET \(col)=NULL WHERE id=? AND \(col)=?", [id, val]) }
                        n += c.changes
                    }
                } else if matched {
                    // Matched before the fill was recorded: the picture addresses are recognisable by their host; text fields cannot be told apart from the playlist's own, so they stay.
                    for col in ["poster_url", "backdrop_url"] {
                        try c.execute("UPDATE \(table) SET \(col)=NULL WHERE id=? AND \(col) LIKE ?", [id, Self.imageBase + "%"])
                        n += c.changes
                    }
                }
            }
            try c.execute("DELETE FROM metadata_matches WHERE matched_at < ?", [cutoff])
            return n
        }) ?? 0
    }

    /// Removes the saved TMDB details (cast, recommendations, trailers) of titles in these folders and of every copy of those titles (same normalized title or same identity), so nothing
    /// about a title that just became locked or hidden stays readable from a copy that is not. Called when a folder is locked or hidden and at launch for the folders that are restricted then.
    @discardableResult func purgeStored(inFolders ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        return (try? db.write { c in
            var n = 0
            for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
                for table in ["movies", "series"] {
                    try c.execute("""
                        DELETE FROM title_details WHERE item_id IN (SELECT id FROM \(table) WHERE category_id IN (\(marks)))
                           OR item_id IN (SELECT id FROM \(table) WHERE normalized_title IN (SELECT normalized_title FROM \(table) WHERE category_id IN (\(marks))))
                           OR item_id IN (SELECT tw.item_id FROM content_identity me JOIN content_identity tw ON tw.kind = me.kind AND tw.identity_key = me.identity_key
                                          WHERE me.item_id IN (SELECT id FROM \(table) WHERE category_id IN (\(marks))))
                        """, args + args + args)
                    n += c.changes
                }
            }
            return n
        }) ?? 0
    }

    /// The same purge for single hidden titles: their saved details, and those of every copy (same normalized title or same identity).
    @discardableResult func purgeStoredTitles(_ ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        return (try? db.write { c in
            var n = 0
            for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
                for table in ["movies", "series"] {
                    try c.execute("""
                        DELETE FROM title_details WHERE item_id IN (\(marks))
                           OR item_id IN (SELECT id FROM \(table) WHERE normalized_title IN (SELECT normalized_title FROM \(table) WHERE id IN (\(marks))))
                           OR item_id IN (SELECT tw.item_id FROM content_identity me JOIN content_identity tw ON tw.kind = me.kind AND tw.identity_key = me.identity_key WHERE me.item_id IN (\(marks)))
                        """, args + args + args)
                    n += c.changes
                }
            }
            return n
        }) ?? 0
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

    /// SQL that leaves out what must never be sent to TMDB: a title in a locked or hidden folder, and a hidden title. Copies and twins are judged afterwards, with the recommendation rule (`isSendable`).
    private static let unrestricted = """
        (category_id IS NULL OR (category_id NOT IN (SELECT category_id FROM locked_categories) AND category_id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category')))
        AND id NOT IN (SELECT item_id FROM hidden_items)
        """

    /// Whether this title may be sent to TMDB at all: not restricted itself, and with no restricted copy (the recommendation rule, identity included). Fails closed on a read error.
    func isSendable(_ id: String) -> Bool {
        ((try? SQLiteCatalogRepository(db: db).recommendableIDs([id])) ?? []).contains(id)
    }

    /// Items with no poster that haven't been looked up (or whose lookup found nothing long enough ago). Restricted titles (locked or hidden folder, hidden, or with a restricted twin) are never listed, so they are never sent.
    func pending(limit: Int, now: Date = Date()) throws -> (items: [Candidate], total: Int) {
        let cutoff = now.addingTimeInterval(-Self.retryAfter).timeIntervalSince1970
        let cond = "(poster_url IS NULL OR poster_url='') AND id NOT IN (SELECT item_id FROM metadata_matches WHERE tmdb_id IS NOT NULL OR matched_at > \(cutoff)) AND \(Self.unrestricted)"
        let total = try db.read { try $0.scalarInt("SELECT (SELECT COUNT(*) FROM movies WHERE \(cond)) + (SELECT COUNT(*) FROM series WHERE \(cond))") }
        let repo = SQLiteCatalogRepository(db: db)
        var out: [Candidate] = []
        // Pages of the list, each checked against the twin rule, until there are enough (a run of restricted twins at the top cannot starve it).
        for (table, isSeries) in [("movies", false), ("series", true)] {
            var offset = 0
            while out.count < limit {
                let page: [Candidate] = try db.read { c in
                    try c.query("SELECT id, title, release_year FROM \(table) WHERE \(cond) ORDER BY added_at DESC LIMIT ? OFFSET ?", [limit * 2 + 8, offset]) {
                        Candidate(id: $0.string(0), isSeries: isSeries, title: $0.string(1), year: $0.optInt(2)) }
                }
                if page.isEmpty { break }
                let ok = (try? repo.recommendableIDs(page.map(\.id))) ?? []
                out += page.filter { ok.contains($0.id) }.prefix(limit - out.count)
                offset += page.count
            }
        }
        return (out, total)
    }

    /// Looks up to `limit` items. Stops on cancellation and on key/rate-limit problems (which would fail every remaining item).
    func run(limit: Int = 300, progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Outcome {
        guard hasKey else { throw MatchError.noKey }
        purgeExpired()
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

    struct Hit: Equatable, Sendable {
        let tmdbID: Int; let overview: String?; let poster: String?; let backdrop: String?; let year: Int?; let rating: String?
    }

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
            var filled: String?
            if let h = hit {
                let table = item.isSeries ? "series" : "movies"
                // What is blank now is what TMDB is about to fill: remembered (with the values) so the 180-day cap can take back exactly that.
                var f: [String: String] = (try c.queryOne("SELECT filled FROM metadata_matches WHERE item_id = ?", [item.id]) { $0.optString(0) } ?? nil)
                    .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String] } ?? [:]
                if let cur = try c.queryOne("SELECT poster_url, backdrop_url, overview, release_year, rating FROM \(table) WHERE id=?", [item.id], { ($0.optString(0), $0.optString(1), $0.optString(2), $0.optInt(3), $0.optString(4)) }) {
                    func blank(_ s: String?) -> Bool { s?.isEmpty ?? true }
                    if blank(cur.0), let v = h.poster { f["poster_url"] = v }
                    if blank(cur.1), let v = h.backdrop { f["backdrop_url"] = v }
                    if blank(cur.2), let v = h.overview { f["overview"] = v }
                    if cur.3 == nil, let v = h.year { f["release_year"] = String(v) }
                    if blank(cur.4), let v = h.rating { f["rating"] = v }
                }
                if !f.isEmpty, let d = try? JSONSerialization.data(withJSONObject: f) { filled = String(decoding: d, as: UTF8.self) }
                try c.execute("""
                    UPDATE \(table) SET poster_url=COALESCE(NULLIF(poster_url,''),?), backdrop_url=COALESCE(NULLIF(backdrop_url,''),?),
                        overview=COALESCE(NULLIF(overview,''),?), release_year=COALESCE(release_year,?), rating=COALESCE(NULLIF(rating,''),?) WHERE id=?
                    """, [h.poster, h.backdrop, h.overview, h.year, h.rating, item.id])
            }
            try c.execute("INSERT OR REPLACE INTO metadata_matches(item_id, kind, tmdb_id, matched_at, filled) VALUES(?,?,?,?,?)",
                          [item.id, item.isSeries ? "series" : "movie", hit?.tmdbID, Date(), filled])
        }
    }

    // MARK: details (trailers, cast, ...)

    /// Details for a movie or series, from the saved copy when it is recent, otherwise from TMDB (and then saved). The title is
    /// matched to TMDB the same careful way as artwork; nil when there is no key, no confident match, or no connection and no copy.
    func details(for item: Candidate, maxAge: TimeInterval = 14 * 86400, now: Date = Date()) async -> TitleDetails? {
        guard isSendable(item.id) else { return nil }          // a locked or hidden title, or one with a restricted copy: nothing is read, kept or sent, even in a session unlocked with the PIN
        let saved: (json: String, at: Double)? = try? db.read { c in
            try c.queryOne("SELECT json, fetched_at FROM title_details WHERE item_id = ?", [item.id]) { ($0.string(0), $0.double(1)) }
        }
        let cached = saved.flatMap { try? JSONDecoder().decode(TitleDetails.self, from: Data($0.json.utf8)) }
        if let cached, let saved, now.timeIntervalSince1970 - saved.at < maxAge { return cached }
        guard hasKey else { return cached }
        // One request per title at a time: the cast row and the trailer row ask together and share the answer.
        return await inflight.run(item.id) { [self] in await fetchDetails(item, cached: cached, now: now) } ?? cached
    }

    private func fetchDetails(_ item: Candidate, cached: TitleDetails?, now: Date) async -> TitleDetails? {
        var d: TitleDetails?
        if hasKey {
            do {
                var id: Int? = try db.read { c in try c.queryOne("SELECT tmdb_id FROM metadata_matches WHERE item_id = ? AND tmdb_id IS NOT NULL", [item.id]) { $0.optInt(0) } } ?? nil
                if id == nil, let hit = try await lookup(item) { id = hit.tmdbID; try store(item, hit) }
                if let id {
                    let path = item.isSeries ? "/3/tv/\(id)" : "/3/movie/\(id)"
                    let append = item.isSeries ? "videos,credits,recommendations,content_ratings" : "videos,credits,recommendations,release_dates"
                    let data = try await get(path, query: [URLQueryItem(name: "append_to_response", value: append), URLQueryItem(name: "language", value: "en-US")])
                    d = TitleDetailsParser.parse(data, isSeries: item.isSeries)
                }
            } catch { return cached }
        }
        guard let d, let json = try? JSONEncoder().encode(d) else { return cached }
        let text = String(decoding: json, as: UTF8.self)
        try? db.write { try $0.execute("INSERT OR REPLACE INTO title_details(item_id, json, fetched_at) VALUES(?, ?, ?)", [item.id, text, now.timeIntervalSince1970]) }
        return d
    }

    // MARK: network

    /// One rule for every TMDB request: a v4 read-access token (a JWT, or any long token) goes in a header; only a v3 key goes in the query.
    static func isBearerToken(_ key: String) -> Bool { key.hasPrefix("eyJ") || key.count > 40 }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        guard let key = ((try? credentials.load(ref: Self.keyRef)) ?? nil)?.password, !key.isEmpty else { throw MatchError.noKey }
        var comps = URLComponents(); comps.scheme = "https"; comps.host = host; comps.path = path
        var items = query
        let bearer = Self.isBearerToken(key)          // v4 "read access token" vs v3 key (v3 keys can only be sent as a query parameter; TMDB offers no header for them, and request addresses are never logged or shown)
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

/// Shares one running details request per title between callers that ask at the same time (the cast row and the trailer row).
final class InflightDetails: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<TitleDetails?, Never>] = [:]
    func run(_ id: String, _ work: @escaping @Sendable () async -> TitleDetails?) async -> TitleDetails? {
        let task: Task<TitleDetails?, Never> = lock.withLock {
            if let t = tasks[id] { return t }
            let t = Task { await work() }
            tasks[id] = t
            return t
        }
        let result = await task.value
        lock.withLock { if tasks[id] == task { tasks[id] = nil } }
        return result
    }
}
