import Foundation

/// Local SQLite database: one serialized writer and one reader (WAL), so UI reads
/// are never blocked by a long catalog import. Everything stays on this Mac.
final class DatabaseManager: @unchecked Sendable {
    let path: String
    private let writer: Connection
    private let reader: Connection
    private let writeQueue = DispatchQueue(label: "app.reddy.db.write")
    private let readQueue = DispatchQueue(label: "app.reddy.db.read")

    init(path: String) throws {
        self.path = path
        writer = try Connection(path: path, readOnly: false)
        try writer.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA busy_timeout=5000;")
        try DatabaseMigrator.migrate(writer)
        reader = try Connection(path: path, readOnly: true)
        try reader.exec("PRAGMA busy_timeout=5000; PRAGMA query_only=ON;")
    }

    /// `~/Library/Application Support/REDDY/Database/reddy.sqlite` (override with REDDY_DB for tests).
    static func standard() throws -> DatabaseManager {
        if let p = ProcessInfo.processInfo.environment["REDDY_DB"] { return try DatabaseManager(path: p) }
        let dir = StorageService.databaseDirectory
        return try DatabaseManager(path: dir.appendingPathComponent("reddy.sqlite").path)
    }

    func read<T>(_ body: (Connection) throws -> T) throws -> T {
        try readQueue.sync { try body(reader) }
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
