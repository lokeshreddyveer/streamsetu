package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.first

/** What the person does: favourites, watch later, resume positions and what was watched. */
class UserRepository(private val db: AppDatabase) {
    private val dao get() = db.user()

    // Favourites and Watch Later are two lists of the same kind.
    fun favouriteIds(list: String = FAVOURITES): Flow<Set<String>> = dao.favoriteIds(list).map { it.toSet() }
    suspend fun setFavourite(itemId: String, kind: ContentKind, on: Boolean, list: String = FAVOURITES) {
        if (on) dao.putFavorite(FavoriteEntity(itemId, kind.name, list, System.currentTimeMillis())) else dao.removeFavorite(itemId, list)
    }

    /** Puts one favourite first or last in its list, leaving the others where they were. */
    suspend fun moveFavourite(itemId: String, toFront: Boolean, list: String = FAVOURITES) {
        if (toFront) dao.moveFavoriteFirst(itemId, list) else dao.moveFavoriteLast(itemId, list)
    }

    suspend fun progress(itemId: String): WatchProgress? = dao.progress(itemId)?.toModel()

    /** Remembers where playback stopped. Within the last 30 s (or 95 %) counts as finished. */
    suspend fun saveProgress(itemId: String, kind: ContentKind, seriesId: String?, positionMs: Long, durationMs: Long) {
        if (durationMs <= 0 || positionMs < 5_000) return
        val finished = durationMs - positionMs < 30_000 || positionMs.toDouble() / durationMs > 0.95
        dao.putProgress(ProgressEntity(itemId, kind.name, seriesId, if (finished) 0 else positionMs, durationMs, System.currentTimeMillis(), finished))
    }

    fun allProgress(): Flow<Map<String, WatchProgress>> = dao.allProgress().map { l -> l.associate { it.itemId to it.toModel() } }

    /** Marks a movie or episode watched (it leaves Continue Watching) or unwatched (its resume point is forgotten). */
    suspend fun setWatched(itemId: String, kind: ContentKind, seriesId: String?, watched: Boolean) {
        db.extras().clearNewEpisode(itemId)
        if (watched) dao.putProgress(ProgressEntity(itemId, kind.name, seriesId, 0, 1, System.currentTimeMillis(), true)) else dao.clearProgress(itemId)
    }
    suspend fun clearResumePoint(itemId: String) = dao.clearProgress(itemId)

    // ---- Taken out of Continue Watching by hand ----
    // A marker of its own (its own small table, made the first time it is used, so no database step is needed), kept apart from the resume points: removing a title from
    // Continue Watching never deletes or changes its progress, its watched mark or its history. A title stays out of the row until it is played again (its progress is then
    // newer than the marker), and Undo simply takes the marker away.

    private val hiddenChanged = kotlinx.coroutines.flow.MutableStateFlow(0L)
    @Volatile private var hiddenReady = false
    private fun hiddenDb(): androidx.sqlite.db.SupportSQLiteDatabase {
        val d = db.openHelper.writableDatabase
        if (!hiddenReady) { d.execSQL("CREATE TABLE IF NOT EXISTS continue_hidden(itemId TEXT PRIMARY KEY NOT NULL, hiddenAt INTEGER NOT NULL)"); hiddenReady = true }
        return d
    }

    /** The titles taken out by hand, with when: a title is out while its progress is no newer than this. */
    suspend fun continueHidden(): Map<String, Long> = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        val out = HashMap<String, Long>()
        hiddenDb().query("SELECT itemId, hiddenAt FROM continue_hidden").use { c -> while (c.moveToNext()) out[c.getString(0)] = c.getLong(1) }
        out
    }

    /** The same, as it changes. */
    fun continueHiddenFlow(): Flow<Map<String, Long>> = hiddenChanged.map { continueHidden() }

    /** Takes titles out of Continue Watching (only a marker is written). Returns what the markers were before, so Undo can put them back exactly. */
    suspend fun hideFromContinue(itemIds: Collection<String>, at: Long = System.currentTimeMillis()): List<Pair<String, Long?>> = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        val before = continueHidden()
        val d = hiddenDb()
        itemIds.distinct().forEach { d.execSQL("INSERT OR REPLACE INTO continue_hidden(itemId, hiddenAt) VALUES(?, ?)", arrayOf(it, at)) }
        hiddenChanged.value++
        itemIds.distinct().map { it to before[it] }
    }

    /** Undo: the markers are put back as they were (a title that had none gets none). */
    suspend fun restoreContinueMarkers(previous: List<Pair<String, Long?>>) = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        val d = hiddenDb()
        previous.forEach { (id, was) -> if (was == null) d.execSQL("DELETE FROM continue_hidden WHERE itemId = ?", arrayOf(id)) else d.execSQL("INSERT OR REPLACE INTO continue_hidden(itemId, hiddenAt) VALUES(?, ?)", arrayOf(id, was)) }
        hiddenChanged.value++
    }

    /** Takes everything now in Continue Watching out of it (markers only; nothing is deleted). Returns the previous markers, for Undo. */
    suspend fun hideAllFromContinue(alsoShown: Collection<String> = emptyList()): List<Pair<String, Long?>> = hideFromContinue(continueWatching(Int.MAX_VALUE / 2).first().map { it.itemId } + alsoShown)

    /** Titles left partway, newest first, without those taken out by hand (until they are played again). The resume points themselves are all kept. */
    fun continueWatching(limit: Int = 20): Flow<List<WatchProgress>> =
        kotlinx.coroutines.flow.combine(dao.continueWatching(if (limit > Int.MAX_VALUE / 4) limit else limit + 200), continueHiddenFlow()) { l, hidden ->
            l.filter { p -> hidden[p.itemId]?.let { at -> p.updatedAt > at } ?: true }.take(limit).map { it.toModel() }
        }

    suspend fun clearHistory() = dao.clearLog()
    /** Takes one title out of Recently Watched. Its resume point and favorites are not touched. */
    suspend fun removeFromRecent(itemId: String) = dao.deleteLogFor(itemId)
    suspend fun clearList(list: String) = dao.clearList(list)
    suspend fun clearAllProgress() = dao.clearAllProgress()

    fun newEpisodes(): Flow<List<app.streamsetu.core.data.db.NewEpisodeEntity>> = db.extras().newEpisodes()

    suspend fun recordPlay(itemId: String, kind: ContentKind, title: String) {
        if (kind == ContentKind.EPISODE) db.extras().clearNewEpisode(itemId)         // starting a new episode removes its New badge
        dao.log(WatchLogEntity(itemId = itemId, kind = kind.name, title = title, playedAt = System.currentTimeMillis()))
        dao.trimLog()
    }

    /** Everything watched, newest first (a title can appear more than once). */
    fun history(limit: Int = 200): Flow<List<app.streamsetu.core.data.db.WatchLogEntity>> = dao.history(limit)

    /** Channels in the order last watched, each once. */
    fun recentChannelIds(limit: Int = 20): Flow<List<String>> = dao.recentChannelLog(200).map { l -> l.map { it.itemId }.distinct().take(limit) }

    companion object { const val FAVOURITES = "favourites"; const val WATCH_LATER = "watch-later" }
}
