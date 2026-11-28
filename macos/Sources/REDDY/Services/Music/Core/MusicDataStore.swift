import Foundation
import SQLite3

/// One small SQLite database that holds everything Music fetched from a source and may need again: album songs, artist lists, playlists, browse
/// shelves. A row is `key -> payload` with when it was saved and last used; the database is bounded (`maxBytes`, least recently used dropped first),
/// every read and write is atomic, a payload that no longer decodes is simply a miss, and the privacy wipe deletes the file.
///
/// Why one database and not a file per answer: small payloads (tens of kilobytes) read faster from a database than from separate files and take less
/// disk, writes are atomic, and eviction is one query (SQLite's own "35% faster than the filesystem" benchmark measures the read speed).
actor MusicDataStore {
    struct Row: Sendable { var data: Data; var savedAt: Date }

    private nonisolated(unsafe) var db: OpaquePointer?
    private let path: URL
    private let maxBytes: Int
    private let clock: @Sendable () -> Date
    /// The size of everything saved, kept as a running total so the limit is checked on EVERY write, not now and then.
    private var total: Int?
    /// Rows removed per transaction when the size limit is passed.
    static let pruneBatch = 200

    init(path: URL, maxBytes: Int = 150_000_000, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path; self.maxBytes = max(1_000_000, maxBytes); self.clock = clock
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: open

    private func open() -> OpaquePointer? {
        if let db { return db }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(h, 2_000)
        exec(h, "PRAGMA journal_mode=WAL")
        exec(h, "PRAGMA synchronous=NORMAL")
        exec(h, "CREATE TABLE IF NOT EXISTS entries (key TEXT PRIMARY KEY, saved REAL NOT NULL, used REAL NOT NULL, size INTEGER NOT NULL, payload BLOB NOT NULL) WITHOUT ROWID")
        exec(h, "CREATE INDEX IF NOT EXISTS entries_used ON entries(used)")
        db = h
        return h
    }

    @discardableResult private func exec(_ h: OpaquePointer, _ sql: String) -> Bool { sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK }

    // MARK: read and write

    /// The saved answer for `key` (and when it was saved), marking it as just used. Nil when there is none.
    func get(_ key: String) -> Row? {
        guard let h = open() else { return nil }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT payload, saved FROM entries WHERE key = ?1", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, key, -1, Self.transient)
        guard sqlite3_step(st) == SQLITE_ROW, let bytes = sqlite3_column_blob(st, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(st, 0)))
        let saved = Date(timeIntervalSince1970: sqlite3_column_double(st, 1))
        touch(key, h)
        return Row(data: data, savedAt: saved)
    }

    func put(_ key: String, data: Data) {
        guard let h = open() else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "INSERT OR REPLACE INTO entries (key, saved, used, size, payload) VALUES (?1, ?2, ?2, ?3, ?4)", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, key, -1, Self.transient)
        sqlite3_bind_double(st, 2, clock().timeIntervalSince1970)
        sqlite3_bind_int64(st, 3, Int64(data.count))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(st, 4, $0.baseAddress, Int32(data.count), Self.transient) }
        guard sqlite3_step(st) == SQLITE_DONE else { return }
        // A replaced key is counted twice until the next prune recounts; that only ever prunes early, never late.
        if let t = total { total = t + data.count } else { total = scalar("SELECT COALESCE(SUM(size), 0) FROM entries") }
        if let t = total, t > maxBytes { prune(h) }
    }

    func remove(prefix: String) {
        guard let h = open() else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "DELETE FROM entries WHERE key >= ?1 AND key < ?2", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, prefix, -1, Self.transient)
        sqlite3_bind_text(st, 2, prefix + "\u{10FFFF}", -1, Self.transient)
        sqlite3_step(st)
    }

    var count: Int { scalar("SELECT COUNT(*) FROM entries") }
    var bytes: Int { scalar("SELECT COALESCE(SUM(size), 0) FROM entries") }

    /// The privacy wipe: the database file and its journal are deleted; the next use starts empty.
    func wipe() {
        if let db { sqlite3_close(db); self.db = nil }
        total = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + suffix) }
    }

    // MARK: housekeeping

    private func touch(_ key: String, _ h: OpaquePointer) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "UPDATE entries SET used = ?2 WHERE key = ?1", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, key, -1, Self.transient)
        sqlite3_bind_double(st, 2, clock().timeIntervalSince1970)
        sqlite3_step(st)
    }

    /// Over the size limit: the least recently used rows go until the database is at three quarters of it.
    private func prune(_ h: OpaquePointer) {
        guard scalar("SELECT COALESCE(SUM(size), 0) FROM entries") > maxBytes else { total = nil; return }
        let target = maxBytes * 3 / 4
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT key, size FROM entries ORDER BY used ASC", -1, &st, nil) == SQLITE_OK else { return }
        var sum = scalar("SELECT COALESCE(SUM(size), 0) FROM entries")
        var doomed: [String] = []
        while sum > target, sqlite3_step(st) == SQLITE_ROW {
            if let c = sqlite3_column_text(st, 0) { doomed.append(String(cString: c)) }
            sum -= Int(sqlite3_column_int64(st, 1))
        }
        sqlite3_finalize(st)
        // Small transactions: SQLite's WAL notes say it "works best with smaller transactions", so the rows go in batches, not all at once.
        var from = 0
        while from < doomed.count {
            exec(h, "BEGIN")
            for k in doomed[from..<min(from + Self.pruneBatch, doomed.count)] {
                var d: OpaquePointer?
                if sqlite3_prepare_v2(h, "DELETE FROM entries WHERE key = ?1", -1, &d, nil) == SQLITE_OK { sqlite3_bind_text(d, 1, k, -1, Self.transient); sqlite3_step(d) }
                sqlite3_finalize(d)
            }
            exec(h, "COMMIT")
            from += Self.pruneBatch
        }
        total = nil
    }

    private func scalar(_ sql: String) -> Int {
        guard let h = open() else { return 0 }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
