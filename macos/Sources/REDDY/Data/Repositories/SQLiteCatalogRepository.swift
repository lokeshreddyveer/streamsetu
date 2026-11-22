import Foundation

final class SQLiteCatalogRepository: CatalogRepository {
    let db: DatabaseManager
    /// While active, content in PIN-locked folders is absent from every query below, as if it were not in the library.
    let restriction = Restriction()
    /// True only for the recommendation view (see `baseline`): locked folders, hidden folders and hidden titles are always absent, whatever the session says,
    /// and a title with a copy in such a folder is absent too.
    let alwaysRestricted: Bool
    /// Whether this view also applies the twin rule inside every query. The recommendation view does for single reads and for lists without a limit; for a limited list it reads
    /// through `lite` (same view, no twin rule) and applies the twin rule to the few rows it got, which costs a handful of lookups instead of two sets built over the whole library.
    private let twinRule: Bool
    private let baselineStore: SQLiteCatalogRepository?
    private let liteStore: SQLiteCatalogRepository?
    init(db: DatabaseManager) {
        self.db = db
        alwaysRestricted = false; twinRule = false
        baselineStore = SQLiteCatalogRepository(baselineOf: db)
        liteStore = nil
    }
    private init(baselineOf db: DatabaseManager) {
        self.db = db; alwaysRestricted = true; twinRule = true; baselineStore = nil
        liteStore = SQLiteCatalogRepository(liteOf: db)
    }
    private init(liteOf db: DatabaseManager) { self.db = db; alwaysRestricted = true; twinRule = false; baselineStore = nil; liteStore = nil }

    /// The catalog as every recommendation surface (hero, shelves, seeds, similar titles, widgets, assistant suggestions) must see it. Unlocking with the PIN does not widen it.
    var baseline: SQLiteCatalogRepository { baselineStore ?? self }
    var recommendationView: any CatalogRepository { baseline }
    /// Locked folders are hidden right now (a PIN is set and not unlocked, or a Kids profile is in use), or this is the recommendation view.
    var isRestricting: Bool { alwaysRestricted || restriction.isActive }

    final class Restriction: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isActive: Bool { get { lock.lock(); defer { lock.unlock() }; return on } set { lock.lock(); on = newValue; lock.unlock() } }
    }

    /// `AND` clause that removes items whose folder is locked. Empty when nothing is restricted.
    fileprivate func restricted(_ alias: String) -> String {
        guard isRestricting else { return "" }
        return " AND (\(alias).category_id IS NULL OR \(alias).category_id NOT IN (SELECT category_id FROM locked_categories))" + baselineExtra(alias)
    }

    /// The `AND` clause this view applies to a table aliased `alias` (`m` movies, `x` series, `c` channels).
    func restrictedClause(_ alias: String) -> String { restricted(alias) }

    /// What only the recommendation view adds: hidden folders and hidden titles, and the rule that a title is restricted when ANY copy of it
    /// (the twin playlist's, another language's) sits in a locked or hidden folder. Two sets are worked out once per statement (never per row): the titles that share an
    /// identity (same key, year within one) with a copy in such a folder, and the titles that share a normalized title with one (the fallback for titles with no identity yet).
    private func baselineExtra(_ alias: String) -> String {
        guard alwaysRestricted else { return "" }
        var s = " AND \(alias).id NOT IN (SELECT item_id FROM hidden_items) AND (\(alias).category_id IS NULL OR \(alias).category_id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category'))"
        guard alias != "c", twinRule else { return s }
        let table = alias == "m" ? "movies" : "series", kind = alias == "m" ? "movie" : "series"
        // Every copy that is restricted: in a locked or hidden folder, or hidden itself.
        let copies = """
            SELECT t.id FROM categories rc JOIN \(table) t ON t.source_id = rc.source_id AND t.category_id = rc.id
            WHERE rc.kind='\(kind)' AND (rc.id IN (SELECT category_id FROM locked_categories) OR rc.id IN (SELECT item_id FROM hidden_items WHERE kind='category'))
            UNION SELECT id FROM \(table) WHERE id IN (SELECT item_id FROM hidden_items WHERE kind<>'category')
            """
        // The title test is only for copies that have no identity row yet (a backfill still running), where the identity rule cannot see them: same title and a compatible year
        // (within one, or either unknown). A copy that has an identity row is judged by the identity rule alone, so unrelated titles that merely share their words are never caught.
        let uncovered = """
            SELECT t2.normalized_title AS nt, t2.release_year AS ry FROM \(table) t2 WHERE t2.id IN (\(copies)) AND t2.normalized_title <> ''
                AND NOT EXISTS (SELECT 1 FROM content_identity ci WHERE ci.item_id = t2.id)
            """
        // And the mirror case: the candidate itself has no identity row yet while a restricted copy (covered or not) has the same title and a compatible year.
        let allRestricted = """
            SELECT t2.normalized_title AS nt, t2.release_year AS ry FROM \(table) t2 WHERE t2.id IN (\(copies)) AND t2.normalized_title <> ''
            """
        // With nothing locked or hidden at all the twin rule has nothing to look for: the constant test is true, the OR stops there, and the sets below are never built.
        s += """
             AND ((NOT EXISTS (SELECT 1 FROM locked_categories) AND NOT EXISTS (SELECT 1 FROM hidden_items)) OR (
                 \(alias).id NOT IN (SELECT me.item_id FROM (\(copies)) r JOIN content_identity tw ON tw.item_id = r.id
                     JOIN content_identity me ON me.kind = tw.kind AND me.identity_key = tw.identity_key AND (me.year IS NULL OR tw.year IS NULL OR abs(me.year - tw.year) <= 1))
                 AND NOT EXISTS (SELECT 1 FROM (\(uncovered)) u WHERE u.nt = \(alias).normalized_title AND (\(alias).release_year IS NULL OR u.ry IS NULL OR abs(\(alias).release_year - u.ry) <= 1))
                 AND NOT (NOT EXISTS (SELECT 1 FROM content_identity me0 WHERE me0.item_id = \(alias).id)
                          AND EXISTS (SELECT 1 FROM (\(allRestricted)) u2 WHERE u2.nt = \(alias).normalized_title AND (\(alias).release_year IS NULL OR u2.ry IS NULL OR abs(\(alias).release_year - u2.ry) <= 1)))))
            """
        return s
    }

    /// Reads rows from the lite view in growing windows from the top until `limit` of them pass the twin rule (or the list ends). Rows that fail are skipped, so the result is
    /// what the full rule would return, in the same order.
    private static func overFetch<T>(limit: Int, read: (Int) throws -> [T], twinFree: ([T]) throws -> Set<String>, id: (T) -> String) throws -> [T] {
        guard limit > 0 else { return [] }
        var window = max(limit * 2 + 16, 48)
        while true {
            let rows = try read(window)
            let ok = try twinFree(rows)
            let kept = rows.filter { ok.contains(id($0)) }
            if kept.count >= limit || rows.count < window { return Array(kept.prefix(limit)) }
            window *= 4
        }
    }

    /// The ids among these (all of one table) that have no copy in a locked or hidden folder: one lookup per id through the identity index, and always the same-title test as well (fail closed: a restricted copy
    /// with no identity row yet, during a backfill, is still caught by its title).
    fileprivate func twinFree(_ ids: [String], table: String) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var out = Set<String>()
        let kind = table == "movies" ? "movie" : "series"
        func bad(_ t: String) -> String { "(\(t).category_id IN (SELECT category_id FROM locked_categories) OR \(t).category_id IN (SELECT item_id FROM hidden_items WHERE kind='category') OR \(t).id IN (SELECT item_id FROM hidden_items WHERE kind<>'category'))" }
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
            let sql = """
                SELECT m.id FROM \(table) m WHERE m.id IN (\(marks))
                AND ((NOT EXISTS (SELECT 1 FROM locked_categories) AND NOT EXISTS (SELECT 1 FROM hidden_items)) OR (
                    NOT EXISTS (SELECT 1 FROM content_identity me JOIN content_identity tw ON tw.kind = me.kind AND tw.identity_key = me.identity_key AND (tw.year IS NULL OR me.year IS NULL OR abs(tw.year - me.year) <= 1)
                        JOIN \(table) t ON t.id = tw.item_id WHERE me.item_id = m.id AND me.kind = '\(kind)' AND \(bad("t")))
                    AND NOT EXISTS (SELECT 1 FROM (SELECT t2.normalized_title AS nt, t2.release_year AS ry FROM \(table) t2 WHERE \(bad("t2")) AND t2.normalized_title <> ''
                                                    AND NOT EXISTS (SELECT 1 FROM content_identity ci WHERE ci.item_id = t2.id)) u
                                    WHERE u.nt = m.normalized_title AND (m.release_year IS NULL OR u.ry IS NULL OR abs(m.release_year - u.ry) <= 1))
                    AND NOT (NOT EXISTS (SELECT 1 FROM content_identity me0 WHERE me0.item_id = m.id)
                             AND EXISTS (SELECT 1 FROM (SELECT t2.normalized_title AS nt, t2.release_year AS ry FROM \(table) t2 WHERE \(bad("t2")) AND t2.normalized_title <> '') u2
                                         WHERE u2.nt = m.normalized_title AND (m.release_year IS NULL OR u2.ry IS NULL OR abs(m.release_year - u2.ry) <= 1)))))
                """
            out.formUnion(try db.read { try $0.query(sql, args) { $0.string(0) } })
        }
        return out
    }

    /// Which of these titles (movies or series) the recommendation view may show: not in a locked or hidden folder, not hidden, and with no copy in one. A few lookups per id.
    func recommendableIDs(_ ids: [String]) throws -> Set<String> {
        let view = baseline, lite = view.liteStore ?? view
        var out = Set<String>()
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ","), args = chunk.map { $0 as (any SQLConvertible)? }
            let movies = try db.read { try $0.query("SELECT m.id FROM movies m WHERE m.id IN (\(marks))\(lite.restricted("m"))", args) { $0.string(0) } }
            let series = try db.read { try $0.query("SELECT x.id FROM series x WHERE x.id IN (\(marks))\(lite.restricted("x"))", args) { $0.string(0) } }
            out.formUnion(try view.twinFree(movies, table: "movies")); out.formUnion(try view.twinFree(series, table: "series"))
        }
        return out
    }

    func hiddenByLock(_ ids: [String]) throws -> Set<String> {
        guard isRestricting, !ids.isEmpty else { return [] }
        var out = Set<String>()
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let args = chunk.map { $0 as (any SQLConvertible)? }
            let lockedIn = "category_id IN (SELECT category_id FROM locked_categories)"
            let sql = """
                SELECT id FROM channels WHERE id IN (\(marks)) AND \(lockedIn)
                UNION SELECT id FROM movies WHERE id IN (\(marks)) AND \(lockedIn)
                UNION SELECT id FROM series WHERE id IN (\(marks)) AND \(lockedIn)
                UNION SELECT e.id FROM episodes e JOIN series s ON s.id = e.series_id WHERE e.id IN (\(marks)) AND s.\(lockedIn)
                """
            out.formUnion(try db.read { try $0.query(sql, args + args + args + args) { $0.string(0) } })
        }
        return out
    }

    func lockedCategoryIDs() throws -> Set<String> { Set(try db.read { try $0.query("SELECT category_id FROM locked_categories") { $0.string(0) } }) }

    /// Locks or unlocks a folder. With `family`, the same-named folders of every other playlist (including ones added later) follow it. Returns the folders changed.
    @discardableResult
    func setCategoryLocked(_ id: String, _ locked: Bool, family: Bool = false) throws -> [String] {
        try db.write { c in
            let ids = family ? try FolderFamily.members(of: id, in: c) : [id]
            for x in ids {
                if locked { try c.execute("INSERT OR IGNORE INTO locked_categories(category_id) VALUES(?)", [x]) }
                else { try c.execute("DELETE FROM locked_categories WHERE category_id=?", [x]) }
            }
            return ids
        }
    }

    /// Every folder (as it is stored) that carries the lock, read live from the database.
    func familyMembers(of id: String) throws -> [String] { try db.read { try FolderFamily.members(of: id, in: $0) } }

    // MARK: sources

    private static let sourceSelect = """
        SELECT s.id, s.name, s.type, s.base_url, s.credential_ref, s.epg_url, s.enabled, s.last_sync, s.sync_status, s.created_at,
               COALESCE(k.live,0), COALESCE(k.movies,0), COALESCE(k.series,0), COALESCE(k.epg,0), k.output_formats
        FROM sources s LEFT JOIN source_capabilities k ON k.source_id = s.id
        """

    private static func mapSource(_ r: Row) -> PlaylistSource? {
        guard let id = r.uuid(0), let type = SourceType(rawValue: r.string(2)) else { return nil }
        let caps = SourceCapabilities(live: r.bool(10), movies: r.bool(11), series: r.bool(12), epg: r.bool(13),
                                      outputFormats: r.optString(14)?.split(separator: ",").map(String.init) ?? [])
        return PlaylistSource(id: id, name: r.string(1), type: type, baseURL: r.string(3), credentialRef: r.optString(4),
                              epgURL: r.optString(5), enabled: r.bool(6), lastSync: r.optDate(7), syncStatus: r.string(8),
                              createdAt: r.date(9), capabilities: caps)
    }

    func sources() throws -> [PlaylistSource] {
        try db.read { try $0.query(Self.sourceSelect + " ORDER BY s.sort_order, s.created_at", [], Self.mapSource).compactMap { $0 } }
    }

    func source(id: UUID) throws -> PlaylistSource? {
        try db.read { try $0.query(Self.sourceSelect + " WHERE s.id=?", [id], Self.mapSource).compactMap { $0 }.first }
    }

    func save(source s: PlaylistSource) throws {
        try db.write { c in
            try c.execute("""
                INSERT INTO sources(id, name, type, base_url, credential_ref, epg_url, enabled, last_sync, sync_status, created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, type=excluded.type, base_url=excluded.base_url,
                    credential_ref=excluded.credential_ref, epg_url=excluded.epg_url, enabled=excluded.enabled
                """, [s.id, s.name, s.type.rawValue, s.baseURL, s.credentialRef, s.epgURL, s.enabled, s.lastSync, s.syncStatus, s.createdAt])
            try c.execute("INSERT OR IGNORE INTO source_capabilities(source_id) VALUES(?)", [s.id])
        }
    }

    func deleteSource(id: UUID) throws {
        try db.write { c in
            let prefix = id.uuidString.lowercased() + "|"
            // Cascades remove catalog rows; user data and the search index are keyed by item id and cleaned explicitly.
            try c.execute("DELETE FROM search_docs WHERE source_id=?", [id])
            try c.execute("DELETE FROM people WHERE source_id=?", [id.uuidString.lowercased()])
            try c.execute("DELETE FROM people_done WHERE source_id=?", [id.uuidString.lowercased()])
            for t in ["favorites", "recently_watched", "watch_progress", "hidden_items", "metadata_overrides", "collection_items", "video_layouts"] {
                try c.execute("DELETE FROM \(t) WHERE substr(item_id,1,37)=?", [prefix])
            }
            try c.execute("DELETE FROM watch_history WHERE substr(item_id,1,37)=?", [prefix])
            try c.execute("DELETE FROM sources WHERE id=?", [id])
        }
    }

    func setEnabled(_ enabled: Bool, sourceID: UUID) throws {
        try db.write { try $0.execute("UPDATE sources SET enabled=? WHERE id=?", [enabled, sourceID]) }
    }

    func updateSyncStatus(sourceID: UUID, status: String, lastSync: Date?) throws {
        try db.write { try $0.execute("UPDATE sources SET sync_status=?, last_sync=COALESCE(?, last_sync) WHERE id=?", [status, lastSync, sourceID]) }
    }

    func saveCapabilities(_ k: SourceCapabilities, sourceID: UUID) throws {
        try db.write { c in
            try c.execute("""
                INSERT INTO source_capabilities(source_id, live, movies, series, epg, output_formats) VALUES(?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET live=excluded.live, movies=excluded.movies, series=excluded.series,
                    epg=excluded.epg, output_formats=excluded.output_formats
                """, [sourceID, k.live, k.movies, k.series, k.epg, k.outputFormats.joined(separator: ",")])
        }
    }

    func syncStates(sourceID: UUID) throws -> [SyncScopeState] {
        try db.read { c in
            try c.query("SELECT scope, last_success, last_attempt, etag, last_modified, item_count, error FROM source_sync_state WHERE source_id=?", [sourceID]) {
                SyncScopeState(scope: $0.string(0), lastSuccess: $0.optDate(1), lastAttempt: $0.optDate(2), etag: $0.optString(3),
                               lastModified: $0.optString(4), itemCount: $0.int(5), error: $0.optString(6))
            }
        }
    }

    func recordSync(sourceID: UUID, scope: String, success: Bool, itemCount: Int?, etag: String?, lastModified: String?, error: String?) throws {
        try db.write { c in
            let now = Date()
            try c.execute("""
                INSERT INTO source_sync_state(source_id, scope, last_success, last_attempt, etag, last_modified, item_count, error)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id, scope) DO UPDATE SET
                    last_success=COALESCE(excluded.last_success, source_sync_state.last_success), last_attempt=excluded.last_attempt,
                    etag=COALESCE(excluded.etag, source_sync_state.etag),
                    last_modified=COALESCE(excluded.last_modified, source_sync_state.last_modified),
                    item_count=COALESCE(?, source_sync_state.item_count), error=excluded.error
                """, [sourceID, scope, success ? now : nil, now, etag, lastModified, itemCount ?? 0, error, itemCount])
        }
    }

    // MARK: categories

    func categories(sourceID: UUID?, kind: ContentKind, includeHidden: Bool) throws -> [CatalogCategory] {
        let table: String
        switch kind { case .channel: table = "channels"; case .movie: table = "movies"; case .series: table = "series"; case .episode: return [] }
        // A locked folder is listed by name only while folders are locked: its count is never computed (the CASE does not run the subquery) and is reported as 0.
        let hideCount = isRestricting ? "1" : "0"
        var sql = """
            SELECT cat.id, cat.source_id, cat.kind, cat.provider_id, cat.name, cat.sort_order,
                   CASE WHEN \(hideCount) = 1 AND lc.category_id IS NOT NULL THEN 0
                        ELSE (SELECT COUNT(*) FROM \(table) x WHERE x.source_id=cat.source_id AND x.category_id=cat.id\(kind == .channel ? " AND x.is_primary=1" : "")) END,
                   lc.category_id IS NOT NULL
            FROM categories cat JOIN sources s ON s.id=cat.source_id AND s.enabled=1
            LEFT JOIN folder_order fo ON fo.category_id=cat.id LEFT JOIN locked_categories lc ON lc.category_id=cat.id WHERE cat.kind=?
            """
        var args: [(any SQLConvertible)?] = [kind.rawValue]
        if let sourceID { sql += " AND cat.source_id=?"; args.append(sourceID) }
        if !includeHidden { sql += " AND cat.id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category')" }
        sql += " ORDER BY fo.position IS NULL, fo.position, cat.sort_order, cat.name COLLATE NOCASE"
        return try db.read { c in
            try c.query(sql, args) { r in
                CatalogCategory(id: r.string(0), sourceID: r.uuid(1) ?? UUID(), kind: kind, providerID: r.string(3), name: r.string(4),
                                sortOrder: r.int(5), itemCount: r.int(6), isLocked: r.bool(7))
            }
        }
    }

    // MARK: folder order

    /// Saves the order of the given folders (first = top). Folders not listed keep the provider's order after them.
    func setFolderOrder(_ categoryIDs: [String]) throws {
        try db.write { c in
            for (i, id) in categoryIDs.enumerated() { try c.execute("INSERT INTO folder_order(category_id, position) VALUES(?, ?) ON CONFLICT(category_id) DO UPDATE SET position=excluded.position", [id, i]) }
        }
    }

    /// Puts the given folders back to the provider's order.
    func clearFolderOrder(_ categoryIDs: [String]) throws {
        try db.write { c in for id in categoryIDs { try c.execute("DELETE FROM folder_order WHERE category_id=?", [id]) } }
    }

    // MARK: channels

    private static let channelSelect = """
        SELECT c.id, c.source_id, c.provider_id, COALESCE(o.display_name, c.name), c.normalized_name, c.category_id,
               COALESCE(o.category_name, c.category_name), c.logo_url, COALESCE(o.epg_id, c.epg_id), c.language, c.country,
               c.resolution_hint, c.sort_order, c.stream_ref, c.group_key, EXISTS(SELECT 1 FROM favorites f WHERE f.item_id=c.id), c.archive_days
        FROM channels c JOIN sources s ON s.id=c.source_id AND s.enabled=1
        LEFT JOIN metadata_overrides o ON o.item_id=c.id
        """

    private static func mapChannel(_ r: Row) -> Channel {
        Channel(id: r.string(0), sourceID: r.uuid(1) ?? UUID(), providerID: r.string(2), name: r.string(3), normalizedName: r.string(4),
                categoryID: r.optString(5), categoryName: r.optString(6), logoURL: r.optString(7), epgID: r.optString(8),
                language: r.optString(9), country: r.optString(10), resolutionHint: r.optString(11), sortOrder: r.int(12),
                streamRef: r.string(13), groupKey: r.optString(14), isFavorite: r.bool(15), archiveDays: r.int(16))
    }

    func channels(_ q: ChannelQuery) throws -> [Channel] {
        guard var (sql, args) = channelFilter(q) else { return [] }
        sql += q.recentlyAdded ? " ORDER BY c.first_seen_at DESC, c.sort_order, c.rowid"
            : q.sortAlphabetically ? " ORDER BY COALESCE(o.display_name, c.name) COLLATE NOCASE, c.rowid" : " ORDER BY c.source_id, c.sort_order, c.rowid"
        if let l = q.limit { sql += " LIMIT \(l) OFFSET \(q.offset)" }
        return try db.read { try $0.query(sql, args, Self.mapChannel) }
    }

    /// How many channels the query matches, ignoring its limit and offset, so a screen that reads them a page at a time can still show the total.
    func countChannels(_ q: ChannelQuery) throws -> Int {
        guard let (sql, args) = channelFilter(q) else { return 0 }
        return try db.read { try $0.scalarInt("SELECT COUNT(*) FROM (" + sql + ")", args) }
    }

    /// The query's select and filters, without ordering or paging; nil when it can match nothing.
    private func channelFilter(_ q: ChannelQuery) -> (String, [(any SQLConvertible)?])? {
        var sql = Self.channelSelect + " WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        if let ids = q.ids {
            guard !ids.isEmpty else { return nil }
            sql += " AND c.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            args += ids.map { $0 as (any SQLConvertible)? }
        }
        sql += restricted("c")
        if let s = q.sourceID { sql += " AND c.source_id=?"; args.append(s) }
        if let cat = q.categoryID {
            if cat == CatalogCategory.uncategorizedID { sql += " AND c.category_id IS NULL" } else { sql += " AND c.category_id=?"; args.append(cat) }
        }
        if q.favoritesOnly { sql += " AND c.id IN (SELECT item_id FROM favorites)" }
        if q.onlyWithGuide { sql += " AND EXISTS (SELECT 1 FROM epg_channel_mappings m WHERE m.channel_id=c.id)" }
        if !q.includeHidden {
            sql += " AND c.id NOT IN (SELECT item_id FROM hidden_items) AND (c.category_id IS NULL OR c.category_id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category'))"
        }
        let term = q.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            if let m = SearchIndexer.ftsQuery(term) {
                sql += " AND c.id IN (SELECT d.item_id FROM catalog_fts f JOIN search_docs d ON d.id=f.rowid WHERE catalog_fts MATCH ? AND d.kind='channel')"
                args.append(m)
            } else { return nil }
        } else if q.collapseVariants {
            sql += " AND c.is_primary=1"
        }
        return (sql, args)
    }

    func channel(id: String) throws -> Channel? {
        try db.read { try $0.query(Self.channelSelect + " WHERE c.id=?" + restricted("c"), [id], Self.mapChannel).first }
    }

    func variants(ofChannel id: String) throws -> [(variant: Channel, label: String)] {
        let rows: [(label: String, id: String)] = try db.read { c in
            try c.query("""
                SELECT v.label, v.variant_id FROM stream_variants v JOIN channels ch ON ch.id=v.variant_id
                WHERE v.channel_id=(SELECT channel_id FROM stream_variants WHERE variant_id=? LIMIT 1)
                ORDER BY ch.sort_order
                """, [id]) { (label: $0.string(0), id: $0.string(1)) }
        }
        return try rows.compactMap { r in try channel(id: r.id).map { (variant: $0, label: r.label) } }
    }

    func channelCopiesInOtherPlaylists(of channel: Channel) throws -> [Channel] {
        guard !channel.normalizedName.isEmpty else { return [] }
        let ids: [String] = try db.read { c in
            try c.query("""
                SELECT ch.id FROM channels ch JOIN sources s ON s.id=ch.source_id AND s.enabled=1
                WHERE ch.source_id != ? AND (ch.normalized_name = ? OR (? != '' AND ch.epg_id = ?))
                ORDER BY (ch.normalized_name = ?) DESC, s.sort_order, ch.sort_order LIMIT 6
                """, [channel.sourceID.uuidString.lowercased(), channel.normalizedName, channel.epgID ?? "", channel.epgID ?? "", channel.normalizedName]) { $0.string(0) }
        }
        return try ids.compactMap { try self.channel(id: $0) }
    }

    // MARK: movies

    private static let movieSelect = """
        SELECT m.id, m.source_id, m.provider_id, m.title, m.normalized_title, m.overview, m.poster_url, m.backdrop_url, m.release_year,
               m.duration_seconds, m.genre, m.rating, m.category_id, m.category_name, m.stream_ref, m.added_at, m.detail_fetched_at,
               EXISTS(SELECT 1 FROM favorites f WHERE f.item_id=m.id)
        FROM movies m JOIN sources s ON s.id=m.source_id AND s.enabled=1
        """

    private static func mapMovie(_ r: Row) -> Movie {
        Movie(id: r.string(0), sourceID: r.uuid(1) ?? UUID(), providerID: r.string(2), title: r.string(3), normalizedTitle: r.string(4),
              overview: r.optString(5), posterURL: r.optString(6), backdropURL: r.optString(7), releaseYear: r.optInt(8),
              durationSeconds: r.optDouble(9), genre: r.optString(10), rating: r.optString(11), categoryID: r.optString(12),
              categoryName: r.optString(13), streamRef: r.string(14), addedAt: r.optDate(15), detailFetchedAt: r.optDate(16),
              isFavorite: r.bool(17))
    }

    private func vodWhere(_ q: VODQuery, alias: String, kind: String, sql: inout String, args: inout [(any SQLConvertible)?]) -> Bool {
        if let ids = q.ids {
            guard !ids.isEmpty else { return false }
            sql += " AND \(alias).id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            args += ids.map { $0 as (any SQLConvertible)? }
        }
        sql += restricted(alias)
        if let s = q.sourceID { sql += " AND \(alias).source_id=?"; args.append(s) }
        if let cat = q.categoryID {
            if cat == CatalogCategory.uncategorizedID { sql += " AND \(alias).category_id IS NULL" } else { sql += " AND \(alias).category_id=?"; args.append(cat) }
        }
        if let y = q.year { sql += " AND \(alias).release_year=?"; args.append(y) }
        if q.favoritesOnly { sql += " AND \(alias).id IN (SELECT item_id FROM favorites)" }
        if q.unwatchedOnly {
            if kind == "movie" { sql += " AND \(alias).id NOT IN (SELECT item_id FROM watch_progress) AND \(alias).id NOT IN (SELECT item_id FROM watch_history)" }
            else { sql += " AND \(alias).id NOT IN (SELECT series_id FROM watch_progress WHERE series_id IS NOT NULL) AND \(alias).id NOT IN (SELECT e.series_id FROM episodes e JOIN watch_history h ON h.item_id = e.id)" }
        }
        if let language = q.language, LanguageTags.known.contains(language) {
            sql += " AND (\(alias).title LIKE '%(\(language)%' OR \(alias).title LIKE '%[\(language)%' OR \(alias).category_name LIKE '%\(language)%')"
        }
        if let quality = q.quality, let terms = LibraryFilterTerms.qualityTerms[quality] {
            sql += " AND (" + terms.map { "(\(alias).title LIKE '%\($0)%' OR \(alias).category_name LIKE '%\($0)%')" }.joined(separator: " OR ") + ")"
        }
        if !q.genres.isEmpty {
            sql += " AND (" + q.genres.map { _ in "\(alias).genre LIKE ? OR \(alias).category_name LIKE ?" }.joined(separator: " OR ") + ")"
            for g in q.genres { args.append("%\(g)%"); args.append("%\(g)%") }
        }
        for g in q.excludeGenres { sql += " AND COALESCE(\(alias).genre,'') NOT LIKE ? AND COALESCE(\(alias).category_name,'') NOT LIKE ?"; args.append("%\(g)%"); args.append("%\(g)%") }
        if let rating = q.minRating { sql += " AND CAST(\(alias).rating AS REAL) >= ?"; args.append(rating) }
        if kind == "movie", let m = q.maxMinutes { sql += " AND \(alias).duration_seconds > 0 AND \(alias).duration_seconds <= ?"; args.append(m * 60) }
        if kind == "movie", let m = q.minMinutes { sql += " AND \(alias).duration_seconds >= ?"; args.append(m * 60) }
        if let decade = q.decade { sql += " AND \(alias).release_year >= ? AND \(alias).release_year < ?"; args.append(decade); args.append(decade + 10) }
        if let watch = q.watch {
            let finished = kind == "movie"
                ? "\(alias).id IN (SELECT item_id FROM watch_progress WHERE completed=1)"
                : "\(alias).id IN (SELECT e.series_id FROM episodes e LEFT JOIN watch_progress p ON p.item_id = e.id AND p.completed = 1 GROUP BY e.series_id HAVING COUNT(p.item_id) = COUNT(*))"
            let begun = kind == "movie"
                ? "\(alias).id IN (SELECT item_id FROM watch_progress WHERE completed=0 AND position_seconds>30)"
                : "\(alias).id IN (SELECT series_id FROM watch_progress WHERE series_id IS NOT NULL)"
            sql += watch == .watched ? " AND \(finished)" : " AND \(begun) AND NOT (\(finished))"
        }
        if q.newEpisodesOnly { sql += " AND \(alias).id IN (SELECT series_id FROM new_episodes WHERE episode_id NOT IN (SELECT item_id FROM watch_progress) AND episode_id NOT IN (SELECT item_id FROM watch_history))" }
        if let days = q.addedWithinDays {
            sql += " AND \(alias).added_at IS NOT NULL AND \(alias).added_at >= ?"
            args.append(Date().addingTimeInterval(-Double(days) * 86400))
        }
        if !q.includeHidden {
            sql += " AND \(alias).id NOT IN (SELECT item_id FROM hidden_items) AND (\(alias).category_id IS NULL OR \(alias).category_id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category'))"
        }
        let term = q.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            guard let m = SearchIndexer.ftsQuery(term) else { return false }
            // A title, or somebody in it: "mahesh babu" finds his films by the cast and directors read from the provider (see PeopleIndex).
            let words = PeopleIndex.norm(term).split(separator: " ").map(String.init)
            var byPerson = ""
            if words.joined().count >= 3 {
                byPerson = " OR \(alias).id IN (SELECT item_id FROM people WHERE kind='\(kind)'"
                for w in words { byPerson += " AND (norm LIKE ? OR norm LIKE ?)" }
                byPerson += ")"
            }
            sql += " AND (\(alias).id IN (SELECT d.item_id FROM catalog_fts f JOIN search_docs d ON d.id=f.rowid WHERE catalog_fts MATCH ? AND d.kind='\(kind)')\(byPerson))"
            args.append(m)
            if !byPerson.isEmpty { for w in words { args.append(w + "%"); args.append("% " + w + "%") } }
        }
        return true
    }

    private static func order(_ sort: VODSort, alias a: String, titleColumn t: String) -> String {
        let byTitle = "\(a).\(t) COLLATE NOCASE"
        switch sort {
        case .recentlyAdded: return " ORDER BY COALESCE(\(a).added_at, \(a).\(a == "m" ? "created_at" : "first_seen_at"), 0) DESC, \(byTitle)"
        case .title: return " ORDER BY \(byTitle)"
        case .titleDescending: return " ORDER BY \(a).\(t) COLLATE NOCASE DESC"
        case .year: return " ORDER BY COALESCE(\(a).release_year,0) DESC, \(byTitle)"
        case .yearOldest: return " ORDER BY (\(a).release_year IS NULL), \(a).release_year ASC, \(byTitle)"      // unknown years last
        case .rating: return " ORDER BY CAST(COALESCE(NULLIF(\(a).rating,''),'0') AS REAL) DESC, \(byTitle)"
        case .durationShortest, .durationLongest:
            guard a == "m" else { return " ORDER BY \(byTitle)" }                                                  // series carry no duration
            let dir = sort == .durationShortest ? "ASC" : "DESC"
            return " ORDER BY (COALESCE(m.duration_seconds,0) <= 0), m.duration_seconds \(dir), \(byTitle)"          // unknown last
        }
    }

    func movies(_ q: VODQuery) throws -> [Movie] {
        if twinRule, let lite = liteStore, let limit = q.limit, q.offset == 0, q.ids == nil {
            return try Self.overFetch(limit: limit) { n in try lite.moviesInView(q.with(limit: n)) } twinFree: { try self.twinFree($0.map(\.id), table: "movies") } id: { $0.id }
        }
        return try moviesInView(q)
    }

    fileprivate func moviesInView(_ q: VODQuery) throws -> [Movie] {
        var sql = Self.movieSelect + " WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        guard vodWhere(q, alias: "m", kind: "movie", sql: &sql, args: &args) else { return [] }
        sql += Self.order(q.sort, alias: "m", titleColumn: "title")
        if let l = q.limit { sql += " LIMIT \(l) OFFSET \(q.offset)" }
        return try db.read { try $0.query(sql, args, Self.mapMovie) }
    }

    /// The languages and qualities that at least one title (or its folder) names, in alphabetical order for languages.
    func filterOptions(sourceID: UUID?, kind: ContentKind) throws -> LibraryFilterOptions {
        func any(_ q: VODQuery) -> Bool {
            var sql = kind == .movie ? "SELECT 1 FROM movies m JOIN sources s ON s.id=m.source_id AND s.enabled=1 WHERE 1=1" : "SELECT 1 FROM series x JOIN sources s ON s.id=x.source_id AND s.enabled=1 WHERE 1=1"
            var args: [(any SQLConvertible)?] = []
            guard vodWhere(q, alias: kind == .movie ? "m" : "x", kind: kind == .movie ? "movie" : "series", sql: &sql, args: &args) else { return false }
            sql += " LIMIT 1"
            return ((try? db.read { try $0.query(sql, args) { _ in 1 } }) ?? []).isEmpty == false
        }
        var out = LibraryFilterOptions()
        for language in LanguageTags.known.sorted() {
            var q = VODQuery(sourceID: sourceID); q.language = language
            if any(q) { out.languages.append(language) }
        }
        for quality in LibraryFilterTerms.qualityOrder {
            var q = VODQuery(sourceID: sourceID); q.quality = quality
            if any(q) { out.qualities.append(quality) }
        }
        return out
    }

    /// The same film as it appears in the library under the same name, in any playlist or folder (for the best copy and the next best when one does not play).
    func movieCopies(of m: Movie) throws -> [Movie] {
        let found = try db.read { try $0.query(Self.movieSelect + " WHERE m.normalized_title=?" + restricted("m"), [m.normalizedTitle], Self.mapMovie) }
        // The film that was handed in is added only when nothing hides it: a title in a folder that has since been locked must not come back through here.
        return found.contains { $0.id == m.id } ? found : (isRestricting ? found : [m] + found)
    }

    func movie(id: String) throws -> Movie? {
        try db.read { try $0.query(Self.movieSelect + " WHERE m.id=?" + restricted("m"), [id], Self.mapMovie).first }
    }

    // MARK: series

    private static let seriesSelect = """
        SELECT x.id, x.source_id, x.provider_id, x.title, x.normalized_title, x.overview, x.poster_url, x.backdrop_url, x.genre,
               x.release_year, x.rating, x.category_id, x.category_name, x.added_at, x.last_metadata_refresh,
               EXISTS(SELECT 1 FROM favorites f WHERE f.item_id=x.id)
        FROM series x JOIN sources s ON s.id=x.source_id AND s.enabled=1
        """

    private static func mapSeries(_ r: Row) -> Series {
        Series(id: r.string(0), sourceID: r.uuid(1) ?? UUID(), providerID: r.string(2), title: r.string(3), normalizedTitle: r.string(4),
               overview: r.optString(5), posterURL: r.optString(6), backdropURL: r.optString(7), genre: r.optString(8),
               releaseYear: r.optInt(9), rating: r.optString(10), categoryID: r.optString(11), categoryName: r.optString(12),
               addedAt: r.optDate(13), lastMetadataRefresh: r.optDate(14), isFavorite: r.bool(15))
    }

    func countMovies(_ q: VODQuery) throws -> Int {
        var sql = "SELECT COUNT(*) FROM movies m JOIN sources s ON s.id=m.source_id AND s.enabled=1 WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        guard vodWhere(q, alias: "m", kind: "movie", sql: &sql, args: &args) else { return 0 }
        return try db.read { try $0.scalarInt(sql, args) }
    }

    func countSeries(_ q: VODQuery) throws -> Int {
        var sql = "SELECT COUNT(*) FROM series x JOIN sources s ON s.id=x.source_id AND s.enabled=1 WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        guard vodWhere(q, alias: "x", kind: "series", sql: &sql, args: &args) else { return 0 }
        return try db.read { try $0.scalarInt(sql, args) }
    }

    func series(_ q: VODQuery) throws -> [Series] {
        if twinRule, let lite = liteStore, let limit = q.limit, q.offset == 0, q.ids == nil {
            return try Self.overFetch(limit: limit) { n in try lite.seriesInView(q.with(limit: n)) } twinFree: { try self.twinFree($0.map(\.id), table: "series") } id: { $0.id }
        }
        return try seriesInView(q)
    }

    fileprivate func seriesInView(_ q: VODQuery) throws -> [Series] {
        var sql = Self.seriesSelect + " WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        guard vodWhere(q, alias: "x", kind: "series", sql: &sql, args: &args) else { return [] }
        sql += Self.order(q.sort, alias: "x", titleColumn: "title")
        if let l = q.limit { sql += " LIMIT \(l) OFFSET \(q.offset)" }
        return try db.read { try $0.query(sql, args, Self.mapSeries) }
    }

    func seriesItem(id: String) throws -> Series? {
        try db.read { try $0.query(Self.seriesSelect + " WHERE x.id=?" + restricted("x"), [id], Self.mapSeries).first }
    }

    func seasons(seriesID: String) throws -> [Season] {
        try db.read { c in
            try c.query("SELECT id, series_id, number, name FROM seasons WHERE series_id=? ORDER BY number", [seriesID]) {
                Season(id: $0.string(0), seriesID: $0.string(1), number: $0.int(2), name: $0.optString(3))
            }
        }
    }

    private static let episodeSelect = "SELECT id, series_id, season_id, season_number, provider_episode_id, episode_number, title, overview, image_url, duration_seconds, stream_ref FROM episodes"

    private static func mapEpisode(_ r: Row) -> Episode {
        Episode(id: r.string(0), seriesID: r.string(1), seasonID: r.optString(2), seasonNumber: r.int(3), providerEpisodeID: r.string(4),
                episodeNumber: r.int(5), title: r.string(6), overview: r.optString(7), imageURL: r.optString(8),
                durationSeconds: r.optDouble(9), streamRef: r.string(10))
    }

    func episodes(seriesID: String) throws -> [Episode] {
        try db.read { try $0.query(Self.episodeSelect + " WHERE series_id=? ORDER BY season_number, episode_number", [seriesID], Self.mapEpisode) }
    }

    func metadataCoverage(kind: ContentKind, sourceID: UUID?) throws -> VODMetadataCoverage {
        let table: String
        switch kind { case .movie: table = "movies"; case .series: table = "series"; default: return VODMetadataCoverage() }
        let durationExpr = kind == .movie ? "SUM(COALESCE(x.duration_seconds,0) > 0)" : "0"
        var sql = """
            SELECT COUNT(*), SUM(CAST(COALESCE(NULLIF(x.rating,''),'0') AS REAL) > 0), SUM(x.release_year IS NOT NULL), \(durationExpr)
            FROM \(table) x JOIN sources s ON s.id=x.source_id AND s.enabled=1
            """
        var args: [(any SQLConvertible)?] = []
        if let sourceID { sql += " WHERE x.source_id=?"; args.append(sourceID) }
        return try db.read { c in
            try c.queryOne(sql, args) { VODMetadataCoverage(total: $0.int(0), rated: $0.int(1), withYear: $0.int(2), withDuration: $0.int(3)) } ?? VODMetadataCoverage()
        }
    }

    func searchCategories(term: String, limit: Int) throws -> [CatalogCategory] {
        let words = MetadataNormalizer.normalize(term).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var sql = """
            SELECT cat.id, cat.source_id, cat.kind, cat.provider_id, cat.name, cat.sort_order
            FROM categories cat JOIN sources s ON s.id=cat.source_id AND s.enabled=1
            WHERE cat.id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category')
            """
        if isRestricting { sql += " AND cat.id NOT IN (SELECT category_id FROM locked_categories)" }
        var args: [(any SQLConvertible)?] = []
        for w in words { sql += " AND cat.normalized_name LIKE ? ESCAPE '\\'"; args.append("%" + w.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%") }
        sql += " ORDER BY (cat.normalized_name = ?) DESC, length(cat.normalized_name), cat.name COLLATE NOCASE LIMIT \(max(1, limit))"
        args.append(words.joined(separator: " "))
        return try db.read { c in try c.query(sql, args) { r in
            CatalogCategory(id: r.string(0), sourceID: r.uuid(1) ?? UUID(), kind: ContentKind(rawValue: r.string(2)) ?? .channel, providerID: r.string(3), name: r.string(4), sortOrder: r.int(5))
        } }
    }

    func uncategorizedCount(sourceID: UUID?, kind: ContentKind) throws -> Int {
        let table: String
        switch kind { case .channel: table = "channels"; case .movie: table = "movies"; case .series: table = "series"; case .episode: return 0 }
        var sql = "SELECT COUNT(*) FROM \(table) x JOIN sources s ON s.id=x.source_id AND s.enabled=1 WHERE x.category_id IS NULL"
        var args: [(any SQLConvertible)?] = []
        if kind == .channel { sql += " AND x.is_primary=1" }
        if let sourceID { sql += " AND x.source_id=?"; args.append(sourceID) }
        return try db.read { try $0.scalarInt(sql, args) }
    }

    func recordCategoryStats(sourceID: UUID, kind: ContentKind, fetch: CategoryFetch, reconcile r: CategoryReconcile) throws {
        try db.write { c in
            try c.execute("""
                INSERT INTO category_sync_stats(source_id, kind, provider_count, parsed_count, rejected_count, rejected_reasons, inserted, updated, removed, kept_stale, synthesized, note, synced_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id, kind) DO UPDATE SET provider_count=excluded.provider_count, parsed_count=excluded.parsed_count,
                    rejected_count=excluded.rejected_count, rejected_reasons=excluded.rejected_reasons, inserted=excluded.inserted,
                    updated=excluded.updated, removed=excluded.removed, kept_stale=excluded.kept_stale, synthesized=excluded.synthesized,
                    note=excluded.note, synced_at=excluded.synced_at
                """, [sourceID, kind.rawValue, fetch.providerCount, fetch.parsedCount, fetch.rejected.count, fetch.rejected.prefix(50).joined(separator: "\n"),
                      r.inserted, r.updated, r.removed, r.keptStale, r.synthesized, r.note, Date()])
        }
    }

    func storedCategoryCount(sourceID: UUID, kind: ContentKind) throws -> Int {
        try db.read { try $0.scalarInt("SELECT COUNT(*) FROM categories WHERE source_id=? AND kind=?", [sourceID, kind.rawValue]) }
    }

    func categoryStats(sourceID: UUID) throws -> [CategoryStatsRow] {
        try db.read { c in
            try c.query("SELECT kind, provider_count, parsed_count, rejected_count, rejected_reasons, inserted, updated, removed, kept_stale, synthesized, note, synced_at FROM category_sync_stats WHERE source_id=?", [sourceID]) { r in
                CategoryStatsRow(sourceID: sourceID, kind: ContentKind(rawValue: r.string(0)) ?? .channel, providerCount: r.int(1), parsedCount: r.int(2),
                                 rejectedCount: r.int(3), rejectedReasons: r.string(4).split(separator: "\n").map(String.init),
                                 reconcile: CategoryReconcile(inserted: r.int(5), updated: r.int(6), removed: r.int(7), keptStale: r.int(8), synthesized: r.int(9), note: r.optString(10)),
                                 syncedAt: r.optDate(11) ?? Date())
            }
        }
    }

    func searchEpisodes(term: String, sourceID: UUID?, limit: Int) throws -> [Episode] {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let like = "%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        var sql = Self.episodeSelect + " WHERE title LIKE ? ESCAPE '\\'"
        var args: [(any SQLConvertible)?] = [like]
        if let sourceID { sql += " AND series_id IN (SELECT id FROM series WHERE source_id=?)"; args.append(sourceID) }
        else { sql += " AND series_id IN (SELECT x.id FROM series x JOIN sources s ON s.id=x.source_id AND s.enabled=1)" }
        if isRestricting { sql += " AND series_id IN (SELECT x.id FROM series x WHERE x.category_id IS NULL OR x.category_id NOT IN (SELECT category_id FROM locked_categories))" }
        sql += " ORDER BY title COLLATE NOCASE LIMIT \(max(1, limit))"
        return try db.read { try $0.query(sql, args, Self.mapEpisode) }
    }

    func episode(id: String) throws -> Episode? {
        try db.read { try $0.query(Self.episodeSelect + " WHERE id=?", [id], Self.mapEpisode).first }
    }

    // MARK: counts / facets

    func counts(sourceID: UUID?) throws -> CatalogCounts {
        try db.read { c in
            let f = sourceID == nil ? "" : " WHERE source_id=?"
            let a: [(any SQLConvertible)?] = sourceID.map { [$0] } ?? []
            return CatalogCounts(channels: try c.scalarInt("SELECT COUNT(*) FROM channels" + f, a),
                                 movies: try c.scalarInt("SELECT COUNT(*) FROM movies" + f, a),
                                 series: try c.scalarInt("SELECT COUNT(*) FROM series" + f, a))
        }
    }

    /// Counts of what anyone may be shown: not in a locked or hidden folder and not hidden themselves, whatever the session says. (`counts` stays the raw table size, for diagnostics and backups.)
    /// Worked out as the table size less what sits in locked or hidden folders less the hidden titles elsewhere, so it never walks the whole table.
    func visibleCounts(sourceID: UUID?) throws -> CatalogCounts {
        try db.read { c in
            let a: [(any SQLConvertible)?] = sourceID.map { [$0] } ?? []
            let src = sourceID == nil ? "" : " AND x.source_id=?"
            func count(_ table: String, _ kind: String) throws -> Int {
                let total = try c.scalarInt("SELECT COUNT(*) FROM \(table) x WHERE 1=1\(src)", a)
                let restrictedFolders = "SELECT rc.id FROM categories rc WHERE rc.kind='\(kind)' AND (rc.id IN (SELECT category_id FROM locked_categories) OR rc.id IN (SELECT item_id FROM hidden_items WHERE kind='category'))"
                let inFolders = try c.scalarInt("SELECT COUNT(*) FROM categories rc JOIN \(table) x ON x.source_id = rc.source_id AND x.category_id = rc.id WHERE rc.id IN (\(restrictedFolders))\(src)", a)
                let hiddenElsewhere = try c.scalarInt("""
                    SELECT COUNT(*) FROM hidden_items h JOIN \(table) x ON x.id = h.item_id
                    WHERE h.kind <> 'category' AND (x.category_id IS NULL OR x.category_id NOT IN (\(restrictedFolders)))\(src)
                    """, a)
                return max(0, total - inFolders - hiddenElsewhere)
            }
            return CatalogCounts(channels: try count("channels", "channel"), movies: try count("movies", "movie"), series: try count("series", "series"))
        }
    }

    /// Genres that at least one visible title has. Never a genre that exists only in a locked or hidden folder.
    func genres(kind: ContentKind) throws -> [String] {
        let table = kind == .movie ? "movies" : "series", alias = kind == .movie ? "m" : "x"
        let sql = """
            SELECT DISTINCT d.genre FROM search_docs d WHERE d.kind=? AND d.genre IS NOT NULL AND d.genre!=''
            AND d.item_id IN (SELECT \(alias).id FROM \(table) \(alias) JOIN sources s ON s.id=\(alias).source_id AND s.enabled=1 WHERE 1=1\(baseline.restricted(alias)))
            ORDER BY d.genre COLLATE NOCASE LIMIT 200
            """
        return try db.read { c in try c.query(sql, [kind.rawValue]) { $0.string(0) } }
    }

    func years(kind: ContentKind) throws -> [Int] {
        let table = kind == .movie ? "movies" : "series", alias = kind == .movie ? "m" : "x"
        let sql = "SELECT DISTINCT \(alias).release_year FROM \(table) \(alias) JOIN sources s ON s.id=\(alias).source_id AND s.enabled=1 WHERE \(alias).release_year BETWEEN 1900 AND 2100\(baseline.restricted(alias)) ORDER BY \(alias).release_year DESC"
        return try db.read { c in try c.query(sql) { $0.int(0) } }
    }

    func allChannelsForManagement(sourceID: UUID?) throws -> [Channel] {
        var sql = Self.channelSelect + " WHERE 1=1" + restricted("c")
        var args: [(any SQLConvertible)?] = []
        if let s = sourceID { sql += " AND c.source_id=?"; args.append(s) }
        sql += " ORDER BY c.source_id, c.sort_order, c.rowid"
        return try db.read { try $0.query(sql, args, Self.mapChannel) }
    }
}
