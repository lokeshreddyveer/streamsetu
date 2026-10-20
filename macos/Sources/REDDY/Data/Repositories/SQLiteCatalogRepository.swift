import Foundation

final class SQLiteCatalogRepository: CatalogRepository {
    let db: DatabaseManager
    /// While active, content in PIN-locked folders is absent from every query below, as if it were not in the library.
    let restriction = Restriction()
    init(db: DatabaseManager) { self.db = db }

    final class Restriction: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isActive: Bool { get { lock.lock(); defer { lock.unlock() }; return on } set { lock.lock(); on = newValue; lock.unlock() } }
    }

    /// `AND` clause that removes items whose folder is locked. Empty when nothing is restricted.
    private func restricted(_ alias: String) -> String {
        restriction.isActive ? " AND (\(alias).category_id IS NULL OR \(alias).category_id NOT IN (SELECT category_id FROM locked_categories))" : ""
    }

    func lockedCategoryIDs() throws -> Set<String> { Set(try db.read { try $0.query("SELECT category_id FROM locked_categories") { $0.string(0) } }) }

    func setCategoryLocked(_ id: String, _ locked: Bool) throws {
        try db.write { c in
            if locked { try c.execute("INSERT OR IGNORE INTO locked_categories(category_id) VALUES(?)", [id]) }
            else { try c.execute("DELETE FROM locked_categories WHERE category_id=?", [id]) }
        }
    }

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
        var sql = """
            SELECT cat.id, cat.source_id, cat.kind, cat.provider_id, cat.name, cat.sort_order,
                   (SELECT COUNT(*) FROM \(table) x WHERE x.source_id=cat.source_id AND x.category_id=cat.id\(kind == .channel ? " AND x.is_primary=1" : ""))
            FROM categories cat JOIN sources s ON s.id=cat.source_id AND s.enabled=1
            LEFT JOIN folder_order fo ON fo.category_id=cat.id WHERE cat.kind=?
            """
        var args: [(any SQLConvertible)?] = [kind.rawValue]
        if let sourceID { sql += " AND cat.source_id=?"; args.append(sourceID) }
        if !includeHidden { sql += " AND cat.id NOT IN (SELECT item_id FROM hidden_items WHERE kind='category')" }
        sql += " ORDER BY fo.position IS NULL, fo.position, cat.sort_order, cat.name COLLATE NOCASE"
        return try db.read { c in
            try c.query(sql, args) { r in
                CatalogCategory(id: r.string(0), sourceID: r.uuid(1) ?? UUID(), kind: kind, providerID: r.string(3), name: r.string(4),
                                sortOrder: r.int(5), itemCount: r.int(6))
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
        var sql = Self.channelSelect + " WHERE 1=1"
        var args: [(any SQLConvertible)?] = []
        if let ids = q.ids {
            guard !ids.isEmpty else { return [] }
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
            } else { return [] }
        } else if q.collapseVariants {
            sql += " AND c.is_primary=1"
        }
        sql += q.recentlyAdded ? " ORDER BY c.first_seen_at DESC, c.sort_order, c.rowid"
            : q.sortAlphabetically ? " ORDER BY COALESCE(o.display_name, c.name) COLLATE NOCASE, c.rowid" : " ORDER BY c.source_id, c.sort_order, c.rowid"
        if let l = q.limit { sql += " LIMIT \(l) OFFSET \(q.offset)" }
        return try db.read { try $0.query(sql, args, Self.mapChannel) }
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
        if let rating = q.minRating { sql += " AND CAST(\(alias).rating AS REAL) >= ?"; args.append(rating) }
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
            sql += " AND \(alias).id IN (SELECT d.item_id FROM catalog_fts f JOIN search_docs d ON d.id=f.rowid WHERE catalog_fts MATCH ? AND d.kind='\(kind)')"
            args.append(m)
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
        return found.contains { $0.id == m.id } ? found : [m] + found
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
        if restriction.isActive { sql += " AND cat.id NOT IN (SELECT category_id FROM locked_categories)" }
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
        if restriction.isActive { sql += " AND series_id IN (SELECT x.id FROM series x WHERE x.category_id IS NULL OR x.category_id NOT IN (SELECT category_id FROM locked_categories))" }
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

    func genres(kind: ContentKind) throws -> [String] {
        try db.read { c in
            try c.query("SELECT DISTINCT genre FROM search_docs WHERE kind=? AND genre IS NOT NULL AND genre!='' ORDER BY genre COLLATE NOCASE LIMIT 200", [kind.rawValue]) { $0.string(0) }
        }
    }

    func years(kind: ContentKind) throws -> [Int] {
        let table = kind == .movie ? "movies" : "series"
        return try db.read { c in
            try c.query("SELECT DISTINCT release_year FROM \(table) WHERE release_year BETWEEN 1900 AND 2100 ORDER BY release_year DESC") { $0.int(0) }
        }
    }

    func allChannelsForManagement(sourceID: UUID?) throws -> [Channel] {
        var sql = Self.channelSelect + " WHERE 1=1" + restricted("c")
        var args: [(any SQLConvertible)?] = []
        if let s = sourceID { sql += " AND c.source_id=?"; args.append(s) }
        sql += " ORDER BY c.source_id, c.sort_order, c.rowid"
        return try db.read { try $0.query(sql, args, Self.mapChannel) }
    }
}
