package app.streamsetu.tv.ui.screens.section

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.sync.SyncService.MovieInfo
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.BannerItem
import app.streamsetu.tv.ui.components.Facts
import app.streamsetu.tv.ui.components.FolderActions
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Folder state and actions shared by Movies, Series and Live TV. */
@OptIn(ExperimentalCoroutinesApi::class)
abstract class FolderViewModel(protected val c: AppContainer, val kind: ContentKind) : ViewModel(), FolderActions {
    val folders: StateFlow<List<Folder>> = c.folders.folders(kind).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    // ---- Folder actions (FolderActions) ----
    override fun toggleFavorite(f: Folder) { viewModelScope.launch { c.folders.toggleFavorite(kind, f) } }
    override fun togglePinned(f: Folder) { viewModelScope.launch { c.folders.togglePinned(kind, f) } }
    override fun toggleHidden(f: Folder) { viewModelScope.launch { c.folders.toggleHidden(kind, f) } }
    override fun toggleLocked(f: Folder) { viewModelScope.launch { c.folders.toggleLocked(kind, f); app.streamsetu.tv.UISound.play(if (f.pref.locked) app.streamsetu.tv.UISoundEvent.FOLDER_UNLOCK else app.streamsetu.tv.UISoundEvent.FOLDER_LOCK) } }
    override fun rename(f: Folder, alias: String?) { viewModelScope.launch { c.folders.setAlias(kind, f, alias) } }
    override fun move(f: Folder, to: app.streamsetu.core.data.repo.MoveTo) { viewModelScope.launch { c.folders.moveTo(kind, folders.value.filter { !it.pref.hidden }, f, to); app.streamsetu.tv.UISound.play(if (to == app.streamsetu.core.data.repo.MoveTo.FIRST) app.streamsetu.tv.UISoundEvent.FOLDER_MOVE_FIRST else app.streamsetu.tv.UISoundEvent.FOLDER_REORDER) } }
    override fun resetPosition(f: Folder) { viewModelScope.launch { c.folders.resetPosition(kind, f) } }
    override fun resetFolder(f: Folder) { viewModelScope.launch { c.folders.resetFolder(kind, f) } }
    override fun createFolder(name: String) { viewModelScope.launch { c.collections.create(name, kind) } }
    override fun restoreOrder() { viewModelScope.launch { c.folders.restoreDefaultOrder(kind) } }
    override fun isUnlocked(folderId: String) = c.folders.isUnlocked(folderId)
    override val hasPin: Boolean get() = c.parental.hasPin
    override fun checkPin(pin: String) = c.parental.checkPin(pin)
    override fun setPin(pin: String) = c.parental.setPin(pin)
    override fun unlock(folderId: String) = c.folders.unlock(folderId)

}

/** One horizontal row of the browsing page (Continue Watching, Favorites...). A row with nothing in it is not shown. */
data class Rail(val key: String, val title: String, val browse: Browse, val cards: List<Card>, val seeAll: Boolean = true)

/** What a poster shows, whether it stands for a movie or a series. */
data class Card(val id: String, val title: String, val posterUrl: String?, val year: Int?, val rating: String?, val sourceId: String, val movie: Movie? = null, val series: Series? = null)

/** How far along a title is, for the Status filter. */
enum class WatchStatus(val label: String) { UNWATCHED("Not watched"), IN_PROGRESS("Started"), WATCHED("Watched"), FAVORITES("Favorites"), NEW_EPISODES("New episodes") }

/** What the filter needs to know about the person's own lists to judge a title. */
data class FilterContext(
    val watched: Set<String> = emptySet(), val partial: Set<String> = emptySet(), val favourites: Set<String> = emptySet(), val newSeries: Set<String> = emptySet(),
    val folderNames: Map<String, String> = emptyMap(),
)

/** Everything the Filter sheet can narrow by. Each choice is kept only while the screen is open. */
data class ContentFilter(
    val sourceId: String? = null, val decade: Int? = null, val language: String? = null, val folderId: String? = null,
    val quality: String? = null, val minRating: Float? = null, val status: WatchStatus? = null,
) {
    val active get() = sourceId != null || decade != null || language != null || folderId != null || quality != null || minRating != null || status != null
    /** How many separate choices are made, for the badge on the Filter button. */
    val count get() = listOfNotNull(sourceId, decade, language, folderId, quality, minRating, status).size

    fun accepts(c: Card, ctx: FilterContext = FilterContext()): Boolean {
        if (sourceId != null && c.sourceId != sourceId) return false
        if (decade != null && (c.year == null || c.year / 10 * 10 != decade)) return false
        val categoryId = c.movie?.categoryId ?: c.series?.categoryId
        if (folderId != null && categoryId != folderId) return false
        if (language != null && app.streamsetu.core.data.repo.TitleLanguages.of(c.title, ctx.folderNames[categoryId]) != language) return false
        if (quality != null && quality !in app.streamsetu.core.data.repo.QualityBadges.from(listOf(c.title, ctx.folderNames[categoryId]), 9)) return false
        if (minRating != null && (c.rating?.toFloatOrNull() ?: 0f) < minRating) return false
        return when (status) {
            null -> true
            WatchStatus.UNWATCHED -> c.id !in ctx.watched && c.id !in ctx.partial
            WatchStatus.IN_PROGRESS -> c.id in ctx.partial
            WatchStatus.WATCHED -> c.id in ctx.watched
            WatchStatus.FAVORITES -> c.id in ctx.favourites
            WatchStatus.NEW_EPISODES -> c.id in ctx.newSeries
        }
    }
}

/** The choices the open list actually has, so the sheet never offers a language or a quality that would show nothing. Names are in alphabetical order. */
data class FilterOptions(val languages: List<String> = emptyList(), val qualities: List<String> = emptyList(), val folders: List<Pair<String, String>> = emptyList()) {
    companion object {
        fun of(cards: List<Card>, ctx: FilterContext): FilterOptions {
            val languages = sortedSetOf<String>(String.CASE_INSENSITIVE_ORDER); val qualities = sortedSetOf<String>(String.CASE_INSENSITIVE_ORDER); val folders = HashMap<String, String>()
            for (c in cards) {
                val categoryId = c.movie?.categoryId ?: c.series?.categoryId
                val folder = ctx.folderNames[categoryId]
                app.streamsetu.core.data.repo.TitleLanguages.of(c.title, folder)?.let { languages += it }
                qualities += app.streamsetu.core.data.repo.QualityBadges.from(listOf(c.title, folder), 9).filter { it in FILTER_QUALITIES }
                if (categoryId != null && folder != null) folders[categoryId] = folder
            }
            return FilterOptions(languages.toList(), FILTER_QUALITIES.filter { it in qualities }, folders.toList().sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.second }))
        }
        val FILTER_QUALITIES = listOf("4K", "1080p", "720p", "HDR", "Dolby Vision")
    }
}

/**
 * The state of Movies or Series: which shortcut or folder is open, how it is sorted and filtered, and the lists shown. It lives with the screen's owner,
 * so the open folder is still there when the person comes back from a detail page.
 */
@OptIn(ExperimentalCoroutinesApi::class)
abstract class SectionViewModel(c: AppContainer, kind: ContentKind) : FolderViewModel(c, kind) {
    companion object { const val PAGE = 90; const val FILTERED_LIMIT = 100_000 }
    val browse = MutableStateFlow<Browse>(Browse.All)
    val filter = MutableStateFlow(ContentFilter())
    var scrollIndex = 0

    val sort: StateFlow<SortSpec> = browse.flatMapLatest { b -> c.browse.sort(kind, (b as? Browse.Folder)?.id) }.stateIn(viewModelScope, SharingStarted.Eagerly, SortSpec.defaultFor(kind))
    val availability = MutableStateFlow(SortAvailability(false, false, false, false))
    val sources: StateFlow<List<LibraryEntry>> = c.library.entries.map { all -> all.filter { it.kind == LibraryEntry.Kind.CONNECTION && it.id.removePrefix("src:") in c.library.sourceIds.value } }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    protected abstract fun source(b: Browse, s: SortSpec, limit: Int, offset: Int = 0): Flow<List<Card>>

    /**
     * The titles shown, null while loading (a skeleton is shown). The first page is watched in the database (a change shows at once); the next pages are read once and added to the end
     * as the remote nears it, one request at a time, so a library of tens of thousands is all reachable and rows already shown are never rebuilt. With a filter on, the filter has to see
     * every title, so the whole list is read instead.
     */
    private val list = MutableStateFlow<List<Card>?>(null)
    private val unfiltered: StateFlow<List<Card>?> = list
    private var shownFor: Triple<Browse, SortSpec, Boolean>? = null
    private var more = true
    private var busy = false
    /** Counts every restart or re-read of the list, so a page still being read at that moment is thrown away. */
    private var generation = 0

    init {
        viewModelScope.launch {
            combine(browse, sort, filter.map { it.active }.distinctUntilChanged()) { b, s, active -> Triple(b, s, active) }
                .flatMapLatest { k -> source(k.first, k.second, if (k.third) FILTERED_LIMIT else PAGE).map { head -> k to head } }
                .collect { (k, head) ->
                    generation++; busy = false
                    val cur = list.value
                    val same = shownFor == k
                    if (!same || cur == null || k.third || app.streamsetu.core.data.repo.orderMoves(k.first, k.second) || cur.size <= PAGE) {
                        shownFor = k; more = !k.third && head.size >= PAGE
                        list.value = if (cur != null && same) reuse(cur, head) else head     // another folder or sort starts again; a change in the same list keeps unchanged cards
                    } else {
                        // Something changed in a stable order: the titles already loaded are read again once, keeping the cards that did not change.
                        val again = runCatching { source(k.first, k.second, cur.size, 0).first() }.getOrNull()
                        if (again != null) { list.value = reuse(cur, again); more = again.size >= cur.size }
                    }
                }
        }
    }

    private fun reuse(old: List<Card>, new: List<Card>): List<Card> { val byId = old.associateBy { it.id }; return new.map { n -> byId[n.id]?.takeIf { it == n } ?: n } }

    /** Reads the next page after the loaded titles and appends only titles not already shown. Ignored while a page is being read. */
    fun loadMore() {
        val k = shownFor ?: return
        if (busy || !more || k.third) return
        busy = true
        val g = generation
        viewModelScope.launch {
            try {
                val cur = list.value.orEmpty()
                val rows = runCatching { source(k.first, k.second, PAGE, cur.size).first() }.getOrNull() ?: return@launch
                if (g != generation) return@launch                    // the folder, sort or list changed while this page was being read
                val seen = cur.mapTo(HashSet()) { it.id }
                val fresh = rows.filter { it.id !in seen }
                list.value = cur + fresh; more = rows.size >= PAGE && fresh.isNotEmpty()
            } finally { busy = false }
        }
    }

    /** The person's own lists, which the Status filter reads. Filled in once those lists exist, below. */
    private val filterContext = MutableStateFlow(FilterContext())
    val filterOptions: StateFlow<FilterOptions> = combine(unfiltered, filterContext) { list, ctx -> FilterOptions.of(list.orEmpty(), ctx) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), FilterOptions())
    val cards: StateFlow<List<Card>?> = combine(unfiltered, filter, filterContext) { list, f, ctx -> if (f.active) list?.filter { f.accepts(it, ctx) } else list }
        .combine(c.collections.overrides) { list, ov -> if (ov.isEmpty()) list else list?.map { card -> ov[card.id]?.let { o -> card.copy(title = o.title ?: card.title, posterUrl = o.posterUrl ?: card.posterUrl) } ?: card } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val favourites: StateFlow<Set<String>> = c.user.favouriteIds(UserRepository.FAVOURITES).stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())
    val watchLater: StateFlow<Set<String>> = c.user.favouriteIds(UserRepository.WATCH_LATER).stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())
    /** Series with an episode that appeared after the person had started them. */
    val newSeries: StateFlow<Set<String>> = c.user.newEpisodes().map { l -> l.map { it.seriesId }.toSet() }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptySet())
    val collections: StateFlow<List<UserCollection>> = c.collections.collections(kind).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val overrides: StateFlow<Map<String, ItemOverride>> = c.collections.overrides.stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())
    fun createCollection(name: String, then: (String) -> Unit = {}) = viewModelScope.launch { then(c.collections.create(name, kind)) }
    fun renameCollection(col: UserCollection, name: String) = viewModelScope.launch { c.collections.rename(col, name) }
    fun deleteCollection(col: UserCollection) = viewModelScope.launch { c.collections.delete(col); if (browse.value == Browse.Collection(col.id)) select(Browse.All) }
    suspend fun containing(itemId: String) = c.collections.containing(itemId)
    fun addToCollection(col: String, itemId: String) = viewModelScope.launch { c.collections.add(col, itemId) }
    fun removeFromCollection(col: String, itemId: String) = viewModelScope.launch { c.collections.remove(col, itemId) }
    val progress: StateFlow<Map<String, WatchProgress>> = c.user.allProgress().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    /** For a series with an episode begun and not finished: "S2 E4 · 23 min left", shown on its poster in place of the year. */
    val seriesNote: StateFlow<Map<String, String>> = progress.mapLatest { all ->
        all.values.filter { it.seriesId != null && !it.completed && it.fraction > 0f }.groupBy { it.seriesId!! }.mapNotNull { (sid, list) ->
            val p = list.maxByOrNull { it.updatedAt } ?: return@mapNotNull null
            val ep = runCatching { c.catalog.episode(p.itemId) }.getOrNull() ?: return@mapNotNull null
            sid to "S${ep.season} E${ep.number}  ·  ${((p.durationMs - p.positionMs) / 60_000).coerceAtLeast(1)} min left"
        }.toMap()
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    init {
        viewModelScope.launch {
            combine(c.watchedTitles, c.partialTitles, favourites, newSeries, folders) { watched, partial, favs, news, folders ->
                FilterContext(watched, partial.keys, favs, news, folders.associate { it.id to it.title })
            }.collect { filterContext.value = it }
        }
    }

    init { viewModelScope.launch { availability.value = runCatching { c.browse.availability() }.getOrDefault(availability.value) } }

    // Another library was opened from this page: the folder, filter and place in the list belonged to the old one.
    init {
        viewModelScope.launch {
            c.library.sourceIds.drop(1).collect { browse.value = Browse.All; filter.value = ContentFilter(); scrollIndex = 0; focusedId = null; focusedIndex = 0; lastFolder = Browse.All }
        }
    }

    /** The id of the title the remote was on, and where it was in the list: coming back to this screen puts the remote on it again. */
    var focusedId: String? = null
    var focusedIndex = 0

    private val railDefs = listOf(
        Triple("continue", "Continue Watching", Browse.Continue), Triple("favorites", "Favorites", Browse.Favorites), Triple("later", "Watch Later", Browse.WatchLater),
        Triple("added", "Recently Added", Browse.RecentlyAdded), Triple("recent", "Recently Watched", Browse.Recent),
    )
    /** The rows above the full list, each a short sample (the first 24) of its list; empty ones are left out. */
    /** Rows only one kind has (Series: the ones with new episodes). */
    protected open fun extraRails(): Flow<List<Rail>> = flowOf(emptyList())
    val rails: StateFlow<List<Rail>> by lazy {
        combine(railDefs.map { (k, t, b) -> source(b, SortSpec.defaultFor(kind), 24).map { Rail(k, t, b, it) } }) { all -> all.filter { it.cards.isNotEmpty() } }
            .combine(extraRails()) { base, extra -> if (extra.isEmpty()) base else base.take(1) + extra + base.drop(1) }
            .combine(c.collections.overrides) { rows, ov -> if (ov.isEmpty()) rows else rows.map { r -> r.copy(cards = r.cards.map { card -> ov[card.id]?.let { o -> card.copy(title = o.title ?: card.title, posterUrl = o.posterUrl ?: card.posterUrl) } ?: card }) } }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    }

    /** The provider folder (or All) the person was last in, so leaving a shortcut returns there. */
    var lastFolder: Browse = Browse.All
    fun select(b: Browse) { if (browse.value != b) { if (b is Browse.Folder || b == Browse.All || b is Browse.Collection) lastFolder = b; browse.value = b; scrollIndex = 0 } }
    fun applySort(spec: SortSpec) = c.browse.setSort(kind, (browse.value as? Browse.Folder)?.id, spec)
    fun toggle(id: String, list: String) = viewModelScope.launch {
        val on = (if (list == UserRepository.FAVOURITES) favourites else watchLater).value.contains(id)
        // The title is saved or removed in every connection of the library that has it.
        val ids = when (kind) {
            ContentKind.MOVIE -> c.catalog.movie(id)?.let { m -> (c.search.movieVariants(m.title).map { it.id } + id).distinct() }
            ContentKind.SERIES -> c.catalog.series(id)?.let { s -> (c.search.seriesVariants(s.title).map { it.id } + id).distinct() }
            else -> null
        } ?: listOf(id)
        ids.forEach { c.user.setFavourite(it, kind, !on, list) }
        val fav = list == UserRepository.FAVOURITES
        app.streamsetu.tv.UISound.play(if (fav) (if (!on) app.streamsetu.tv.UISoundEvent.FAVORITE_ADD else app.streamsetu.tv.UISoundEvent.FAVORITE_REMOVE) else (if (!on) app.streamsetu.tv.UISoundEvent.WATCH_LATER_ADD else app.streamsetu.tv.UISoundEvent.WATCH_LATER_REMOVE))
    }
    abstract fun setWatched(card: Card, watched: Boolean)

    // ---- Shortcuts under the banner (their order is the person's) ----
    val defaultShortcuts = listOf("favorites", "later", "recent", "continue")
    val shortcutOrder = MutableStateFlow(c.ui.shortcutOrder(kind.name, defaultShortcuts))
    fun moveShortcut(name: String, delta: Int) {
        val l = shortcutOrder.value.toMutableList(); val i = l.indexOf(name); val j = i + delta
        if (i < 0 || j !in l.indices) return
        l.removeAt(i); l.add(j, name); shortcutOrder.value = l; c.ui.setShortcutOrder(kind.name, l)
    }

    // ---- Banner ----
    protected val info = MutableStateFlow<Map<String, MovieInfo>>(emptyMap())
    abstract val banner: StateFlow<List<BannerItem>>
    protected fun bannerSource(): Flow<List<Card>> = cards.map { list -> list.orEmpty().filter { !it.posterUrl.isNullOrBlank() }.take(10) }.distinctUntilChanged()
}

@HiltViewModel
class MoviesSectionViewModel @Inject constructor(c: AppContainer) : SectionViewModel(c, ContentKind.MOVIE) {
    override fun source(b: Browse, s: SortSpec, limit: Int, offset: Int) = c.browse.movies(b, s, limit, offset).map { l -> l.map { Card(it.id, it.title, it.posterUrl, it.year, it.rating, it.sourceId, movie = it) } }

    override fun setWatched(card: Card, watched: Boolean) { viewModelScope.launch { c.user.setWatched(card.id, ContentKind.MOVIE, null, watched) } }

    override val banner: StateFlow<List<BannerItem>> = bannerSource().onEach { cards ->
        // The provider's own picture and story for the first few titles, fetched one at a time and kept.
        viewModelScope.launch { cards.take(6).forEach { card -> val m = card.movie ?: return@forEach; if (info.value[m.id] == null) { c.sync.movieInfo(m)?.let { i -> info.update { it + (m.id to i) } }; delay(150) } } }
    }.combine(info) { cards, infos ->
        cards.mapNotNull { card ->
            val m = card.movie ?: return@mapNotNull null
            val i = infos[m.id]
            BannerItem(m.id, m.title, listOfNotNull(i?.genre?.takeIf { it.isNotBlank() }, m.year?.toString(), Facts.runtime(i?.duration), Facts.rating(m.rating)),
                (i?.plot ?: m.plot)?.takeIf { it.isNotBlank() }, i?.backdrop?.takeIf { it.isNotBlank() } ?: m.posterUrl, "Play", imageIsBackdrop = !i?.backdrop.isNullOrBlank())
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
}

@HiltViewModel
class SeriesSectionViewModel @Inject constructor(c: AppContainer) : SectionViewModel(c, ContentKind.SERIES) {
    override fun source(b: Browse, s: SortSpec, limit: Int, offset: Int) = c.browse.series(b, s, limit, offset).map { l -> l.map { Card(it.id, it.title, it.posterUrl, it.year, it.rating, it.sourceId, series = it) } }

    override fun setWatched(card: Card, watched: Boolean) {}

    override fun extraRails(): Flow<List<Rail>> = c.user.newEpisodes().map { list ->
        val cards = list.map { it.seriesId }.distinct().take(24).mapNotNull { id -> c.catalog.series(id) }.map { Card(it.id, it.title, it.posterUrl, it.year, it.rating, it.sourceId, series = it) }
        if (cards.isEmpty()) emptyList() else listOf(Rail("new", "New Episodes", Browse.All, cards, seeAll = false))
    }

    override val banner: StateFlow<List<BannerItem>> = bannerSource().map { cards ->
        cards.mapNotNull { card ->
            val s = card.series ?: return@mapNotNull null
            BannerItem(s.id, s.title, listOfNotNull(s.year?.toString(), Facts.rating(s.rating)), s.plot?.takeIf { it.isNotBlank() }, s.backdropUrl?.takeIf { it.isNotBlank() } ?: s.posterUrl, "Episodes", imageIsBackdrop = !s.backdropUrl.isNullOrBlank())
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
}
