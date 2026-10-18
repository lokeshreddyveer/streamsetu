package app.streamsetu.core.sync

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.PeopleIndex
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.core.data.repo.toModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException

/**
 * Reads who is in each movie (the cast and directors the playlist offers) so people can be searched for. It works slowly in the background: one movie at a
 * time with a pause, never while something is playing (a detail request competes with a stream, and some providers allow only one connection), and it stops
 * by itself when a playlist keeps failing. What it learned is kept, so each pass carries on where the last stopped.
 */
class PeopleIndexer(private val db: AppDatabase, private val sync: SyncService, private val busy: () -> Boolean) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val running = AtomicBoolean(false)

    /** How many movies have been asked about, and how many there are. */
    fun progress(): Pair<Int, Int> = runCatching { PeopleIndex.progress(db.openHelper.readableDatabase) }.getOrDefault(0 to 0)

    /** Starts a pass unless one is running. Safe to call as often as is convenient. */
    fun start() {
        if (!running.compareAndSet(false, true)) return
        scope.launch { try { run() } finally { running.set(false) } }
    }

    private suspend fun run() {
        val raw = db.openHelper.writableDatabase
        val failures = HashMap<String, Int>()
        val giveUp = HashSet<String>()
        while (true) {
            scope.coroutineContext.ensureActive()
            if (busy()) { delay(8_000); continue }
            val batch = PeopleIndex.pendingMovies(raw, 8, giveUp)
            if (batch.isEmpty()) return
            for ((id, sourceId) in batch) {
                if (busy()) break
                val movie = db.catalog().movie(id)?.toModel()
                if (movie == null) { PeopleIndex.markDone(raw, id, sourceId); continue }
                try {
                    val names = sync.peopleOf(movie)
                    if (names == null) PeopleIndex.markDone(raw, id, sourceId)         // this kind of playlist has no details: nothing to learn
                    else PeopleIndex.save(raw, id, "MOVIE", sourceId, names, SearchText::normalize)
                    failures[sourceId] = 0
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    val n = (failures[sourceId] ?: 0) + 1
                    failures[sourceId] = n
                    if (n >= 4) giveUp += sourceId                                      // struggling: leave it until the next pass
                    delay(2_000)
                }
                delay(350)
            }
        }
    }
}
