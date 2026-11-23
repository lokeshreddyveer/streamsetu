package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.net.HttpStatusException
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * The express lane: what the person sees or opens is matched at once, apart from the bulk queue. It has its own small budget (a few titles at a time on its own threads, and its own reserved share
 * of the request rate in [RequestPacer], so the bulk run can never starve it).
 *  - Visible tiles without a picture: [tileVisible] says which tiles are on screen; about [Config.debounceMs] after scrolling pauses, the newest [Config.maxVisible] of them are matched (one search,
 *    no year, a local choice). A tile that has scrolled away before its turn is dropped.
 *  - An opened title: [open] matches it and fetches its details in one go (cast, wide picture, summary, trailer), and keeps the picture and summary so the bulk run skips it.
 * Nothing is sent without a credential, the switch, or for a restricted title: that is checked again right before every request.
 */
class ArtworkExpress(
    private val db: AppDatabase,
    private val service: TmdbService,
    private val cast: TmdbCast,
    private val engine: ArtworkMatchEngine,
    private val visibility: Visibility?,
    private val enabled: () -> Boolean,
    private val config: Config = Config(),
    private val now: () -> Long = System::currentTimeMillis,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    scope: CoroutineScope,
) {
    data class Config(val concurrency: Int = 3, val maxVisible: Int = 12, val debounceMs: Long = 300)

    /** Called (at most about once a second) after something was stored, so screens read their list again. */
    @Volatile var onStored: () -> Unit = {}

    /** Told (library item id, is a series, raw TMDB details reply) after an opened title's details were fetched: the metadata hub keeps the other services' ids from it. */
    @Volatile var extrasSink: (suspend (String, Boolean, String) -> Unit)? = null

    private val visible = LinkedHashSet<String>()
    private val pokes = Channel<Unit>(Channel.CONFLATED)
    private val permits = Semaphore(config.concurrency)
    @Volatile private var coolUntil = 0L
    @Volatile private var lastNotice = 0L

    init { scope.launch { pokes.receiveAsFlow().debounce(config.debounceMs).collect { runCatching { serve() } } } }

    /** What is on screen is matched when matching is on and TMDB can be used. The rules that pause the bulk run (mobile data off, battery) never apply here. */
    private fun ready() = enabled() && service.auth.available && now() >= coolUntil
    /** An opened title is the person's own request: it needs only a credential (not the matching switch, not the network rules). */
    private fun readyToOpen() = service.auth.available && now() >= coolUntil

    /** A poster-less tile came on screen ([on]) or went away. Cheap: a set update and a poke. */
    fun tileVisible(id: String, on: Boolean) {
        synchronized(visible) { if (on) { visible.remove(id); visible.add(id) } else visible.remove(id) }
        if (on) pokes.trySend(Unit)
    }

    /** Ids still on screen, newest first (tests and diagnostics). */
    fun visibleNow(): List<String> = synchronized(visible) { visible.toList().asReversed() }

    private suspend fun serve() {
        if (!ready()) return
        val ids = visibleNow().take(config.maxVisible).filterNot { engine.isHandled(it) }
        if (ids.isEmpty()) return
        val extras = db.extras()
        val have = extras.overrideIdsAmong(ids).toSet()
        val gen = engine.generationNow()
        val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND)
        class Item(val id: String, val title: String, val year: Int?, val kind: String)
        val items = ArrayList<Item>()
        for (m in extras.moviesByIds(ids)) if (m.id !in have && m.posterUrl.isNullOrBlank() && (snap == null || snap.movieOk(m.toModel()))) items += Item(m.id, m.title, m.year, "movie")
        for (s in extras.seriesByIds(ids)) if (s.id !in have && s.posterUrl.isNullOrBlank() && (snap == null || snap.seriesOk(s.toModel()))) items += Item(s.id, s.title, s.year, "tv")
        val order = ids.withIndex().associate { it.value to it.index }
        coroutineScope {
            for (it in items.sortedBy { order[it.id] }) launch {
                permits.withPermit {
                    // Right before sending: still on screen, nothing restricted since, still allowed.
                    if (it.id !in visibleNow() || engine.generationNow() != gen || engine.isHandled(it.id) || !ready()) return@withPermit
                    try {
                        val row = withContext(dispatcher) { ArtworkLane.express { service.lookup(it.id, it.title, it.year, it.kind) } }
                        if (engine.generationNow() != gen) { service.purge(); return@withPermit }
                        db.extras().putOverride(row.second); engine.markHandled(it.id); noticeStored()
                    } catch (e: CancellationException) { throw e }
                    catch (e: HttpStatusException) { if (e.code == 429) coolUntil = now() + maxOf(5L, e.retryAfterSeconds ?: 0L) * 1000 }
                    catch (e: Exception) { }
                }
            }
        }
    }

    private fun noticeStored() { val t = now(); if (t - lastNotice >= 1000) { lastNotice = t; onStored() } }

    /**
     * A title was opened: its match and details come together (one search, one details call), the picture and summary are kept when it had none, and the cast, wide picture and trailer are returned.
     * Quietly empty when nothing may be asked.
     */
    suspend fun open(id: String?, title: String, year: Int?, series: Boolean, categoryId: String?): TmdbCast.Details = openChecked(id, title, year, series, categoryId).first

    /** As [open], and the error when TMDB could not be asked or did not answer (null when it answered, even with nothing). */
    suspend fun openChecked(id: String?, title: String, year: Int?, series: Boolean, categoryId: String?): Pair<TmdbCast.Details, Exception?> {
        if (!readyToOpen()) return TmdbCast.Details.NONE to null
        val kind = if (series) ContentKind.SERIES else ContentKind.MOVIE
        val gen = engine.generationNow()
        if (visibility != null && !visibility.snapshot(Visibility.Surface.RECOMMEND).titleOk(kind, categoryId, title, year)) return TmdbCast.Details.NONE to null
        var failure: Exception? = null
        var rawExtras: String? = null
        val d = permits.withPermit {
            if (engine.generationNow() != gen || !readyToOpen()) return@withPermit TmdbCast.Details.NONE
            withContext(dispatcher) { ArtworkLane.express { try { cast.detailsOrThrow(title, year, series) { _, raw -> rawExtras = raw } } catch (e: CancellationException) { throw e } catch (e: Exception) { failure = e; if (e is HttpStatusException && e.code == 429) coolUntil = now() + maxOf(5L, e.retryAfterSeconds ?: 0L) * 1000; TmdbCast.Details.NONE } } }
        }
        if (id != null && d.tmdbId != null) service.idStore?.put(id, d.tmdbId, series)
        if (id != null) rawExtras?.let { raw -> runCatching { extrasSink?.invoke(id, series, raw) } }
        if (id != null && (d.poster != null || d.plot != null) && engine.generationNow() == gen && !engine.isHandled(id)) {
            val extras = db.extras()
            if (extras.overrideIdsAmong(listOf(id)).isEmpty()) {
                val movie = extras.moviesByIds(listOf(id)).firstOrNull()?.let { it.posterUrl to it.plot }
                val ser = if (movie == null) extras.seriesByIds(listOf(id)).firstOrNull()?.let { it.posterUrl to it.plot } else null
                val (hasPoster, hasPlot) = (movie ?: ser)?.let { !it.first.isNullOrBlank() to !it.second.isNullOrBlank() } ?: (true to true)
                if (!hasPoster || !hasPlot) { service.store(id, if (hasPoster) null else d.poster, if (hasPlot) null else d.plot); engine.markHandled(id); noticeStored() }
            }
        }
        return d to failure
    }
}
