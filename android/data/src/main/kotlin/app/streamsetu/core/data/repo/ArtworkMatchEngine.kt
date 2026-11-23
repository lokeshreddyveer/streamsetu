package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.net.HttpStatusException
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import androidx.room.withTransaction
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/** Which lane the request on this thread belongs to: the express lane (what the person sees or opened) has its own reserved share of the request rate. */
object ArtworkLane {
    private val flag = ThreadLocal<Boolean>()
    fun isExpress() = flag.get() == true
    inline fun <T> express(block: () -> T): T { set(true); try { return block() } finally { set(false) } }
    fun set(v: Boolean) = flag.set(v)
}

/**
 * Spreads requests out: at most [rps] start per second in all, however many threads ask, in a steady rhythm and never as a burst. [expressRps] of that is reserved for the express lane (it has its
 * own clock, so bulk work can never queue ahead of it); the bulk lane gets the rest. The clock and the sleep are replaceable (tests).
 */
class RequestPacer(@Volatile var rps: Int, private val expressRps: Int = 0, private val nowMs: () -> Long = System::currentTimeMillis, private val sleepMs: (Long) -> Unit = { Thread.sleep(it) }) {
    constructor(rps: Int, nowMs: () -> Long, sleepMs: (Long) -> Unit) : this(rps, 0, nowMs, sleepMs)
    private var nextBulk = 0L; private var nextExpress = 0L
    fun acquire() {
        val express = ArtworkLane.isExpress() && expressRps > 0
        val wait = synchronized(this) {
            val t = nowMs()
            if (express) { val slot = maxOf(t, nextExpress); nextExpress = slot + 1000L / expressRps; slot - t }
            else { val rate = (if (expressRps > 0) rps - expressRps else rps).coerceAtLeast(1); val slot = maxOf(t, nextBulk); nextBulk = slot + 1000L / rate; slot - t }
        }
        if (wait > 0) sleepMs(wait)
    }
}

/**
 * Matches artwork in the background without anyone pressing anything: one continuous run through every title that lacks a picture or a summary (movies and series), resumed from a saved
 * cursor after the app is closed or stopped. The queue is never held in memory: it is read from the database in small pages by id, so it costs one page whatever the library's size.
 *
 *  - First what is seen: [prioritize] puts ids on screen (or opened) at the front. A debounced, cheap call.
 *  - Gentle: a [RequestPacer] limits the rate, [Config.concurrency] titles at a time, a failed run waits with exponential backoff (a 429's Retry-After is honoured); the wait is saved,
 *    so a restart does not start asking again at once.
 *  - Private: a title in a locked, hidden or adult/Kids-restricted folder, or with a copy in one (the strictest rule), is never listed and never sent; [onRestrictionsChanged] empties the
 *    priority list and makes every page being worked on be checked again before its next request.
 *  - Only with a credential ([TmdbAuth]) and the switch on; either one gone stops it.
 */
class ArtworkMatchEngine(
    private val db: AppDatabase,
    private val service: TmdbService,
    private val visibility: Visibility?,
    private val dir: File,
    private val profile: () -> String,
    private val enabled: () -> Boolean,
    /** The network, battery and playback rules of the moment (unmetered unless the person allows mobile data, battery not low, nothing playing). */
    private val allowed: () -> Boolean = { true },
    private val config: Config = Config(),
    private val now: () -> Long = System::currentTimeMillis,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** Why [allowed] is false, for the Settings line. */
    private val pauseCause: () -> PauseCause = { PauseCause.OTHER },
) {
    // includeSummaryOnly is off: the bulk run fills missing posters only; summaries and details are fetched on demand (opened, on screen, hero) and cached, so a library is never bulk-fetched.
    data class Config(val concurrency: Int = 8, val page: Int = 200, val writeBatch: Int = 50, val baseBackoffMs: Long = 30_000, val maxBackoffMs: Long = 3_600_000, val failuresBeforeBackoff: Int = 3, val includeSummaryOnly: Boolean = false) {
        companion object { fun forDevice(lowEnd: Boolean) = Config(concurrency = if (lowEnd) 2 else 8) }
    }
    enum class State { IDLE, RUNNING, COMPLETE, OFF, NO_KEY, WAITING, BACKOFF }
    /** Why the bulk run is paused for the network rules (never for what the person looks at). */
    enum class PauseCause { METERED, BATTERY, OFFLINE, OTHER }
    data class Progress(val done: Int = 0, val total: Int = 0, val notFound: Int = 0, val state: State = State.IDLE, val retryAt: Long = 0L, val perSecond: Double = 0.0, val secondsLeft: Long = 0L, val cause: PauseCause? = null) {
        private fun left(): String = if (perSecond <= 0.0 || secondsLeft <= 0) "" else " · about " + (if (secondsLeft < 90) "1 min" else if (secondsLeft < 5400) "${(secondsLeft + 30) / 60} min" else "${secondsLeft / 3600} h ${(secondsLeft % 3600 + 30) / 60} min") + " left"
        /** The one line Settings shows: "Matching artwork: 1,204 of 3,218 done · 61 not found", and "All artwork matched · 61 not found" at the end. */
        fun line(builtInRefused: Boolean = false, locale: java.util.Locale = java.util.Locale.getDefault()): String {
            fun n(v: Int) = String.format(locale, "%,d", v)
            val nf = if (notFound > 0) " · ${n(notFound)} not found" else ""
            return when {
                state == State.OFF -> "Automatic artwork matching is off."
                state == State.NO_KEY -> if (builtInRefused) "The built-in key is not working; add your own free key to keep artwork." else "Add your own free TMDB key to match artwork."
                state == State.COMPLETE || (total > 0 && done >= total) -> "All artwork matched$nf"
                state == State.WAITING -> when (cause) {
                    PauseCause.METERED -> "Paused: waiting for Wi-Fi (mobile data is off in Settings). Opening titles still works."
                    PauseCause.BATTERY -> "Paused: the battery is low. Opening titles still works."
                    PauseCause.OFFLINE -> "Paused: no connection. Matching carries on by itself."
                    else -> "Paused for now: ${n(done)} of ${n(total)} done$nf. Opening titles still works."
                }
                state == State.BACKOFF -> "Matching artwork will carry on shortly: ${n(done)} of ${n(total)} done$nf"
                total == 0 && done == 0 && state != State.IDLE -> "Nothing to match$nf"
                total == 0 -> "Matching artwork starts automatically."
                else -> "Matching artwork: ${n(done)} of ${n(total)} done$nf" + (if (perSecond >= 0.5) " · ${String.format(locale, "%.0f", perSecond)}/s" else "") + left()
            }
        }
    }
    sealed class Result { object Complete : Result(); object Paused : Result(); object Waiting : Result(); object TimeUp : Result(); data class Backoff(val until: Long) : Result() }

    companion object {
        const val STATE_PREFIX = "artwork-state-"
        /** Raised when the matching rules change: titles remembered as "not found" under older rules are asked again once. */
        const val RULES = 4   // 4: name-only decision and the extra query tiers
        private const val MAX_PRIORITY = 300
    }

    private val _progress = MutableStateFlow(Progress())
    val progress: StateFlow<Progress> = _progress

    private data class Item(val id: String, val title: String, val year: Int?, val kind: String, val plotOnly: Boolean)
    private class Saved(var rules: Int = 0, var phase: Int = 0, var cursor: String = "", var until: Long = 0, var step: Int = 0, var restricted: Int = 0)

    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val priority = LinkedHashSet<String>()
    private val recent = HashMap<String, Long>()
    private val lock = Any()
    @Volatile private var generation = 0
    private val running = java.util.concurrent.atomic.AtomicBoolean(false)

    // Counters kept in memory so a page never re-reads the log.
    private var done = 0; private var notFound = 0; private var pending = 0; private var countsKnown = false
    private var saved = Saved(); private var savedFor = ""

    private fun stateFile() = File(dir, STATE_PREFIX + profile().filter { it.isLetterOrDigit() || it == '-' || it == '_' }.ifEmpty { "default" } + ".json")
    private fun load(): Saved {
        val f = stateFile()
        if (f.path == savedFor) return saved
        savedFor = f.path; countsKnown = false
        saved = runCatching { Json.parseToJsonElement(f.readText()).jsonObject.let { o -> Saved(o["v"]!!.jsonPrimitive.int, o["p"]!!.jsonPrimitive.int, o["c"]!!.jsonPrimitive.content, o["u"]!!.jsonPrimitive.long, o["s"]!!.jsonPrimitive.int, o["r"]?.jsonPrimitive?.intOrNull ?: 0) } }.getOrDefault(Saved())
        return saved
    }
    private fun store() { runCatching { dir.mkdirs(); val s = saved; stateFile().writeText(buildJsonObject { put("v", s.rules); put("p", s.phase); put("c", s.cursor); put("u", s.until); put("s", s.step); put("r", s.restricted) }.toString()) } }

    /** Puts titles that are on screen or opened at the front of the queue. Cheap: a set insert and a wake-up; the same id again within two seconds is ignored. */
    fun prioritize(ids: Collection<String>) {
        if (ids.isEmpty()) return
        val t = now(); var added = false
        synchronized(lock) {
            for (id in ids) {
                if ((recent[id] ?: 0L) > t - 2_000) continue
                if (recent.size > 600) recent.clear()
                recent[id] = t
                priority.remove(id); priority.add(id); added = true
                if (priority.size > MAX_PRIORITY) priority.remove(priority.first())
            }
        }
        if (added) wake.trySend(Unit)
    }
    /** A key or switch change: start or resume the run at once. */
    fun kick() { wake.trySend(Unit) }

    /** "Match now": the person asked, so the mobile-data and battery rules no longer pause the bulk run for the rest of this session. */
    @Volatile var forced = false; private set
    fun matchAnyway() { forced = true; kick() }

    /** A lock, hide or adult block changed: whatever is queued is dropped at once and every page in flight is checked again before its next request. */
    fun onRestrictionsChanged() { synchronized(lock) { priority.clear(); recent.clear() }; generation++ }

    /** The counters are read again from the record (after a purge or a change of rules). */
    /** What the express lane has already stored: bulk work skips these. */
    private val handled = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())
    fun markHandled(id: String) { if (handled.size > 4000) handled.clear(); handled.add(id) }
    fun isHandled(id: String) = id in handled
    /** Changes whenever a lock, hide or adult block changes; the express lane checks it right before it sends. */
    fun generationNow(): Int = generation

    fun resync() { countsKnown = false; wake.trySend(Unit) }

    /** The run for the life of the app: works through the queue, then waits to be woken (a new title on screen, the switch, the key, the network). */
    suspend fun runForever() {
        while (currentCoroutineContext().isActive) {
            val wait = when (val r = runOnce()) {
                is Result.Backoff -> (r.until - now()).coerceAtLeast(1_000)
                Result.Waiting -> 60_000L
                Result.TimeUp -> 0L
                else -> 6 * 3_600_000L
            }
            if (wait > 0) withTimeoutOrNull(wait) { wake.receive() }
        }
    }

    private suspend fun ensureCounts() {
        if (countsKnown) return
        val (d, n) = service.counts(); done = d; notFound = n
        val extras = db.extras()
        pending = ((if (config.includeSummaryOnly) extras.countMoviesToMatch() + extras.countSeriesToMatch() else extras.countMoviesNoPoster() + extras.countSeriesNoPoster()) - load().restricted).coerceAtLeast(0)
        countsKnown = true
    }
    private var runStart = 0L; private var doneAtStart = 0
    private fun publish(state: State, retryAt: Long = 0L, cause: PauseCause? = null) {
        val n = done - doneAtStart; val secs = (now() - runStart) / 1000.0
        // A rate and the time left are shown only after 100 titles of this run, so the first seconds do not make wild guesses.
        val rate = if (n >= 100 && secs > 0) n / secs else 0.0
        _progress.value = Progress(done, done + pending, notFound, state, retryAt, rate, if (rate > 0) (pending / rate).toLong() else 0L, cause)
    }

    /** One run of the queue until it is complete, paused, waiting for the network, backing off, or [deadlineMs] (worker time limit) passes. */
    suspend fun runOnce(deadlineMs: Long = Long.MAX_VALUE): Result {
        if (!running.compareAndSet(false, true)) return Result.Waiting
        try { return withContext(dispatcher) { run(deadlineMs) } } finally { running.set(false) }
    }

    private suspend fun run(deadlineMs: Long): Result {
        if (!enabled()) { publishQuiet(State.OFF); return Result.Paused }
        if (!service.auth.available) { publishQuiet(State.NO_KEY); return Result.Paused }
        val st = load()
        if (st.rules != RULES) {            // the rules changed: what was "not found" under the old ones is asked again, once
            service.forgetNotFound(service.notFoundIds()); st.rules = RULES; st.phase = 0; st.cursor = ""; st.restricted = 0; store(); countsKnown = false
        }
        ensureCounts(); runStart = now(); doneAtStart = done
        if (st.until > now()) { publish(State.BACKOFF, st.until); return Result.Backoff(st.until) }
        var skipped = if (st.phase != 0 || st.cursor.isNotEmpty()) st.restricted else 0; var doneAtSweepStart = done          // a resumed sweep keeps the restricted titles the earlier process passed over
        while (true) {
            currentCoroutineContext().ensureActive()
            if (!enabled()) { publish(State.OFF); return Result.Paused }
            if (!service.auth.available) { publish(State.NO_KEY); return Result.Paused }
            if (!forced && !allowed()) { publish(State.WAITING, cause = pauseCause()); return Result.Waiting }
            if (now() >= deadlineMs) { publish(State.RUNNING); return Result.TimeUp }
            val gen = generation
            val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND)
            val ph = saved.phase; val cur = saved.cursor
            val (items, skippedNow) = nextPage(snap)
            skipped += skippedNow; saved.restricted = skipped
            if (items.isEmpty()) {
                if (saved.phase >= 4) {
                    saved.phase = 0; saved.cursor = ""; saved.restricted = skipped; store(); countsKnown = false; ensureCounts()
                    // Titles passed over (a page cut short by a lock, a failure) are picked up by one more sweep, as long as the last one got somewhere.
                    if (pending > 0 && done > doneAtSweepStart) { doneAtSweepStart = done; skipped = 0; continue }
                    publish(State.COMPLETE); return Result.Complete
                }
                continue
            }
            publish(State.RUNNING)
            val problem = work(items, gen)
            if (problem != null || gen != generation) { saved.phase = ph; saved.cursor = cur }          // the page was not finished: it is read again
            store(); publish(State.RUNNING)
            if (problem != null) { publish(State.BACKOFF, problem); return Result.Backoff(problem) }
        }
    }

    private fun publishQuiet(state: State) { _progress.value = _progress.value.copy(state = state) }

    /** The next page: what is on screen first, then the saved cursor onwards. Restricted titles are counted, never returned. */
    private suspend fun nextPage(snap: Visibility.Snapshot?): Pair<List<Item>, Int> {
        val extras = db.extras()
        val n = config.page
        val ids = synchronized(lock) { priority.take(n).also { priority.removeAll(it.toSet()) } }
        if (ids.isNotEmpty()) {
            val have = extras.overrideIdsAmong(ids).toSet()
            val out = ArrayList<Item>()
            for (m in extras.moviesByIds(ids)) if (m.id !in have && (m.posterUrl.isNullOrBlank() || m.plot.isNullOrBlank()) && (snap == null || snap.movieOk(m.toModel()))) out += Item(m.id, m.title, m.year, "movie", !m.posterUrl.isNullOrBlank())
            for (s in extras.seriesByIds(ids)) if (s.id !in have && (s.posterUrl.isNullOrBlank() || s.plot.isNullOrBlank()) && (snap == null || snap.seriesOk(s.toModel()))) out += Item(s.id, s.title, s.year, "tv", !s.posterUrl.isNullOrBlank())
            if (out.isNotEmpty()) return out to 0
        }
        val st = saved
        var skipped = 0
        val out = ArrayList<Item>()
        var any = false
        fun add(id: String, title: String, year: Int?, kind: String, plotOnly: Boolean, ok: Boolean) { any = true; st.cursor = id; if (ok) out += Item(id, title, year, kind, plotOnly) else skipped++ }
        when (st.phase) {
            0 -> extras.moviesNoPosterAfter(st.cursor, n).forEach { m -> add(m.id, m.title, m.year, "movie", false, snap == null || snap.movieOk(m.toModel())) }
            1 -> extras.seriesNoPosterAfter(st.cursor, n).forEach { s -> add(s.id, s.title, s.year, "tv", false, snap == null || snap.seriesOk(s.toModel())) }
            2 -> if (config.includeSummaryOnly) extras.moviesNoPlotAfter(st.cursor, n).forEach { m -> add(m.id, m.title, m.year, "movie", true, snap == null || snap.movieOk(m.toModel())) }
            3 -> if (config.includeSummaryOnly) extras.seriesNoPlotAfter(st.cursor, n).forEach { s -> add(s.id, s.title, s.year, "tv", true, snap == null || snap.seriesOk(s.toModel())) }
        }
        if (!any) { st.phase++; st.cursor = ""; return emptyList<Item>() to 0 }
        return out to skipped
    }

    /** Works through a page with [Config.concurrency] titles at a time. Returns when to try again if the run must back off, else null. */
    private suspend fun work(items: List<Item>, gen: Int): Long? = coroutineScope {
        val next = AtomicInteger(0)
        val untilBox = java.util.concurrent.atomic.AtomicLong(0L)
        var fails = 0
        val jobs = List(config.concurrency) {
            launch(dispatcher) {
                while (true) {
                    val i = next.getAndIncrement(); if (i >= items.size || untilBox.get() != 0L) break
                    // Checked again right before each request: a lock made while the page was queued stops it here.
                    if (gen != generation || !enabled() || !service.auth.available) { next.set(Int.MAX_VALUE / 2); break }
                    val it = items[i]
                    if (isHandled(it.id)) continue          // the express lane already did this one
                    try {
                        val (o, row) = service.lookup(it.id, it.title, it.year, it.kind, it.plotOnly)
                        val full = synchronized(lock) { buffer += row; buffer.size >= config.writeBatch }
                        if (full) flush()
                        synchronized(lock) { done++; if (pending > 0) pending--; if (o == TmdbService.Outcome.NOT_FOUND) notFound++; fails = 0; saved.step = 0 }
                    } catch (e: CancellationException) { throw e }
                    catch (e: HttpStatusException) {
                        when (e.code) {
                            429 -> untilBox.set(backoff(e.retryAfterSeconds))
                            401, 403 -> { if (service.auth.available) untilBox.set(backoff(null, long = true)) else next.set(Int.MAX_VALUE / 2) }
                            else -> synchronized(lock) { if (++fails >= config.failuresBeforeBackoff) untilBox.set(backoff(null)) }
                        }
                    } catch (e: Exception) { synchronized(lock) { if (++fails >= config.failuresBeforeBackoff) untilBox.set(backoff(null)) } }
                }
            }
        }
        jobs.joinAll()
        withContext(NonCancellable) { flush() }
        if (gen != generation) runCatching { service.purge() }          // a lock made during the page: anything it covered is taken back at once
        untilBox.get().takeIf { it != 0L }
    }

    private val buffer = ArrayList<app.streamsetu.core.data.db.OverrideEntity>()
    private val flushLock = Mutex()
    /** Writes what is waiting in one transaction (50 results at a time). */
    private suspend fun flush() {
        flushLock.withLock {
            val rows = synchronized(lock) { if (buffer.isEmpty()) return; buffer.toList().also { buffer.clear() } }
            db.withTransaction { db.extras().putOverrides(rows) }
        }
    }

    private fun backoff(retryAfterSeconds: Long?, long: Boolean = false): Long = synchronized(lock) {
        saved.step = (saved.step + 1).coerceAtMost(12)
        val exp = (config.baseBackoffMs shl (saved.step - 1).coerceAtMost(20)).coerceAtMost(config.maxBackoffMs)
        val wait = maxOf(exp, (retryAfterSeconds ?: 0L) * 1000, if (long) config.maxBackoffMs else 0L)
        saved.until = now() + wait; saved.until
    }
}
