import Foundation
import os

/// Local SQLite database: one serialized writer and a small pool of read-only connections (WAL), so UI reads
/// are never blocked by a long catalog import, nor by another long read (a broad search, a Smart Mix build).
/// Everything stays on this device.
final class DatabaseManager: @unchecked Sendable {
    let path: String
    private let writer: Connection
    private struct Reader { let connection: Connection; let queue: DispatchQueue }
    private let readers: [Reader]
    /// How many reads each connection is running or has waiting; a new read goes to the least busy one.
    private let load = OSAllocatedUnfairLock(initialState: [Int]())
    private let writeQueue = DispatchQueue(label: "app.reddy.db.write")
    static let defaultReaderCount = 3

    init(path: String, readerCount: Int = DatabaseManager.defaultReaderCount) throws {
        self.path = path
        writer = try Connection(path: path, readOnly: false)
        try writer.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA busy_timeout=5000;")
        try DatabaseMigrator.migrate(writer)
        var pool: [Reader] = []
        for i in 0..<max(1, readerCount) {
            let c = try Connection(path: path, readOnly: true)
            try c.exec("PRAGMA busy_timeout=5000; PRAGMA query_only=ON; PRAGMA cache_size=-32768; PRAGMA mmap_size=268435456; PRAGMA temp_store=MEMORY;")
            pool.append(Reader(connection: c, queue: DispatchQueue(label: "app.reddy.db.read.\(i)", qos: .userInitiated)))
        }
        readers = pool
        let n = pool.count
        load.withLock { $0 = Array(repeating: 0, count: n) }
    }

    var readerCount: Int { readers.count }

    /// `~/Library/Application Support/REDDY/Database/reddy.sqlite` (override with REDDY_DB for tests).
    static func standard() throws -> DatabaseManager {
        if let p = ProcessInfo.processInfo.environment["REDDY_DB"] { return try DatabaseManager(path: p) }
        let dir = StorageService.databaseDirectory
        return try DatabaseManager(path: dir.appendingPathComponent("reddy.sqlite").path)
    }

    func read<T>(_ body: (Connection) throws -> T) throws -> T {
        let i = load.withLock { l -> Int in
            let k = l.indices.min { l[$0] < l[$1] } ?? 0
            l[k] += 1
            return k
        }
        defer { load.withLock { $0[i] -= 1 } }
        let r = readers[i]
        return try r.queue.sync { try body(r.connection) }
    }

    /// Runs `body` in one transaction. Throwing rolls everything back.
    func write<T>(_ body: (Connection) throws -> T) throws -> T {
        try writeQueue.sync {
            try writer.exec("BEGIN IMMEDIATE")
            do {
                let r = try body(writer)
                try writer.exec("COMMIT")
                return r
            } catch {
                try? writer.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Runs `body` on the writer, outside a transaction (VACUUM and wal_checkpoint cannot run inside one). It shares the
    /// write queue, so it can never overlap a catalog import or any other write.
    func maintenance<T>(_ body: (Connection) throws -> T) throws -> T { try writeQueue.sync { try body(writer) } }

    func optimize() { try? write { try $0.exec("PRAGMA optimize") } }
}
