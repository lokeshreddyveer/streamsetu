package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase

/**
 * Which TMDB title a library item was matched to (kept only when the artwork matcher or the express lane matched it). A Room table (tmdb_ids, database version 15; it used to be made on first use outside Room). It lets the person screen find a film in the library by its exact id. It is removed with the rest of what TMDB gave: after 180 days, when the
 * title becomes restricted (see [TmdbService.purge]), when the key is removed or matching is switched off ([clearAll]).
 */
class TmdbIdStore(private val db: AppDatabase, private val now: () -> Long = System::currentTimeMillis) : LibraryTmdbIds {
    private fun raw(): androidx.sqlite.db.SupportSQLiteDatabase = db.openHelper.writableDatabase

    fun put(itemId: String, tmdbId: Long, tv: Boolean) { runCatching { raw().execSQL("INSERT OR REPLACE INTO tmdb_ids(itemId, tmdbId, tv, at) VALUES(?, ?, ?, ?)", arrayOf(itemId, tmdbId, if (tv) 1 else 0, now())) } }

    override fun itemIds(tmdbId: Long, series: Boolean): List<String> = runCatching {
        raw().query("SELECT itemId FROM tmdb_ids WHERE tmdbId = ? AND tv = ?", arrayOf(tmdbId.toString(), if (series) "1" else "0")).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }
    }.getOrDefault(emptyList())

    /** The TMDB title (id and whether it is a series) a library item was matched to, or null. */
    fun tmdbOf(itemId: String): Pair<Long, Boolean>? = runCatching {
        raw().query("SELECT tmdbId, tv FROM tmdb_ids WHERE itemId = ?", arrayOf(itemId)).use { c -> if (c.moveToFirst()) c.getLong(0) to (c.getInt(1) == 1) else null }
    }.getOrNull()

    fun count(): Int = runCatching { raw().query("SELECT COUNT(*) FROM tmdb_ids").use { it.moveToFirst(); it.getInt(0) } }.getOrDefault(0)
    fun remove(ids: Collection<String>) { runCatching { ids.chunked(400).forEach { ch -> raw().execSQL("DELETE FROM tmdb_ids WHERE itemId IN (${ch.joinToString(",") { "?" }})", ch.toTypedArray()) } }; TmdbGenreStore(db, now).remove(ids) }
    fun purgeOlderThan(cutoff: Long) { runCatching { raw().execSQL("DELETE FROM tmdb_ids WHERE at < ?", arrayOf(cutoff)) }; TmdbGenreStore(db, now).purgeOlderThan(cutoff) }
    fun clearAll() { runCatching { raw().execSQL("DELETE FROM tmdb_ids") }; TmdbGenreStore(db, now).clearAll() }
}
