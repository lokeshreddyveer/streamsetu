package app.streamsetu.tv.ui.screens.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.sync.upcoming
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.BannerItem
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ResumeItem(val progress: WatchProgress, val playable: Playable, val subtitle: String, val isNew: Boolean = false)
data class LiveItem(val channel: Channel, val now: String?)
sealed interface FavItem { val id: String; val title: String
    data class Ch(val channel: Channel) : FavItem { override val id get() = channel.id; override val title get() = channel.name }
    data class Mv(val movie: Movie) : FavItem { override val id get() = movie.id; override val title get() = movie.title }
    data class Sr(val series: Series) : FavItem { override val id get() = series.id; override val title get() = series.title }
}
data class CategoryTile(val kind: ContentKind, val folder: Folder)

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class HomeViewModel @Inject constructor(private val c: AppContainer) : ViewModel() {
    val libraryName: StateFlow<String> = c.library.active.map { it?.name ?: "StreamSetu" }.stateIn(viewModelScope, SharingStarted.Eagerly, "StreamSetu")
    val libraryOk: StateFlow<Boolean> = c.library.active.map { it?.health == LibraryEntry.Health.OK }.stateIn(viewModelScope, SharingStarted.Eagerly, true)

    // ---- Banner: real titles from the open library, enriched with the provider's own story and picture ----
    private val featured = MutableStateFlow<List<Playable>>(emptyList())
    private val info = MutableStateFlow<Map<String, app.streamsetu.core.sync.SyncService.MovieInfo>>(emptyMap())
    init {
        viewModelScope.launch {
            c.library.sourceIds.collectLatest { ids ->
                featured.value = emptyList()
                if (ids.isEmpty()) return@collectLatest
                // Waits until the library has something (a connection just read arrives after this screen opens).
                c.catalog.latestMovies(1).first { it.isNotEmpty() }
                val f = runCatching { c.featured().take(8) }.getOrDefault(emptyList())
                featured.value = f
                f.take(6).forEach { p -> if (p is MoviePlayable && info.value[p.id] == null) { c.sync.movieInfo(p.movie)?.let { i -> info.update { it + (p.id to i) } }; delay(150) } }
            }
        }
    }
    val banner: StateFlow<List<BannerItem>> = combine(featured, info) { list, infos ->
        list.mapNotNull { p ->
            when (p) {
                is MoviePlayable -> { val m = p.movie; val i = infos[m.id]
                    BannerItem(m.id, m.title, listOfNotNull(i?.genre?.takeIf { it.isNotBlank() }, m.year?.toString(), i?.duration?.takeIf { it.isNotBlank() }), (i?.plot ?: m.plot)?.takeIf { it.isNotBlank() },
                        i?.backdrop?.takeIf { it.isNotBlank() } ?: m.posterUrl, "Play") }
                is SeriesFeature -> { val s = p.series
                    BannerItem(s.id, s.title, listOfNotNull(s.year?.toString(), s.rating?.takeIf { it.isNotBlank() && it != "0" }?.let { "★ $it" }), s.plot?.takeIf { it.isNotBlank() }, s.backdropUrl?.takeIf { it.isNotBlank() } ?: s.posterUrl, "Episodes") }
                else -> null
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    fun playableFor(bannerId: String): Playable? = featured.value.firstOrNull { it.id == bannerId }

    val watchLaterIds: StateFlow<Set<String>> = c.user.favouriteIds(UserRepository.WATCH_LATER).stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())
    fun toggleWatchLater(id: String, kind: ContentKind) = viewModelScope.launch { c.user.setFavourite(id, kind, id !in watchLaterIds.value, UserRepository.WATCH_LATER) }

    // ---- Rails ----
    /**
     * Continue Watching: titles left partway, and series with an episode that appeared after the person finished the earlier ones (marked New).
     * A series shows once, whichever of the two applies; a new episode is never put ahead of one that is still in progress.
     */
    val continueWatching: StateFlow<List<ResumeItem>> = combine(c.user.continueWatching(), c.user.newEpisodes(), c.user.allProgress(), c.library.sourceIds) { list, fresh, progress, ids -> arrayOf(list, fresh, progress, ids) }.mapLatest { a ->
        @Suppress("UNCHECKED_CAST") val list = a[0] as List<WatchProgress>
        @Suppress("UNCHECKED_CAST") val fresh = a[1] as List<app.streamsetu.core.data.db.NewEpisodeEntity>
        @Suppress("UNCHECKED_CAST") val progress = a[2] as Map<String, WatchProgress>
        @Suppress("UNCHECKED_CAST") val ids = a[3] as List<String>
        val out = ArrayList<ResumeItem>()
        val seenSeries = HashSet<String>()
        list.forEach { p ->
            when (p.kind) {
                ContentKind.MOVIE -> c.catalog.movie(p.itemId)?.takeIf { it.sourceId in ids }?.let { out += ResumeItem(p, MoviePlayable(it), remaining(p)) }
                ContentKind.EPISODE -> c.catalog.episode(p.itemId)?.let { e -> c.catalog.series(e.seriesId)?.takeIf { it.sourceId in ids && seenSeries.add(it.id) }?.let { out += ResumeItem(p, EpisodePlayable(e, it), "S${e.season} E${e.number}  ·  ${remaining(p)}") } }
                else -> {}
            }
        }
        fresh.groupBy { it.seriesId }.forEach { (sid, flagged) ->
            if (sid in seenSeries) return@forEach
            val series = c.catalog.series(sid)?.takeIf { it.sourceId in ids } ?: return@forEach
            val plan = app.streamsetu.core.data.repo.EpisodePlan.of(c.catalog.episodesOnce(sid), progress)
            val next = plan.forward ?: return@forEach
            // Only when everything before it was finished: otherwise the person is still catching up and Continue Watching already knows.
            if (plan.catchUp != null || plan.inProgress != null || next.id !in flagged.map { it.episodeId }) return@forEach
            out += ResumeItem(WatchProgress(next.id, ContentKind.EPISODE, sid, 0, 1, flagged.maxOf { it.discoveredAt }, false), EpisodePlayable(next, series), "New episode  ·  S${next.season} E${next.number}", isNew = true)
        }
        out.sortedByDescending { it.progress.updatedAt }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val recentLive: StateFlow<List<LiveItem>> = combine(c.user.recentChannelIds(14), c.library.sourceIds) { ids, lib -> ids to lib }.mapLatest { (ids, lib) ->
        ids.mapNotNull { c.catalog.channel(it) }.filter { it.sourceId in lib }.let { chs -> val map = runCatching { c.epg.resolve(chs) }.getOrDefault(emptyMap()); chs.map { ch -> LiveItem(ch, map[ch.id]?.let { e -> runCatching { c.epg.upcoming(c.db, e, 1).firstOrNull()?.title }.getOrNull() }) } }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val favourites: StateFlow<List<FavItem>> = combine(c.user.favouriteIds(UserRepository.FAVOURITES), c.library.sourceIds) { ids, lib -> ids to lib }.mapLatest { (ids, lib) ->
        val list = ids.toList()
        val ch = list.mapNotNull { c.catalog.channel(it) }.filter { it.sourceId in lib }.map { FavItem.Ch(it) }
        val mv = c.catalog.moviesByIds(list).filter { it.sourceId in lib }.map { FavItem.Mv(it) }
        val sr = c.catalog.seriesByIds(list).filter { it.sourceId in lib }.map { FavItem.Sr(it) }
        val order = list.withIndex().associate { it.value to it.index }
        (ch + mv + sr).sortedBy { order[it.id] }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val watchLater: StateFlow<List<FavItem>> = combine(c.user.favouriteIds(UserRepository.WATCH_LATER), c.library.sourceIds) { ids, lib -> ids to lib }.mapLatest { (ids, lib) ->
        val list = ids.toList(); val order = list.withIndex().associate { it.value to it.index }
        (c.catalog.moviesByIds(list).filter { it.sourceId in lib }.map { FavItem.Mv(it) } + c.catalog.seriesByIds(list).filter { it.sourceId in lib }.map { FavItem.Sr(it) }).sortedBy { order[it.id] }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val recentMovies: StateFlow<List<Movie>> = c.browse.movies(Browse.RecentlyAdded, SortSpec(SortField.ADDED), 30).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val recentSeries: StateFlow<List<Series>> = c.browse.series(Browse.RecentlyAdded, SortSpec(SortField.ADDED), 30).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val categories: StateFlow<List<CategoryTile>> = combine(c.folders.folders(ContentKind.MOVIE), c.folders.folders(ContentKind.SERIES)) { m, s ->
        (m.filter { !it.pref.hidden && !it.pref.locked && it.count > 0 }.take(12).map { CategoryTile(ContentKind.MOVIE, it) } + s.filter { !it.pref.hidden && !it.pref.locked && it.count > 0 }.take(12).map { CategoryTile(ContentKind.SERIES, it) })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val order: List<String> get() = c.ui.homeOrder(DEFAULT_ORDER)

    fun nowPlayingCatalogReady() = c.library.sourceIds.value.isNotEmpty()

    private fun remaining(p: WatchProgress): String {
        val left = ((p.durationMs - p.positionMs) / 60000).toInt().coerceAtLeast(0)
        return if (left >= 1) "${left}m left" else "Almost done"
    }

    companion object { val DEFAULT_ORDER = listOf("continue", "live", "favorites", "later", "movies", "series", "categories") }
}
