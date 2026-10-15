import Foundation

/// Plex pictures used to be saved with the access token in their address. This removes it from what an earlier version stored; addresses without it are not touched.
enum PlexTokenCleanup {
    private static let columns = [("movies", "poster_url"), ("movies", "backdrop_url"), ("series", "poster_url"), ("series", "backdrop_url"), ("episodes", "image_url")]

    static func run(_ db: DatabaseManager) throws {
        try db.write { c in
            for (table, column) in columns {
                try c.execute("UPDATE \(table) SET \(column) = substr(\(column), 1, instr(\(column), '?X-Plex-Token=') - 1) WHERE \(column) LIKE '%?X-Plex-Token=%'")
            }
        }
    }
}
