import Foundation
import SQLite3

struct DatabaseError: Error, CustomStringConvertible, Sendable {
    let message: String
    let code: Int32
    var description: String { "SQLite error \(code): \(message)" }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value that can be bound to a prepared statement.
protocol SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32)
}

extension String: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) { sqlite3_bind_text(stmt, index, self, -1, sqliteTransient) }
}
extension Int: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) { sqlite3_bind_int64(stmt, index, Int64(self)) }
}
extension Int64: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) { sqlite3_bind_int64(stmt, index, self) }
}
extension Double: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) { sqlite3_bind_double(stmt, index, self) }
}
extension Bool: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) { sqlite3_bind_int64(stmt, index, self ? 1 : 0) }
}
extension Date: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) { sqlite3_bind_double(stmt, index, timeIntervalSince1970) }
}
extension UUID: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) { uuidString.lowercased().bind(to: stmt, at: index) }
}
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    func bind(to stmt: OpaquePointer?, at index: Int32) {
        if let v = self { v.bind(to: stmt, at: index) } else { sqlite3_bind_null(stmt, index) }
    }
}

/// One result row. Only valid inside the mapping closure.
struct Row {
    let stmt: OpaquePointer?
    func isNull(_ i: Int) -> Bool { sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL }
    func string(_ i: Int) -> String { optString(i) ?? "" }
    func optString(_ i: Int) -> String? { sqlite3_column_text(stmt, Int32(i)).map { String(cString: $0) } }
    func int(_ i: Int) -> Int { Int(sqlite3_column_int64(stmt, Int32(i))) }
    func optInt(_ i: Int) -> Int? { isNull(i) ? nil : int(i) }
    func double(_ i: Int) -> Double { sqlite3_column_double(stmt, Int32(i)) }
    func optDouble(_ i: Int) -> Double? { isNull(i) ? nil : double(i) }
    func bool(_ i: Int) -> Bool { int(i) != 0 }
    func date(_ i: Int) -> Date { Date(timeIntervalSince1970: double(i)) }
    func optDate(_ i: Int) -> Date? { optDouble(i).map { Date(timeIntervalSince1970: $0) } }
    func uuid(_ i: Int) -> UUID? { optString(i).flatMap(UUID.init(uuidString:)) }
}

/// A reusable prepared statement (for bulk inserts).
final class Statement {
    fileprivate let stmt: OpaquePointer
    private let db: OpaquePointer

    fileprivate init(db: OpaquePointer, sql: String) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(db)) + " in: \(sql.prefix(80))", code: sqlite3_errcode(db))
        }
        stmt = s
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func run(_ args: [(any SQLConvertible)?]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, a) in args.enumerated() {
            if let a { a.bind(to: stmt, at: Int32(i + 1)) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(db)), code: rc)
        }
    }
}

final class Connection {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool) throws {
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &h, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let h { sqlite3_close_v2(h) }
            throw DatabaseError(message: msg, code: rc)
        }
        handle = h
    }

    deinit { sqlite3_close_v2(handle) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs one or more SQL statements without parameters.
    func exec(_ script: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, script, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw DatabaseError(message: msg, code: rc)
        }
    }

    func prepare(_ sql: String) throws -> Statement { try Statement(db: handle, sql: sql) }

    func execute(_ sql: String, _ args: [(any SQLConvertible)?] = []) throws {
        try prepare(sql).run(args)
    }

    func query<T>(_ sql: String, _ args: [(any SQLConvertible)?] = [], _ map: (Row) throws -> T) throws -> [T] {
        let st = try prepare(sql)
        for (i, a) in args.enumerated() {
            if let a { a.bind(to: st.stmt, at: Int32(i + 1)) } else { sqlite3_bind_null(st.stmt, Int32(i + 1)) }
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st.stmt)
            if rc == SQLITE_ROW { out.append(try map(Row(stmt: st.stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw DatabaseError(message: errorMessage, code: rc) }
        }
        return out
    }

    func queryOne<T>(_ sql: String, _ args: [(any SQLConvertible)?] = [], _ map: (Row) throws -> T) throws -> T? {
        try query(sql, args, map).first
    }

    func scalarInt(_ sql: String, _ args: [(any SQLConvertible)?] = []) throws -> Int {
        try queryOne(sql, args) { $0.int(0) } ?? 0
    }
}
