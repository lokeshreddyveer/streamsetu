package app.streamsetu.core.data.db

import androidx.sqlite.db.SupportSQLiteDatabase

/** One row found by the text index. */
data class SearchHit(val kind: String, val itemId: String, val sourceId: String, val folderId: String?, val title: String)

/**
 * The local text index (SQLite FTS4, unicode-aware: case and accents do not matter, and a word may be given as a prefix).
 * It lives beside the Room tables but is managed here directly, because Room cannot declare a virtual table with extra filter columns.
 * Rows are written inside the same transaction that replaces a catalog, so a refresh that fails leaves the old index in place.
 */
object SearchIndex {
    const val TABLE = "search_fts"
    const val CREATE = "CREATE VIRTUAL TABLE IF NOT EXISTS $TABLE USING FTS4(kind, itemId, sourceId, folderId, title, notindexed=kind, notindexed=itemId, notindexed=sourceId, notindexed=folderId, tokenize=unicode61)"

    fun create(db: SupportSQLiteDatabase) { db.execSQL(CREATE) }

    /** Fills the index from catalog rows already stored (after an upgrade). */
    fun backfill(db: SupportSQLiteDatabase) {
        db.execSQL("INSERT INTO $TABLE(kind, itemId, sourceId, folderId, title) SELECT 'CHANNEL', id, sourceId, categoryId, name FROM channels")
        db.execSQL("INSERT INTO $TABLE(kind, itemId, sourceId, folderId, title) SELECT 'MOVIE', id, sourceId, categoryId, title FROM movies")
        db.execSQL("INSERT INTO $TABLE(kind, itemId, sourceId, folderId, title) SELECT 'SERIES', id, sourceId, categoryId, title FROM series")
    }

    fun clear(db: SupportSQLiteDatabase, sourceId: String) { db.execSQL("DELETE FROM $TABLE WHERE sourceId = ?", arrayOf(sourceId)) }

    fun insert(db: SupportSQLiteDatabase, rows: List<SearchHit>) {
        val st = db.compileStatement("INSERT INTO $TABLE(kind, itemId, sourceId, folderId, title) VALUES (?, ?, ?, ?, ?)")
        try {
            for (r in rows) {
                st.clearBindings()
                st.bindString(1, r.kind); st.bindString(2, r.itemId); st.bindString(3, r.sourceId)
                if (r.folderId != null) st.bindString(4, r.folderId) else st.bindNull(4)
                st.bindString(5, r.title)
                st.executeInsert()
            }
        } finally { st.close() }
    }

    /** [match] is an FTS query such as `bat* man*`; the caller builds it from user text (see SearchRepository). */
    fun query(db: SupportSQLiteDatabase, match: String, sources: List<String>, kinds: List<String>, limit: Int): List<SearchHit> {
        if (match.isBlank() || sources.isEmpty()) return emptyList()
        val sql = "SELECT kind, itemId, sourceId, folderId, title FROM $TABLE WHERE $TABLE MATCH ? AND kind IN (${kinds.joinToString(",") { "?" }}) AND sourceId IN (${sources.joinToString(",") { "?" }}) LIMIT $limit"
        val args = (listOf(match) + kinds + sources).toTypedArray()
        db.query(sql, args).use { c ->
            val out = ArrayList<SearchHit>(minOf(limit, 256))
            while (c.moveToNext()) out += SearchHit(c.getString(0), c.getString(1), c.getString(2), if (c.isNull(3)) null else c.getString(3), c.getString(4))
            return out
        }
    }
}
