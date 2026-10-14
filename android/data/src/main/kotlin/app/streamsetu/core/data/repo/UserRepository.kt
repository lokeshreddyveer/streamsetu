package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map

/** What the person does: favourites, watch later, resume positions and what was watched. */
class UserRepository(private val db: AppDatabase) {
    private val dao get() = db.user()

    // Favourites and Watch Later are two lists of the same kind.
    fun favouriteIds(list: String = FAVOURITES): Flow<Set<String>> = dao.favoriteIds(list).map { it.toSet() }
    suspend fun setFavourite(itemId: String, kind: ContentKind, on: Boolean, list: String = FAVOURITES) {
        if (on) dao.putFavorite(FavoriteEntity(itemId, kind.name, list, System.currentTimeMillis())) else dao.removeFavorite(itemId, list)
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

    fun continueWatching(limit: Int = 20): Flow<List<WatchProgress>> = dao.continueWatching(limit).map { l -> l.map { it.toModel() } }

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

    /** Channels watched at least twice in the last 30 days, most plays first. */
    fun mostWatchedChannelIds(limit: Int = 12): Flow<List<String>> =
        dao.mostWatched(System.currentTimeMillis() - 30L * 24 * 3600 * 1000, limit).map { l -> l.map { it.itemId } }

    companion object { const val FAVOURITES = "favourites"; const val WATCH_LATER = "watch-later" }
}
