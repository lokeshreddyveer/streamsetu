import Foundation

final class SQLiteHistoryRepository: HistoryRepository {
    let db: DatabaseManager
    init(db: DatabaseManager) { self.db = db }

    func recordPlay(itemID: String, kind: ContentKind, title: String) throws {
        try db.write { c in
            let now = Date()
            try c.execute("INSERT INTO watch_history(item_id, kind, title, played_at) VALUES(?,?,?,?)", [itemID, kind.rawValue, title, now])
            try c.execute("""
                INSERT INTO recently_watched(item_id, kind, last_played, play_count) VALUES(?,?,?,1)
                ON CONFLICT(item_id) DO UPDATE SET last_played=excluded.last_played, play_count=recently_watched.play_count+1
                """, [itemID, kind.rawValue, now])
            try c.execute("DELETE FROM watch_history WHERE id NOT IN (SELECT id FROM watch_history ORDER BY played_at DESC LIMIT 500)")
        }
    }

    func recentIDs(kind: ContentKind, limit: Int) throws -> [String] {
        try db.read { try $0.query("SELECT item_id FROM recently_watched WHERE kind=? ORDER BY last_played DESC LIMIT ?", [kind.rawValue, limit]) { $0.string(0) } }
    }

    func watchLog(limit: Int) throws -> [WatchLogEntry] {
        try db.read { c in
            try c.query("SELECT item_id, kind, title, played_at FROM watch_history ORDER BY played_at DESC LIMIT ?", [limit]) {
                WatchLogEntry(itemID: $0.string(0), kind: ContentKind(rawValue: $0.string(1)) ?? .movie, title: $0.string(2), playedAt: $0.date(3))
            }
        }
    }

    func mostPlayed(kinds: [ContentKind], since: Date, limit: Int) throws -> [(itemID: String, plays: Int)] {
        let marks = kinds.map { _ in "?" }.joined(separator: ",")
        var args: [(any SQLConvertible)?] = kinds.map { $0.rawValue as (any SQLConvertible)? }
        args.append(since); args.append(limit)
        return try db.read { c in
            try c.query("SELECT item_id, COUNT(*) n FROM watch_history WHERE kind IN (\(marks)) AND played_at >= ? GROUP BY item_id ORDER BY n DESC, MAX(played_at) DESC LIMIT ?", args) {
                (itemID: $0.string(0), plays: $0.int(1))
            }
        }
    }

    func clearHistory() throws {
        try db.write { c in
            try c.execute("DELETE FROM watch_history")
            try c.execute("DELETE FROM recently_watched")
        }
    }

    func clearRecent(kind: ContentKind?, sourcePrefix: String?) throws {
        var sql = "DELETE FROM recently_watched WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        if let kind { sql += " AND kind=?"; args.append(kind.rawValue) }
        if let sourcePrefix { sql += " AND item_id LIKE ? ESCAPE '\\'"; args.append(Self.like(sourcePrefix)) }
        try db.write { try $0.execute(sql, args) }
    }

    func removeRecent(itemID: String) throws { try db.write { try $0.execute("DELETE FROM recently_watched WHERE item_id=?", [itemID]) } }

    func clearLog(since: Date?, sourcePrefix: String?) throws {
        var sql = "DELETE FROM watch_history WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        if let since { sql += " AND played_at >= ?"; args.append(since) }
        if let sourcePrefix { sql += " AND item_id LIKE ? ESCAPE '\\'"; args.append(Self.like(sourcePrefix)) }
        try db.write { try $0.execute(sql, args) }
    }

    func removeLogEntry(itemID: String, playedAt: Date) throws {
        try db.write { try $0.execute("DELETE FROM watch_history WHERE item_id=? AND ABS(played_at-?) < 0.001", [itemID, playedAt]) }
    }

    func clearResumePoints(sourcePrefix: String?) throws {
        if let sourcePrefix { try db.write { try $0.execute("DELETE FROM watch_progress WHERE item_id LIKE ? ESCAPE '\\'", [Self.like(sourcePrefix)]) } }
        else { try db.write { try $0.execute("DELETE FROM watch_progress") } }
    }

    /// "<uuid>|" as a LIKE pattern that matches only ids starting with it.
    private static func like(_ prefix: String) -> String {
        prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    // MARK: progress

    private static func map(_ r: Row) -> WatchProgress {
        WatchProgress(itemID: r.string(0), kind: ContentKind(rawValue: r.string(1)) ?? .movie, seriesID: r.optString(2),
                      positionSeconds: r.double(3), durationSeconds: r.double(4), updatedAt: r.date(5), completed: r.bool(6))
    }
    private static let select = "SELECT item_id, kind, series_id, position_seconds, duration_seconds, updated_at, completed FROM watch_progress"

    func saveProgress(_ p: WatchProgress) throws {
        try db.write { c in
            // Within 95% (or the last 60s) counts as finished, so resume never drops viewers on the credits.
            let done = p.completed || (p.durationSeconds > 0 && (p.positionSeconds / p.durationSeconds >= 0.95 || p.durationSeconds - p.positionSeconds < 60))
            try c.execute("""
                INSERT INTO watch_progress(item_id, kind, series_id, position_seconds, duration_seconds, updated_at, completed)
                VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(item_id) DO UPDATE SET position_seconds=excluded.position_seconds, duration_seconds=excluded.duration_seconds,
                    updated_at=excluded.updated_at, completed=excluded.completed, series_id=COALESCE(excluded.series_id, watch_progress.series_id)
                """, [p.itemID, p.kind.rawValue, p.seriesID, p.positionSeconds, p.durationSeconds, p.updatedAt, done])
        }
    }

    func progress(for itemID: String) throws -> WatchProgress? {
        try db.read { try $0.query(Self.select + " WHERE item_id=?", [itemID], Self.map).first }
    }

    func progress(forSeries seriesID: String) throws -> [WatchProgress] {
        try db.read { try $0.query(Self.select + " WHERE series_id=?", [seriesID], Self.map) }
    }

    /// Unfinished movies/episodes, newest first (one entry per series: its most recent episode).
    func continueWatching(limit: Int) throws -> [WatchProgress] {
        let rows = try db.read { try $0.query(Self.select + " WHERE completed=0 AND position_seconds>30 ORDER BY updated_at DESC LIMIT 200", [], Self.map) }
        var seenSeries = Set<String>(), out: [WatchProgress] = []
        for p in rows {
            if let s = p.seriesID { guard seenSeries.insert(s).inserted else { continue } }
            out.append(p)
            if out.count == limit { break }
        }
        return out
    }

    func watchedTitleIDs() throws -> Set<String> {
        try db.read { d in
            let movies = try d.query("SELECT item_id FROM watch_progress WHERE completed=1 AND kind='movie'", []) { $0.string(0) }
            let series = try d.query("""
                SELECT e.series_id FROM episodes e LEFT JOIN watch_progress p ON p.item_id = e.id AND p.completed = 1
                GROUP BY e.series_id HAVING COUNT(p.item_id) = COUNT(*)
                """, []) { $0.string(0) }
            return Set(movies + series)
        }
    }

    func partialProgress() throws -> [String: Double] {
        try db.read { d in
            var out: [String: Double] = [:]
            for row in try d.query("SELECT item_id, position_seconds / duration_seconds FROM watch_progress WHERE kind='movie' AND completed=0 AND position_seconds>30 AND duration_seconds>0", [], { ($0.string(0), $0.double(1)) }) {
                out[row.0] = min(0.99, row.1)
            }
            let series = try d.query("""
                SELECT e.series_id, SUM(CASE WHEN p.completed = 1 THEN 1.0 WHEN p.duration_seconds > 0 THEN p.position_seconds / p.duration_seconds ELSE 0 END) / COUNT(*) AS f
                FROM episodes e LEFT JOIN watch_progress p ON p.item_id = e.id GROUP BY e.series_id HAVING f > 0 AND f < 1
                """, [], { ($0.string(0), $0.double(1)) })
            for row in series { out[row.0] = row.1 }
            return out
        }
    }

    func markWatched(itemID: String, kind: ContentKind, seriesID: String?, duration: Double) throws {
        try saveProgress(WatchProgress(itemID: itemID, kind: kind, seriesID: seriesID, positionSeconds: duration, durationSeconds: duration,
                                       updatedAt: Date(), completed: true))
    }

    func clearProgress(itemID: String) throws { try db.write { try $0.execute("DELETE FROM watch_progress WHERE item_id=?", [itemID]) } }

    // MARK: sessions

    func beginSession(itemID: String, engine: String) throws -> Int64 {
        try db.write { c in
            try c.execute("INSERT INTO playback_sessions(item_id, started_at, engine) VALUES(?,?,?)", [itemID, Date(), engine])
            return c.lastInsertRowID
        }
    }

    func endSession(id: Int64, outcome: String, error: String?) throws {
        try db.write { c in
            try c.execute("UPDATE playback_sessions SET ended_at=?, outcome=?, error=? WHERE id=?", [Date(), outcome, error.map(CredentialRedactor.redact), id])
            try c.execute("DELETE FROM playback_sessions WHERE id NOT IN (SELECT id FROM playback_sessions ORDER BY id DESC LIMIT 20000)")
        }
    }
}
