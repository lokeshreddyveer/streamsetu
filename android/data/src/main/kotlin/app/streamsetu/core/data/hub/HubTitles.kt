package app.streamsetu.core.data.hub

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.ArtworkLane
import app.streamsetu.core.data.repo.TmdbAuth
import app.streamsetu.core.data.repo.TmdbCall
import app.streamsetu.core.data.repo.TmdbIdStore
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.net.HttpStatusException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * What a title page asks the hub: which ids the title has (the crosswalk, fed by TMDB), a refresh through the express lane, and what is saved. Only titles the person opens come here
 * (the same as the Apple app): fanart.tv is never asked in bulk. TMDB is reached only through [tmdbCall], the app's one shared TMDB pacer.
 */
class HubTitles(
    private val db: AppDatabase, val hub: MetadataHub, private val store: HubFactStore, private val tmdbIds: TmdbIdStore, private val auth: TmdbAuth, private val tmdbCall: TmdbCall,
    private val isSendable: suspend (String) -> Boolean = { true },
    private val now: () -> Long = System::currentTimeMillis, private val dispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.IO,
) {
    /** What is saved for one title (cache only, never the network). */
    data class Saved(val logo: String? = null, val backdrop: String? = null, val poster: String? = null, val nextEpisode: String? = null, val provenance: Set<HubSource> = emptySet()) {
        companion object { val NONE = Saved() }
    }

    suspend fun saved(item: String): Saved = Saved(hub.image(item, ArtKind.LOGO), hub.image(item, ArtKind.BACKDROP), hub.image(item, ArtKind.POSTER), hub.text(item, "nextepisode"), hub.provenance(item))

    /** From TMDB's details reply (opened title): the other services' ids, filed under the library item's own id. */
    suspend fun ingestTmdbDetails(item: String, series: Boolean, raw: String) {
        val parsed = TMDBExtras.parse(raw, series) ?: return
        store.saveIdentity(item, parsed.ids, HubSource.TMDB, now())
    }

    /** The title's ids: the saved crosswalk, plus its TMDB id from the matcher, plus (for a series, once, through the shared TMDB pacer) TMDB's external ids so the other services can be asked. */
    suspend fun identity(item: String, series: Boolean): HubIdentity {
        var id = store.identity(item) ?: HubIdentity()
        if (id.tmdb == null) withContext(dispatcher) { tmdbIds.tmdbOf(item) }?.let { (t, tv) -> if (tv == series && t in 1..Int.MAX_VALUE) { id = id.copy(tmdb = t.toInt()); store.saveIdentity(item, HubIdentity(tmdb = t.toInt()), HubSource.TMDB, now()) } }
        val tmdb = id.tmdb
        if (series && tmdb != null && id.tvdb == null && id.imdb == null && auth.available && !(store.fact(item, IDS_FIELD)?.second?.let { it > now() } ?: false)) {
            val t = now()
            try {
                val text = withContext(dispatcher) { ArtworkLane.express { auth.call("tv/$tmdb/external_ids", "", tmdbCall) } }
                val ext = TMDBExtras.parseExternalIds(text, tmdb, true)
                if (ext != null) { store.saveIdentity(item, ext, HubSource.TMDB, t); id = store.identity(item) ?: id }
                store.putMiss(item, IDS_FIELD, HubSource.TMDB, t + (if (ext?.isEmpty == false) 7 else 1) * 86_400_000L, t)          // asked once; again after a day (nothing found) or a week
            } catch (e: CancellationException) { throw e }
            catch (e: HttpStatusException) { if (e.code == 404) store.putMiss(item, IDS_FIELD, HubSource.TMDB, t + 30 * 86_400_000L, t) }
            catch (e: Exception) { /* offline: asked again next time */ }
        }
        return id
    }

    /** A title was opened: after a short visibility delay the caller applies, ask the services that can improve what is missing. Quietly nothing when the title may not be sent. */
    suspend fun open(item: String, series: Boolean): Saved {
        if (!isSendable(item)) return Saved.NONE          // a title in a locked or hidden folder (or with a twin there) is asked about nowhere, TMDB's ids included
        val id = identity(item, series)
        hub.refresh(item, id, if (series) HubTitleKind.SERIES else HubTitleKind.MOVIE)
        return saved(item)
    }

    companion object { const val IDS_FIELD = "ids" }
}

/** Whether a library title may be sent to an extra service: not in a locked or hidden folder, and not with a twin there. An unknown id is not sent. */
class HubSendable(private val db: AppDatabase, private val visibility: Visibility?) {
    suspend operator fun invoke(item: String): Boolean {
        val extras = db.extras()
        val movie = extras.moviesByIds(listOf(item)).firstOrNull(); val series = if (movie == null) extras.seriesByIds(listOf(item)).firstOrNull() else null
        if (movie == null && series == null) return false
        val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND) ?: return true
        return movie?.let { snap.movieOk(it.toModel()) } ?: series?.let { snap.seriesOk(it.toModel()) } ?: false
    }
}

/** When a series' next episode airs, in words for a glance. Comes from the hub's ISO time stamp; past or unreadable stamps give nothing. */
sealed class NextEpisode {
    object Today : NextEpisode()
    object Tomorrow : NextEpisode()
    data class InDays(val n: Int) : NextEpisode()
    /** Further away: the date as "1 Dec" (month names in the person's locale). */
    data class On(val date: String) : NextEpisode()

    /** The words as an English key or template the app's translator knows ("Next episode in {} days"); [arg] is its one changing part. */
    fun key(): Pair<String, String?> = when (this) {
        Today -> "Next episode today" to null
        Tomorrow -> "Next episode tomorrow" to null
        is InDays -> "Next episode in {} days" to n.toString()
        is On -> "Next episode on {}" to date
    }

    companion object {
        fun from(stamp: String?, today: java.time.LocalDate = java.time.LocalDate.now(), zone: java.time.ZoneId = java.time.ZoneId.systemDefault(), locale: java.util.Locale = java.util.Locale.getDefault()): NextEpisode? {
            val s = stamp?.trim().orEmpty()
            if (s.isEmpty()) return null
            val date = runCatching { java.time.OffsetDateTime.parse(s).atZoneSameInstant(zone).toLocalDate() }.getOrNull()
                ?: runCatching { java.time.LocalDate.parse(s.take(10)) }.getOrNull() ?: return null
            val n = java.time.temporal.ChronoUnit.DAYS.between(today, date).toInt()
            return when {
                n < 0 -> null
                n == 0 -> Today
                n == 1 -> Tomorrow
                n <= 14 -> InDays(n)
                else -> On(java.time.format.DateTimeFormatter.ofPattern("d MMM", locale).format(date))
            }
        }
    }
}
