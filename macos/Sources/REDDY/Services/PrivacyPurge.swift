import Foundation

/// What is dropped when a folder is locked or the PIN session ends. Everything here only removes: pictures of the folder (memory and disk), and what the recommendation
/// code remembered about its titles. It never touches a playlist row, Continue Watching, favourites or any history.
struct PrivacyPurge: Sendable {
    let db: DatabaseManager
    let artwork: ArtworkService

    /// Every picture address of the titles in these folders: posters, backdrops, channel logos and episode stills. Read in chunks, in one pass per kind.
    static func artworkURLs(inFolders ids: [String], db: DatabaseManager) throws -> [String] {
        var out = Set<String>()
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
            let sql = """
                SELECT poster_url FROM movies WHERE category_id IN (\(marks)) UNION SELECT backdrop_url FROM movies WHERE category_id IN (\(marks))
                UNION SELECT poster_url FROM series WHERE category_id IN (\(marks)) UNION SELECT backdrop_url FROM series WHERE category_id IN (\(marks))
                UNION SELECT logo_url FROM channels WHERE category_id IN (\(marks))
                UNION SELECT e.image_url FROM episodes e JOIN series s ON s.id = e.series_id WHERE s.category_id IN (\(marks))
                """
            out.formUnion(try db.read { try $0.query(sql, args + args + args + args + args + args) { $0.optString(0) } }.compactMap { $0 }.filter { !$0.isEmpty })
        }
        return Array(out)
    }

    /// The folders that are hidden or locked right now.
    func restrictedFolderIDs() throws -> [String] {
        try db.read { c in
            try c.query("SELECT category_id FROM locked_categories UNION SELECT item_id FROM hidden_items WHERE kind='category'") { $0.string(0) }
        }
    }

    /// Evicts the pictures of these folders. Slow for a big folder, so callers run it off the main thread; it works in chunks and can be repeated safely.
    @discardableResult
    func evictArtwork(inFolders ids: [String]) async -> Int {
        guard !ids.isEmpty, let urls = try? Self.artworkURLs(inFolders: ids, db: db) else { return 0 }
        var removed = 0
        for chunk in stride(from: 0, to: urls.count, by: 500).map({ Array(urls[$0..<min($0 + 500, urls.count)]) }) {
            removed += await artwork.evict(urls: chunk)
            await Task.yield()
        }
        return removed
    }

    /// Evicts the pictures of every locked and hidden folder: after an unlocked session ends, and on launch when the last session ended without it (a crash or a quit while unlocked).
    @discardableResult
    func sweepRestrictedArtwork() async -> Int {
        guard let ids = try? restrictedFolderIDs() else { return 0 }
        return await evictArtwork(inFolders: ids)
    }
}
