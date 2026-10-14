package app.streamsetu.tv.ui.screens.live

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.core.sync.upcoming
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.search.SearchContent
import app.streamsetu.tv.ui.screens.section.FolderViewModel
import app.streamsetu.tv.ui.theme.Tokens
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date
import javax.inject.Inject

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class LiveSectionViewModel @Inject constructor(c: AppContainer) : FolderViewModel(c, ContentKind.CHANNEL) {
    val browse = MutableStateFlow<Browse>(Browse.All)
    var scrollIndex = 0
    val sort: StateFlow<SortSpec> = browse.flatMapLatest { b -> c.browse.sort(ContentKind.CHANNEL, (b as? Browse.Folder)?.id) }.stateIn(viewModelScope, SharingStarted.Eagerly, SortSpec())
    val availability = MutableStateFlow(SortAvailability(false, false, false, false))
    val channels: StateFlow<List<Channel>?> = combine(browse, sort) { b, s -> b to s }
        .flatMapLatest { (b, s) -> c.browse.channels(b, s).map<List<Channel>, List<Channel>?> { it }.onStart { emit(null) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
    val favourites: StateFlow<Set<String>> = c.user.favouriteIds(UserRepository.FAVOURITES).stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    /** What is on now for the channels listed, refreshed once a minute. */
    val now: StateFlow<Map<String, EpgProgram>> = channels.flatMapLatest { list ->
        flow { while (true) { emit(list.orEmpty().mapNotNull { it.epgId }.distinct().take(300)); delay(60_000) } }
    }.mapLatest { ids -> if (ids.isEmpty()) emptyMap() else runCatching { c.epg.nowFor(ids, System.currentTimeMillis() - c.ui.epgOffsetMinutes.value * 60_000L) }.getOrDefault(emptyMap()) }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    init { viewModelScope.launch { availability.value = runCatching { c.browse.availability() }.getOrDefault(availability.value) } }

    fun select(b: Browse) { if (browse.value != b) { browse.value = b; scrollIndex = 0 } }
    fun applySort(spec: SortSpec) = c.browse.setSort(ContentKind.CHANNEL, (browse.value as? Browse.Folder)?.id, spec)
    fun toggleFavourite(ch: Channel) = viewModelScope.launch { c.user.setFavourite(ch.id, ContentKind.CHANNEL, ch.id !in favourites.value) }
    suspend fun programmes(ch: Channel): List<EpgProgram> = ch.epgId?.let { runCatching { c.epg.upcoming(c.db, it, 2) }.getOrDefault(emptyList()) }.orEmpty()
}

private fun timeText(ms: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

/**
 * Live TV, three columns: folders (20 %), channels (20 %) and the live picture (60 %).
 * Moving through folders and channels only browses. A stream starts when a channel is chosen (OK), and OK on the picture opens it fullscreen.
 * Back from fullscreen returns here with the same folder, channel and place in the list; the preview keeps playing.
 */
@Composable
fun LiveScreen(vm: LiveSectionViewModel, c: AppContainer, nav: Navigator) {
    val folders by vm.folders.collectAsState()
    val browse by vm.browse.collectAsState()
    val channels by vm.channels.collectAsState()
    val sort by vm.sort.collectAsState()
    val avail by vm.availability.collectAsState()
    val now by vm.now.collectAsState()
    val favs by vm.favourites.collectAsState()
    val current by c.playback.current.collectAsState()
    val state by c.playback.state.collectAsState()
    val entry = LocalContentEntry.current ?: remember { FocusRequester() }
    val showNumbers by c.settings.showChannelNumbers.collectAsState()
    val listState = rememberLazyListState(vm.scrollIndex)
    LaunchedEffect(listState) { snapshotFlow { listState.firstVisibleItemIndex }.collect { vm.scrollIndex = it } }
    var sortOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<Channel?>(null) }
    var inChannels by remember { mutableStateOf(false) }
    var inPreview by remember { mutableStateOf(false) }
    val channelEntry = remember { FocusRequester() }
    val previewEntry = remember { FocusRequester() }
    val live = current?.takeIf { it.isLive } as? ChannelPlayable
    val fullscreen = nav.top == Overlay.Player

    // Leaving Live TV releases the stream (a provider may allow only one connection).
    DisposableEffect(Unit) { onDispose { if (c.playback.current.value?.isLive == true && nav.top != Overlay.Player) c.playback.stop() } }
    // "Open Live TV on the last channel" (off by default): nothing starts by itself unless the person asked for it.
    LaunchedEffect(Unit) { if (c.settings.resumeLastChannel.value && c.playback.current.value == null) c.settings.lastChannelId?.let { id -> c.catalog.channel(id)?.let { ch -> c.play(ChannelPlayable(ch), listOf(ChannelPlayable(ch))) } } }
    LaunchedEffect(Unit) { nav.pendingFolder?.takeIf { it.first == ContentKind.CHANNEL }?.let { vm.select(Browse.Folder(it.second)); nav.pendingFolder = null } }

    val shortcuts = listOf(
        Shortcut(Browse.All, "All Channels", Icons.Filled.LiveTv), Shortcut(Browse.Favorites, "Favorites", Icons.Filled.Favorite), Shortcut(Browse.Recent, "Recently Watched", Icons.Filled.History),
    ) + if (folders.any { it.pref.favorite }) listOf(Shortcut(Browse.FavoriteFolders, "Favorite Folders", Icons.Filled.Star)) else emptyList()

    BackHandler(enabled = inChannels || inPreview) { runCatching { entry.requestFocus() } }

    fun choose(ch: Channel) {
        if (live?.channel?.id == ch.id) { nav.liveFullscreen = true; nav.open(Overlay.Player); return }
        c.play(ChannelPlayable(ch), channels.orEmpty().map { ChannelPlayable(it) })
    }

    Row(Modifier.fillMaxSize()) {
        FolderPanel("Live TV", shortcuts, folders, browse, vm::select, vm, Modifier.weight(0.2f), entry = entry, selectOnDwell = c.settings.foldersOpenOnFocus.collectAsState().value, onRight = { runCatching { channelEntry.requestFocus() }.isSuccess })

        // Channels
        Column(Modifier.weight(0.2f).fillMaxHeight().background(Tokens.surface).onFocusChanged { inChannels = it.hasFocus }.padding(top = Tokens.safeVertical)) {
            Row(Modifier.padding(horizontal = 10.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Label(if (browse is Browse.Folder) folders.firstOrNull { it.id == (browse as Browse.Folder).id }?.title ?: "Channels" else shortcuts.firstOrNull { it.browse == browse }?.label ?: "Channels", Tokens.heading, Tokens.text, FontWeight.Bold)
                    Label(channels?.let { "%,d channels".format(it.size) } ?: "Loading…", Tokens.caption, Tokens.textSecondary)
                }
                SmallIcon(Icons.Filled.Search, "Search channels") { searchOpen = true }
                SmallIcon(Icons.Filled.SwapVert, "Sort channels") { sortOpen = true }
            }
            val list = channels
            when {
                list == null -> LazyColumn(Modifier.fillMaxSize(), userScrollEnabled = false) { items(14) { Box(Modifier.padding(8.dp).fillMaxWidth().height(34.dp).background(Tokens.card, RoundedCornerShape(8.dp))) } }
                list.isEmpty() -> Box(Modifier.fillMaxSize().padding(12.dp), Alignment.Center) { Label(if (browse == Browse.Favorites) "No favorite channels yet. Hold OK on a channel to add one." else "No channels here.", Tokens.small, Tokens.textSecondary, maxLines = 4) }
                else -> LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(horizontal = 6.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    items(list.size, key = { list[it].id }) { i ->
                        val ch = list[i]
                        val playing = live?.channel?.id == ch.id
                        Focusable({ choose(ch) }, (if (i == 0) Modifier.focusRequester(channelEntry) else Modifier).fillMaxWidth(), scaleOnFocus = 1.0f, container = if (playing) Tokens.elevated else Tokens.card.copy(alpha = 0f), shape = RoundedCornerShape(8.dp), onLongClick = { menuFor = ch }) { f ->
                            Row(Modifier.padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                ChannelLogo(ch.logoUrl, ch.name, 26.dp)
                                Column(Modifier.weight(1f)) {
                                    Label((if (showNumbers) ch.number?.let { "$it  " } else null).orEmpty() + ch.name, Tokens.row, if (playing) Tokens.accent else Tokens.text, FontWeight.Medium, maxLines = 2)
                                    ch.epgId?.let { id -> now[id] }?.let { p -> Label(p.title, Tokens.caption, Tokens.textSecondary) }
                                }
                                if (ch.id in favs) Image(Icons.Filled.Favorite, null, Modifier.size(11.dp), colorFilter = ColorFilter.tint(Tokens.accent))
                            }
                        }
                    }
                }
            }
        }

        // Preview
        Column(Modifier.weight(0.6f).fillMaxHeight().padding(start = 14.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 20.dp).onFocusChanged { inPreview = it.hasFocus }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Focusable({ if (live != null) { nav.liveFullscreen = true; nav.open(Overlay.Player) } }, Modifier.fillMaxWidth().aspectRatio(16f / 9f).focusRequester(previewEntry), scaleOnFocus = 1.0f, container = Tokens.surface, shape = RoundedCornerShape(Tokens.radiusLarge)) { _ ->
                if (live != null) EngineSurface(c, Modifier.fillMaxSize(), active = !fullscreen)
                Box(Modifier.fillMaxSize(), Alignment.Center) {
                    when (val st = state) {
                        PlaybackState.Resolving, PlaybackState.Buffering -> if (live != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { Spinner(); Label("Loading…", Tokens.small, Tokens.textSecondary) }
                        is PlaybackState.Retrying -> Label("Trying again…", Tokens.small, Tokens.textSecondary)
                        is PlaybackState.Failed -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) { Label("This channel did not play", Tokens.heading, Tokens.text, FontWeight.SemiBold); Label(st.error.message, Tokens.small, Tokens.textSecondary, maxLines = 2); Label("Press OK on the channel to try again.", Tokens.caption, Tokens.textTertiary) }
                        else -> if (live == null) Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) { Image(Icons.Filled.LiveTv, null, Modifier.size(34.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary)); Label("Choose a channel to watch", Tokens.heading, Tokens.textSecondary) }
                    }
                }
                if (live != null) Box(Modifier.align(Alignment.TopStart).padding(8.dp).background(Tokens.danger, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp)) { Label("LIVE", Tokens.caption, androidx.compose.ui.graphics.Color.White, FontWeight.Bold) }
            }
            if (live != null) NowNext(live.channel, vm, c, nav)
        }
    }

    if (sortOpen) SortSheet(ContentKind.CHANNEL, sort, avail, onApply = vm::applySort, onClose = { sortOpen = false })
    if (searchOpen) androidx.compose.ui.window.Dialog(onDismissRequest = { searchOpen = false }, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val first = remember { FocusRequester() }
        LaunchedEffect(Unit) { delay(120); runCatching { first.requestFocus() } }
        Box(Modifier.fillMaxSize().background(Tokens.background).padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label("Search Channels", Tokens.display, Tokens.text, FontWeight.Bold)
                SearchContent(c, setOf(ContentKind.CHANNEL), Modifier.fillMaxSize(), entry = first, onChannel = { ch -> searchOpen = false; c.play(ChannelPlayable(ch), listOf(ChannelPlayable(ch))) }, onMovie = {}, onSeries = {})
            }
        }
    }
    menuFor?.let { ch ->
        ContextMenu(ch.name, null, listOf(
            MenuAction("Watch", Icons.Filled.PlayArrow) { choose(ch) },
            MenuAction("Watch fullscreen", Icons.Filled.Fullscreen) { c.play(ChannelPlayable(ch), channels.orEmpty().map { ChannelPlayable(it) }); nav.liveFullscreen = true; nav.open(Overlay.Player) },
            MenuAction(if (ch.id in favs) "Remove from Favorites" else "Add to Favorites", Icons.Filled.Favorite) { vm.toggleFavourite(ch) },
        ), onClose = { menuFor = null })
    }
}

@Composable
private fun SmallIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Focusable(onClick, Modifier.padding(start = 4.dp), shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.08f) { f ->
        Image(icon, label, Modifier.padding(6.dp).size(14.dp), colorFilter = ColorFilter.tint(if (f) Tokens.accent else Tokens.textSecondary))
    }
}

/** The name, what is on, what is next, and a progress bar, only when the guide really has the data. */
@Composable
private fun NowNext(ch: Channel, vm: LiveSectionViewModel, c: AppContainer, nav: Navigator) {
    var programmes by remember(ch.id) { mutableStateOf<List<EpgProgram>>(emptyList()) }
    var tick by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val shift = c.ui.epgOffsetMinutes.collectAsState().value * 60_000L
    LaunchedEffect(ch.id, shift) { while (true) { programmes = vm.programmes(ch).map { it.copy(startMs = it.startMs + shift, endMs = it.endMs + shift) }; tick = System.currentTimeMillis(); delay(30_000) } }
    val nowP = programmes.firstOrNull { it.isLive(tick) }
    val next = programmes.firstOrNull { it.startMs >= (nowP?.endMs ?: tick) }
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        ChannelLogo(ch.logoUrl, ch.name, 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Label(ch.name, Tokens.title, Tokens.text, FontWeight.Bold)
            if (nowP != null) {
                Label("${nowP.title}  ·  ${timeText(nowP.startMs)} – ${timeText(nowP.endMs)}", Tokens.body, Tokens.text, maxLines = 1)
                val f = ((tick - nowP.startMs).toFloat() / (nowP.endMs - nowP.startMs)).coerceIn(0f, 1f)
                Box(Modifier.fillMaxWidth().height(3.dp).background(Tokens.elevated, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(f).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
                nowP.description?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.small, Tokens.textSecondary, maxLines = 2) }
                next?.let { Label("Next  ·  ${it.title}  ·  ${timeText(it.startMs)}", Tokens.small, Tokens.textSecondary, maxLines = 1) }
            } else Label(if (ch.epgId == null) "No guide information for this channel." else "No guide information right now.", Tokens.small, Tokens.textTertiary)
        }
        TvButton("Fullscreen", { nav.liveFullscreen = true; nav.open(Overlay.Player) }, icon = Icons.Filled.Fullscreen)
    }
}
