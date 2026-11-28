import Foundation

/// The graph file's own versioned migrations, kept in `meta.schema`. Handed to `DatabaseManager(path:migrator:)`, so the app's migrations never run on it.
enum MusicGraphMigrator {
    struct Migration { let version: Int; let sql: String }

    /// Append new migrations; never edit a released one. Additive first: new tables, new nullable columns, new indexes.
    static let migrations: [Migration] = [
        Migration(version: 1, sql: MusicGraphSchemaV1.sql),
        Migration(version: 2, sql: repairIdlessProviderIDs),
    ]
    /// Version 2 repairs data an old build wrote: a provider album with an empty id got the shared external id `provider-name:` (nothing after the colon), so every
    /// id-less album of that provider merged into one entity and its tracks all hung on it. A real provider id never ends with a colon. The shared id and the
    /// edges it collected are removed, so the next time those tracks are seen they are linked again (an id-less album is no longer linked at all).
    static let repairIdlessProviderIDs = """
    DELETE FROM edge WHERE object IN (SELECT entity FROM external_id WHERE scheme = 'provider' AND substr(value, -1) = ':')
       OR subject IN (SELECT entity FROM external_id WHERE scheme = 'provider' AND substr(value, -1) = ':');
    DELETE FROM external_id WHERE scheme = 'provider' AND substr(value, -1) = ':';
    """
    static var latestVersion: Int { migrations.last?.version ?? 0 }

    /// The schema version recorded in a file (0 for a new file).
    static func version(_ c: Connection) throws -> Int {
        guard try c.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='meta'") > 0 else { return 0 }
        return try c.queryOne("SELECT v FROM meta WHERE k='schema'") { Int($0.string(0)) ?? 0 } ?? 0
    }

    /// Brings a file up to date, one transaction per version. A file NEWER than this build is left alone (the store opens it read-only).
    static func migrate(_ c: Connection) throws {
        let current = try version(c)
        if current >= latestVersion { return }
        if current == 0 { try? c.exec("PRAGMA auto_vacuum=INCREMENTAL") }   // takes effect only on a file with no tables yet
        for m in migrations where m.version > current {
            try c.exec("BEGIN IMMEDIATE")
            do {
                try c.exec(m.sql)
                try c.execute("INSERT INTO meta(k, v) VALUES('schema', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [String(m.version)])
                try c.exec("COMMIT")
            } catch {
                try? c.exec("ROLLBACK")
                throw error
            }
        }
    }
}
