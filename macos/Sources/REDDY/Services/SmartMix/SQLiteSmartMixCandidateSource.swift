import Foundation

/// The SQL adapter between the identity layer (`content_identity`, SchemaV19) and the pure Smart Mix engine.
///
/// A shelf never reads the whole library: a pool of about 2,000 titles per kind is chosen by indexed queries (newest, best rated, the preferred language, what was
/// watched lately, this week's trending keys), then every copy of those titles is read so twin playlists and other-language versions group into one title. Each
/// candidate carries `restricted` and `dismissed` at identity level: a title is restricted when ANY copy sits in a locked or hidden folder (or is hidden itself).
/// No title text, address or login is read here: ids, identity keys, counts and flags only.
final class SQLiteSmartMixCandidateSource: SmartMixCandidateSource, @unchecked Sendable {
    let db: DatabaseManager
    static let defaultPool = 2000

    private let lock = NSLock()
    private var rev = SMRevision()
    private var trendKeys: Set<String> = []
    private var source: UUID?
    private var lang: String?
    private(set) var lastReadMillis = 0

    init(db: DatabaseManager) { self.db = db }

    // MARK: revision

    func bump(_ kp: WritableKeyPath<SMRevision, Int>) { lock.withLock { rev[keyPath: kp] += 1; cover = nil } }
    func revision(profile: String) async -> SMRevision { lock.withLock { rev } }

    /// Playlist filter (nil = all enabled playlists) and the preferred language (English name). A change is a new revision.
    func configure(sourceID: UUID?, preferredLanguage: String?) {
        lock.withLock {
            if source != sourceID { source = sourceID; rev.catalog += 1 }
            if lang != preferredLanguage { lang = preferredLanguage; rev.prefs += 1 }
        }
    }

    func setTrendingKeys(_ keys: Set<String>) { lock.withLock { trendKeys = keys } }

    // MARK: candidates

    func candidates(profile: String, scope: SMScope, poolLimit: Int) async throws -> [SMCandidate] {
        let (src, lang, trend) = lock.withLock { (source, self.lang, trendKeys) }
        let started = DispatchTime.now()
        let out = try db.read { c in try Self.read(c, profile: profile, scope: scope, pool: poolLimit, source: src, lang: lang, trend: trend, now: Date()) }
        lock.withLock { lastReadMillis = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000) }
        return out
    }

    /// Whether the identity table covers (almost) every title; below 99 % the caller keeps the older Home. The answer is kept for a short while (30 s when covered, 5 s when not, and dropped
    /// at once by any revision bump), because every folder row asks and each ask is a full count over the table.
    func coverageOK(now: Date = Date()) -> Bool {
        if let c = lock.withLock({ cover }), now.timeIntervalSince(c.at) < (c.ok ? 30 : 5) { return c.ok }
        let ok: Bool
        lock.withLock { coverageScans += 1 }
        if let r = try? IdentityStore(db: db).coverage() { ok = r.total == 0 || r.done * 100 >= r.total * 99 } else { ok = false }
        lock.withLock { cover = (now, ok) }
        return ok
    }
    private var cover: (at: Date, ok: Bool)?
    private(set) var coverageScans = 0

    // MARK: SQL

    private struct YearSet { var anyYear = false; var years: Set<Int> = [] }

    private static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    /// Stage timings (milliseconds) of the last read, for the benchmark. Counts only.
    nonisolated(unsafe) static var trace: ((String, Int) -> Void)?
    private static func lap(_ name: String, _ t0: inout DispatchTime) { let n = DispatchTime.now(); trace?(name, Int((n.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)); t0 = n }

    static func read(_ c: Connection, profile: String, scope: SMScope, pool: Int, source: UUID?, lang: String?, trend: Set<String>, now: Date) throws -> [SMCandidate] {
        let nowT = now.timeIntervalSince1970
        var t0 = DispatchTime.now()
        // Restricted folders and hidden titles (small tables).
        let badCats = Set(try c.query("SELECT category_id FROM locked_categories UNION SELECT item_id FROM hidden_items WHERE kind='category'") { $0.string(0) })
        let hiddenItems = Set(try c.query("SELECT item_id FROM hidden_items WHERE kind<>'category'") { $0.string(0) })
        var restrictedKeys: [String: YearSet] = [:]
        func addKey(_ kind: String, _ key: String, _ year: Int?) {
            let k = kind + "\u{1}" + key
            if let y = year { restrictedKeys[k, default: YearSet()].years.insert(y) } else { restrictedKeys[k, default: YearSet()].anyYear = true }
        }
        if !badCats.isEmpty {
            let sql = """
                SELECT ci.kind, ci.identity_key, ci.year FROM content_identity ci JOIN %@ t ON t.id = ci.item_id
                WHERE ci.kind = '%@' AND t.category_id IN (SELECT category_id FROM locked_categories UNION SELECT item_id FROM hidden_items WHERE kind='category')
                """
            for (table, kind) in [("movies", "movie"), ("series", "series")] {
                for r in try c.query(String(format: sql, table, kind), [], { ($0.string(0), $0.string(1), $0.optInt(2)) }) { addKey(r.0, r.1, r.2) }
            }
        }
        if !hiddenItems.isEmpty {
            for chunk in stride(from: 0, to: hiddenItems.count, by: 400).map({ Array(Array(hiddenItems)[$0..<min($0 + 400, hiddenItems.count)]) }) {
                for r in try c.query("SELECT kind, identity_key, year FROM content_identity WHERE item_id IN (\(marks(chunk.count)))", chunk.map { $0 as (any SQLConvertible)? }, { ($0.string(0), $0.string(1), $0.optInt(2)) }) { addKey(r.0, r.1, r.2) }
            }
        }
        // Fail closed for a restricted copy that has no identity row yet (a backfill still running, a version bump): the key rule above cannot see it, so its normalized title and year
        // are read straight from the playlist tables. A copy that has an identity row is judged by the key rule alone.
        var restrictedTitles: [String: YearSet] = [:]
        if !badCats.isEmpty || !hiddenItems.isEmpty {
            func addTitle(_ t: String?, _ y: Int?) {
                guard let t, !t.isEmpty else { return }
                if let y { restrictedTitles[t, default: YearSet()].years.insert(y) } else { restrictedTitles[t, default: YearSet()].anyYear = true }
            }
            for table in ["movies", "series"] {
                if !badCats.isEmpty {
                    for r in try c.query("SELECT normalized_title, release_year FROM \(table) t WHERE category_id IN (SELECT category_id FROM locked_categories UNION SELECT item_id FROM hidden_items WHERE kind='category') AND NOT EXISTS (SELECT 1 FROM content_identity ci WHERE ci.item_id = t.id)", [], { ($0.optString(0), $0.optInt(1)) }) { addTitle(r.0, r.1) }
                }
                if !hiddenItems.isEmpty {
                    for chunk in stride(from: 0, to: hiddenItems.count, by: 400).map({ Array(Array(hiddenItems)[$0..<min($0 + 400, hiddenItems.count)]) }) {
                        for r in try c.query("SELECT normalized_title, release_year FROM \(table) t WHERE id IN (\(marks(chunk.count))) AND NOT EXISTS (SELECT 1 FROM content_identity ci WHERE ci.item_id = t.id)", chunk.map { $0 as (any SQLConvertible)? }, { ($0.optString(0), $0.optInt(1)) }) { addTitle(r.0, r.1) }
                    }
                }
            }
        }
        func isRestrictedTitle(_ t: String?, _ year: Int?) -> Bool {
            guard let t, let s = restrictedTitles[t] else { return false }
            guard let y = year else { return true }
            return s.anyYear || s.years.contains { abs($0 - y) <= 1 }
        }
        lap("restricted keys", &t0)
        func isRestrictedKey(_ kind: String, _ key: String, _ year: Int?) -> Bool {
            guard let s = restrictedKeys[kind + "\u{1}" + key] else { return false }
            guard let y = year else { return true }
            return s.anyYear || s.years.contains { abs($0 - y) <= 1 }
        }
        // Dismissed markers of this profile (any copy of a dismissed title counts).
        var dismissedIDs = Set<String>()
        var dismissedKeys: [String: YearSet] = [:]
        for r in try c.query("SELECT item_id, kind, identity_key, year FROM rec_dismissed WHERE profile_id=?", [profile], { ($0.string(0), $0.string(1), $0.string(2), $0.optInt(3)) }) {
            dismissedIDs.insert(r.0)
            let k = r.1 + "\u{1}" + r.2
            if let y = r.3 { dismissedKeys[k, default: YearSet()].years.insert(y) } else { dismissedKeys[k, default: YearSet()].anyYear = true }
        }
        func isDismissedKey(_ kind: String, _ key: String, _ year: Int?) -> Bool {
            guard let s = dismissedKeys[kind + "\u{1}" + key] else { return false }
            guard let y = year else { return true }
            return s.anyYear || s.years.contains { abs($0 - y) <= 1 }
        }

        // Watch signals: movies by their own id, series through their episodes.
        struct Sig { var last = 0.0; var plays = 0; var p7 = 0; var p30 = 0 }
        var sig: [String: Sig] = [:]
        let since = nowT - 365 * 86400
        for r in try c.query("SELECT item_id, MAX(played_at), COUNT(*), SUM(played_at >= ?), SUM(played_at >= ?) FROM watch_history WHERE kind='movie' AND played_at >= ? GROUP BY item_id",
                             [nowT - 7 * 86400, nowT - 30 * 86400, since], { ($0.string(0), $0.double(1), $0.int(2), $0.int(3), $0.int(4)) }) {
            sig[r.0] = Sig(last: r.1, plays: r.2, p7: r.3, p30: r.4)
        }
        for r in try c.query("""
            SELECT e.series_id, MAX(h.played_at), COUNT(*), SUM(h.played_at >= ?), SUM(h.played_at >= ?) FROM watch_history h JOIN episodes e ON e.id = h.item_id
            WHERE h.kind='episode' AND h.played_at >= ? GROUP BY e.series_id
            """, [nowT - 7 * 86400, nowT - 30 * 86400, since], { ($0.string(0), $0.double(1), $0.int(2), $0.int(3), $0.int(4)) }) {
            sig[r.0] = Sig(last: r.1, plays: r.2, p7: r.3, p30: r.4)
        }
        var completed = Set<String>()
        for r in try c.query("SELECT item_id FROM watch_progress WHERE completed=1 AND kind='movie'", [], { $0.string(0) }) { completed.insert(r) }
        for r in try c.query("SELECT DISTINCT series_id FROM watch_progress WHERE completed=1 AND series_id IS NOT NULL", [], { $0.string(0) }) { completed.insert(r) }
        for r in try c.query("SELECT item_id FROM recently_watched WHERE kind='movie'", [], { $0.string(0) }) where sig[r] == nil { sig[r] = Sig(last: 0, plays: 1) }

        lap("dismissed+signals", &t0)
        // Pool: ids chosen per kind by indexed queries.
        let ok = " AND (t.category_id IS NULL OR t.category_id NOT IN (SELECT category_id FROM locked_categories)) AND (t.category_id IS NULL OR t.category_id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category')) AND t.id NOT IN (SELECT item_id FROM hidden_items)"
        var argsSource: [(any SQLConvertible)?] = []
        var srcClause = ""
        if let s = source { srcClause = " AND t.source_id = ?"; argsSource = [s] }
        var poolIDs: [String: [String]] = ["movie": [], "series": []]   // kind -> ids
        let kinds: [(table: String, kind: String, added: String)] = [("movies", "movie", "COALESCE(t.added_at, t.created_at, 0)"), ("series", "series", "COALESCE(t.added_at, t.first_seen_at, 0)")]
        let (nRecent, nRating, nLang, nSeen) = (pool * 35 / 100, pool * 25 / 100, pool * 20 / 100, pool * 10 / 100)

        if case .folder(let fk) = scope {
            for k in kinds {
                let ids = try c.query("SELECT t.id FROM \(k.table) t JOIN content_identity ci ON ci.item_id = t.id WHERE ci.folder_key = ?\(ok)\(srcClause) ORDER BY \(k.added) DESC, t.id LIMIT ?",
                                      [fk] + argsSource + [pool], { $0.string(0) })
                poolIDs[k.kind] = ids
            }
        } else {
            for k in kinds {
                var set = Set<String>()
                var ordered: [String] = []
                func add(_ ids: [String]) { for i in ids where set.insert(i).inserted { ordered.append(i) } }
                add(try c.query("SELECT t.id FROM \(k.table) t WHERE 1=1\(ok)\(srcClause) ORDER BY \(k.added) DESC, t.id LIMIT ?", argsSource + [nRecent], { $0.string(0) }))
                add(try c.query("SELECT t.id FROM \(k.table) t WHERE 1=1\(ok)\(srcClause) ORDER BY CAST(COALESCE(NULLIF(t.rating,''),'0') AS REAL) DESC, t.title COLLATE NOCASE, t.id LIMIT ?", argsSource + [nRating], { $0.string(0) }))
                if let lang, !lang.isEmpty {
                    add(try c.query("SELECT t.id FROM content_identity ci JOIN \(k.table) t ON t.id = ci.item_id WHERE ci.kind = '\(k.kind)' AND ci.lang = ?\(ok)\(srcClause) ORDER BY \(k.added) DESC, t.id LIMIT ?",
                                    [lang] + argsSource + [nLang], { $0.string(0) }))
                }
                // Watched lately (affinity, rediscover exclusion, because-you-watched seeds).
                let seen = sig.sorted { $0.value.last > $1.value.last }.prefix(nSeen * 2).map(\.key)
                if !seen.isEmpty {
                    for chunk in stride(from: 0, to: seen.count, by: 400).map({ Array(seen[$0..<min($0 + 400, seen.count)]) }) {
                        add(try c.query("SELECT t.id FROM \(k.table) t WHERE t.id IN (\(marks(chunk.count)))", chunk.map { $0 as (any SQLConvertible)? }, { $0.string(0) }))
                    }
                }
                // Titles matching this week's trending list.
                if !trend.isEmpty {
                    let keys = Array(trend)
                    for chunk in stride(from: 0, to: keys.count, by: 400).map({ Array(keys[$0..<min($0 + 400, keys.count)]) }) {
                        add(try c.query("SELECT ci.item_id FROM content_identity ci JOIN \(k.table) t ON t.id = ci.item_id WHERE ci.kind = '\(k.kind)' AND ci.identity_key IN (\(marks(chunk.count)))\(ok)\(srcClause)",
                                        chunk.map { $0 as (any SQLConvertible)? } + argsSource, { $0.string(0) }))
                    }
                }
                poolIDs[k.kind] = ordered
            }
        }

        lap("pool ids", &t0)
        // Expand to every copy of every title in the pool, in every playlist (twins are restricted-checked on all copies).
        var out: [SMCandidate] = []
        for k in kinds {
            let ids = poolIDs[k.kind] ?? []
            if ids.isEmpty { continue }
            var keys = Set<String>()
            for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
                for r in try c.query("SELECT identity_key FROM content_identity WHERE item_id IN (\(marks(chunk.count)))", chunk.map { $0 as (any SQLConvertible)? }, { $0.string(0) }) { keys.insert(r) }
            }
            let keyList = Array(keys)
            for chunk in stride(from: 0, to: keyList.count, by: 300).map({ Array(keyList[$0..<min($0 + 300, keyList.count)]) }) {
                let sql = """
                    SELECT ci.item_id, ci.identity_key, ci.year, ci.lang, ci.quality_rank, ci.is_cam, ci.folder_key,
                           (t.poster_url IS NOT NULL AND t.poster_url <> ''), (t.backdrop_url IS NOT NULL AND t.backdrop_url <> ''), t.rating,
                           \(k.added), t.category_id, t.genre, t.normalized_title
                    FROM content_identity ci JOIN \(k.table) t ON t.id = ci.item_id
                    WHERE ci.kind = '\(k.kind)' AND ci.identity_key IN (\(marks(chunk.count)))
                    """
                let rows = try c.query(sql, chunk.map { $0 as (any SQLConvertible)? }) { r -> SMCandidate in
                    var cand = SMCandidate(id: r.string(0))
                    cand.kind = k.kind == "movie" ? .movie : .series
                    cand.key = r.string(1); cand.year = r.optInt(2); cand.lang = r.optString(3)
                    cand.q = min(5, max(0, r.int(4))); cand.cam = r.bool(5); cand.folder = r.optString(6)
                    cand.poster = r.bool(7); cand.backdrop = r.bool(8)
                    let rating = r.optString(9); cand.rating = (rating?.isEmpty ?? true) ? nil : rating
                    let added = r.double(10)
                    cand.added = added > 0 ? max(0, Int((nowT - added) / 86400)) : nil
                    let cat = r.optString(11)
                    cand.restricted = (cat.map { badCats.contains($0) } ?? false) || hiddenItems.contains(cand.id) || isRestrictedKey(k.kind, cand.key, cand.year)
                        || isRestrictedTitle(r.optString(13), cand.year)
                    cand.dismissed = dismissedIDs.contains(cand.id) || isDismissedKey(k.kind, cand.key, cand.year)
                    if let g = r.optString(12)?.split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }), !g.isEmpty { cand.genre = g }
                    if let s = sig[cand.id] {
                        cand.watched = true
                        cand.p7 = s.p7; cand.p30 = s.p30
                        if s.last > 0 { cand.lastWatched = max(0, Int((nowT - s.last) / 86400)) }
                    }
                    cand.completed = completed.contains(cand.id)
                    return cand
                }
                out.append(contentsOf: rows)
            }
        }
        lap("expand+rows", &t0)
        return out
    }
}
