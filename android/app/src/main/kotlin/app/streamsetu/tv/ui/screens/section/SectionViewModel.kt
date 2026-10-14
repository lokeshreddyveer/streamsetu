package app.streamsetu.tv.ui.screens.section

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.sync.SyncService.MovieInfo
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.BannerItem
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
    override fun toggleLocked(f: Folder) { viewModelScope.launch { c.folders.toggleLocked(kind, f) } }
    override fun rename(f: Folder, alias: String?) { viewModelScope.launch { c.folders.setAlias(kind, f, alias) } }
    override fun move(f: Folder, delta: Int) { viewModelScope.launch { c.folders.move(kind, folders.value, f, delta) } }
    override fun restoreOrder() { viewModelScope.launch { c.folders.restoreDefaultOrder(kind) } }
    override fun isUnlocked(folderId: String) = c.folders.isUnlocked(folderId)
    override val hasPin: Boolean get() = c.parental.hasPin
    override fun checkPin(pin: String) = c.parental.checkPin(pin)
    override fun setPin(pin: String) = c.parental.setPin(pin)
    override fun unlock(folderId: String) = c.folders.unlock(folderId)

}

/** What a poster shows, whether it stands for a movie or a series. */
data class Card(val id: String, val title: String, val posterUrl: String?, val year: Int?, val rating: String?, val sourceId: String, val movie: Movie? = null, val series: Series? = null)

data class ContentFilter(val sourceId: String? = null, val decade: Int? = null) {
    val active get() = sourceId != null || decade != null
    fun accepts(c: Card): Boolean = (sourceId == null || c.sourceId == sourceId) && (decade == null || (c.year != null && c.year / 10 * 10 == decade))
}

/**
 * The state of Movies or Series: which shortcut or folder is open, how it is sorted and filtered, and the lists shown. It lives with the screen's owner,
 * so the open folder is still there when the person comes back from a detail page.
 */
@OptIn(ExperimentalCoroutinesApi::class)
abstract class SectionViewModel(c: AppContainer, kind: ContentKind) : FolderViewModel(c, kind) {
    val browse = MutableStateFlow<Browse>(Browse.All)
    val filter = MutableStateFlow(ContentFilter())
    var scrollIndex = 0

    val sort: StateFlow<SortSpec> = browse.flatMapLatest { b -> c.browse.sort(kind, (b as? Browse.Folder)?.id) }.stateIn(viewModelScope, SharingStarted.Eagerly, SortSpec())
    val availability = MutableStateFlow(SortAvailability(false, false, false, false))
    val sources: StateFlow<List<LibraryEntry>> = c.library.entries.map { all -> all.filter { it.kind == LibraryEntry.Kind.CONNECTION && it.id.removePrefix("src:") in c.library.sourceIds.value } }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    protected abstract fun source(b: Browse, s: SortSpec): Flow<List<Card>>

    /** null while loading (a skeleton is shown), then the list. */
    val cards: StateFlow<List<Card>?> = combine(browse, sort) { b, s -> b to s }
        .flatMapLatest { (b, s) -> source(b, s).map<List<Card>, List<Card>?> { it }.onStart { emit(null) } }
        .combine(filter) { list, f -> if (f.active) list?.filter { f.accepts(it) } else list }
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

    init { viewModelScope.launch { availability.value = runCatching { c.browse.availability() }.getOrDefault(availability.value) } }

    fun select(b: Browse) { if (browse.value != b) { browse.value = b; scrollIndex = 0 } }
    fun applySort(spec: SortSpec) = c.browse.setSort(kind, (browse.value as? Browse.Folder)?.id, spec)
    fun toggle(id: String, list: String) = viewModelScope.launch {
        val on = (if (list == UserRepository.FAVOURITES) favourites else watchLater).value.contains(id)
        c.user.setFavourite(id, kind, !on, list)
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
    override fun source(b: Browse, s: SortSpec) = c.browse.movies(b, s).map { l -> l.map { Card(it.id, it.title, it.posterUrl, it.year, it.rating, it.sourceId, movie = it) } }

    override fun setWatched(card: Card, watched: Boolean) { viewModelScope.launch { c.user.setWatched(card.id, ContentKind.MOVIE, null, watched) } }

    override val banner: StateFlow<List<BannerItem>> = bannerSource().onEach { cards ->
        // The provider's own picture and story for the first few titles, fetched one at a time and kept.
        viewModelScope.launch { cards.take(6).forEach { card -> val m = card.movie ?: return@forEach; if (info.value[m.id] == null) { c.sync.movieInfo(m)?.let { i -> info.update { it + (m.id to i) } }; delay(150) } } }
    }.combine(info) { cards, infos ->
        cards.mapNotNull { card ->
            val m = card.movie ?: return@mapNotNull null
            val i = infos[m.id]
            BannerItem(m.id, m.title, listOfNotNull(i?.genre?.takeIf { it.isNotBlank() }, m.year?.toString(), i?.duration?.takeIf { it.isNotBlank() }, m.rating?.takeIf { it.isNotBlank() && it != "0" }?.let { "★ $it" }),
                (i?.plot ?: m.plot)?.takeIf { it.isNotBlank() }, i?.backdrop?.takeIf { it.isNotBlank() } ?: m.posterUrl, "Play")
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
}

@HiltViewModel
class SeriesSectionViewModel @Inject constructor(c: AppContainer) : SectionViewModel(c, ContentKind.SERIES) {
    override fun source(b: Browse, s: SortSpec) = c.browse.series(b, s).map { l -> l.map { Card(it.id, it.title, it.posterUrl, it.year, it.rating, it.sourceId, series = it) } }

    override fun setWatched(card: Card, watched: Boolean) {}

    override val banner: StateFlow<List<BannerItem>> = bannerSource().map { cards ->
        cards.mapNotNull { card ->
            val s = card.series ?: return@mapNotNull null
            BannerItem(s.id, s.title, listOfNotNull(s.year?.toString(), s.rating?.takeIf { it.isNotBlank() && it != "0" }?.let { "★ $it" }), s.plot?.takeIf { it.isNotBlank() }, s.backdropUrl?.takeIf { it.isNotBlank() } ?: s.posterUrl, "Episodes")
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
}
