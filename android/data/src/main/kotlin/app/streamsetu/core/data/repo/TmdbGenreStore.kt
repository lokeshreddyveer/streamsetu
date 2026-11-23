package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase

/**
 * The TMDB genre ids of a library title, kept only where TMDB details were fetched for it (opening a title page). A Room table (tmdb_genres, database version 15),
 * removed with everything else TMDB gave: after 180 days, when the key is removed or matching is switched off ([clearAll]), and for titles that become restricted ([remove]). Genre shelves read it
 * first and fall back to the folder name's words (see GenreShelves: TMDB ids, then folder text).
 */
class TmdbGenreStore(private val db: AppDatabase, private val now: () -> Long = System::currentTimeMillis) {
    private fun raw(): androidx.sqlite.db.SupportSQLiteDatabase = db.openHelper.writableDatabase
    fun put(itemId: String, ids: List<Int>) { if (ids.isNotEmpty()) runCatching { raw().execSQL("INSERT OR REPLACE INTO tmdb_genres(itemId, ids, at) VALUES(?, ?, ?)", arrayOf(itemId, ids.joinToString(",", ",", ","), now())) } }
    /** itemId -> TMDB genre ids, for every title that has them. */
    fun all(): Map<String, List<Int>> = runCatching {
        val m = HashMap<String, List<Int>>()
        raw().query("SELECT itemId, ids FROM tmdb_genres").use { c -> while (c.moveToNext()) m[c.getString(0)] = c.getString(1).split(',').mapNotNull { it.toIntOrNull() } }
        m
    }.getOrDefault(emptyMap())
    fun remove(ids: Collection<String>) { runCatching { ids.chunked(400).forEach { ch -> raw().execSQL("DELETE FROM tmdb_genres WHERE itemId IN (${ch.joinToString(",") { "?" }})", ch.toTypedArray()) } } }
    fun purgeOlderThan(cutoff: Long) { runCatching { raw().execSQL("DELETE FROM tmdb_genres WHERE at < ?", arrayOf(cutoff)) } }
    fun clearAll() { runCatching { raw().execSQL("DELETE FROM tmdb_genres") } }
}
