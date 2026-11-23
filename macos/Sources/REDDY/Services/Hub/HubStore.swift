import Foundation

/// hub_identity (the crosswalk; SchemaV19's content_identity is derived data and is left alone) and metadata_facts (SchemaV24). Purged as a whole.
struct HubStore: Sendable {
    let db: DatabaseManager

    func identity(_ item: String) -> (ids: HubIdentity, missUntil: Date?)? {
        (try? db.read { c in try c.queryOne("SELECT tmdb_id, tvdb_id, imdb_id, tvmaze_id, kind, miss_until FROM hub_identity WHERE item_id=?", [item]) {
            (HubIdentity(tmdb: $0.optInt(0), tvdb: $0.optInt(1), imdb: $0.optString(2), tvmaze: $0.optInt(3), kind: $0.optString(4).flatMap(HubTitleKind.init(rawValue:))), $0.optDate(5))
        } }) ?? nil
    }
    /// Fills gaps only (see HubIdentity.merge).
    func saveIdentity(_ item: String, _ incoming: HubIdentity, from source: HubSource, now: Date = Date()) {
        let old = identity(item)?.ids ?? HubIdentity()
        let merged = HubIdentity.merge(old, incoming, incomingRank: HubIdentity.rank(of: source), existingRank: source == .playlist ? 99 : 0)       // what is stored is kept; only the playlist's own ids override
        try? db.write { c in
            try c.execute("""
            INSERT INTO hub_identity(item_id, tmdb_id, tvdb_id, imdb_id, tvmaze_id, kind, resolved_at) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(item_id) DO UPDATE SET tmdb_id=excluded.tmdb_id, tvdb_id=excluded.tvdb_id, imdb_id=excluded.imdb_id, tvmaze_id=excluded.tvmaze_id, kind=excluded.kind, resolved_at=excluded.resolved_at
            """, [item, merged.tmdb, merged.tvdb, merged.imdb, merged.tvmaze, merged.kind?.rawValue, now])
            if merged != old { try c.execute("UPDATE hub_identity SET miss_until=NULL WHERE item_id=?", [item]) }          // new ids: the title is worth asking about again
        }
    }
    /// Remembers that a service did not know the ids of this title, so it is not asked again until `until` (cleared when new ids are saved).
    func setIdentityMiss(_ item: String, until: Date) {
        try? db.write { c in
            try c.execute("INSERT INTO hub_identity(item_id, miss_until) VALUES(?,?) ON CONFLICT(item_id) DO UPDATE SET miss_until=excluded.miss_until", [item, until])
        }
    }

    func fact(_ item: String, _ field: String) -> (fact: StoredFact, missUntil: Date?)? {
        (try? db.read { c in try c.queryOne("SELECT value, source, quality, expires_at, fail_count, miss_until FROM metadata_facts WHERE item_id=? AND field=?", [item, field]) {
            (StoredFact(value: $0.string(0), source: HubSource(rawValue: $0.string(1)) ?? .playlist, quality: $0.double(2), expiresAt: $0.date(3), failCount: $0.int(4)), $0.optDate(5))
        } }) ?? nil
    }
    /// Writes a value only when the arbiter says so (never a downgrade).
    @discardableResult func put(_ item: String, _ field: String, value: String, source: HubSource, quality: Double, now: Date = Date(), keep: TimeInterval) -> Bool {
        let stored = fact(item, field)?.fact
        if let s = stored, s.value != "" {
            if s.quality.isInfinite { return false }
            let expired = s.expiresAt <= now || s.failCount >= Arbiter.maxFailures
            if !expired && quality <= s.quality + Arbiter.margin && !(value == s.value) { return false }
        }
        try? db.write { c in
            try c.execute("""
            INSERT INTO metadata_facts(item_id, field, value, source, quality, fetched_at, expires_at, miss_until, fail_count) VALUES(?,?,?,?,?,?,?,NULL,0)
            ON CONFLICT(item_id, field) DO UPDATE SET value=excluded.value, source=excluded.source, quality=excluded.quality, fetched_at=excluded.fetched_at, expires_at=excluded.expires_at, miss_until=NULL, fail_count=0
            """, [item, field, value, source.rawValue, quality.isInfinite ? 1e12 : quality, now, now.addingTimeInterval(keep)])
        }
        return true
    }
    func putMiss(_ item: String, _ field: String, source: HubSource, until: Date, now: Date = Date()) {
        try? db.write { c in
            try c.execute("""
            INSERT INTO metadata_facts(item_id, field, value, source, quality, fetched_at, expires_at, miss_until) VALUES(?,?,NULL,?,0,?,?,?)
            ON CONFLICT(item_id, field) DO UPDATE SET miss_until=excluded.miss_until, fetched_at=excluded.fetched_at
            """, [item, field, source.rawValue, now, until, until])
        }
    }
    /// Counts a failed ask on a row that exists (a stored value that failed twice may be replaced; see Arbiter.maxFailures).
    func noteFailure(_ item: String, _ field: String) {
        try? db.write { c in try c.execute("UPDATE metadata_facts SET fail_count = fail_count + 1 WHERE item_id=? AND field=?", [item, field]) }
    }
    func provenance(_ item: String) -> Set<HubSource> {
        let rows = (try? db.read { c in try c.query("SELECT DISTINCT source FROM metadata_facts WHERE item_id=? AND value IS NOT NULL", [item]) { HubSource(rawValue: $0.string(0)) } }) ?? []
        return Set(rows.compactMap { $0 })
    }

    /// Saves what a TMDB details reply carried: the crosswalk ids and the Hindi/Telugu text (never replacing a better stored value).
    func saveTMDBExtras(_ item: String, _ p: TMDBExtras.Parsed, now: Date = Date()) {
        saveIdentity(item, p.ids, from: .tmdb, now: now)
        for (k, v) in p.translations { put(item, k, value: v, source: .tmdb, quality: 100, now: now, keep: HubPolicy.tmdb.keep) }
    }

    @discardableResult func purgeExpired(now: Date = Date()) -> Int {
        (try? db.write { c in try c.execute("DELETE FROM metadata_facts WHERE expires_at <= ?", [now]); return c.changes }) ?? 0
    }
    @discardableResult func purge(items: [String]) -> Int {
        guard !items.isEmpty else { return 0 }
        return (try? db.write { c in
            var n = 0
            for i in items { try c.execute("DELETE FROM metadata_facts WHERE item_id=?", [i]); n += c.changes; try c.execute("DELETE FROM hub_identity WHERE item_id=?", [i]) }
            return n
        }) ?? 0
    }
    /// Everything saved about the titles of these folders (locked or hidden folders, or a folder removed from the library).
    @discardableResult func purge(inFolders ids: [String]) -> Int {
        var n = 0
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
            let items = "SELECT id FROM movies WHERE category_id IN (\(marks)) UNION SELECT id FROM series WHERE category_id IN (\(marks))"
            n += (try? db.write { c in
                try c.execute("DELETE FROM metadata_facts WHERE item_id IN (\(items))", args + args); let k = c.changes
                try c.execute("DELETE FROM hub_identity WHERE item_id IN (\(items))", args + args); return k
            }) ?? 0
        }
        return n
    }
    /// Turning one service off deletes what it saved (the playlist's data and the other services' data stay).
    func purge(source: HubSource) { try? db.write { c in try c.execute("DELETE FROM metadata_facts WHERE source=?", [source.rawValue]) } }
}
