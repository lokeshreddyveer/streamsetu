import Foundation

/// Fills in missing posters, backdrops, summaries, years and ratings from The Movie Database. The credential is the person's own key when they entered one, else the
/// token built into this build when it has one (see TMDBAccess). Only gaps are filled: whatever the playlist already provides is never replaced. The credential is
/// sent only to api.themoviedb.org; nothing about the library leaves the device except the title (and year) being looked up.
final class MetadataMatchService: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    enum MatchError: LocalizedError, Equatable {
        case noKey, invalidKey, rateLimited, offline, unreadable, switchedOff, notFound
        /// Neutral wording for every screen but Settings: no service is named.
        var errorDescription: String? {
            switch self {
            case .noKey: "No artwork and details key is available. Add your own free key to turn artwork matching on."
            case .invalidKey: "The details service did not accept this key. Check that you copied the whole key."
            case .rateLimited: "The details service asked us to slow down. Try again in a few minutes."
            case .offline: "The details service did not answer, try again."
            case .unreadable: "The details service sent a reply that could not be read."
            case .switchedOff: "Artwork matching is switched off in Settings."
            case .notFound: "The details service has no such title."
            }
        }
        /// For the Settings key test only, where the service may be named.
        var settingsMessage: String {
            switch self {
            case .noKey: "No TMDB key is available. Add your own free key to turn artwork matching on."
            case .invalidKey: "TMDB did not accept this key. Check that you copied the whole key."
            case .rateLimited: "TMDB asked us to slow down. Try again in a few minutes."
            case .offline: "TMDB did not answer, try again."
            case .unreadable: "TMDB sent a reply that could not be read."
            default: errorDescription ?? ""
            }
        }
    }

    struct Progress: Sendable, Equatable { var done = 0, total = 0, matched = 0 }
    struct Outcome: Sendable, Equatable { var looked = 0, matched = 0, unmatched = 0, remaining = 0 }

    static let keyRef = "tmdb-api-key"
    static let attribution = "This product uses the TMDB API but is not endorsed or certified by TMDB."
    static let imageBase = "https://image.tmdb.org/t/p/"
    /// What is written beside a title that found nothing, after both tries. Such a title is not looked up again until this changes (a new version of the matching rules) or its record is
    /// dropped by the 180-day cap. Raise it whenever the cleaning or matching rules change.
    /// Stored instead of the rules version for a name that is not a title (a fixture of two teams, a press conference): never asked for, never counted.
    static let nonTitleMark = "nontitle"
    static let rulesVersion = "v3"   // v3: name-only decision + more query tiers. A "not found" stored under v2 is asked again once, through the same paced bulk queue (pending() lists only titles without a poster and orders newest first; the ratings backfill is separate)

    let db: DatabaseManager
    private let credentials: CredentialStore
    private let fetch: Fetch
    private let pause: UInt64
    private let host: String
    private let inflight = InflightDetails()
    let access: TMDBAccess
    /// Spaces every request out (about 10 a second in the app). Off (interval 0) in tests that do not care.
    let pacer: RequestPacer
    /// True inside work for something the person opened or sees: it uses the express request budget.
    @TaskLocal static var expressLane = false
    private let hint = RetryHint()
    /// The person's switch: when it is off nothing is sent to TMDB at all (matching, cast, trailers, a person look-up). Testing the key is the one exception.
    var lookupsAllowed: @Sendable () -> Bool { get { allow.get() } set { allow.set(newValue) } }
    private let allow = AllowBox()

    init(db: DatabaseManager, credentials: CredentialStore, host: String = "api.themoviedb.org", pause: UInt64 = 0, defaults: UserDefaults = .standard,
         builtIn: @escaping @Sendable () -> String? = { BuiltInTMDB.token() }, pacer: RequestPacer = RequestPacer(interval: 0), fetch: @escaping Fetch) {
        self.db = db; self.credentials = credentials; self.host = host; self.pause = pause; self.fetch = fetch; self.pacer = pacer
        self.access = TMDBAccess(ownKey: { ((try? credentials.load(ref: MetadataMatchService.keyRef)) ?? nil)?.password?.trimmingCharacters(in: .whitespacesAndNewlines) }, builtIn: builtIn, defaults: defaults)
    }

    convenience init(db: DatabaseManager, credentials: CredentialStore, http: HTTPClient, defaults: UserDefaults = .standard, pacer: RequestPacer) {
        self.init(db: db, credentials: credentials, defaults: defaults, pacer: pacer) { try await http.data($0, maxBytes: 2_000_000) }
    }

    /// Seconds TMDB asked us to wait (Retry-After) with the last 429, if it said.
    var lastRetryAfter: TimeInterval? { hint.value }

    /// Nothing from TMDB is kept longer than 180 days (called at launch and before every matching run): saved details (cast, recommendations, trailers) older than that are deleted, and
    /// whatever a lookup filled into a movie or series row (poster, backdrop, summary, year, rating) is taken back, only where the row still holds exactly what TMDB gave (a value the playlist
    /// itself supplied is never touched). The title then looks as the playlist has it, and can be looked up again. The weekly trending list has the same cap in its own cache.
    static let maxKeepDays = Retention.maxKeepDays
    private static let fillable: [String: String] = ["poster_url": "poster_url", "backdrop_url": "backdrop_url", "overview": "overview", "release_year": "release_year", "rating": "rating"]
    @discardableResult func purgeExpired(now: Date = Date()) -> Int {
        let cutoff = now.timeIntervalSince1970 - Double(Self.maxKeepDays) * 86400
        return (try? db.write { c in
            try c.execute("DELETE FROM title_details WHERE fetched_at < ?", [cutoff])
            var n = c.changes
            try c.execute("DELETE FROM rating_checks WHERE checked_at < ?", [cutoff])
            n += c.changes
            try c.execute("DELETE FROM title_details WHERE (item_id LIKE 'person:%' OR item_id LIKE 'personq:%') AND fetched_at < ?", [now.timeIntervalSince1970 - Double(Self.personKeepDays) * 86400])
            n += c.changes
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

    /// Whether TMDB can be used at all: the person's own key, or the built-in token this build carries (and TMDB has not refused).
    var hasKey: Bool { access.credential() != nil }
    /// Whether the person entered a key of their own (the one that is removed with Remove Key).
    var hasOwnKey: Bool { ((try? credentials.load(ref: Self.keyRef)) ?? nil)?.password?.isEmpty == false }
    var keySource: TMDBAccess.Source { access.source }

    func saveKey(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { try credentials.delete(ref: Self.keyRef) } else { try credentials.save(Credentials(username: "tmdb", password: k), ref: Self.keyRef) }
        access.clearRejection()
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
    func verifyKey() async throws { _ = try await get("/3/configuration", query: [], force: true) }

    // MARK: matching

    struct Candidate: Sendable, Equatable { let id: String; let isSeries: Bool; let title: String; let year: Int?
        /// The library's language for the title ("Telugu"), and the ids the provider listed for it, when it did.
        var languageTag = ""; var tmdbID: Int? = nil; var imdbID: String? = nil
        /// Only the rating is wanted (the title is matched already): one small request, for a title on screen.
        var ratingOnly = false
        /// The folder (category) the item sits in: used as the name only when the item's own name cleans to nothing (an episode marker alone). Never sent when the item has a name.
        var folderName = "" }

    /// SQL that leaves out what must never be sent to TMDB: a title in a locked or hidden folder, and a hidden title. Copies and twins are judged afterwards, with the recommendation rule (`isSendable`).
    private static let unrestricted = """
        (category_id IS NULL OR (category_id NOT IN (SELECT category_id FROM locked_categories) AND category_id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category')))
        AND id NOT IN (SELECT item_id FROM hidden_items)
        """

    /// Whether this title may be sent to TMDB at all: not restricted itself, and with no restricted copy (the recommendation rule, identity included). Fails closed on a read error.
    func isSendable(_ id: String) -> Bool {
        ((try? SQLiteCatalogRepository(db: db).recommendableIDs([id])) ?? []).contains(id)
    }

    /// Titles that still need a look-up: no poster or no summary, never looked up (a title that found nothing is remembered under the current rules version).
    /// The bulk run covers titles without a poster only; summaries, backdrops and cast are fetched when a title is opened. Set true to also bulk-match titles that only lack a summary (most Xtream titles do: tens of thousands of calls).
    static let includeSummaryOnly = false
    private static let missing = includeSummaryOnly ? "((poster_url IS NULL OR poster_url='') OR (overview IS NULL OR overview=''))" : "(poster_url IS NULL OR poster_url='')"
    private static let pendingCond = """
        \(missing)
        AND id NOT IN (SELECT item_id FROM metadata_matches WHERE tmdb_id IS NOT NULL OR filled IN ('\(rulesVersion)', '\(nonTitleMark)'))
        AND \(unrestricted)
        """

    /// The next titles to look up, newest first, without the ones in `excluding`. Restricted titles (locked or hidden folder, hidden, or with a restricted twin) are never listed, so they are never sent.
    /// Lists only what is asked for (a few dozen rows), so a 66,000-title library costs the same as a small one; `total` is the count of all that wait.
    func pending(limit: Int, excluding: Set<String> = [], now: Date = Date(), skipped: ((String) -> Void)? = nil) throws -> (items: [Candidate], total: Int) {
        let total = try pendingCount()
        let repo = SQLiteCatalogRepository(db: db)
        var out: [Candidate] = []
        // Pages of the list, each checked against the twin rule, until there are enough (a run of restricted twins at the top cannot starve it).
        for (table, isSeries) in [("movies", false), ("series", true)] {
            var offset = 0
            while out.count < limit {
                let page: [Candidate] = try db.read { c in
                    try c.query("SELECT id, title, release_year, (SELECT lang FROM content_identity WHERE item_id = \(table).id), COALESCE((SELECT tmdb_id FROM provider_ids WHERE item_id = \(table).id), (SELECT tmdb_id FROM hub_identity WHERE item_id = \(table).id)), COALESCE((SELECT imdb_id FROM provider_ids WHERE item_id = \(table).id), (SELECT imdb_id FROM hub_identity WHERE item_id = \(table).id)), category_name FROM \(table) WHERE \(Self.pendingCond) ORDER BY added_at DESC LIMIT ? OFFSET ?", [limit * 2 + 8, offset]) {
                        Candidate(id: $0.string(0), isSeries: isSeries, title: $0.string(1), year: $0.optInt(2), languageTag: $0.optString(3) ?? "", tmdbID: $0.optInt(4), imdbID: $0.optString(5), folderName: $0.optString(6) ?? "") }
                }
                if page.isEmpty { break }
                let fresh = page.filter { !excluding.contains($0.id) }
                let ok = (try? repo.recommendableIDs(fresh.map(\.id))) ?? []
                for c in fresh where !ok.contains(c.id) { skipped?(c.id) }
                out += fresh.filter { ok.contains($0.id) }.prefix(limit - out.count)
                offset += page.count
            }
        }
        return (out, total)
    }

    /// The poster a title has now (a tile that was drawn without one asks when its artwork lands).
    func posterURL(for id: String) -> String? {
        (try? db.read { c in
            try c.queryOne("SELECT poster_url FROM movies WHERE id=? UNION ALL SELECT poster_url FROM series WHERE id=?", [id, id]) { $0.optString(0) }
        }) ?? nil
    }

    /// Whether details with a cast are already saved for this title (the menu offers "Go to Cast" only then).
    func hasSavedCast(_ id: String) -> Bool {
        guard let json = (try? db.read { c in try c.queryOne("SELECT json FROM title_details WHERE item_id=?", [id]) { $0.string(0) } }) ?? nil,
              let d = try? JSONDecoder().decode(TitleDetails.self, from: Data(json.utf8)) else { return false }
        return !d.cast.isEmpty
    }

    /// The rating a title shows now (what a tile asks when its details landed), or nil.
    func ratingValue(for id: String) -> Double? {
        let raw: String? = (try? db.read { c in try c.queryOne("SELECT rating FROM movies WHERE id=? UNION ALL SELECT rating FROM series WHERE id=?", [id, id]) { $0.optString(0) } }) ?? nil
        return RatingRule.credible(raw)
    }

    func pendingCount() throws -> Int {
        try db.read { try $0.scalarInt("SELECT (SELECT COUNT(*) FROM movies WHERE \(Self.pendingCond)) + (SELECT COUNT(*) FROM series WHERE \(Self.pendingCond))") }
    }

    /// Titles looked up so far and how many of them found nothing.
    func lookedUpCounts() -> (done: Int, notFound: Int) {
        // "Not found" is artwork the library still lacks: a rating-only look-up of a title that already has a poster is not an artwork miss.
        (try? db.read { c in (try c.scalarInt("SELECT COUNT(*) FROM metadata_matches WHERE COALESCE(filled, '') <> '\(Self.nonTitleMark)'"), try c.scalarInt("""
            SELECT COUNT(*) FROM metadata_matches m WHERE tmdb_id IS NULL AND COALESCE(filled, '') <> '\(Self.nonTitleMark)' AND (
              EXISTS(SELECT 1 FROM movies t WHERE t.id = m.item_id AND (t.poster_url IS NULL OR t.poster_url = ''))
              OR EXISTS(SELECT 1 FROM series t WHERE t.id = m.item_id AND (t.poster_url IS NULL OR t.poster_url = '')))
            """)) }) ?? (0, 0)
    }

    /// Candidates for these ids, only those that still wait and may be sent (the priority list: what is on screen).
    func candidates(ids: [String]) -> [Candidate] {
        guard !ids.isEmpty else { return [] }
        let sendable = (try? SQLiteCatalogRepository(db: db).recommendableIDs(ids)) ?? []
        var out: [Candidate] = []
        for (table, isSeries) in [("movies", false), ("series", true)] {
            for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
                let rows: [Candidate] = (try? db.read { c in
                    try c.query("SELECT id, title, release_year, (SELECT lang FROM content_identity WHERE item_id = \(table).id), COALESCE((SELECT tmdb_id FROM provider_ids WHERE item_id = \(table).id), (SELECT tmdb_id FROM hub_identity WHERE item_id = \(table).id)), COALESCE((SELECT imdb_id FROM provider_ids WHERE item_id = \(table).id), (SELECT imdb_id FROM hub_identity WHERE item_id = \(table).id)) FROM \(table) WHERE id IN (\(marks)) AND \(Self.pendingCond)", args) { Candidate(id: $0.string(0), isSeries: isSeries, title: $0.string(1), year: $0.optInt(2), languageTag: $0.optString(3) ?? "", tmdbID: $0.optInt(4), imdbID: $0.optString(5)) }
                }) ?? []
                out += rows.filter { sendable.contains($0.id) }
            }
        }
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })          // the same title can be asked for twice (two shelves)
        return out.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    /// Titles (by id) whose rating is missing or junk and that were not asked about yet: matched ones need one small request, unmatched ones are matched first (one search that also carries the rating).
    /// Titles that wait for a poster are left to the bulk run. Used for what is on screen (express lane).
    func ratingCandidates(ids: [String]) -> [Candidate] {
        guard !ids.isEmpty else { return [] }
        let sendable = (try? SQLiteCatalogRepository(db: db).recommendableIDs(ids)) ?? []
        var out: [Candidate] = []
        for (table, isSeries) in [("movies", false), ("series", true)] {
            for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
                out += ratingRows("t.id IN (\(marks))", args, table, isSeries, limit: 400).filter { sendable.contains($0.id) }
            }
        }
        return out
    }

    /// The next titles without a credible rating, newest first, for the slow background pass (matched or not, never restricted).
    func ratingBacklog(limit: Int, excluding: Set<String> = []) -> [Candidate] {
        var out: [Candidate] = []
        let repo = SQLiteCatalogRepository(db: db)
        for (table, isSeries) in [("movies", false), ("series", true)] {
            var offset = 0
            while out.count < limit {
                let rows = ratingRows("1=1", [], table, isSeries, limit: limit * 3, offset: offset).filter { !excluding.contains($0.id) }
                let raw = rows.count
                if raw == 0 { break }
                let ok = (try? repo.recommendableIDs(rows.map(\.id))) ?? []
                out += rows.filter { ok.contains($0.id) }.prefix(limit - out.count)
                offset += limit * 3
                if raw < limit { break }
            }
        }
        return out
    }

    private func ratingRows(_ cond: String, _ args: [(any SQLConvertible)?], _ table: String, _ isSeries: Bool, limit: Int, offset: Int = 0) -> [Candidate] {
        let rows: [(Candidate, String?)] = (try? db.read { c in
            try c.query("""
                SELECT t.id, t.title, t.release_year, m.tmdb_id, t.rating FROM \(table) t LEFT JOIN metadata_matches m ON m.item_id = t.id
                WHERE \(cond) AND \(RatingRule.sqlIsJunk("t.rating"))
                  AND t.id NOT IN (SELECT item_id FROM rating_checks) AND (t.poster_url IS NOT NULL AND t.poster_url <> '')
                ORDER BY t.added_at DESC LIMIT \(limit) OFFSET \(offset)
                """, args) { (Candidate(id: $0.string(0), isSeries: isSeries, title: $0.string(1), year: $0.optInt(2), tmdbID: $0.optInt(3), ratingOnly: true), $0.optString(4)) }
        }) ?? []
        return rows.filter { RatingRule.credible($0.1) == nil }.map(\.0)
    }

    /// One request for a title's TMDB rating (a matched title: its details; an unmatched one: the search first, which carries the rating); written like any other fill, and remembered so it is asked once.
    func backfillRating(_ item: Candidate) async throws {
        guard isSendable(item.id) else { return }
        var text: String?
        if let tmdb = item.tmdbID {
            let data = try await get((item.isSeries ? "/3/tv/" : "/3/movie/") + String(tmdb), query: [URLQueryItem(name: "language", value: "en-US")])
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            text = DisplayRating.tmdbText(average: (j?["vote_average"] as? Double) ?? (j?["vote_average"] as? Int).map(Double.init), votes: j?["vote_count"] as? Int)
            if let text { try db.write { c in try Self.write(c, item, Hit(tmdbID: tmdb, overview: nil, poster: nil, backdrop: nil, year: nil, rating: text)) } }
        } else {
            let hit = try await lookup(item)
            try store(item, hit, notify: false)
            text = hit?.rating
        }
        try db.write { try $0.execute("INSERT OR REPLACE INTO rating_checks(item_id, checked_at) VALUES(?,?)", [item.id, Date().timeIntervalSince1970]) }
        if text != nil { TitleMetadataEvent.post([item.id]) }
    }

    /// Looks up to `limit` items in one go (the "Match now" / test path); the automatic matcher uses `lookupAndStore` item by item instead.
    func run(limit: Int = 300, progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Outcome {
        guard hasKey else { throw MatchError.noKey }
        runCache.clear()
        purgeExpired()
        let (items, total) = try pending(limit: limit)
        var out = Outcome(), p = Progress(done: 0, total: items.count)
        for item in items {
            try Task.checkCancellation()
            let hit = try await lookupAndStore(item)
            out.looked += 1
            if hit != nil { out.matched += 1 } else { out.unmatched += 1 }
            p.done += 1; p.matched = out.matched; progress(p)
            if pause > 0 { try await Task.sleep(nanoseconds: pause) }
        }
        out.remaining = max(0, total - items.count)
        return out
    }

    /// The look-up half, for callers that write the answers in batches (the sendable check is made here, at the moment of sending).
    func lookupForBatch(_ item: Candidate) async throws -> Hit?? {
        guard isSendable(item.id) else { return nil }
        return .some(try await lookup(item))
    }

    /// One title: look it up (with the second try), and write the answer down. A title that is not sendable any more is left alone (nothing is sent).
    @discardableResult func lookupAndStore(_ item: Candidate) async throws -> Hit? {
        guard isSendable(item.id) else { return nil }
        let hit = try await lookup(item)
        try store(item, hit, notify: false)
        return hit
    }

    struct Hit: Equatable, Sendable {
        let tmdbID: Int; let overview: String?; let poster: String?; let backdrop: String?; let year: Int?; let rating: String?
    }

    /// Engine v2. A title the provider gave a TMDB id (or IMDb id) for is fetched by it, with no search. Otherwise: one search without the year (en-US), the choice made locally by
    /// `ArtworkMatchDecision`; and only when that finds nothing sure, at most three more: without the last word, without the first word. A title is never given a poster unless the decision is sure; two equally good answers leave it unmatched.
    func lookup(_ item: Candidate) async throws -> Hit? {
        if let hit = try await lookupByProviderID(item) { return hit }
        if Self.isNonTitle(item.title, year: item.year) { return nil }
        var parsed = ArtworkNameCleaner.parse(item.title, year: item.year)
        // A name that cleans to nothing or to an episode marker alone ("S01E04", "Episode 12") borrows the folder's name.
        if Self.isMarkerOnly(parsed.text), !item.folderName.isEmpty { parsed = ArtworkNameCleaner.parse(item.folderName, year: item.year) }
        let text = parsed.text, year = parsed.year
        guard !text.isEmpty, !Self.isMarkerOnly(text) else { return nil }
        // One resolution per series (or title) per run: every episode and sibling whose name cleans to the same text inherits the first answer, so TMDB is asked once.
        let cacheKey = (item.isSeries ? "tv|" : "movie|") + ArtworkMatchDecision.canon(text)
        if !seriesCacheEnabled { return try await resolve(item, text: text, year: year) }
        return try await runCache.resolve(cacheKey) { try await self.resolve(item, text: text, year: year) }
    }

    /// "season" is available but off: the name cleaner already cuts there (measured: no gain). The other three: measured +3.7 pt on the new-noise rows for +3 wrong in 600.
    nonisolated(unsafe) var extraTiers: Set<String> = ["year", "lang-tail", "lang-head"]

    /// Fallback query texts, each shorter than the name, in this order: the name cut at a Season/Episode marker, cut at a year that follows a word, without a trailing language word, without a leading one.
    static func extraQueries(_ text: String, tiers: Set<String>) -> [String] {
        var out: [String] = []
        func add(_ t: String) { let x = t.trimmingCharacters(in: CharacterSet(charactersIn: " -:|,")); if x.count >= 2, x != text, !out.contains(x) { out.append(x) } }
        if tiers.contains("season"), let r = text.range(of: #"(?i)\s+(?:(?:season|series|saison|temporada|staffel)\s*\d+|episode\s*\d+|ep\s*\d+|s\d{1,2}\s?e\d{1,3})\b.*$"#, options: .regularExpression) { add(String(text[..<r.lowerBound])) }
        if tiers.contains("year"), let r = text.range(of: #"\s+(?:19\d{2}|20[0-2]\d|2030)\b.*$"#, options: .regularExpression), text.distance(from: text.startIndex, to: r.lowerBound) > 1 { add(String(text[..<r.lowerBound])) }
        let words = text.split(separator: " ").map(String.init)
        if tiers.contains("lang-tail"), words.count >= 2, languageWords.contains(words[words.count - 1].lowercased()) { add(words.dropLast().joined(separator: " ")) }
        if tiers.contains("lang-head"), words.count >= 2, languageWords.contains(words[0].lowercased()) { add(words.dropFirst().joined(separator: " ")) }
        return out
    }
    static let languageWords: Set<String> = Set(ArtworkMatchDecision.languageCodes.keys).union(["multi", "dual", "dubbed", "subbed", "sub", "dub"])

    /// A name that is not a title: a fixture of two sides without a year ("Team A vs Team B"), or a recording of an event (highlights, press conference, pay-per-view, weigh-in).
    static func isNonTitle(_ raw: String, year: Int?) -> Bool {
        let low = raw.lowercased()
        if low.range(of: #"\b(highlights|press conference|post[- ]?match|pre[- ]?match|weigh[- ]?in|ppv|full match|full replay)\b"#, options: .regularExpression) != nil { return true }
        return year == nil && low.range(of: #"\S\s+vs\.?\s+\S"#, options: .regularExpression) != nil && low.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) == nil
    }

    static func isMarkerOnly(_ t: String) -> Bool {
        t.isEmpty || t.range(of: #"^(s\d{1,2}\s?e\d{1,3}|\d{1,2}x\d{1,3}|(episode|ep|episodio|folge|e)\s?\d{1,3})$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Answers found in this run, by kind and normalised cleaned name; a sibling asking while the first is still searching waits for the same answer. Cleared when a run starts; bounded; a thrown error is never kept.
    let runCache = RunResolutionCache()
    final class RunResolutionCache: @unchecked Sendable {
        private let lock = NSLock(); private var map: [String: Task<Hit?, Error>] = [:]
        func resolve(_ k: String, _ make: @escaping @Sendable () async throws -> Hit?) async throws -> Hit? {
            let t: Task<Hit?, Error> = lock.withLock {
                if let t = map[k] { return t }
                if map.count >= 8192 { map.removeAll(keepingCapacity: true) }
                let t = Task { try await make() }; map[k] = t; return t
            }
            do { return try await t.value } catch { lock.withLock { if map[k] == t { map[k] = nil } }; throw error }
        }
        func clear() { lock.withLock { map.removeAll() } }
        var count: Int { lock.withLock { map.count } }
    }

    private func resolve(_ item: Candidate, text: String, year: Int?) async throws -> Hit? {
        let q = ArtworkMatchDecision.Query(title: item.title, year: year, isSeries: item.isSeries, languageTag: item.languageTag)
        let path = item.isSeries ? "/3/search/tv" : "/3/search/movie"
        var seen: [SearchResult] = []
        func search(_ query: String) async throws -> [SearchResult] {
            var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false"), URLQueryItem(name: "language", value: "en-US")]
            let data = try await get(path, query: items)
            guard let reply = try? JSONDecoder().decode(SearchReply.self, from: data) else { throw MatchError.unreadable }
            for r in reply.results where !seen.contains(where: { $0.id == r.id }) { seen.append(r) }
            return reply.results
        }
        func decide() -> Hit? {
            guard let id = ArtworkMatchDecision.decide(q, seen.map(Self.candidate), text: text), let r = seen.first(where: { $0.id == id }) else { return nil }
            return Self.hit(r)
        }
        _ = try await search(text)
        if let h = decide() { return h }
        // The offline alias index, by name only: the name is an alias (other language, other script, alternative title) of one film or series; its details are fetched by that id.
        if let h = try await aliasHit(text, isSeries: item.isSeries, phonetic: false) { return h }
        let words = text.split(separator: " ")
        // A year left on the end of the name ("Hospital Playlist 2020"): the name is searched again without it (the year is never used to decide).
        if words.count >= 2, let last = words.last, last.count == 4, let ty = Int(last), (1900...2030).contains(ty) {
            _ = try await search(words.dropLast().joined(separator: " "))
            if let id = ArtworkMatchDecision.decide(q, seen.map(Self.candidate), text: words.dropLast().joined(separator: " ")), let r = seen.first(where: { $0.id == id }) { return Self.hit(r) }
        }
        if words.count >= 3 { _ = try await search(words.dropLast().joined(separator: " ")); if let h = decide() { return h } }
        if words.count >= 3 { _ = try await search(words.dropFirst().joined(separator: " ")); if let h = decide() { return h } }
        // More NAME-only attempts (cut at a season/episode marker, at a year, a language word at either end); the same name-equality decision gates every answer, and a year or language is never a match signal.
        for t in Self.extraQueries(text, tiers: extraTiers) {
            _ = try await search(t)
            if let id = ArtworkMatchDecision.decide(q, seen.map(Self.candidate), text: t), let r = seen.first(where: { $0.id == id }) { return Self.hit(r) }
        }
        // Phonetic tiers of the alias index (same skeleton, then one edit away): "Bahubali", "Dhoom Machale".
        if let h = try await aliasHit(text, isSeries: item.isSeries, phonetic: true) { return h }
        // Last resort, only when TMDB found nothing at all: the other common spellings of an Indian or Asian name ("Baahubalee" -> "Bahubali"). The search is not phonetic, so the spellings are asked for; the decision still has to find the name close.
        if seen.isEmpty { for v in Self.spellingVariants(text).prefix(3) { _ = try await search(v); if let h = decide() { return h } } }
        return nil
    }

    /// The alias index in use (nil: none shipped or loaded). Set by the app at start; tests set their own.
    private let aliasLock = NSLock()
    private nonisolated(unsafe) var aliasStore: AliasIndex?
    private nonisolated(unsafe) var tierCounts: [String: Int] = [:]
    /// Switches (on by default) so the measurements can switch one part off at a time.
    /// Both alias tiers are OFF by default: measured with the seed index, exact added 6 wrong and no recall, phonetic +0.2 pt for +6 wrong (report-final.md).
    nonisolated(unsafe) var aliasExactEnabled = false
    nonisolated(unsafe) var aliasPhoneticEnabled = false
    nonisolated(unsafe) var seriesCacheEnabled = true
    private nonisolated(unsafe) var aliasTried = false
    /// The shipped index is read from the app's resources on first use (nil when the build has none); tests and the measurements set their own.
    var aliasIndex: AliasIndex? {
        get { aliasLock.withLock { if aliasStore == nil, !aliasTried { aliasTried = true; aliasStore = AliasIndex.bundled() }; return aliasStore } }
        set { aliasLock.withLock { aliasStore = newValue; aliasTried = true } }
    }
    /// Counts for the measurements: how many answers came from which alias tier.
    var aliasTierCounts: [String: Int] { aliasLock.withLock { tierCounts } }

    private func aliasHit(_ text: String, isSeries: Bool, phonetic: Bool) async throws -> Hit? {
        guard phonetic ? aliasPhoneticEnabled : aliasExactEnabled, let idx = aliasIndex else { return nil }
        let found: (AliasIndex.Entry, AliasIndex.Tier)? = phonetic ? idx.phonetic(text, isSeries: isSeries) : idx.exact(text, isSeries: isSeries).map { ($0, .exact) }
        guard let (e, tier) = found else { return nil }
        do {
            let data = try await get((isSeries ? "/3/tv/" : "/3/movie/") + String(e.tmdbID), query: [URLQueryItem(name: "language", value: "en-US")])
            guard let r = try? JSONDecoder().decode(SearchResult.self, from: data) else { return nil }
            aliasLock.withLock { tierCounts[tier.rawValue, default: 0] += 1 }
            return Self.hit(r)
        } catch MatchError.notFound { return nil }
    }

    /// Alternative Latin spellings of a name: long vowels and doubled letters shortened, and the aspirate h dropped (A), the same with ee/oo read as i/u (B). Only those that differ from the name; names of under 5 letters get none.
    static func spellingVariants(_ text: String) -> [String] {
        let low = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        guard low.filter(\.isLetter).count >= 5, low.unicodeScalars.allSatisfy({ $0.isASCII }) else { return [] }
        func shorten(_ s: String, _ pairs: [(String, String)]) -> String {
            var t = s
            for (a, b) in pairs { t = t.replacingOccurrences(of: a, with: b) }
            return t.replacingOccurrences(of: #"([b-df-hj-np-tv-z])\1"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"\b([a-z]*[tdbkgp])h"#, with: "$1", options: .regularExpression)
        }
        let a = shorten(low, [("aa", "a"), ("ee", "e"), ("oo", "o"), ("ii", "i"), ("uu", "u")])
        let b = shorten(low, [("aa", "a"), ("ee", "i"), ("oo", "u"), ("ii", "i"), ("uu", "u"), ("ou", "u"), ("ae", "e"), ("ay", "ai")])
        // C: A with v read as w (Santhvaanam / Santhwanam); D: letters repeated three or more times cut to two first (Cooontdown), then A.
        let c = a.replacingOccurrences(of: "v", with: "w")
        let d = shorten(low.replacingOccurrences(of: #"(.)\1{2,}"#, with: "$1$1", options: .regularExpression), [("aa", "a"), ("ee", "e"), ("oo", "o"), ("ii", "i"), ("uu", "u")])
        var out: [String] = []
        for v in [a, b, c, d] where v != low && !out.contains(v) { out.append(v) }
        return out
    }

    /// The provider's own id: the title is fetched by it ("exact match, no search"). A missing or unknown id falls back to the search.
    private func lookupByProviderID(_ item: Candidate) async throws -> Hit? {
        var tmdb = item.tmdbID, imdb = item.imdbID
        if tmdb == nil, imdb == nil, let ids = ProviderIDStore(db: db).ids(for: item.id) { tmdb = ids.tmdb; imdb = ids.imdb }
        if tmdb == nil, imdb == nil, Self.expressLane, let ask = providerLookupBox.get() {          // only for a title the person opened: it costs the provider one request
            tmdb = await ask(item)
            if let tmdb { ProviderIDStore(db: db).save([item.id: ProviderIDs(tmdb: tmdb, imdb: nil)]) }
        }
        if let id = tmdb {
            do {
                let data = try await get((item.isSeries ? "/3/tv/" : "/3/movie/") + String(id), query: [URLQueryItem(name: "language", value: "en-US")])
                if let r = try? JSONDecoder().decode(SearchResult.self, from: data) { return Self.hit(r) }
            } catch MatchError.notFound { }
        }
        if let imdb {
            let data = try await get("/3/find/" + imdb, query: [URLQueryItem(name: "external_source", value: "imdb_id"), URLQueryItem(name: "language", value: "en-US")])
            if let reply = try? JSONDecoder().decode(FindReply.self, from: data), let r = (item.isSeries ? reply.tv_results : reply.movie_results)?.first { return Self.hit(r) }
        }
        return nil
    }
    struct FindReply: Decodable { let movie_results: [SearchResult]?; let tv_results: [SearchResult]? }

    /// Asks the provider (get_vod_info / get_series_info) for its TMDB id of an opened title; set by the app. Only used when a title is opened.
    func setProviderLookup(_ f: @escaping @Sendable (Candidate) async -> Int?) { providerLookupBox.set(f) }
    private let providerLookupBox = ProviderLookupBox()

    static func candidate(_ r: SearchResult) -> ArtworkMatchDecision.Candidate {
        .init(id: r.id, title: r.title ?? r.name, originalTitle: r.original_title ?? r.original_name, year: (r.release_date ?? r.first_air_date).flatMap { Int($0.prefix(4)) },
              popularity: r.popularity ?? 0, originalLanguage: r.original_language)
    }
    static func hit(_ r: SearchResult) -> Hit {
        Hit(tmdbID: r.id, overview: r.overview.flatMap { $0.isEmpty ? nil : $0 }, poster: r.poster_path.map { imageBase + "w500" + $0 }, backdrop: r.backdrop_path.map { imageBase + "w1280" + $0 },
            year: (r.release_date ?? r.first_air_date).flatMap { Int($0.prefix(4)) }, rating: DisplayRating.tmdbText(average: r.vote_average, votes: r.vote_count))
    }

    /// Years may differ by one only for a longer title: a one-word name or one under 8 letters needs the exact year.
    static func yearTolerance(for text: String) -> Int {
        let n = MetadataNormalizer.normalize(text)
        return n.split(separator: " ").count < 2 || n.filter(\.isLetter).count < 8 ? 0 : 1
    }

    static let minSimilarity = ArtworkMatchDecision.minSimilarity
    static func similarity(_ a: String, _ b: String) -> Double { ArtworkMatchDecision.similarity(a, b) }

    /// Picks the result that is this title, or none (see `ArtworkMatchDecision`).
    static func best(_ results: [SearchResult], for text: String, year: Int?, withoutYearSearch: Bool = false) -> Hit? {
        let q = ArtworkMatchDecision.Query(title: text, year: year, isSeries: results.first?.name != nil && results.first?.title == nil)
        guard let id = ArtworkMatchDecision.decide(q, results.map(candidate), text: text) else { return nil }
        return results.first { $0.id == id }.map(hit)
    }

    struct SearchReply: Decodable { let results: [SearchResult] }
    struct SearchResult: Decodable {
        let id: Int
        let title: String?, name: String?, original_title: String?, original_name: String?
        let overview: String?, poster_path: String?, backdrop_path: String?
        let release_date: String?, first_air_date: String?
        let vote_average: Double?
        var vote_count: Int? = nil
        let popularity: Double?
        var original_language: String? = nil
    }

    func store(_ item: Candidate, _ hit: Hit?, notify: Bool = true) throws {
        try db.write { c in try Self.write(c, item, hit) }
        if notify, hit != nil { TitleMetadataEvent.post([item.id]) }
    }

    /// Many answers in one transaction (the automatic matcher writes about fifty at a time).
    func storeBatch(_ rows: [(item: Candidate, hit: Hit?)]) throws {
        guard !rows.isEmpty else { return }
        try db.write { c in for r in rows { try Self.write(c, r.item, r.hit) } }
    }

    private static func write(_ c: Connection, _ item: Candidate, _ hit: Hit?) throws {
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
                    if let v = h.rating, cur.4 != v { f["rating"] = v }          // a credible TMDB rating replaces a missing or junk one, and is taken back with the rest
                }
                if !f.isEmpty, let d = try? JSONSerialization.data(withJSONObject: f) { filled = String(decoding: d, as: UTF8.self) }
                try c.execute("""
                    UPDATE \(table) SET poster_url=COALESCE(NULLIF(poster_url,''),?), backdrop_url=COALESCE(NULLIF(backdrop_url,''),?),
                        overview=COALESCE(NULLIF(overview,''),?), release_year=COALESCE(release_year,?), rating=COALESCE(?, NULLIF(rating,'')) WHERE id=?
                    """, [h.poster, h.backdrop, h.overview, h.year, h.rating, item.id])
            }
            try c.execute("INSERT OR REPLACE INTO metadata_matches(item_id, kind, tmdb_id, matched_at, filled) VALUES(?,?,?,?,?)",
                          [item.id, item.isSeries ? "series" : "movie", hit?.tmdbID, Date(), hit == nil ? (Self.isNonTitle(item.title, year: item.year) ? Self.nonTitleMark : Self.rulesVersion) : filled])
    }

    // MARK: details (trailers, cast, ...)

    /// Details for a movie or series, from the saved copy when it is recent, otherwise from TMDB (and then saved). The title is
    /// matched to TMDB the same careful way as artwork; nil when there is no key, no confident match, or no connection and no copy.
    func details(for item: Candidate, maxAge: TimeInterval = Retention.detailsRefresh, now: Date = Date()) async -> TitleDetails? {
        guard isSendable(item.id) else { return nil }          // a locked or hidden title, or one with a restricted copy: nothing is read, kept or sent, even in a session unlocked with the PIN
        let saved: (json: String, at: Double)? = try? db.read { c in
            try c.queryOne("SELECT json, fetched_at FROM title_details WHERE item_id = ?", [item.id]) { ($0.string(0), $0.double(1)) }
        }
        let cached = saved.flatMap { try? JSONDecoder().decode(TitleDetails.self, from: Data($0.json.utf8)) }
        if let cached, let saved, now.timeIntervalSince1970 - saved.at < maxAge {
            // Saved before the page learned to fill a missing backdrop or poster: look once an hour more while the picture is still blank.
            guard hasKey, now.timeIntervalSince1970 - saved.at > 3600, missingArtwork(item) else { return cached }
        }
        guard hasKey else { return cached }
        // One request per title at a time: the cast row and the trailer row ask together and share the answer.
        return await Self.$expressLane.withValue(true) { await inflight.run(item.id) { [self] in await fetchDetails(item, cached: cached, now: now) } } ?? cached
    }

    private func fetchDetails(_ item: Candidate, cached: TitleDetails?, now: Date) async -> TitleDetails? {
        var d: TitleDetails?
        if hasKey {
            do {
                var id: Int? = try db.read { c in try c.queryOne("SELECT tmdb_id FROM metadata_matches WHERE item_id = ? AND tmdb_id IS NOT NULL", [item.id]) { $0.optInt(0) } } ?? nil
                if id == nil, let hit = try await lookup(item) { id = hit.tmdbID; try store(item, hit) }
                if let id {
                    let path = item.isSeries ? "/3/tv/\(id)" : "/3/movie/\(id)"
                    let append = item.isSeries ? "videos,credits,images,recommendations,content_ratings,external_ids,translations" : "videos,credits,images,recommendations,release_dates,external_ids,translations"
                    let data = try await get(path, query: [URLQueryItem(name: "append_to_response", value: append), URLQueryItem(name: "language", value: "en-US")])
                    d = TitleDetailsParser.parse(data, isSeries: item.isSeries)
                    fillGaps(item, tmdbID: id, from: data)
                    if let extras = TMDBExtras.parse(data, isSeries: item.isSeries) { HubStore(db: db).saveTMDBExtras(item.id, extras) }          // the other services' ids and the Hindi/Telugu text
                }
            } catch { return cached }
        }
        guard let d, let json = try? JSONEncoder().encode(d) else { return cached }
        let text = String(decoding: json, as: UTF8.self)
        try? db.write { try $0.execute("INSERT OR REPLACE INTO title_details(item_id, json, fetched_at) VALUES(?, ?, ?)", [item.id, text, now.timeIntervalSince1970]) }
        TitleMetadataEvent.post([item.id])
        return d
    }

    private func missingArtwork(_ item: Candidate) -> Bool {
        let table = item.isSeries ? "series" : "movies"
        return (try? db.read { c in try c.queryOne("SELECT (backdrop_url IS NULL OR backdrop_url='') FROM \(table) WHERE id=?", [item.id]) { $0.bool(0) } }) ?? false == true
    }

    /// A title matched earlier (by id) may still lack the backdrop, poster or summary: the details reply carries them, so the blanks are filled now (never a value the playlist has).
    /// The page that asked is told through `titleMetadataLanded` when the details are saved.
    private func fillGaps(_ item: Candidate, tmdbID: Int, from data: Data) {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        func text(_ k: String) -> String? { (j[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let date = text(item.isSeries ? "first_air_date" : "release_date")
        let hit = Hit(tmdbID: tmdbID, overview: text("overview"), poster: text("poster_path").map { Self.imageBase + "w500" + $0 }, backdrop: text("backdrop_path").map { Self.imageBase + "w1280" + $0 },
                      year: date.flatMap { Int($0.prefix(4)) }, rating: DisplayRating.tmdbText(average: (j["vote_average"] as? Double) ?? (j["vote_average"] as? Int).map(Double.init), votes: j["vote_count"] as? Int))
        let table = item.isSeries ? "series" : "movies"
        let blank = (try? db.read { c in try c.queryOne("SELECT (poster_url IS NULL OR poster_url=''), (backdrop_url IS NULL OR backdrop_url=''), (overview IS NULL OR overview=''), rating FROM \(table) WHERE id=?", [item.id]) { ($0.bool(0), $0.bool(1), $0.bool(2), $0.optString(3)) } }) ?? nil
        guard let blank, (blank.0 && hit.poster != nil) || (blank.1 && hit.backdrop != nil) || (blank.2 && hit.overview != nil) || (hit.rating != nil && hit.rating != blank.3) else { return }
        try? store(item, hit, notify: false)
    }

    // MARK: network

    /// One rule for every TMDB request: a v4 read-access token (a JWT, or any long token) goes in a header; only a v3 key goes in the query.
    static func isBearerToken(_ key: String) -> Bool { key.hasPrefix("eyJ") || key.count > 40 }

    func get(_ path: String, query: [URLQueryItem], force: Bool = false) async throws -> Data {
        guard force || lookupsAllowed() else { throw MatchError.switchedOff }
        guard let credential = access.credential() else { throw MatchError.noKey }
        var comps = URLComponents(); comps.scheme = "https"; comps.host = host; comps.path = path
        comps.queryItems = query.isEmpty ? nil : query
        // v3 keys can only be sent as a query parameter; TMDB offers no header for them, and request addresses are never logged or shown. The built-in token is always a header.
        guard let url = comps.url, let req = access.sign(url) else { throw MatchError.unreadable }
        try await pacer.wait(express: Self.expressLane)
        do { return try await fetch(req) }
        catch let e as NetworkError {
            if case .http(let status, let after) = e {
                if status == 429 { hint.set(after) }
                if BuiltInKeyPause.isRefusal(status) && credential.source == .builtIn { access.markBuiltInRejected() }          // revoked or suspended: set aside, quietly
            }
            throw Self.map(e)
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw MatchError.offline }                          // never surface the error text: it can contain the request URL
    }

    private static func map(_ e: NetworkError) -> MatchError {
        switch e {
        case .http(let status, _): status == 401 || status == 403 ? .invalidKey : status == 429 ? .rateLimited : status == 404 ? .notFound : .offline
        case .cancelled: .offline
        default: .offline
        }
    }
}

extension Notification.Name {
    /// Posted (on any thread) when artwork or details for titles were written down. Post and read it only through `TitleMetadataEvent`.
    static let titleMetadataLanded = Notification.Name("streamsetu.titleMetadataLanded")
}

/// The payload of `.titleMetadataLanded`, typed: the items that landed, and whether it was a bulk run (only bulk runs refresh the whole library's tiles; a single title page is told by its id).
struct TitleMetadataEvent: Sendable, Equatable {
    var ids: [String]
    var bulk = false
    static func post(_ ids: [String], bulk: Bool = false) {
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: .titleMetadataLanded, object: nil, userInfo: bulk ? ["ids": ids, "bulk": true] : ["ids": ids])
    }
    init(ids: [String], bulk: Bool = false) { self.ids = ids; self.bulk = bulk }
    init(_ n: Notification) { ids = n.userInfo?["ids"] as? [String] ?? []; bulk = n.userInfo?["bulk"] as? Bool == true }
}

final class ProviderLookupBox: Sendable {
    private let f = Locked<(@Sendable (MetadataMatchService.Candidate) async -> Int?)?>(nil)
    func get() -> (@Sendable (MetadataMatchService.Candidate) async -> Int?)? { f.value }
    func set(_ x: @escaping @Sendable (MetadataMatchService.Candidate) async -> Int?) { f.value = x }
}

final class AllowBox: Sendable {
    private let f = Locked<@Sendable () -> Bool>({ true })
    func get() -> @Sendable () -> Bool { f.value }
    func set(_ x: @escaping @Sendable () -> Bool) { f.value = x }
}

final class RetryHint: Sendable {
    /// The last Retry-After and when it came. A success of another request does NOT clear it (with parallel workers that raced the worker that was told to wait); it simply goes stale after two minutes.
    private let v = Locked<(after: TimeInterval, at: Date)?>(nil)
    var value: TimeInterval? { v.value.flatMap { Date().timeIntervalSince($0.at) < 120 ? $0.after : nil } }
    func set(_ x: TimeInterval?) { v.value = x.map { ($0, Date()) } }
}

/// Turns a provider title ("EN - The Matrix (1999) 4K") into something TMDB can search for (see ArtworkNameCleaner).
enum TitleCleaner {
    static func query(_ title: String, year: Int?) -> (text: String, year: Int?) { let p = ArtworkNameCleaner.parse(title, year: year); return (p.text, p.year) }
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
