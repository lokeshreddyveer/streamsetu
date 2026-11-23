package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.RatingCheckEntity
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.parse.Xtream
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

/**
 * The rating every tile shows, by [DisplayRating]: TMDB's when enough people voted, else the provider's when it is credible, else none. Tiles only say which titles are on screen ([want]);
 * about [debounceMs] later those are read together, in three queries for the whole batch (the rows' own ratings and what TMDB said), never one per tile. A matched title with no
 * credible rating that was never asked gets one small request through the express lane (its own reserved share of the request rate), once; a restricted title is never asked about.
 */
@OptIn(FlowPreview::class)
class RatingBadges(
    private val db: AppDatabase, private val auth: TmdbAuth, private val ids: TmdbIdStore, private val visibility: Visibility?, private val http: TmdbCall,
    private val enabled: () -> Boolean, scope: CoroutineScope, private val now: () -> Long = System::currentTimeMillis, debounceMs: Long = 80L,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO, private val maxValues: Int = MAX_VALUES,
) {
    private val _values = MutableStateFlow<Map<String, Double>>(emptyMap())
    /** Item id to the rating to show; a title with none is absent. */
    val values: StateFlow<Map<String, Double>> = _values

    private val lock = Any()
    private val pending = LinkedHashSet<String>()
    private val seen = HashSet<String>()
    private val poke = Channel<Unit>(Channel.CONFLATED)

    companion object {
        const val BATCH = 60; const val BACKFILL_PER_BATCH = 12
        /** The most ratings kept at once: a long scroll through a huge library keeps only the newest ones (older ones are read again when shown). */
        const val MAX_VALUES = 3_000
    }

    /** Adds [more] and drops the oldest entries beyond [MAX_VALUES], so the map neither grows without bound nor is copied at full library size. */
    private fun add(more: Map<String, Double>) = _values.update { cur ->
        val m = LinkedHashMap<String, Double>(cur.size + more.size)
        for ((k, v) in cur) if (k !in more) m[k] = v
        m.putAll(more)
        if (m.size > maxValues) { val drop = m.size - maxValues; val oldest = m.keys.iterator(); repeat(drop) { oldest.next(); oldest.remove() } }
        m
    }

    init { scope.launch { poke.receiveAsFlow().debounce(debounceMs).collect { runCatching { process() } } } }

    /** A tile with this title is on screen. Cheap: a set insert and a poke. */
    fun want(id: String) {
        val added = synchronized(lock) { if (id in seen) false else pending.add(id) }
        if (added) poke.trySend(Unit)
    }

    /** What is shown for a title right now, from what was read for it (null: none, or not read yet). */
    fun valueOf(id: String): Double? = _values.value[id]

    private fun credible(tmdbText: String?, provider: String?): Double? = DisplayRating.value(tmdbText?.toDoubleOrNull(), tmdbText?.let { DisplayRating.TMDB_VOTE_FLOOR }, provider)

    suspend fun process() {
        val batch = synchronized(lock) { pending.take(BATCH).also { pending.removeAll(it.toSet()); seen.addAll(it); if (seen.size > 5_000) seen.clear() } }
        if (batch.isEmpty()) return
        if (synchronized(lock) { pending.isNotEmpty() }) poke.trySend(Unit)
        val extras = db.extras()
        val provider = (extras.movieRatings(batch) + extras.seriesRatings(batch)).associate { it.id to it.rating }
        val checks = extras.ratingChecks(batch).associateBy { it.itemId }
        val found = HashMap<String, Double>()
        val lacking = ArrayList<String>()
        for (id in batch) { val v = credible(checks[id]?.tmdbRating, provider[id]); if (v != null) found[id] = v else if (id !in checks) lacking += id }
        if (found.isNotEmpty()) add(found)
        if (lacking.isNotEmpty() && enabled() && auth.available) backfill(lacking.take(BACKFILL_PER_BATCH), provider)
    }

    /** One small request for each matched title with no credible rating that was never asked, for titles on screen only. */
    private suspend fun backfill(candidates: List<String>, provider: Map<String, String?>) {
        val extras = db.extras()
        val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND)
        val movies = extras.moviesByIds(candidates).associateBy { it.id }; val series = extras.seriesByIds(candidates).associateBy { it.id }
        for (id in candidates) {
            val m = movies[id]; val s = series[id]
            if (snap != null && ((m != null && !snap.movieOk(m.toModel())) || (s != null && !snap.seriesOk(s.toModel())))) continue          // never asked about a restricted title
            val (tmdb, tv) = ids.tmdbOf(id) ?: continue
            val kind = if (tv) "tv" else "movie"
            val text = try {
                withContext(dispatcher) { ArtworkLane.express { val o = Xtream.parseObject(auth.call("$kind/$tmdb", "language=en-US", http)); DisplayRating.tmdbText(o?.get("vote_average")?.jsonPrimitive?.doubleOrNull, o?.get("vote_count")?.jsonPrimitive?.intOrNull) } }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { continue }          // not asked again for this screen; tried once more the next time it is shown
            // Asked once: a title with nothing credible is remembered as asked (a re-check happens only after the 180-day limit).
            extras.putRatingCheck(RatingCheckEntity(id, text, now()))
            credible(text, provider[id])?.let { v -> add(mapOf(id to v)) }
        }
    }

    /** TMDB's ratings are taken back (the key removed, matching switched off, "Clear"): tiles fall back to the provider's rating. */
    suspend fun clearAll() { db.extras().clearAllRatingChecks(); synchronized(lock) { seen.clear() }; _values.value = emptyMap() }
}
