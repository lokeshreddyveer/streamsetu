package app.streamsetu.core.data.db

import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Who is in each movie and series (cast and directors), so a person can be searched for. It lives beside the Room tables and is managed here
 * directly, like the text index. [normalize] turns a name into what is compared (lower case, no accents or punctuation).
 */
object PeopleIndex {
    fun create(db: SupportSQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS people (itemId TEXT NOT NULL, kind TEXT NOT NULL, sourceId TEXT NOT NULL, name TEXT NOT NULL, norm TEXT NOT NULL, PRIMARY KEY(itemId, norm))")
        db.execSQL("CREATE INDEX IF NOT EXISTS people_norm ON people (norm)")
        db.execSQL("CREATE INDEX IF NOT EXISTS people_source ON people (sourceId)")
        db.execSQL("CREATE TABLE IF NOT EXISTS people_done (itemId TEXT NOT NULL PRIMARY KEY, sourceId TEXT NOT NULL, doneAt INTEGER NOT NULL)")
    }

    /** Replaces what is known about the people in one title, and remembers that the title was looked at. */
    fun save(db: SupportSQLiteDatabase, itemId: String, kind: String, sourceId: String, names: List<String>, normalize: (String) -> String) {
        db.beginTransaction()
        try {
            db.execSQL("DELETE FROM people WHERE itemId = ?", arrayOf(itemId))
            val seen = HashSet<String>()
            for (name in names.take(40)) {
                val n = normalize(name)
                if (n.length < 3 || !seen.add(n)) continue
                db.execSQL("INSERT OR IGNORE INTO people(itemId, kind, sourceId, name, norm) VALUES (?, ?, ?, ?, ?)", arrayOf(itemId, kind, sourceId, name, n))
            }
            db.execSQL("INSERT OR REPLACE INTO people_done(itemId, sourceId, doneAt) VALUES (?, ?, ?)", arrayOf(itemId, sourceId, System.currentTimeMillis()))
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    fun markDone(db: SupportSQLiteDatabase, itemId: String, sourceId: String) {
        db.execSQL("INSERT OR REPLACE INTO people_done(itemId, sourceId, doneAt) VALUES (?, ?, ?)", arrayOf(itemId, sourceId, System.currentTimeMillis()))
    }

    fun clear(db: SupportSQLiteDatabase, sourceId: String) {
        db.execSQL("DELETE FROM people WHERE sourceId = ?", arrayOf(sourceId))
        db.execSQL("DELETE FROM people_done WHERE sourceId = ?", arrayOf(sourceId))
    }

    /** Movies not asked about yet, the best-rated and newest first, from playlists that are switched on (leaving out [skip]). Pairs of movie id and playlist id. */
    fun pendingMovies(db: SupportSQLiteDatabase, limit: Int, skip: Set<String> = emptySet()): List<Pair<String, String>> {
        val notIn = if (skip.isEmpty()) "" else " AND m.sourceId NOT IN (${skip.joinToString(",") { "?" }})"
        val sql = "SELECT m.id, m.sourceId FROM movies m JOIN sources s ON s.id = m.sourceId AND s.enabled = 1 AND s.draft = 0 " +
            "WHERE NOT EXISTS (SELECT 1 FROM people_done d WHERE d.itemId = m.id)$notIn ORDER BY CAST(COALESCE(m.rating, '0') AS REAL) DESC, m.addedAt DESC LIMIT $limit"
        db.query(sql, skip.toTypedArray<Any?>()).use { c ->
            val out = ArrayList<Pair<String, String>>()
            while (c.moveToNext()) out += c.getString(0) to c.getString(1)
            return out
        }
    }

    /** How many movies have been asked about, and how many there are. */
    fun progress(db: SupportSQLiteDatabase): Pair<Int, Int> {
        val base = "FROM movies m JOIN sources s ON s.id = m.sourceId AND s.enabled = 1 AND s.draft = 0"
        fun count(sql: String) = db.query(sql).use { if (it.moveToFirst()) it.getInt(0) else 0 }
        return count("SELECT COUNT(*) $base JOIN people_done d ON d.itemId = m.id") to count("SELECT COUNT(*) $base")
    }

    /** Titles with a person whose name starts with each word typed. [words] are already normalised; at least three letters in all. */
    fun hits(db: SupportSQLiteDatabase, words: List<String>, sources: List<String>, kinds: List<String>, limit: Int): List<SearchHit> {
        if (words.isEmpty() || words.sumOf { it.length } < 3 || sources.isEmpty() || kinds.isEmpty()) return emptyList()
        val conditions = words.joinToString("") { " AND (norm LIKE ? OR norm LIKE ?)" }
        val sql = "SELECT p.kind, p.itemId, p.sourceId, COALESCE(m.categoryId, s.categoryId), COALESCE(m.title, s.title) " +
            "FROM (SELECT DISTINCT itemId, kind, sourceId FROM people WHERE sourceId IN (${sources.joinToString(",") { "?" }}) AND kind IN (${kinds.joinToString(",") { "?" }})$conditions) p " +
            "LEFT JOIN movies m ON p.kind = 'MOVIE' AND m.id = p.itemId LEFT JOIN series s ON p.kind = 'SERIES' AND s.id = p.itemId " +
            "WHERE m.id IS NOT NULL OR s.id IS NOT NULL ORDER BY CAST(COALESCE(m.rating, s.rating, '0') AS REAL) DESC LIMIT $limit"
        val args = ArrayList<Any?>().apply { addAll(sources); addAll(kinds); words.forEach { add("$it%"); add("% $it%") } }
        db.query(sql, args.toTypedArray()).use { c ->
            val out = ArrayList<SearchHit>()
            while (c.moveToNext()) out += SearchHit(c.getString(0), c.getString(1), c.getString(2), if (c.isNull(3)) null else c.getString(3), c.getString(4))
            return out
        }
    }

    /** The people known for each of these titles, as written (nothing for a title not read yet). */
    fun names(db: SupportSQLiteDatabase, ids: List<String>): Map<String, List<String>> {
        val out = HashMap<String, MutableList<String>>()
        for (chunk in ids.chunked(80)) db.query("SELECT itemId, name FROM people WHERE itemId IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray<Any?>()).use { c ->
            while (c.moveToNext()) out.getOrPut(c.getString(0)) { ArrayList() } += c.getString(1)
        }
        return out
    }
}
