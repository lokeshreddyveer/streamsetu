package app.streamsetu.tv.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.SearchResults
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import app.streamsetu.core.sync.upcoming

/** What the Home screen shows. */
class HomeViewModel(private val c: AppContainer) : ViewModel() {
    private val _featured = MutableStateFlow<List<Playable>>(emptyList())
    val featured: StateFlow<List<Playable>> = _featured
    // The mix is picked once the library has something in it (a playlist that was just read arrives after this screen opens).
    init { viewModelScope.launch { c.catalog.latestMovies(1).collect { if (_featured.value.isEmpty() && it.isNotEmpty()) { val f = runCatching { c.catalog.featured(6) }.onFailure { e -> android.util.Log.e("Featured", "failed", e) }.getOrDefault(emptyList()); android.util.Log.i("Featured", "picked ${f.size}"); _featured.value = f } } } }

    data class ResumeItem(val progress: WatchProgress, val playable: Playable)

    val continueWatching: StateFlow<List<ResumeItem>> = c.user.continueWatching().map { list ->
        list.mapNotNull { p ->
            val playable = when (p.kind) {
                ContentKind.MOVIE -> c.catalog.movie(p.itemId)?.let { MoviePlayable(it) }
                ContentKind.EPISODE -> c.catalog.episode(p.itemId)?.let { e -> c.catalog.series(e.seriesId)?.let { EpisodePlayable(e, it) } }
                else -> null
            }
            playable?.let { ResumeItem(p, it) }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val recentChannels: StateFlow<List<Channel>> = c.user.recentChannelIds(12).map { ids -> ids.mapNotNull { c.catalog.channel(it) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val yourChannels: StateFlow<List<Channel>> = c.user.mostWatchedChannelIds(12).map { ids -> ids.mapNotNull { c.catalog.channel(it) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val favourites: StateFlow<List<Channel>> = c.user.favouriteIds().map { ids -> ids.mapNotNull { c.catalog.channel(it) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val latestMovies: StateFlow<List<Movie>> = c.catalog.latestMovies(30).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val someSeries: StateFlow<List<Series>> = c.catalog.allSeries(30).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
}

@OptIn(ExperimentalCoroutinesApi::class)
class LiveViewModel(private val c: AppContainer) : ViewModel() {
    val categories: StateFlow<List<Category>> = combine(c.catalog.categories(ContentKind.CHANNEL), c.parental.hideAdult) { l, h -> l.filter { c.parental.visible(it, h) } }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val selected = MutableStateFlow<String?>(null)
    val selectedCategory: StateFlow<String?> = selected
    val favouriteIds: StateFlow<Set<String>> = c.user.favouriteIds().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptySet())

    val channels: StateFlow<List<Channel>> = combine(selected, categories) { s, cats -> s ?: cats.firstOrNull()?.id }.distinctUntilChanged()
        .flatMapLatest { id -> if (id == null) flowOf(emptyList()) else c.catalog.channels(id) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** What is on now, by guide id. */
    val nowOn: StateFlow<Map<String, EpgProgram>> = channels.map { list -> c.epg.nowFor(list.mapNotNull { it.epgId }) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    fun select(id: String) { selected.value = id }
    fun toggleFavourite(ch: Channel) = viewModelScope.launch { c.user.setFavourite(ch.id, ContentKind.CHANNEL, ch.id !in favouriteIds.value) }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MoviesViewModel(private val c: AppContainer) : ViewModel() {
    val categories: StateFlow<List<Category>> = combine(c.catalog.categories(ContentKind.MOVIE), c.parental.hideAdult) { l, h -> l.filter { c.parental.visible(it, h) } }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val selected = MutableStateFlow<String?>(null)
    val selectedCategory: StateFlow<String?> = selected
    val movies: StateFlow<List<Movie>> = combine(selected, categories) { s, cats -> s ?: cats.firstOrNull()?.id }.distinctUntilChanged()
        .flatMapLatest { id -> if (id == null) flowOf(emptyList()) else c.catalog.movies(id) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    fun select(id: String) { selected.value = id }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SeriesViewModel(private val c: AppContainer) : ViewModel() {
    val categories: StateFlow<List<Category>> = combine(c.catalog.categories(ContentKind.SERIES), c.parental.hideAdult) { l, h -> l.filter { c.parental.visible(it, h) } }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val selected = MutableStateFlow<String?>(null)
    val selectedCategory: StateFlow<String?> = selected
    val series: StateFlow<List<Series>> = combine(selected, categories) { s, cats -> s ?: cats.firstOrNull()?.id }.distinctUntilChanged()
        .flatMapLatest { id -> if (id == null) flowOf(emptyList()) else c.catalog.seriesIn(id) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    fun select(id: String) { selected.value = id }
}

class SeriesDetailViewModel(private val c: AppContainer, val series: Series) : ViewModel() {
    val episodes: StateFlow<List<Episode>> = c.catalog.episodes(series.id).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val _loading = MutableStateFlow(true)
    val loading: StateFlow<Boolean> = _loading
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error
    private val _progress = MutableStateFlow<Map<String, WatchProgress>>(emptyMap())
    val progress: StateFlow<Map<String, WatchProgress>> = _progress

    init {
        viewModelScope.launch {
            runCatching { c.sync.loadEpisodes(series) }.onFailure { _error.value = "The episodes could not be loaded. ${it.message.orEmpty()}" }
            _loading.value = false
            _progress.value = episodes.value.mapNotNull { e -> c.user.progress(e.id)?.let { e.id to it } }.toMap()
        }
    }
}

class SearchViewModel(private val c: AppContainer) : ViewModel() {
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query
    @OptIn(kotlinx.coroutines.FlowPreview::class)
    val results: StateFlow<SearchResults> = _query.debounce(250).mapLatest { c.catalog.search(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), SearchResults())
    fun setQuery(q: String) { _query.value = q }
}

class SettingsViewModel(private val c: AppContainer) : ViewModel() {
    val sources: StateFlow<List<Source>> = c.sources.sources.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message

    fun sync(s: Source) = viewModelScope.launch {
        _message.value = "Reading ${s.name}…"
        _message.value = runCatching { c.syncWithGuide(s.id) }
            .map { "Read ${it.channels} channels, ${it.movies} movies and ${it.series} series." }
            .getOrElse { it.message ?: "The playlist could not be read." }
    }
    fun remove(s: Source) = viewModelScope.launch { c.sources.remove(s.id); _message.value = "${s.name} was removed." }
}

class AddPlaylistViewModel(private val c: AppContainer) : ViewModel() {
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy
    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message

    /** Saves the playlist and reads it. Calls [done] when it worked. */
    fun add(type: SourceType, name: String, address: String, user: String, password: String, done: () -> Unit) {
        viewModelScope.launch {
            _busy.value = true; _message.value = null
            val saved = c.sources.add(
                Source(id = "", name = name.ifBlank { address.substringAfter("://").substringBefore('/').take(30) }, type = type,
                    address = address.trim(), username = user.trim().ifBlank { null }),
                password.ifBlank { null },
            )
            runCatching { c.syncWithGuide(saved.id) }
                .onSuccess { _busy.value = false; done() }
                .onFailure { c.sources.remove(saved.id); _busy.value = false; _message.value = it.message ?: "The playlist could not be read." }
        }
    }
}

class FavouritesViewModel(private val c: AppContainer) : ViewModel() {
    val channels: StateFlow<List<Channel>> = c.user.favouriteIds().map { ids -> ids.mapNotNull { c.catalog.channel(it) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val watchLater: StateFlow<List<Movie>> = c.user.favouriteIds(app.streamsetu.core.data.repo.UserRepository.WATCH_LATER).map { ids -> ids.mapNotNull { c.catalog.movie(it) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    fun remove(ch: Channel) = viewModelScope.launch { c.user.setFavourite(ch.id, ContentKind.CHANNEL, false) }
}

class GuideViewModel(private val c: AppContainer) : ViewModel() {
    data class Row(val channel: Channel, val programmes: List<EpgProgram>)

    val rows: StateFlow<List<Row>> = c.catalog.allChannels(400).map { list ->
        list.filter { it.epgId != null }.take(200).map { ch -> Row(ch, c.epg.upcoming(c.db, ch.epgId!!)) }
            .filter { it.programmes.isNotEmpty() }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
}
