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
        // Every row gets its fixed number (see [docid]), the same one a catalog refresh writes and deletes by, so an item is in the index once however it got there.
        for ((kind, table, titleColumn) in listOf(Triple("CHANNEL", "channels", "name"), Triple("MOVIE", "movies", "title"), Triple("SERIES", "series", "title"))) {
            val batch = ArrayList<SearchHit>(BACKFILL_BATCH)
            db.query("SELECT id, sourceId, categoryId, $titleColumn FROM $table").use { c ->
                while (c.moveToNext()) {
                    batch += SearchHit(kind, c.getString(0), c.getString(1), if (c.isNull(2)) null else c.getString(2), c.getString(3).orEmpty())
                    if (batch.size >= BACKFILL_BATCH) { upsert(db, batch); batch.clear() }
                }
            }
            if (batch.isNotEmpty()) upsert(db, batch)
        }
    }
    private const val BACKFILL_BATCH = 2000

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

    /** The row number an item has in the index: the same item always has the same one, so writing it again replaces it, and a removed item is deleted without scanning the index. */
    fun docid(kind: String, itemId: String): Long {
        var h = -3750763034362895579L          // FNV-1a, 64 bit
        for (c in kind) h = (h xor c.code.toLong()) * 1099511628211L
        h = (h xor 0L) * 1099511628211L
        for (c in itemId) h = (h xor c.code.toLong()) * 1099511628211L
        return h
    }

    /** Adds or replaces these items (one item is one row, whatever was there before). */
    fun upsert(db: SupportSQLiteDatabase, rows: List<SearchHit>) {
        val st = db.compileStatement("INSERT OR REPLACE INTO $TABLE(docid, kind, itemId, sourceId, folderId, title) VALUES (?, ?, ?, ?, ?, ?)")
        try {
            for (r in rows) {
                st.clearBindings()
                st.bindLong(1, docid(r.kind, r.itemId)); st.bindString(2, r.kind); st.bindString(3, r.itemId); st.bindString(4, r.sourceId)
                if (r.folderId != null) st.bindString(5, r.folderId) else st.bindNull(5)
                st.bindString(6, r.title)
                st.executeInsert()
            }
        } finally { st.close() }
    }

    fun delete(db: SupportSQLiteDatabase, kind: String, itemIds: List<String>) {
        val st = db.compileStatement("DELETE FROM $TABLE WHERE docid = ?")
        try { for (id in itemIds) { st.clearBindings(); st.bindLong(1, docid(kind, id)); st.executeUpdateDelete() } } finally { st.close() }
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
