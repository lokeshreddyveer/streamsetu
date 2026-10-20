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
    fun kind(): String = when (this) { is Ch -> "c"; is Mv -> "m"; is Sr -> "s" }
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
    val banner: StateFlow<List<BannerItem>> = combine(featured, info, c.user.favouriteIds(UserRepository.FAVOURITES)) { list, infos, favs ->
        // Titles with a picture first, then favorites; a title that comes from two connections is one slide.
        list.distinctBy { app.streamsetu.core.data.repo.SearchText.normalize(it.title) }.mapNotNull { p ->
            when (p) {
                is MoviePlayable -> { val m = p.movie; val i = infos[m.id]
                    BannerItem(m.id, m.title, listOfNotNull(i?.genre?.takeIf { it.isNotBlank() }, m.year?.toString(), i?.duration?.takeIf { it.isNotBlank() }), (i?.plot ?: m.plot)?.takeIf { it.isNotBlank() },
                        i?.backdrop?.takeIf { it.isNotBlank() } ?: m.posterUrl, "Play") }
                is SeriesFeature -> { val s = p.series
                    BannerItem(s.id, s.title, listOfNotNull(s.year?.toString(), s.rating?.takeIf { it.isNotBlank() && it != "0" }?.let { "★ $it" }), s.plot?.takeIf { it.isNotBlank() }, s.backdropUrl?.takeIf { it.isNotBlank() } ?: s.posterUrl, "Episodes") }
                else -> null
            }
        }
    }.map { items -> items.sortedByDescending { !it.imageUrl.isNullOrBlank() } }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    fun playableFor(bannerId: String): Playable? = featured.value.firstOrNull { it.id == bannerId }

    val favouriteIds: StateFlow<Set<String>> = c.user.favouriteIds(UserRepository.FAVOURITES).stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())
    val hiddenRows: StateFlow<Set<String>> = c.ui.homeHidden
    val shortcutOrder: List<String> get() = c.ui.shortcutOrder("HOME", listOf("favorites", "later", "recent", "continue"))
    fun moveShortcut(name: String, delta: Int) {
        val l = shortcutOrder.toMutableList(); val i = l.indexOf(name); val j = i + delta
        if (i < 0 || j !in l.indices) return
        l.removeAt(i); l.add(j, name); c.ui.setShortcutOrder("HOME", l)
    }
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

    /** Tonight: favourite channels with something on now or starting within four hours, soonest first, each with what it is ("Now · Match" or "21:30 · News"). */
    val tonight: StateFlow<List<LiveItem>> = combine(c.user.favouriteIds(UserRepository.FAVOURITES), c.library.sourceIds) { ids, lib -> ids to lib }.mapLatest { (ids, lib) ->
        val now = System.currentTimeMillis(); val limit = now + 4 * 3_600_000L
        val clock = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT)
        val channels = ids.toList().mapNotNull { c.catalog.channel(it) }.filter { it.sourceId in lib }.take(60)
        val guide = runCatching { c.epg.resolve(channels) }.getOrDefault(emptyMap())
        channels.mapNotNull { ch ->
            val epgId = guide[ch.id] ?: return@mapNotNull null
            val p = runCatching { c.epg.upcoming(c.db, epgId, 2) }.getOrDefault(emptyList()).firstOrNull { it.endMs > now && it.startMs < limit } ?: return@mapNotNull null
            (if (p.isLive(now)) 0L else p.startMs) to LiveItem(ch, (if (p.isLive(now)) "Now" else clock.format(java.util.Date(p.startMs))) + " · " + p.title)
        }.sortedBy { it.first }.map { it.second }.take(14)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val favourites: StateFlow<List<FavItem>> = combine(c.user.favouriteIds(UserRepository.FAVOURITES), c.library.sourceIds) { ids, lib -> ids to lib }.mapLatest { (ids, lib) ->
        val list = ids.toList()
        val ch = list.mapNotNull { c.catalog.channel(it) }.filter { it.sourceId in lib }.map { FavItem.Ch(it) }
        val mv = c.catalog.moviesByIds(list).filter { it.sourceId in lib }.map { FavItem.Mv(it) }
        val sr = c.catalog.seriesByIds(list).filter { it.sourceId in lib }.map { FavItem.Sr(it) }
        val order = list.withIndex().associate { it.value to it.index }
        (ch + mv + sr).sortedBy { order[it.id] }.distinctBy { it.kind() + app.streamsetu.core.data.repo.SearchText.normalize(it.title) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val watchLater: StateFlow<List<FavItem>> = combine(c.user.favouriteIds(UserRepository.WATCH_LATER), c.library.sourceIds) { ids, lib -> ids to lib }.mapLatest { (ids, lib) ->
        val list = ids.toList(); val order = list.withIndex().associate { it.value to it.index }
        (list.mapNotNull { c.catalog.channel(it) }.filter { it.sourceId in lib }.map { FavItem.Ch(it) } + c.catalog.moviesByIds(list).filter { it.sourceId in lib }.map { FavItem.Mv(it) } + c.catalog.seriesByIds(list).filter { it.sourceId in lib }.map { FavItem.Sr(it) })
            .sortedBy { order[it.id] }.distinctBy { it.kind() + app.streamsetu.core.data.repo.SearchText.normalize(it.title) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val recentMovies: StateFlow<List<Movie>> = c.browse.movies(Browse.RecentlyAdded, SortSpec(SortField.ADDED), 30).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val recentSeries: StateFlow<List<Series>> = c.browse.series(Browse.RecentlyAdded, SortSpec(SortField.ADDED), 30).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val collections: StateFlow<List<UserCollection>> = combine(c.collections.collections(ContentKind.MOVIE), c.collections.collections(ContentKind.SERIES)) { m, s -> m + s }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val categories: StateFlow<List<CategoryTile>> = combine(c.folders.folders(ContentKind.MOVIE), c.folders.folders(ContentKind.SERIES)) { m, s ->
        (m.filter { !it.pref.hidden && !it.pref.locked && it.count > 0 }.take(12).map { CategoryTile(ContentKind.MOVIE, it) } + s.filter { !it.pref.hidden && !it.pref.locked && it.count > 0 }.take(12).map { CategoryTile(ContentKind.SERIES, it) })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** Everything watched lately, whatever it is, newest first (the "Recently Watched" shortcut). */
    val recentWatched: StateFlow<List<FavItem>> = combine(c.user.history(120), c.library.sourceIds) { log, lib -> log to lib }.mapLatest { (log, lib) ->
        val seen = HashSet<String>(); val out = ArrayList<FavItem>()
        for (h in log) {
            val item: FavItem? = when (h.kind) {
                "CHANNEL" -> c.catalog.channel(h.itemId)?.takeIf { it.sourceId in lib }?.let { FavItem.Ch(it) }
                "MOVIE" -> c.catalog.movie(h.itemId)?.takeIf { it.sourceId in lib }?.let { FavItem.Mv(it) }
                "EPISODE" -> c.catalog.episode(h.itemId)?.let { e -> c.catalog.series(e.seriesId)?.takeIf { it.sourceId in lib }?.let { FavItem.Sr(it) } }
                else -> null
            }
            if (item != null && seen.add(item.id)) out += item
            if (out.size >= 60) break
        }
        out
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** The row "For You": titles like the last few things watched, and the names of those, for the line under the heading. */
    data class ForYou(val items: List<FavItem>, val because: String)

    /** Never anything already watched, one entry for each film however many copies the library holds, and nothing until there is enough to go on. */
    val forYou: StateFlow<ForYou?> = recentWatched.mapLatest { watched ->
        val seeds = watched.filter { it !is FavItem.Ch }.take(4)
        if (seeds.isEmpty()) return@mapLatest null
        val seen = watched.map { it.id }.toSet()
        val lists = seeds.map { seed ->
            when (seed) {
                is FavItem.Mv -> c.search.similarMovies(seed.movie, null) { null }.first().filter { it.reason != "Same language" }.map { FavItem.Mv(it.item) as FavItem }
                is FavItem.Sr -> c.search.similarSeries(seed.series).filter { it.reason != "Same language" }.map { FavItem.Sr(it.item) as FavItem }
                else -> emptyList()
            }.filter { it.id !in seen }.toMutableList()
        }
        val out = ArrayList<FavItem>(); val keys = HashSet<String>()
        while (out.size < 14 && lists.any { it.isNotEmpty() }) {
            for (l in lists) {
                if (l.isEmpty() || out.size >= 14) continue
                val item = l.removeAt(0)
                val year = when (item) { is FavItem.Mv -> item.movie.year; is FavItem.Sr -> item.series.year; else -> null }
                if (keys.add(app.streamsetu.core.data.repo.Similarity.stem(item.title) + "|" + (year ?: 0))) out += item
            }
        }
        if (out.size < 6) null else ForYou(out, seeds.take(2).joinToString(", ") { "“${it.title}”" })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    /** The row "More with …": the person in the most of what was watched lately (at least two titles), and their other titles here. */
    data class MoreWith(val name: String, val items: List<FavItem>, val titles: Int)

    val moreWith: StateFlow<MoreWith?> = recentWatched.mapLatest { watched ->
        val titles = watched.filter { it !is FavItem.Ch }.take(12)
        val ids = titles.map { it.id }
        val names = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { app.streamsetu.core.data.db.PeopleIndex.names(c.db.openHelper.readableDatabase, ids) }
        val (name, n) = app.streamsetu.core.data.repo.FavouritePerson.pick(names) ?: return@mapLatest null
        val seen = ids.toSet()
        val words = app.streamsetu.core.data.db.PeopleIndex.let { name.lowercase().split(Regex("\\s+")).filter { w -> w.isNotEmpty() } }
        val hits = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            app.streamsetu.core.data.db.PeopleIndex.hits(c.db.openHelper.readableDatabase, words, c.library.sourceIds.value.toList(), listOf("MOVIE", "SERIES"), 40)
        }
        val keys = HashSet<String>(); val out = ArrayList<FavItem>()
        for (h in hits) {
            if (h.itemId in seen) continue
            val item: FavItem? = if (h.kind == "SERIES") c.catalog.series(h.itemId)?.let { FavItem.Sr(it) } else c.catalog.movie(h.itemId)?.let { FavItem.Mv(it) }
            val year = when (item) { is FavItem.Mv -> item.movie.year; is FavItem.Sr -> item.series.year; else -> null }
            if (item != null && keys.add(app.streamsetu.core.data.repo.Similarity.stem(item.title) + "|" + (year ?: 0))) out += item
            if (out.size >= 14) break
        }
        if (out.size < 4) null else MoreWith(name, out, n)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val order: List<String> get() = visibleRows(c.ui.homeOrder(DEFAULT_ORDER), hiddenRows.value)

    // ---- Actions behind the long-press menu (the screen only passes typed identities in) ----
    /** The same title from every connection of the open library (a title in two connections is one title to the person). Channels and other kinds stand alone. */
    private suspend fun logicalIds(id: String, kind: ContentKind): List<String> = when (kind) {
        ContentKind.MOVIE -> c.catalog.movie(id)?.let { m -> (c.search.movieVariants(m.title).map { it.id } + id).distinct() } ?: listOf(id)
        ContentKind.SERIES -> c.catalog.series(id)?.let { s -> (c.search.seriesVariants(s.title).map { it.id } + id).distinct() } ?: listOf(id)
        else -> listOf(id)
    }
    fun setFavorite(id: String, kind: ContentKind, on: Boolean) = viewModelScope.launch { logicalIds(id, kind).forEach { c.user.setFavourite(it, kind, on) }; app.streamsetu.tv.UISound.play(if (on) app.streamsetu.tv.UISoundEvent.FAVORITE_ADD else app.streamsetu.tv.UISoundEvent.FAVORITE_REMOVE) }
    fun moveFavorite(id: String, kind: ContentKind, toFront: Boolean) = viewModelScope.launch { logicalIds(id, kind).forEach { c.user.moveFavourite(it, toFront) } }
    fun setWatchLater(id: String, kind: ContentKind, on: Boolean) = viewModelScope.launch { logicalIds(id, kind).forEach { c.user.setFavourite(it, kind, on, UserRepository.WATCH_LATER) }; app.streamsetu.tv.UISound.play(if (on) app.streamsetu.tv.UISoundEvent.WATCH_LATER_ADD else app.streamsetu.tv.UISoundEvent.WATCH_LATER_REMOVE) }
    fun setWatched(id: String, kind: ContentKind, seriesId: String?, watched: Boolean) = viewModelScope.launch { c.user.setWatched(id, kind, seriesId, watched) }
    /** Takes a title out of Continue Watching: only its resume point goes; watch history stays. */
    fun removeFromContinue(id: String) = viewModelScope.launch { c.user.clearResumePoint(id) }
    fun removeFromRecent(id: String) = viewModelScope.launch { c.user.removeFromRecent(id) }
    fun toggleFolderFavorite(t: CategoryTile) = viewModelScope.launch { c.folders.toggleFavorite(t.kind, t.folder) }
    fun toggleFolderPinned(t: CategoryTile) = viewModelScope.launch { c.folders.togglePinned(t.kind, t.folder) }
    fun hideFolder(t: CategoryTile) = viewModelScope.launch { c.folders.toggleHidden(t.kind, t.folder) }
    suspend fun movieVariants(m: Movie) = c.search.movieVariants(m.title)
    suspend fun seriesVariants(s: Series) = c.search.seriesVariants(s.title)
    /** The episodes of a series in order, the one to play next, and whether every episode is finished. Reads the episode list from the provider if it is not stored yet. */
    suspend fun seriesPlan(series: Series): Triple<List<EpisodePlayable>, EpisodePlayable?, Boolean> {
        var eps = c.catalog.episodesOnce(series.id)
        if (eps.isEmpty()) { runCatching { c.sync.loadEpisodes(series) }; eps = c.catalog.episodesOnce(series.id) }
        val progress = c.user.allProgress().first().filterValues { it.seriesId == series.id }
        val plan = app.streamsetu.core.data.repo.EpisodePlan.of(eps, progress)
        val queue = eps.sortedWith(compareBy({ it.season }, { it.number })).map { EpisodePlayable(it, series) }
        val next = (plan.inProgress ?: plan.forward)?.takeIf { !plan.allFinished || plan.inProgress != null }?.let { EpisodePlayable(it, series) }
        return Triple(queue, next, plan.allFinished)
    }
    fun setSeriesWatched(series: Series, watched: Boolean) = viewModelScope.launch {
        var eps = c.catalog.episodesOnce(series.id)
        if (eps.isEmpty()) { runCatching { c.sync.loadEpisodes(series) }; eps = c.catalog.episodesOnce(series.id) }
        eps.forEach { c.user.setWatched(it.id, ContentKind.EPISODE, series.id, watched) }
    }
    suspend fun hasGuide(ch: Channel): Boolean = runCatching { c.epg.resolve(listOf(ch))[ch.id] != null }.getOrDefault(false)
    suspend fun progressOf(id: String): WatchProgress? = c.user.progress(id)

    fun nowPlayingCatalogReady() = c.library.sourceIds.value.isNotEmpty()

    private fun remaining(p: WatchProgress): String {
        val left = ((p.durationMs - p.positionMs) / 60000).toInt().coerceAtLeast(0)
        return if (left >= 1) "${left}m left" else "Almost done"
    }

    companion object { val DEFAULT_ORDER = listOf("continue", "live", "favorites", "later", "foryou", "movies", "series", "categories") }
}
