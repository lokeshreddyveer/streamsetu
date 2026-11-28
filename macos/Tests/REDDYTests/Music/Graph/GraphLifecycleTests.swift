import Foundation
import Testing
@testable import REDDY

private typealias T = GraphTestSupport

@Suite("Graph file lifecycle") struct GraphLifecycleTests {
    private func tableNames(_ path: String) throws -> Set<String> {
        let c = try Connection(path: path, readOnly: true)
        return Set(try c.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) })
    }

    @Test func freshFileMigratesToV1AndReopensIdempotently() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "created lazily")
        let id = try await s.upsert(T.recording("Song", uid: "p:1")).id
        #expect(try await s.counts().schemaVersion == MusicGraphMigrator.latestVersion)
        #expect(MusicGraphMigrator.latestVersion >= 1)
        let names = try tableNames(s.databaseURL.path)
        for t in ["meta", "entity", "external_id", "name_alias", "edge", "fact", "cache_state", "work_item", "source_health", "affinity", "rec_cache", "decision", "entity_fts"] { #expect(names.contains(t), "\(t)") }
        let s2 = MusicGraphStore(directory: dir)
        #expect(try await s2.entity(id)?.name == "Song")
        let c2 = try await s2.counts()
        #expect(c2.entities == 1 && c2.schemaVersion == MusicGraphMigrator.latestVersion)
        // Migrating a current file again does nothing.
        let c = try Connection(path: s.databaseURL.path, readOnly: false)
        try MusicGraphMigrator.migrate(c)
        #expect(try MusicGraphMigrator.version(c) == MusicGraphMigrator.latestVersion)
    }

    @Test func aNewerSchemaOpensReadOnly() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let id = try await s.upsert(T.recording("Song", uid: "p:1")).id
        try await s.withWriter { try $0.exec("UPDATE meta SET v = '99' WHERE k = 'schema'") }
        let s2 = MusicGraphStore(directory: dir)
        #expect(try await s2.entity(id)?.name == "Song")
        #expect(try await s2.counts().schemaVersion == 99)
        await #expect(throws: MusicGraphError.readOnly) { try await s2.upsert(T.recording("New", uid: "p:2")) }
        await #expect(throws: MusicGraphError.readOnly) { try await s2.setPinned(id, true) }
        #expect(await s2.isReadOnly)
        #expect(try await s2.counts().entities == 1)
        #expect(try await s2.counts().schemaVersion == 99, "nothing was downgraded")
    }

    @Test func aCorruptFileIsSetAsideAndRebuilt() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        _ = try await s.upsert(T.recording("Song", uid: "p:1"))
        let path = s.databaseURL
        try await s.wipe()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((0..<8192).map { UInt8(($0 &* 31 &+ 7) % 251) }).write(to: path)

        let s2 = MusicGraphStore(directory: dir)
        #expect(try await s2.counts().entities == 0, "starts empty")
        #expect(await s2.recoveries == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("graph.sqlite.bad").path))
        // And works afterwards.
        let id = try await s2.upsert(T.recording("Again", uid: "p:9")).id
        #expect(try await s2.entity(id)?.name == "Again")

        // A damaged page in the middle of a healthy file is caught by the integrity check.
        for i in 0..<300 { _ = try await s2.upsert(T.recording("Song \(i)", uid: "p:x\(i)")) }
        await s2.close()
        let handle = try FileHandle(forWritingTo: path)
        try handle.seek(toOffset: 4096 * 3)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 4096 * 2))
        try handle.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + suffix) }
        let s3 = MusicGraphStore(directory: dir)
        #expect(try await s3.counts().entities == 0)
        #expect(await s3.recoveries == 1)
    }

    @Test func verifyOrRebuildReportsHealth() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        _ = try await s.upsert(T.recording("Song", uid: "p:1"))
        #expect(try await s.verifyOrRebuild())
        #expect(try await s.counts().entities == 1)
    }

    @Test func wipeLeavesNoFileAndTheNextUseStartsEmpty() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        _ = try await s.upsert(T.recording("Song", uid: "p:1"))
        _ = try await s.counts()
        #expect(FileManager.default.fileExists(atPath: s.databaseURL.path))
        try await s.wipe()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try await s.counts().entities == 0, "reopened empty, lazily")
        _ = try await s.upsert(T.recording("Song", uid: "p:1"))
        #expect(try await s.counts().entities == 1)
    }

    @Test func folderIsExcludedFromBackup() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        _ = try await s.upsert(T.recording("Song", uid: "p:1"))
        let v = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(v.isExcludedFromBackup == true)
    }

    @Test func runtimeIsLazyAndWipesTheFolder() async throws {
        let base = T.tempDirectory(); defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("Graph", isDirectory: true)
        let rt = MusicGraphRuntime(directory: { dir })
        #expect(!FileManager.default.fileExists(atPath: dir.path), "creating the runtime touches nothing")
        let id = try await rt.index.entityID(for: T.recording("Song", uid: "p:1"))
        #expect(try await rt.store.entity(id)?.name == "Song")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        await rt.wipe()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // The index forgot too: the same draft mints again into an empty graph.
        _ = try await rt.index.entityID(for: T.recording("Song", uid: "p:1"))
        #expect(try await rt.store.counts().entities == 1)
        await rt.wipe()
        // Wiping a graph that was never opened is fine.
        await MusicGraphRuntime(directory: { dir }).wipe()
    }

    @Test func graphRevAdvancesWithEveryWrite() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let r0 = try await s.graphRev()
        _ = try await s.upsert(T.recording("Song", uid: "p:1"))
        let r1 = try await s.graphRev()
        #expect(r1 > r0)
        _ = try await s.entity(MusicEntityID.derive(kind: .recording, aliasKey: "x"))
        #expect(try await s.graphRev() == r1, "reads do not")
    }

    @Test func databaseManagerMigratorParameterLeavesTheAppsMigrationsAlone() throws {
        let base = T.tempDirectory(); try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Default: the app's own migrator, exactly as before.
        let appPath = base.appendingPathComponent("app.sqlite").path
        let app = try DatabaseManager(path: appPath, readerCount: 1)
        #expect(try app.read { try $0.scalarInt("PRAGMA user_version") } == DatabaseMigrator.latestVersion)
        #expect(!(try tableNames(appPath)).contains("entity_fts"))
        // Graph: its own migrator; no app tables, no app version.
        let graphPath = base.appendingPathComponent("graph.sqlite").path
        let g = try DatabaseManager.music(at: URL(fileURLWithPath: graphPath))
        #expect(g.readerCount == 2)
        #expect(try g.read { try $0.scalarInt("PRAGMA user_version") } == 0)
        let names = try tableNames(graphPath)
        #expect(names.contains("entity_fts") && names.contains("edge"))
        #expect(names.isDisjoint(with: try tableNames(appPath).subtracting(["meta", "sqlite_sequence"])))
        // Journal mode and foreign keys come from the shared init.
        #expect(try g.read { try $0.queryOne("PRAGMA journal_mode") { $0.string(0) } } == "wal")
        // A custom migrator really replaces the default.
        let custom = try DatabaseManager(path: base.appendingPathComponent("c.sqlite").path, readerCount: 1, migrator: { try $0.exec("CREATE TABLE only_me(x)") })
        #expect(try custom.read { try $0.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = 'only_me'") } == 1)
        #expect(try custom.read { try $0.scalarInt("PRAGMA user_version") } == 0)
    }
}
