import Testing
import Foundation
@testable import REDDY

/// A damaged library database must never cost the person their playlists, favourites, lists, profiles, locks or history.
@Suite("Database recovery") struct DatabaseRecoveryTests {
    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("recov-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A library with a bit of everything personal, in `dir`, closed again; `history` rows spread the file over many pages.
    @discardableResult private func makeLibrary(in dir: URL, history: Int = 4000) throws -> PlaylistSource {
        let db = try DatabaseManager(path: dir.appendingPathComponent("reddy.sqlite").path)
        let s = try TestSupport.makeSource(db, name: "My Playlist")
        try db.write { c in
            try c.execute("INSERT OR REPLACE INTO profiles(id,name,kind,pin_salt,pin_hash,color,sort_order,created_at) VALUES('kid','Kids','kid','salt','hash',2,1,5)")
            try c.execute("INSERT INTO locked_categories(category_id) VALUES('cat-adult')")
            try c.execute("INSERT INTO favorites(item_id,kind,created_at) VALUES('ch1','channel',1)")
            try c.execute("INSERT INTO collections(id,name,created_at) VALUES('col','Cricket',1)")
            try c.execute("INSERT INTO collection_items(collection_id,item_id,kind,sort_order,added_at) VALUES('col','ch1','channel',0,1)")
            try c.execute("INSERT INTO hidden_items(item_id,kind,hidden_at) VALUES('ch9','channel',1)")
            try c.execute("INSERT INTO watch_progress(item_id,kind,position_seconds,duration_seconds,updated_at,completed) VALUES('mv1','movie',120,6000,1,0)")
            try c.execute("INSERT INTO metadata_overrides(item_id,display_name) VALUES('ch1','Sports One')")
            for i in 0..<history { try c.execute("INSERT INTO watch_history(item_id,kind,title,played_at) VALUES(?,?,?,?)", ["item\(i)", "movie", "A long enough title to fill pages \(i)", Double(i)]) }
        }
        try db.maintenance { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        return s
    }

    private func corrupt(_ dir: URL, fromFraction f: Double) throws {
        let url = dir.appendingPathComponent("reddy.sqlite")
        var data = try Data(contentsOf: url)
        let start = Int(Double(data.count) * f)
        for i in start..<min(data.count, start + 16_384) { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try data.write(to: url)
    }

    private func check(_ dir: URL, source: PlaylistSource) throws -> DatabaseManager {
        let db = try DatabaseManager(path: dir.appendingPathComponent("reddy.sqlite").path)
        func n(_ sql: String) throws -> Int { try db.read { try $0.scalarInt(sql) } }
        func text(_ sql: String, _ args: [(any SQLConvertible)?] = []) throws -> String? { try db.read { try $0.queryOne(sql, args) { $0.string(0) } } }
        #expect(try text("SELECT name FROM sources WHERE id=?", [source.id]) == "My Playlist", "the playlist record survived")
        #expect(try text("SELECT pin_hash FROM profiles WHERE id='kid'") == "hash", "a profile and its PIN survived")
        #expect(try n("SELECT COUNT(*) FROM locked_categories WHERE category_id='cat-adult'") == 1, "the folder lock survived")
        #expect(try n("SELECT COUNT(*) FROM favorites") == 1)
        #expect(try n("SELECT COUNT(*) FROM collection_items WHERE collection_id='col'") == 1, "the list and its items survived")
        #expect(try n("SELECT COUNT(*) FROM hidden_items") == 1)
        #expect(try n("SELECT COUNT(*) FROM watch_progress WHERE item_id='mv1' AND position_seconds=120") == 1, "the resume point survived")
        #expect(try text("SELECT display_name FROM metadata_overrides WHERE item_id='ch1'") == "Sports One")
        return db
    }

    @Test func aDamagedDatabaseIsMovedAsideNeverDeleted() throws {
        let root = try folder(), dir = root.appendingPathComponent("Database", isDirectory: true), recovery = root.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeLibrary(in: dir, history: 10)
        let kept = try DatabaseRecovery.quarantine(dir, into: recovery)
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("reddy.sqlite").path), "the old database is kept whole")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("reddy.sqlite").path), "the live folder is empty so a fresh database can start")
        let again = try DatabaseRecovery.quarantine(try { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir }(), into: recovery, now: Date())
        #expect(again != kept, "a second recovery never overwrites the first")
    }

    @Test func aHealthyButUnopenableLibraryKeepsEverythingPersonal() throws {
        let root = try folder(), dir = root.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try makeLibrary(in: dir, history: 50)
        let out = try DatabaseRecovery.recover(keepPersonalData: true, databaseDirectory: dir, root: root.appendingPathComponent("Recovery"))
        #expect(out.lost.isEmpty && out.copied["watch_history"] == 50)
        let db = try check(dir, source: s)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM profile_state") } == 1, "one active-profile row, not two")
    }

    @Test func pageDamageLosesOnlyTheRowsOnThatPage() throws {
        let root = try folder(), dir = root.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try makeLibrary(in: dir)
        try corrupt(dir, fromFraction: 0.6)
        let out = try DatabaseRecovery.recover(keepPersonalData: true, databaseDirectory: dir, root: root.appendingPathComponent("Recovery"))
        _ = try check(dir, source: s)
        let kept = out.copied["watch_history"] ?? 0
        #expect(kept > 1000 && kept < 4000, "most history is kept, only the damaged part is lost (kept \(kept))")
        #expect(FileManager.default.fileExists(atPath: out.kept.appendingPathComponent("reddy.sqlite").path), "the damaged original is still there")
    }

    @Test func aFileThatIsNotADatabaseStartsFreshButIsKept() throws {
        let root = try folder(), dir = root.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 5000).write(to: dir.appendingPathComponent("reddy.sqlite"))
        let out = try DatabaseRecovery.recover(keepPersonalData: true, databaseDirectory: dir, root: root.appendingPathComponent("Recovery"))
        #expect(out.copied.isEmpty && !out.lost.isEmpty, "the person is told something could not be read")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.kept.path).contains("reddy.sqlite"))
        _ = try DatabaseManager(path: dir.appendingPathComponent("reddy.sqlite").path)      // the app can open a database again
    }

    @Test func startFreshStillKeepsTheOldCopy() throws {
        let root = try folder(), dir = root.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeLibrary(in: dir, history: 5)
        let out = try DatabaseRecovery.recover(keepPersonalData: false, databaseDirectory: dir, root: root.appendingPathComponent("Recovery"))
        #expect(out.copied.isEmpty)
        let old = try DatabaseManager(path: out.kept.appendingPathComponent("reddy.sqlite").path)
        #expect(try old.read { try $0.scalarInt("SELECT COUNT(*) FROM sources") } == 1, "nothing was deleted")
    }

    @Test func theInventoryCountsWhatWouldBeLost() throws {
        let dir = try folder()
        try makeLibrary(in: dir, history: 7)
        let inv = DatabaseRecovery.inspect(dir)
        #expect(inv.readable && inv.playlists == 1 && inv.favourites == 1 && inv.collections == 1 && inv.history == 7 && inv.profiles >= 2)
        let junk = try folder(); try Data(repeating: 0x41, count: 5000).write(to: junk.appendingPathComponent("reddy.sqlite"))
        #expect(!DatabaseRecovery.inspect(junk).readable)
        #expect(!DatabaseRecovery.inspect(try folder()).readable, "no database file at all")
    }
}
