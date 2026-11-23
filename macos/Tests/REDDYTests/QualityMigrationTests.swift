import Testing
import Foundation
@testable import REDDY

/// Every released schema version must upgrade to the current one, with the same objects a fresh database has. In-memory, no files.
@Suite("Migration quality") struct QualityMigrationTests {
    private func memory() throws -> Connection { try Connection(path: ":memory:", readOnly: false) }
    private func objects(_ c: Connection) throws -> [String] {
        try c.query("SELECT type || ':' || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY 1") { $0.string(0) }
    }

    @Test func everyPriorVersionUpgradesToTheSameSchemaAsAFreshDatabase() throws {
        let fresh = try memory(); try DatabaseMigrator.migrate(fresh)
        let want = try objects(fresh)
        let latest = DatabaseMigrator.latestVersion
        #expect(try fresh.scalarInt("PRAGMA user_version") == latest)
        for v in 1..<latest {
            let c = try memory()
            for m in DatabaseMigrator.migrations where m.version <= v { try c.exec(m.sql); try c.exec("PRAGMA user_version = \(m.version)") }
            try DatabaseMigrator.migrate(c)
            #expect(try c.scalarInt("PRAGMA user_version") == latest, "from v\(v)")
            #expect(try objects(c) == want, "schema differs after v\(v) -> v\(latest)")
            #expect(try c.query("PRAGMA integrity_check") { $0.string(0) } == ["ok"], "from v\(v)")
        }
    }

    @Test func versionsAreContiguousAndRerunIsANoOp() throws {
        #expect(DatabaseMigrator.migrations.map(\.version) == Array(1...DatabaseMigrator.latestVersion))
        let c = try memory(); try DatabaseMigrator.migrate(c)
        let before = try objects(c)
        try DatabaseMigrator.migrate(c)
        #expect(try objects(c) == before)
    }

    @Test func aFailingMigrationRollsBackAndKeepsTheOldVersion() throws {
        let c = try memory()
        try c.exec("BEGIN"); try c.exec("CREATE TABLE t(a)"); try c.exec("PRAGMA user_version = 1"); try c.exec("COMMIT")
        do { try c.exec("BEGIN"); try c.exec("CREATE TABLE t(a)"); try c.exec("COMMIT") } catch { try? c.exec("ROLLBACK") }
        #expect(try c.scalarInt("PRAGMA user_version") == 1)
    }

    @Test func settingsMigrateFromV1OnceAndKeepWhatIsAlreadyCurrent() throws {
        let name = "quality.migration.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
        d.set("Violet", forKey: "settings.accent"); d.set(true, forKey: "settings.hwdec")
        #expect(SettingsMigrator.migrate(d) == SettingsMigrator.currentVersion)
        #expect(d.string(forKey: "settings.accent") == AccentChoice.purple.rawValue)
        d.set("Violet", forKey: "settings.accent")           // a later write is not converted again
        #expect(SettingsMigrator.migrate(d) == SettingsMigrator.currentVersion)
        #expect(d.string(forKey: "settings.accent") == "Violet")
    }
}
