import Foundation
import CryptoKit

enum IndexError: LocalizedError, Sendable {
    case emptyRefresh(String)
    case suspiciousShrink(previous: Int, new: Int)

    var errorDescription: String? {
        switch self {
        case .emptyRefresh(let w): "The provider returned no \(w). Your existing library was kept."
        case .suspiciousShrink(let p, let n): "The provider returned only \(n) items (previously \(p)). Your existing library was kept."
        }
    }
}

struct IndexResult: Sendable {
    var total: Int
    var previous: Int
    var removed: Int
    var categories = CategoryReconcile()
}

/// Writes a fully downloaded and validated catalog in ONE transaction. A failed or implausible refresh never
/// replaces a good catalog. Favorites, progress, hidden items and overrides live in other tables keyed by stable ids,
/// so they survive every refresh.
final class CatalogIndexer: Sendable {
    let db: DatabaseManager
    init(db: DatabaseManager) { self.db = db }

    /// Raise when the importer starts reading other fields: every saved fingerprint then stops matching and the catalogs are written once more.
    static let fingerprintVersion = 1

    /// A fingerprint of everything about to be written for one playlist and kind: the categories, and every item with all of its fields, in order.
    private func fingerprint<T>(categories: [CatalogCategory], items: [T]) -> String {
        var h = SHA256()
        h.update(data: Data(String(describing: categories).utf8))
        for chunk in stride(from: 0, to: items.count, by: 2000) {
            h.update(data: Data(String(describing: items[chunk..<min(chunk + 2000, items.count)]).utf8))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when the saved fingerprint is this one, for this many rows, and the table still holds that many rows (so a fingerprint never vouches for a table that was changed behind its back).
    private func isUnchanged(kind: String, table: String, source: PlaylistSource, fingerprint fp: String, rows: Int) throws -> Bool {
        try db.read { c in
            guard let s = try c.queryOne("SELECT fingerprint, version, rows FROM catalog_fingerprints WHERE source_id=? AND kind=?", [source.id, kind], { ($0.string(0), $0.int(1), $0.int(2)) }),
                  s.0 == fp, s.1 == Self.fingerprintVersion, s.2 == rows else { return false }
            return try c.scalarInt("SELECT COUNT(*) FROM \(table) WHERE source_id=?", [source.id]) == rows
        }
    }

    private func saveFingerprint(kind: String, source: PlaylistSource, fingerprint fp: String, rows: Int, in c: Connection) throws {
        try c.execute("INSERT OR REPLACE INTO catalog_fingerprints(source_id, kind, fingerprint, version, rows) VALUES(?,?,?,?,?)", [source.id, kind, fp, Self.fingerprintVersion, rows])
    }

    private func integrityCheck(previous: Int, new: Int, what: String) throws {
        if new == 0 && previous > 0 { throw IndexError.emptyRefresh(what) }
        if previous >= 50 && new < previous / 10 { throw IndexError.suspiciousShrink(previous: previous, new: new) }
    }

    /// Brings the stored categories for one source and content type in line with a freshly fetched list.
    /// - Every fetched category is stored, including ones that currently hold no items.
    /// - A category that items refer to but the provider did not list is created (named after the item's category).
    /// - A stored category the fetch no longer mentions is removed only when the fetch looks complete. An empty list, or one
    ///   that lost more than half of 20+ categories, is treated as a bad answer and the stored folders are kept.
    private func upsertCategories(_ cats: [CatalogCategory], referenced: [String: String], kind: ContentKind, source: PlaylistSource,
                                  stamp: Date, in c: Connection) throws -> CategoryReconcile {
        var result = CategoryReconcile()
        let existing = Set(try c.query("SELECT id FROM categories WHERE source_id=? AND kind=?", [source.id, kind.rawValue]) { $0.string(0) })
        let st = try c.prepare("""
            INSERT INTO categories(id, source_id, kind, provider_id, name, normalized_name, sort_order, last_seen_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, normalized_name=excluded.normalized_name,
                sort_order=excluded.sort_order, last_seen_at=excluded.last_seen_at
            """)
        var incoming = Set<String>()
        for cat in cats where incoming.insert(cat.id).inserted {
            try st.run([cat.id, source.id, kind.rawValue, cat.providerID, cat.name, MetadataNormalizer.normalize(cat.name), cat.sortOrder, stamp])
            if existing.contains(cat.id) { result.updated += 1 } else { result.inserted += 1 }
        }
        var order = cats.count
        for (id, name) in referenced.sorted(by: { $0.key < $1.key }) where !incoming.contains(id) {
            try st.run([id, source.id, kind.rawValue, name, name, MetadataNormalizer.normalize(name), order, stamp])
            order += 1; incoming.insert(id)
            result.synthesized += 1
            if !existing.contains(id) { result.inserted += 1 }
        }
        let stale = existing.subtracting(incoming)
        let looksIncomplete = (cats.isEmpty && !existing.isEmpty) || (existing.count >= 20 && cats.count < existing.count / 2)
        if looksIncomplete && !stale.isEmpty {
            result.keptStale = stale.count
            result.note = "The provider returned \(cats.count) categories where \(existing.count) were stored, so the stored folders were kept."
        } else {
            for id in stale { try c.execute("DELETE FROM categories WHERE id=?", [id]) }
            result.removed = stale.count
        }
        return result
    }

    /// Category ids (and display names) that items refer to.
    private static func referencedCategories<T>(_ items: [T], id: KeyPath<T, String?>, name: KeyPath<T, String?>) -> [String: String] {
        var out: [String: String] = [:]
        for i in items { if let cid = i[keyPath: id], out[cid] == nil { out[cid] = i[keyPath: name] ?? "Category" } }
        return out
    }

    // MARK: live

    @discardableResult
    func commitChannels(source: PlaylistSource, categories: [CatalogCategory], channels: [Channel], stamp: Date = Date()) throws -> IndexResult {
        let previous = try db.read { try $0.scalarInt("SELECT COUNT(*) FROM channels WHERE source_id=?", [source.id]) }
        try integrityCheck(previous: previous, new: channels.count, what: "channels")
        let grouped = ChannelDeduplicator.group(channels.uniqued(by: \.id))
        let fp = fingerprint(categories: categories, items: grouped.channels)
        if try isUnchanged(kind: "channel", table: "channels", source: source, fingerprint: fp, rows: grouped.channels.count) {
            return IndexResult(total: grouped.channels.count, previous: previous, removed: 0)          // the provider sent exactly what is saved: nothing is written
        }

        return try db.write { c in
            let rec = try upsertCategories(categories, referenced: Self.referencedCategories(channels, id: \.categoryID, name: \.categoryName), kind: .channel, source: source, stamp: stamp, in: c)
            let st = try c.prepare("""
                INSERT INTO channels(id, source_id, provider_id, name, normalized_name, category_id, category_name, logo_url, epg_id,
                    language, country, resolution_hint, sort_order, stream_ref, group_key, is_primary, last_seen_at, first_seen_at, archive_days)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, normalized_name=excluded.normalized_name,
                    category_id=excluded.category_id, category_name=excluded.category_name, logo_url=excluded.logo_url,
                    epg_id=excluded.epg_id, language=excluded.language, country=excluded.country,
                    resolution_hint=excluded.resolution_hint, sort_order=excluded.sort_order, stream_ref=excluded.stream_ref,
                    group_key=excluded.group_key, is_primary=excluded.is_primary, last_seen_at=excluded.last_seen_at,
                    archive_days=excluded.archive_days
                """)
            for ch in grouped.channels {
                try st.run([ch.id, ch.sourceID, ch.providerID, ch.name, ch.normalizedName, ch.categoryID, ch.categoryName, ch.logoURL,
                            ch.epgID, ch.language, ch.country, ch.resolutionHint, ch.sortOrder, ch.streamRef, ch.groupKey,
                            grouped.primaryIDs.contains(ch.id), stamp, stamp, ch.archiveDays])
            }
            try c.execute("DELETE FROM channels WHERE source_id=? AND last_seen_at < ?", [source.id, stamp])
            let removed = c.changes

            try c.execute("DELETE FROM stream_variants WHERE channel_id IN (SELECT id FROM channels WHERE source_id=?)", [source.id])
            let vst = try c.prepare("INSERT OR IGNORE INTO stream_variants(channel_id, variant_id, label) VALUES(?,?,?)")
            for v in grouped.variants { try vst.run([v.channelID, v.variantID, v.label]) }

            let sourceName = source.name
            try SearchIndexer.upsert(grouped.channels.map {
                SearchDoc(itemID: $0.id, kind: .channel, sourceID: source.id, title: $0.name, normalized: $0.normalizedName,
                          category: $0.categoryName, genre: nil, language: $0.language ?? $0.country, sourceName: sourceName)
            }, in: c)
            try SearchIndexer.removeStale(kind: .channel, table: "channels", sourceID: source.id, in: c)
            try reapplyOverrides(in: c)
            try saveFingerprint(kind: "channel", source: source, fingerprint: fp, rows: grouped.channels.count, in: c)
            return IndexResult(total: grouped.channels.count, previous: previous, removed: removed, categories: rec)
        }
    }

    // MARK: movies

    @discardableResult
    func commitMovies(source: PlaylistSource, categories: [CatalogCategory], movies: [Movie], stamp: Date = Date()) throws -> IndexResult {
        let previous = try db.read { try $0.scalarInt("SELECT COUNT(*) FROM movies WHERE source_id=?", [source.id]) }
        try integrityCheck(previous: previous, new: movies.count, what: "movies")
        let unique = movies.uniqued(by: \.id)
        let fp = fingerprint(categories: categories, items: unique)
        if try isUnchanged(kind: "movie", table: "movies", source: source, fingerprint: fp, rows: unique.count) {
            return IndexResult(total: unique.count, previous: previous, removed: 0)
        }
        return try db.write { c in
            let rec = try upsertCategories(categories, referenced: Self.referencedCategories(movies, id: \.categoryID, name: \.categoryName), kind: .movie, source: source, stamp: stamp, in: c)
            let st = try c.prepare("""
                INSERT INTO movies(id, source_id, provider_id, title, normalized_title, overview, poster_url, backdrop_url, release_year,
                    duration_seconds, genre, rating, category_id, category_name, stream_ref, added_at, created_at, updated_at, last_seen_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, normalized_title=excluded.normalized_title,
                    overview=COALESCE(excluded.overview, movies.overview), poster_url=COALESCE(excluded.poster_url, movies.poster_url),
                    backdrop_url=COALESCE(excluded.backdrop_url, movies.backdrop_url), release_year=COALESCE(excluded.release_year, movies.release_year),
                    duration_seconds=COALESCE(excluded.duration_seconds, movies.duration_seconds), genre=COALESCE(excluded.genre, movies.genre),
                    rating=COALESCE(excluded.rating, movies.rating), category_id=excluded.category_id, category_name=excluded.category_name,
                    stream_ref=excluded.stream_ref, added_at=COALESCE(excluded.added_at, movies.added_at),
                    updated_at=excluded.updated_at, last_seen_at=excluded.last_seen_at
                """)
            for m in unique {
                try st.run([m.id, m.sourceID, m.providerID, m.title, m.normalizedTitle, m.overview, m.posterURL, m.backdropURL, m.releaseYear,
                            m.durationSeconds, m.genre, m.rating, m.categoryID, m.categoryName, m.streamRef, m.addedAt, stamp, stamp, stamp])
            }
            try c.execute("DELETE FROM movies WHERE source_id=? AND last_seen_at < ?", [source.id, stamp])
            let removed = c.changes
            try SearchIndexer.upsert(unique.map {
                SearchDoc(itemID: $0.id, kind: .movie, sourceID: source.id, title: $0.title, normalized: $0.normalizedTitle,
                          category: $0.categoryName, genre: $0.genre, language: nil, sourceName: source.name)
            }, in: c)
            try SearchIndexer.removeStale(kind: .movie, table: "movies", sourceID: source.id, in: c)
            try saveFingerprint(kind: "movie", source: source, fingerprint: fp, rows: unique.count, in: c)
            return IndexResult(total: unique.count, previous: previous, removed: removed, categories: rec)
        }
    }

    func saveMovieDetail(id: String, detail: MovieDetail) throws {
        try db.write { c in
            try c.execute("""
                UPDATE movies SET overview=COALESCE(?, overview), backdrop_url=COALESCE(?, backdrop_url), poster_url=COALESCE(?, poster_url),
                    genre=COALESCE(?, genre), release_year=COALESCE(?, release_year), duration_seconds=COALESCE(?, duration_seconds),
                    rating=COALESCE(?, rating), detail_fetched_at=? WHERE id=?
                """, [detail.overview, detail.backdropURL, detail.posterURL, detail.genre, detail.releaseYear, detail.durationSeconds,
                      detail.rating, Date(), id])
            if let g = detail.genre { try c.execute("UPDATE search_docs SET genre=? WHERE item_id=?", [g, id]) }
        }
    }

    // MARK: series

    @discardableResult
    func commitSeries(source: PlaylistSource, categories: [CatalogCategory], series: [Series], stamp: Date = Date()) throws -> IndexResult {
        let previous = try db.read { try $0.scalarInt("SELECT COUNT(*) FROM series WHERE source_id=?", [source.id]) }
        try integrityCheck(previous: previous, new: series.count, what: "series")
        let unique = series.uniqued(by: \.id)
        let fp = fingerprint(categories: categories, items: unique)
        if try isUnchanged(kind: "series", table: "series", source: source, fingerprint: fp, rows: unique.count) {
            return IndexResult(total: unique.count, previous: previous, removed: 0)
        }
        return try db.write { c in
            let rec = try upsertCategories(categories, referenced: Self.referencedCategories(series, id: \.categoryID, name: \.categoryName), kind: .series, source: source, stamp: stamp, in: c)
            let st = try c.prepare("""
                INSERT INTO series(id, source_id, provider_id, title, normalized_title, overview, poster_url, backdrop_url, genre, release_year,
                    rating, category_id, category_name, added_at, last_seen_at, first_seen_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, normalized_title=excluded.normalized_title,
                    overview=COALESCE(excluded.overview, series.overview), poster_url=COALESCE(excluded.poster_url, series.poster_url),
                    backdrop_url=COALESCE(excluded.backdrop_url, series.backdrop_url), genre=COALESCE(excluded.genre, series.genre),
                    release_year=COALESCE(excluded.release_year, series.release_year), rating=COALESCE(excluded.rating, series.rating),
                    category_id=excluded.category_id, category_name=excluded.category_name,
                    added_at=COALESCE(excluded.added_at, series.added_at), last_seen_at=excluded.last_seen_at
                """)
            for s in unique {
                try st.run([s.id, s.sourceID, s.providerID, s.title, s.normalizedTitle, s.overview, s.posterURL, s.backdropURL, s.genre,
                            s.releaseYear, s.rating, s.categoryID, s.categoryName, s.addedAt, stamp, stamp])
            }
            try c.execute("DELETE FROM series WHERE source_id=? AND last_seen_at < ?", [source.id, stamp])
            let removed = c.changes
            try SearchIndexer.upsert(unique.map {
                SearchDoc(itemID: $0.id, kind: .series, sourceID: source.id, title: $0.title, normalized: $0.normalizedTitle,
                          category: $0.categoryName, genre: $0.genre, language: nil, sourceName: source.name)
            }, in: c)
            try SearchIndexer.removeStale(kind: .series, table: "series", sourceID: source.id, in: c)
            try saveFingerprint(kind: "series", source: source, fingerprint: fp, rows: unique.count, in: c)
            return IndexResult(total: unique.count, previous: previous, removed: removed, categories: rec)
        }
    }

    /// Replaces seasons/episodes for one series. Episode ids are stable, so watch progress is untouched.
    func saveSeriesDetail(_ d: SeriesDetail) throws {
        try db.write { c in
            let s = d.series
            try c.execute("""
                UPDATE series SET overview=COALESCE(?, overview), poster_url=COALESCE(?, poster_url), backdrop_url=COALESCE(?, backdrop_url),
                    genre=COALESCE(?, genre), rating=COALESCE(?, rating), last_metadata_refresh=? WHERE id=?
                """, [s.overview, s.posterURL, s.backdropURL, s.genre, s.rating, Date(), s.id])
            if let g = s.genre { try c.execute("UPDATE search_docs SET genre=? WHERE item_id=?", [g, s.id]) }
            try c.execute("DELETE FROM seasons WHERE series_id=?", [s.id])
            try c.execute("DELETE FROM episodes WHERE series_id=?", [s.id])
            let ss = try c.prepare("INSERT OR REPLACE INTO seasons(id, series_id, number, name) VALUES(?,?,?,?)")
            for x in d.seasons { try ss.run([x.id, x.seriesID, x.number, x.name]) }
            let es = try c.prepare("""
                INSERT OR REPLACE INTO episodes(id, series_id, season_id, season_number, provider_episode_id, episode_number, title,
                    overview, image_url, duration_seconds, stream_ref) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """)
            for e in d.episodes {
                try es.run([e.id, e.seriesID, e.seasonID, e.seasonNumber, e.providerEpisodeID, e.episodeNumber, e.title, e.overview,
                            e.imageURL, e.durationSeconds, e.streamRef])
            }
        }
    }

    /// User renames survive provider refreshes.
    private func reapplyOverrides(in c: Connection) throws {
        try c.execute("""
            UPDATE search_docs SET title=(SELECT display_name FROM metadata_overrides o WHERE o.item_id=search_docs.item_id),
                normalized=(SELECT display_name FROM metadata_overrides o WHERE o.item_id=search_docs.item_id)
            WHERE item_id IN (SELECT item_id FROM metadata_overrides WHERE display_name IS NOT NULL)
            """)
    }
}
