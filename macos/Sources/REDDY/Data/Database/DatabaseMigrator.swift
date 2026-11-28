import Foundation

enum DatabaseMigrator {
    struct Migration { let version: Int; let sql: String }

    /// Append new migrations here; never edit a released one.
    static let migrations: [Migration] = [
        Migration(version: 1, sql: SchemaV1.sql),
        Migration(version: 2, sql: SchemaV2.sql),
        Migration(version: 3, sql: SchemaV3.sql),
        Migration(version: 4, sql: SchemaV4.sql),
        Migration(version: 5, sql: SchemaV5.sql),
        Migration(version: 6, sql: SchemaV6.sql),
        Migration(version: 7, sql: SchemaV7.sql),
        Migration(version: 8, sql: SchemaV8.sql),
        Migration(version: 9, sql: SchemaV9.sql),
        Migration(version: 10, sql: SchemaV10.sql),
        Migration(version: 11, sql: SchemaV11.sql),
        Migration(version: 12, sql: SchemaV12.sql),
        Migration(version: 13, sql: SchemaV13.sql),
        Migration(version: 14, sql: SchemaV14.sql),
        Migration(version: 15, sql: SchemaV15.sql),
        Migration(version: 16, sql: SchemaV16.sql),
        Migration(version: 17, sql: SchemaV17.sql),
        Migration(version: 18, sql: SchemaV18.sql),
        Migration(version: 19, sql: SchemaV19.sql),
        Migration(version: 20, sql: SchemaV20.sql),
        Migration(version: 21, sql: SchemaV21.sql),
        Migration(version: 22, sql: SchemaV22.sql),
        Migration(version: 23, sql: SchemaV23.sql),
        Migration(version: 24, sql: SchemaV24.sql),
        Migration(version: 25, sql: SchemaV25.sql),
        Migration(version: 26, sql: SchemaV26.sql),          // a no-op that keeps the numbers consecutive (see SchemaV26)
        Migration(version: 27, sql: SchemaV27.sql),          // removes the tables of a feature that was withdrawn (version 26 was only ever used by development builds)
    ]

    static var latestVersion: Int { migrations.last?.version ?? 0 }

    static func migrate(_ c: Connection) throws {
        let current = try c.scalarInt("PRAGMA user_version")
        for m in migrations where m.version > current {
            try c.exec("BEGIN")
            do {
                try c.exec(m.sql)
                try c.exec("PRAGMA user_version = \(m.version)")
                try c.exec("COMMIT")
                Log.database.info("migrated database to v\(m.version)")
            } catch {
                try? c.exec("ROLLBACK")
                throw error
            }
        }
    }
}
