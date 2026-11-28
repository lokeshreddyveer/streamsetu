import Foundation

extension DatabaseManager {
    /// The music graph's file: its own migrations, two readers with a smaller cache than the app database.
    static func music(at url: URL) throws -> DatabaseManager {
        try DatabaseManager(path: url.path, readerCount: 2, readerCacheKiB: 16_384, migrator: MusicGraphMigrator.migrate)
    }
}
