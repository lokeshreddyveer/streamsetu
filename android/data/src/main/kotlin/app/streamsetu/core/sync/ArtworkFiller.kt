package app.streamsetu.core.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Finds the picture of a title that has none (or whose picture would not load). Titles are asked for one at a time, a few a second, never the same title twice in a run, so a screen full of
 * blank tiles fills in quietly and costs the provider and the device almost nothing. The answer is saved with the title, so it is also there the next time and on every other screen.
 */
class ArtworkFiller(private val sync: SyncService, scope: CoroutineScope, private val pauseMs: Long = 250) {
    private val asked = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())
    /** Counts the pictures found so far, so a screen that read its list once can read it again when one more is there. */
    val filled = kotlinx.coroutines.flow.MutableStateFlow(0)
    /** A short queue: at most this many titles wait; the rest are asked for again when they are next seen without a picture. */
    private val queue = Channel<Pair<String, Boolean>>(32)
    @Volatile private var quietUntil = 0L
    @Volatile private var lastNotice = 0L

    init {
        scope.launch(Dispatchers.IO) {
            for ((id, replace) in queue) {
                // Nothing is asked of the provider or written to the database while the remote is in use (browsing, scrolling) or something is playing.
                while (System.currentTimeMillis() < quietUntil) delay(300)
                val found = runCatching { sync.fillPoster(id, replace) }.getOrDefault(false)
                // Screens that read their list once look again, but at most once a second however many pictures arrive.
                if (found && System.currentTimeMillis() - lastNotice > 1000) { lastNotice = System.currentTimeMillis(); filled.value++ }
                delay(pauseMs)
            }
        }
    }

    /** The remote was used: hold the queue for [ms] after the last key. */
    fun quietFor(ms: Long = 1500) { quietUntil = System.currentTimeMillis() + ms }

    /** [id] shows no picture. [replace]: it had one that did not load. */
    fun want(id: String, replace: Boolean = false) { val key = "$id/$replace"; if (asked.add(key) && queue.trySend(id to replace).isFailure) asked.remove(key) }
}
