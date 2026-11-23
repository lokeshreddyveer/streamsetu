import Testing
import Foundation
@testable import REDDY

/// Only the tests use this (the app reads off the main thread through `OffMain`), so it lives here, not in the app.
extension DatabaseManager {
    func readAsync<T: Sendable>(_ body: @escaping @Sendable (Connection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try self.read(body)) } catch { cont.resume(throwing: error) }
            }
        }
    }
}

@Suite("Database reader pool") struct DatabaseReaderPoolTests {
    @Test func readersAreAPoolOfReadOnlyWALConnections() throws {
        let db = try TestSupport.makeDB()
        #expect(db.readerCount == DatabaseManager.defaultReaderCount)
        #expect(try db.read { try $0.query("PRAGMA journal_mode") { $0.string(0) } }.first == "wal")
        #expect(throws: (any Error).self) { try db.read { try $0.execute("INSERT INTO collections(id, name, created_at) VALUES('x','X',0)") } }
        #expect(try db.read { try $0.scalarInt("PRAGMA query_only") } == 1)
        #expect(try db.read { try $0.scalarInt("PRAGMA busy_timeout") } == 5000)
    }

    @Test func manyThreadsReadWhileAWriterCommits() async throws {
        let db = try TestSupport.makeDB()
        try db.write { try $0.execute("INSERT INTO collections(id, name, created_at) VALUES('a','A',0)") }
        let reads = await withTaskGroup(of: Int.self) { g -> Int in
            for _ in 0..<8 { g.addTask { var ok = 0; for _ in 0..<200 { if (try? db.read { try $0.scalarInt("SELECT COUNT(*) FROM collections") }) ?? 0 >= 1 { ok += 1 } }; return ok } }
            g.addTask { for i in 0..<50 { try? db.write { try $0.execute("INSERT INTO collections(id, name, created_at) VALUES(?, 'n', 0)", ["w\(i)"]) } }; return 0 }
            var total = 0; for await n in g { total += n }; return total
        }
        #expect(reads == 8 * 200, "no read failed or came back empty while the writer was committing (busy handling)")
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM collections") } == 51)
    }

    @Test func aLongReadDoesNotBlockAnotherRead() async throws {
        let db = try TestSupport.makeDB()
        let long = Task.detached { try db.read { c in try c.scalarInt("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 3000000) SELECT COUNT(*) FROM n") } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try db.read { try $0.scalarInt("SELECT 1") }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        _ = try await long.value
        print("DBPOOL read behind a long read: \(Int(ms)) ms")
        #expect(ms < 100)
    }

    @Test func readAsyncReturnsTheSameAnswer() async throws {
        let db = try TestSupport.makeDB()
        try db.write { try $0.execute("INSERT INTO collections(id, name, created_at) VALUES('a','A',0)") }
        let n = try await db.readAsync { try $0.scalarInt("SELECT COUNT(*) FROM collections") }
        #expect(n == 1)
    }

    @Test func aWriteIsVisibleToTheNextReadOnAnyConnection() throws {
        let db = try TestSupport.makeDB()
        for i in 0..<10 {
            try db.write { try $0.execute("INSERT INTO collections(id, name, created_at) VALUES(?, 'n', 0)", ["k\(i)"]) }
            #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM collections") } == i + 1)
        }
    }
}
