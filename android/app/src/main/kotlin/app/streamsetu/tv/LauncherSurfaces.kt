package app.streamsetu.tv

import android.content.Context
import android.media.tv.TvContract
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.model.EpisodePlayable
import app.streamsetu.core.model.MoviePlayable
import app.streamsetu.core.model.Playable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * The things the launcher shows outside the app (the Continue Watching widget, the Android TV "Play next" row) follow the folder rules too. They use the strictest rule
 * ([Visibility.Surface.RECOMMEND]: locked stays out even after a PIN unlock, hidden, adult-blocked, Kids, and any title with a copy in such a folder), because nothing outside the app can ask for the PIN.
 * Whenever a lock, hide, unlock, the adult filter, Kids mode or the profile changes, what was already put there is taken away, and nothing restricted is added. The saved progress itself is never touched.
 */
object LauncherSurfaces {
    @Volatile private var snapshot: Visibility.Snapshot? = null

    /** False until the first look at the folder rules (nothing is added before then). */
    fun allowed(item: Playable): Boolean {
        val s = snapshot ?: return false
        return when (item) {
            is MoviePlayable -> s.movieOk(item.movie)
            is EpisodePlayable -> s.seriesOk(item.series)
            else -> false
        }
    }

    /** Looks at the folder rules again. */
    suspend fun refresh(v: Visibility) { snapshot = v.snapshot(Visibility.Surface.RECOMMEND) }
    internal fun reset() { snapshot = null }

    fun start(c: AppContainer) {
        c.appScope.launch(Dispatchers.IO) {
            combine(c.folders.restrictRev, c.profiles.activeId) { a, b -> "$a|$b" }.collect {
                refresh(c.folders.visibility)
                runCatching { sweepWatchNext(c) }
                ContinueWidget.refresh(c.context)
            }
        }
        // The row follows Continue Watching itself: a title taken out of it by hand, history or resume positions cleared, "erase everything", all take it off the launcher too (a private watch never added it).
        c.appScope.launch(Dispatchers.IO) {
            c.user.continueWatching(CONTINUE_KEEP).collect { list ->
                keep = list.map { it.itemId }.toSet()
                runCatching { sweepWatchNext(c) }
                ContinueWidget.refresh(c.context)
            }
        }
    }
    private const val CONTINUE_KEEP = 200
    /** The items Continue Watching holds now (null until it has been read: nothing is removed for that reason before). */
    @Volatile private var keep: Set<String>? = null

    /** Takes off the Play-next row every entry whose title is restricted now, gone, or no longer in Continue Watching. */
    suspend fun sweepWatchNext(c: AppContainer) {
        val ids = WatchNext.listed(c.context)
        val inContinue = keep
        for (id in ids) {
            val ok = c.catalog.movie(id)?.let { snapshot?.movieOk(it) }
                ?: c.catalog.episode(id)?.let { e -> c.catalog.series(e.seriesId)?.let { snapshot?.seriesOk(it) } }
            if (ok != true || (inContinue != null && id !in inContinue)) WatchNext.remove(c.context, id)
        }
    }
}
