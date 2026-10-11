import Testing
import Foundation
@testable import REDDY

@Suite("Database") struct DatabaseTests {
    @Test func migratesToLatestVersion() throws {
        let db = try TestSupport.makeDB()
        let v = try db.read { try $0.scalarInt("PRAGMA user_version") }
        #expect(v == DatabaseMigrator.latestVersion)
        // reopening an existing database is a no-op
        let again = try DatabaseManager(path: db.path)
        #expect(try again.read { try $0.scalarInt("PRAGMA user_version") } == v)
    }

    @Test func allSpecTablesExist() throws {
        let db = try TestSupport.makeDB()
        let expected = ["sources", "source_capabilities", "source_sync_state", "categories", "channels", "movies", "series", "seasons",
                        "episodes", "stream_variants", "epg_channels", "epg_programs", "epg_channel_mappings", "favorites", "watch_history",
                        "watch_progress", "recently_watched", "collections", "collection_items", "hidden_items", "playback_sessions",
                        "sync_jobs", "metadata_overrides", "catalog_fts"]
        let names = Set(try db.read { try $0.query("SELECT name FROM sqlite_master") { $0.string(0) } })
        for t in expected { #expect(names.contains(t), "missing table \(t)") }
    }

    @Test func failedWriteRollsBack() throws {
        let db = try TestSupport.makeDB()
        struct Boom: Error {}
        _ = try? db.write { c -> Void in
            try c.execute("INSERT INTO collections(id, name, created_at) VALUES('a','A',0)")
            throw Boom()
        }
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM collections") } == 0)
    }

    @Test func readerSeesCommittedWrites() throws {
        let db = try TestSupport.makeDB()
        try db.write { try $0.execute("INSERT INTO collections(id, name, created_at) VALUES('a','A',0)") }
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM collections") } == 1)
    }

    @Test func integrityCheckPasses() throws {
        let db = try TestSupport.makeDB()
        let r = try IndexHealthMonitor(db: db).check()
        #expect(r.integrityOK)
        #expect(r.healthy)
    }
}
