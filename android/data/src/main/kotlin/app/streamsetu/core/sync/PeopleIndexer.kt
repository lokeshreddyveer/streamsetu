package app.streamsetu.core.sync

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.PeopleIndex
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.core.data.repo.toModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException

/**
 * Reads who is in each movie (the cast and directors the playlist offers) so people can be searched for. What it has learned is kept (the people tables, one "done" row per title),
 * and Search reads that index whenever it likes. This class only ADDS to it, and it never runs by itself during normal use:
 *  - [start]: a pass the person asked for (Settings, "Update cast search index");
 *  - [watchIdle]: an optional pass after several minutes without the remote being used (off by default on low-memory TVs).
 * A pass stops at once when playback starts (a detail request competes with a stream, and some providers allow only one connection); an idle pass also stops the moment the remote
 * is used ([noteInput]). It reads small batches, one title at a time with a pause, and stops by itself when a playlist keeps failing. Only titles without a "done" row are read,
 * so a pass after a sync reads just the titles that are new, and every pass carries on where the last stopped.
 */
class PeopleIndexer(private val db: AppDatabase, private val sync: SyncService, private val busy: () -> Boolean) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val running = AtomicBoolean(false)
    @Volatile private var job: Job? = null
    @Volatile private var idlePass = false
    @Volatile private var lastInputAt = SystemClock.elapsedRealtime()

    /** How many movies have been asked about, and how many there are. */
    fun progress(): Pair<Int, Int> = runCatching { PeopleIndex.progress(db.openHelper.readableDatabase) }.getOrDefault(0 to 0)

    /** True when some movies have not been read yet, so a cast search may miss people. */
    fun isStale(): Boolean = progress().let { it.first < it.second }

    /** The remote (or a touch) was used. An idle pass stops at once; a pass the person asked for goes on. */
    fun noteInput() {
        lastInputAt = SystemClock.elapsedRealtime()
        if (idlePass) job?.cancel()
    }

    /** A pass the person asked for. Does nothing if one is already running. */
    fun start() = launchPass(idle = false)

    /** Stops a pass that is running. What was learned stays. */
    fun stop() { job?.cancel() }

    /** Checks once a minute; starts an idle pass when [enabled], the remote has been left alone for [IDLE_MS], nothing plays and there is something left to read. */
    fun watchIdle(watcher: CoroutineScope, enabled: () -> Boolean) {
        watcher.launch(Dispatchers.IO) {
            while (true) {
                delay(60_000)
                if (enabled() && !running.get() && !busy() && SystemClock.elapsedRealtime() - lastInputAt >= IDLE_MS && isStale()) launchPass(idle = true)
            }
        }
    }

    private fun launchPass(idle: Boolean) {
        if (!running.compareAndSet(false, true)) return
        idlePass = idle
        job = scope.launch { try { run() } finally { idlePass = false; running.set(false) } }
    }

    private suspend fun run() {
        val raw = db.openHelper.writableDatabase
        val failures = HashMap<String, Int>()
        val giveUp = HashSet<String>()
        while (true) {
            currentCoroutineContext().ensureActive()
            if (busy()) return                                                      // playback started: stop now; the next pass carries on
            val batch = PeopleIndex.pendingMovies(raw, BATCH, giveUp)
            if (batch.isEmpty()) return
            for ((id, sourceId) in batch) {
                currentCoroutineContext().ensureActive()
                if (busy()) return
                val movie = db.catalog().movie(id)?.toModel()
                if (movie == null) { PeopleIndex.markDone(raw, id, sourceId); continue }
                try {
                    val names = sync.peopleOf(movie)
                    if (names == null) PeopleIndex.markDone(raw, id, sourceId)         // this kind of playlist has no details: nothing to learn
                    else PeopleIndex.save(raw, id, "MOVIE", sourceId, names, SearchText::normalize)          // saved title by title, so progress is never lost
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
            delay(1_000)                                                            // a breath between batches
        }
    }

    private companion object {
        const val BATCH = 4
        const val IDLE_MS = 5 * 60_000L
    }
}
