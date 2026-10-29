package app.streamsetu.tv.ui.screens.live

import app.streamsetu.core.sync.ChannelGuide
import app.streamsetu.core.sync.channelGuide
import kotlinx.coroutines.flow.collectLatest
import app.streamsetu.tv.ui.theme.ui
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.focusable
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.core.sync.upcoming
import app.streamsetu.core.sync.programmeCount
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInWindow
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

/** One channel as the list shows it. When the same channel comes in several qualities or from several connections, [variants] holds them all and [rep] is the best one. */
data class ChannelGroup(val rep: Channel, val variants: List<Channel>)

private fun qualityRank(name: String): Int = when {
    Regex("(?i)\\b(4k|uhd)\\b").containsMatchIn(name) -> 4
    Regex("(?i)\\b(fhd|1080p?)\\b").containsMatchIn(name) -> 3
    Regex("(?i)\\bhd\\b|720p").containsMatchIn(name) -> 2
    Regex("(?i)\\bsd\\b").containsMatchIn(name) -> 0
    else -> 1
}
fun qualityLabel(name: String) = when (qualityRank(name)) { 4 -> "4K"; 3 -> "FHD"; 2 -> "HD"; 0 -> "SD"; else -> "Standard" }

fun groupChannels(list: List<Channel>): List<ChannelGroup> {
    val order = LinkedHashMap<String, MutableList<Channel>>()
    list.forEach { ch -> order.getOrPut(app.streamsetu.core.data.repo.SearchText.normalize(app.streamsetu.core.sync.stripQuality(ch.name))) { mutableListOf() } += ch }
    return order.values.map { v -> ChannelGroup(v.maxByOrNull { qualityRank(it.name) } ?: v.first(), v.sortedByDescending { qualityRank(it.name) }) }
}

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class LiveSectionViewModel @Inject constructor(c: AppContainer) : FolderViewModel(c, ContentKind.CHANNEL) {
    val browse = MutableStateFlow<Browse>(Browse.All)
    var scrollIndex = 0
    /** The channel the remote was on, so coming back to Live TV puts it there again. */
    var focusedChannelId: String? = null
    var focusedChannelIndex = 0
    val sort: StateFlow<SortSpec> = browse.flatMapLatest { b -> c.browse.sort(ContentKind.CHANNEL, (b as? Browse.Folder)?.id) }.stateIn(viewModelScope, SharingStarted.Eagerly, SortSpec())
    val availability = MutableStateFlow(SortAvailability(false, false, false, false))
    /** The channels shown. The first 150 are watched in the database (so a change shows at once); the next 150 are read and added to the end as the remote nears it, one request at a time. Rows already shown are kept as they are. */
    private val list = MutableStateFlow<List<Channel>?>(null)
    val channels: StateFlow<List<Channel>?> = list
    private var shownFor: Pair<Browse, SortSpec>? = null
    private var more = true
    private var busy = false
    /** Counts every time what is shown starts again or is read again, so a page that was still being read when that happened is thrown away, never added to the wrong list. */
    private var generation = 0
    private var restoreJob: kotlinx.coroutines.Job? = null
    /** True when the last page could not be read; the list ends with a Retry row. */
    val pageFailed = MutableStateFlow(false)
    /** True while a page is being read, for the small "Loading" row at the end. */
    val loadingMore = MutableStateFlow(false)
    /** All the channels the shortcut or folder holds, counted by the database and kept apart from the loaded rows. */
    val total: StateFlow<Int?> = browse.flatMapLatest { b -> c.browse.channelCount(b).map<Int, Int?> { it } }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    init {
        viewModelScope.launch {
            combine(browse, sort) { b, s -> b to s }.flatMapLatest { (b, s) -> c.browse.channels(b, s, PAGE).map { head -> Triple(b, s, head) } }.collect { (b, s, head) ->
                generation++; restoreJob?.cancel(); busy = false; loadingMore.value = false
                val cur = list.value
                val sameQuery = shownFor == b to s
                if (!sameQuery || cur == null || app.streamsetu.core.data.repo.orderMoves(b, s) || cur.size <= PAGE) {       // another folder, source or sort, or an order that moves: start again from the top
                    shownFor = b to s; more = head.size >= PAGE; pageFailed.value = false
                    list.value = if (cur != null && sameQuery) reuse(cur, head) else head
                } else {
                    // Something changed in a stable order: the rows already loaded are read again once, keeping the instances that did not change.
                    val again = runCatching { c.browse.channelPage(b, s, cur.size, 0) }.getOrNull()
                    if (again != null) { list.value = reuse(cur, again); more = again.size >= cur.size }
                }
            }
        }
    }

    /** The new rows, using the old instance wherever a row is unchanged, so only rows that really changed are redrawn. */
    private fun reuse(old: List<Channel>, new: List<Channel>): List<Channel> { val byId = old.associateBy { it.id }; return new.map { n -> byId[n.id]?.takeIf { it == n } ?: n } }

    /** Reads one page after the loaded rows and appends only rows not already shown. Returns how many were added; 0 ends the list. */
    private suspend fun readPage(): Int {
        val q = shownFor ?: return 0
        val g = generation; val cur = list.value.orEmpty()
        val rows = runCatching { c.browse.channelPage(q.first, q.second, PAGE, cur.size) }.getOrElse { if (g == generation) pageFailed.value = true; return 0 }
        if (g != generation) return 0                                       // the folder, source or sort changed while this page was being read
        val seen = cur.mapTo(HashSet()) { it.id }
        val fresh = rows.filter { it.id !in seen }
        list.value = cur + fresh; more = rows.size >= PAGE && fresh.isNotEmpty(); pageFailed.value = false
        return fresh.size
    }

    /** Reads the next page; ignored while a page is already being read. */
    fun loadMore() {
        if (busy || !more) return
        busy = true; loadingMore.value = true
        viewModelScope.launch { try { readPage() } finally { busy = false; loadingMore.value = false } }
    }
    fun retryPage() { pageFailed.value = false; loadMore() }

    /** Loads pages, one at a time, until [index] is in the list (coming back to a channel far down). It stops at the end of the list, when a page adds nothing, on a failure, and when anything starts again. */
    fun loadUpTo(index: Int) {
        restoreJob?.cancel()
        restoreJob = viewModelScope.launch {
            while (more && !pageFailed.value && (list.value?.size ?: 0) <= index) {
                if (busy) { kotlinx.coroutines.delay(30); continue }
                busy = true; loadingMore.value = true
                val added = try { readPage() } finally { busy = false; loadingMore.value = false }
                if (added == 0) break
            }
        }
    }

    val favourites: StateFlow<Set<String>> = c.user.favouriteIds(UserRepository.FAVOURITES).stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())
    /** The list as shown: duplicates of one channel folded into one row (Settings, Live TV), or every channel on its own. */
    val groups: StateFlow<List<ChannelGroup>?> = combine(channels, c.ui.groupDuplicates) { list, on -> list?.let { if (on) groupChannels(it) else it.map { ch -> ChannelGroup(ch, listOf(ch)) } } }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    /** The guide id for each listed channel: its own, or one matched by name. */
    val epgIds: StateFlow<Map<String, String>> = channels.mapLatest { list -> runCatching { c.epg.resolve(list.orEmpty().take(1500)) }.getOrDefault(emptyMap()) }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    /** What is on now for the channels listed, refreshed once a minute. */
    val now: StateFlow<Map<String, EpgProgram>> = epgIds.flatMapLatest { ids ->
        flow { while (true) { emit(ids.values.distinct().take(300)); delay(60_000) } }
    }.mapLatest { ids -> if (ids.isEmpty()) emptyMap() else runCatching { c.epg.nowFor(ids, System.currentTimeMillis() - c.ui.epgOffsetMinutes.value * 60_000L) }.getOrDefault(emptyMap()) }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    init { viewModelScope.launch { availability.value = runCatching { c.browse.availability() }.getOrDefault(availability.value) } }

    init { viewModelScope.launch { c.library.sourceIds.drop(1).collect { browse.value = Browse.All; scrollIndex = 0; focusedChannelId = null; focusedChannelIndex = 0 } } }
    private companion object { const val PAGE = 150 }
    fun select(b: Browse) { if (browse.value != b) { browse.value = b; scrollIndex = 0 } }
    fun applySort(spec: SortSpec) = c.browse.setSort(ContentKind.CHANNEL, (browse.value as? Browse.Folder)?.id, spec)
    fun toggleFavourite(ch: Channel) = viewModelScope.launch { c.user.setFavourite(ch.id, ContentKind.CHANNEL, ch.id !in favourites.value) }
    /** From the downloaded guide; a channel that guide has nothing for is asked of the provider directly. */
    suspend fun programmes(ch: Channel, n: Int = 12, askProvider: Boolean = false): List<EpgProgram> =
        c.epg.resolve(listOf(ch))[ch.id]?.let { runCatching { c.epg.upcoming(c.db, it, n) }.getOrDefault(emptyList()) }.orEmpty()
            .ifEmpty { if (askProvider) runCatching { c.sync.shortEpg(ch, n) }.getOrDefault(emptyList()) else emptyList() }          // the provider is asked only for the channel that was chosen (OK), never because the remote moved
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
    val groups by vm.groups.collectAsState()
    val total by vm.total.collectAsState()
    val pageFailed by vm.pageFailed.collectAsState()
    val loadingMore by vm.loadingMore.collectAsState()
    val sort by vm.sort.collectAsState()
    val avail by vm.availability.collectAsState()
    val now by vm.now.collectAsState()
    val epgIds by vm.epgIds.collectAsState()
    val favs by vm.favourites.collectAsState()
    val current by c.playback.current.collectAsState()
    val state by c.playback.state.collectAsState()
    val entry = LocalContentEntry.current ?: remember { FocusRequester() }
    val showNumbers by c.settings.showChannelNumbers.collectAsState()
    val listState = rememberLazyListState(vm.scrollIndex)
    LaunchedEffect(listState) { snapshotFlow { listState.firstVisibleItemIndex }.collect { vm.scrollIndex = it } }
    // Load the next page a screen or two before the end of what is loaded; coming back to a channel far down loads far enough to reach it.
    LaunchedEffect(listState, vm) { snapshotFlow { Pair(listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0, listState.layoutInfo.totalItemsCount) }.collect { (last, n) -> if (n > 0 && last >= n - 40 && n < (vm.total.value ?: Int.MAX_VALUE)) vm.loadMore() } }
    LaunchedEffect(Unit) { nav.memory.recall(app.streamsetu.tv.nav.Tab.LIVE)?.let { vm.loadUpTo(it.index) } }
    var sortOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<Channel?>(null) }
    var menuVariants by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var inChannels by remember { mutableStateOf(false) }
    var inPreview by remember { mutableStateOf(false) }
    val channelEntry = remember { FocusRequester() }
    val focusedRow = remember { FocusRequester() }
    val previewEntry = remember { FocusRequester() }
    val live = current?.takeIf { it.isLive } as? ChannelPlayable
    DisposableEffect(Unit) { onDispose { nav.videoBounds = null } }          // no preview, no place for the picture

    // Leaving Live TV releases the stream (a provider may allow only one connection).
    DisposableEffect(Unit) { onDispose { if (c.playback.current.value?.isLive == true && nav.top != Overlay.Player) c.playback.stop() } }
    // "Open Live TV on the last channel" (off by default): nothing starts by itself unless the person asked for it.
    LaunchedEffect(Unit) { if (c.settings.resumeLastChannel.value && c.playback.current.value == null) c.settings.lastChannelId?.let { id -> c.catalog.channel(id)?.let { ch -> c.play(ChannelPlayable(ch), listOf(ChannelPlayable(ch))) } } }
    LaunchedEffect(nav.pendingFolder) { nav.pendingFolder?.takeIf { it.first == ContentKind.CHANNEL }?.let { vm.select(Browse.Folder(it.second)); nav.pendingFolder = null } }

    val shortcuts = listOf(
        Shortcut(Browse.All, "All Channels", Icons.Filled.LiveTv), Shortcut(Browse.Favorites, "Favorites", Icons.Filled.Favorite), Shortcut(Browse.WatchLater, "Watch Later", Icons.Filled.Bookmark), Shortcut(Browse.Recent, "Recently Watched", Icons.Filled.History),
    ) + if (folders.any { it.pref.favorite }) listOf(Shortcut(Browse.FavoriteFolders, "Favorite Folders", Icons.Filled.Star)) else emptyList()

    // Back from the preview goes to the channel it came from; from the channels it goes to the categories; from the categories the shell opens the rail.
    // The folders are a column beside the channels that can be hidden. Choosing a folder or pressing Right hides it; Back from the channels shows it again, and Back from the folders opens the main sidebar.
    LaunchedEffect(Unit) { c.ensureGuide() }
    val folderNav = remember { app.streamsetu.tv.nav.FolderNav(startOpen = true) }
    val foldersOpen = folderNav.open
    val focusFolders = folderNav.focusTick
    var folderFocused by remember { mutableStateOf(false) }
    val folderClaim = remember { Any() }
    SideEffect { nav.holdFolders(folderClaim, foldersOpen || nav.foldersRequested) }
    DisposableEffect(Unit) { onDispose { nav.holdFolders(folderClaim, false) } }
    LaunchedEffect(foldersOpen) { if (!foldersOpen) folderFocused = false }
    LaunchedEffect(nav.foldersRequested) { if (nav.foldersRequested) folderNav.show() }
    // The request is answered (and the claim on the remote released) only when a folder row really holds the remote, or when the folders are closed again.
    LaunchedEffect(folderFocused, foldersOpen, nav.foldersRequested) { if (nav.foldersRequested && (folderFocused || !folderNav.open)) nav.foldersRequested = false }
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    // The channel (or picture) that had the remote lets go of it before the folders take it, so exactly one thing holds the remote.
    LaunchedEffect(foldersOpen, focusFolders) { if (foldersOpen) { if (inChannels || inPreview) focusManager.clearFocus(force = true); app.streamsetu.tv.ui.components.requestFocusOnFrames(90, { entry.requestFocus() }, { folderFocused }) } }
    val folderScope = androidx.compose.runtime.rememberCoroutineScope()
    fun hideFolders() { folderNav.hide(); folderScope.launch { app.streamsetu.tv.ui.components.requestFocusOnFrames(8, { channelEntry.requestFocus() }, { inChannels }) } }
    // The page's own levels come before the sidebar: the picture goes back to the channels, the channels to the folders, the folders to the main sidebar.
    DisposableEffect(inPreview, foldersOpen) {
        val hook: () -> Boolean = {
            when {
                inPreview -> { runCatching { focusedRow.requestFocus() }; true }
                foldersOpen -> { folderNav.back(); nav.revealSidebar(); true }
                else -> { focusManager.clearFocus(force = true); folderNav.show(); true }          // the channel lets go of the remote first, then the folders open and take it
            }
        }
        nav.backHook = hook
        onDispose { if (nav.backHook === hook) nav.backHook = null }
    }
    // Coming back to Live TV puts the remote on the channel it was on (or the nearest one if it has gone).
    val channelIds = remember(groups) { groups.orEmpty().map { it.rep.id } }
    var restored by remember { mutableStateOf(false) }
    LaunchedEffect(channelIds) {
        if (restored || channelIds.isEmpty()) return@LaunchedEffect
        if (folderNav.open) { restored = true; return@LaunchedEffect }          // opened from the sidebar: the remote belongs to the folders, not to the last channel
        val at = nav.memory.target(app.streamsetu.tv.nav.Tab.LIVE, channelIds) ?: return@LaunchedEffect
        restored = true
        listState.scrollToItem((at - 2).coerceAtLeast(0)); app.streamsetu.tv.ui.components.requestFocusOnFrames(6, { focusedRow.requestFocus() }, { inChannels || folderNav.open })
    }

    // OK on a channel opens it fullscreen at once (no stop in between). Browsing only reads about it; the picture on the right keeps showing what is playing.
    var focusedChannel by remember { mutableStateOf<Channel?>(null) }
    // OK on a channel plays it in the picture beside the list; OK on the one already playing (or on the picture, or Watch Fullscreen) opens it full screen.
    fun openFullscreen(ch: Channel) {
        if (live?.channel?.id != ch.id) c.play(ChannelPlayable(ch), groups.orEmpty().map { ChannelPlayable(it.rep) })
        nav.liveFullscreen = true; nav.open(Overlay.Player)
    }
    fun choose(ch: Channel) { if (live?.channel?.id == ch.id) openFullscreen(ch) else c.play(ChannelPlayable(ch), groups.orEmpty().map { ChannelPlayable(it.rep) }) }
    fun previewHere(ch: Channel) { if (live?.channel?.id != ch.id) c.play(ChannelPlayable(ch), groups.orEmpty().map { ChannelPlayable(it.rep) }) }

    androidx.compose.runtime.CompositionLocalProvider(LocalFocusRing provides androidx.compose.ui.graphics.Color.Unspecified) {
    // While the folders are open (or asked for) nothing in the page can take the remote; only the folder column is enabled. The channels are enabled again after Right or OK from the folders.
    androidx.compose.runtime.CompositionLocalProvider(LocalFocusEnabled provides !(folderNav.open || nav.foldersRequested)) {
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
    // The columns follow the screen: with the folders open, folders about 19 %, channels about 30 %, the picture the rest; closed, channels about 36 % and the picture 64 %.
    val screenW = maxWidth
    val screenH = maxHeight
    val folderW = Tokens.folderPanelWidth
    val channelsW = if (folderNav.open) screenW * 0.22f else screenW * 0.25f
    Row(Modifier.fillMaxSize()) {
        androidx.compose.animation.AnimatedVisibility(foldersOpen, Modifier.fillMaxHeight(),
            enter = folderEnter(), exit = androidx.compose.animation.ExitTransition.None) {
            androidx.compose.runtime.CompositionLocalProvider(LocalFocusEnabled provides true) { FolderPanel("Live TV", shortcuts, folders, browse, vm::select, vm, Modifier.onFocusChanged { folderFocused = it.hasFocus }.width(folderW).railOnLeft(), entry = entry, showSearch = true, selectOnDwell = true, onConfirm = { hideFolders() }, onRight = { hideFolders(); true }, onLeft = { folderNav.left(); nav.revealSidebar() }) }
        }
        // Channels
        Column(Modifier.width(channelsW).fillMaxHeight().background(Tokens.surface).then(if (foldersOpen) Modifier.leftGoesTo(entry) else Modifier).onPreviewKeyEvent { e -> if (!foldersOpen && e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown && e.key == androidx.compose.ui.input.key.Key.DirectionLeft) { focusManager.clearFocus(force = true); folderNav.show(); true } else false }.onFocusChanged { inChannels = it.hasFocus }.padding(top = Tokens.safeVertical)) {
            Row(Modifier.padding(horizontal = 10.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Label(if (browse is Browse.Folder) folders.firstOrNull { it.id == (browse as Browse.Folder).id }?.title ?: "Channels" else shortcuts.firstOrNull { it.browse == browse }?.label ?: "Channels", Tokens.heading, Tokens.text, FontWeight.Bold)
                    Label(groups?.let { "%,d channels".format(total?.takeIf { t -> t >= it.size } ?: it.size) } ?: "Loading…", Tokens.caption, Tokens.textSecondary)
                }
                SmallIcon(Icons.Filled.Search, "Search channels") { searchOpen = true }
                SmallIcon(Icons.Filled.SwapVert, "Sort channels") { sortOpen = true }
            }
            val list = groups
            when {
                list == null -> LazyColumn(Modifier.fillMaxSize(), userScrollEnabled = false) { items(14) { Box(Modifier.padding(8.dp).fillMaxWidth().height(34.dp).background(Tokens.card, RoundedCornerShape(8.dp))) } }
                list.isEmpty() -> Box(Modifier.fillMaxSize().padding(12.dp), Alignment.Center) {
                    // An empty list still has something for the remote to land on, so Right from the folders never loses focus.
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Label(if (browse == Browse.Favorites) "No favorite channels yet. Hold OK on a channel to add one." else "No channels here.", Tokens.small, Tokens.textSecondary, maxLines = 4)
                        TvButton(if (browse == Browse.All) "Choose a folder" else "Show all channels", { if (browse == Browse.All) folderNav.show() else vm.select(Browse.All) }, Modifier.focusRequester(channelEntry), primary = true)
                    }
                }
                else -> LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(horizontal = 6.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    items(list.size, key = { list[it].rep.id }, contentType = { "channel" }) { i ->
                        val grp = list[i]; val ch = grp.rep
                        val playing = live?.channel?.id == ch.id
                        Focusable({ choose(ch) }, (if (i == 0) Modifier.focusRequester(channelEntry) else Modifier).heightIn(min = 76.ui).then(if (ch.id == (nav.memory.recall(app.streamsetu.tv.nav.Tab.LIVE)?.id ?: channelIds.firstOrNull())) Modifier.focusRequester(focusedRow) else Modifier).fillMaxWidth(), onFocus = { if (it) { focusedChannel = ch; vm.focusedChannelId = ch.id; nav.memory.remember(app.streamsetu.tv.nav.Tab.LIVE, ch.id, i) } }, scaleOnFocus = 1.0f, container = if (playing) Tokens.accent.copy(alpha = 0.2f) else Tokens.card.copy(alpha = 0f), shape = RoundedCornerShape(10.dp), ringWidth = 2.5.dp, onLongClick = { menuFor = ch; menuVariants = grp.variants }) { f ->
                            // [number] [logo] [name over what is on]: the number has its own narrow column so names line up, and a long name wraps to two lines instead of being cut.
                            Row(Modifier.padding(horizontal = 8.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                if (showNumbers) Label(ch.number?.toString().orEmpty(), Tokens.caption, if (f || playing) Tokens.goldHighlight else Tokens.textTertiary, FontWeight.SemiBold, modifier = Modifier.width(38.dp), maxLines = 1)
                                ChannelLogo(ch.logoUrl, ch.name, 28.dp)
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                                    Label(ch.name, Tokens.small, if (playing) Tokens.goldHighlight else Tokens.text, if (playing || f) FontWeight.SemiBold else FontWeight.Medium, maxLines = 2)
                                    epgIds[ch.id]?.let { id -> now[id] }?.let { p -> Label(p.title, Tokens.caption, Tokens.textSecondary) }
                                }
                                if (grp.variants.size > 1) Label("+${grp.variants.size - 1}", Tokens.caption, Tokens.textTertiary)
                                if (ch.id in favs) Image(Icons.Filled.Favorite, null, Modifier.size(12.dp), colorFilter = ColorFilter.tint(Tokens.gold))
                            }
                        }
                    }
                    if (loadingMore) item(key = "loading") { Box(Modifier.fillMaxWidth().padding(8.dp), Alignment.Center) { Label("Loading…", Tokens.caption, Tokens.textTertiary) } }
                    if (pageFailed) item(key = "retry") { Box(Modifier.fillMaxWidth().padding(8.dp), Alignment.Center) { TvButton("Could not load more. Retry", { vm.retryPage() }, icon = Icons.Filled.Refresh) } }
                }
            }
        }

        // Preview
        Column(Modifier.weight(1f).fillMaxHeight().leftGoesTo(focusedRow).padding(start = 14.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical + 8.dp, bottom = Tokens.safeVertical).onFocusChanged { inPreview = it.hasFocus }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            // The picture has an explicit 16:9 size: about 44 % of the usable height (inside the safe margins), never wider than the column. What is left below it is reserved for the channel,
            // its buttons and the guide, so a short or overscanned screen cannot push them off the bottom.
            val usableH = (screenH - Tokens.safeVertical * 2 - 8.dp).coerceAtLeast(200.dp)
            androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxWidth()) {
            val playerH = minOf(usableH * 0.44f, maxWidth * 9f / 16f)
            val playerW = playerH * 16f / 9f
            Focusable({ if (live != null) { nav.liveFullscreen = true; nav.open(Overlay.Player) } }, Modifier.size(playerW, playerH).focusRequester(previewEntry).onGloballyPositioned { nav.videoBounds = it.boundsInWindow() }, scaleOnFocus = 1.0f, container = Color.Black, shape = RoundedCornerShape(16.dp), ringWidth = 3.dp) {
                // The picture is not drawn here: one video surface lives above the screens (PersistentVideo) and is placed on this box, so it is never moved between parents.
                Box(Modifier.fillMaxSize())
            }
            }
            (focusedChannel ?: live?.channel)?.let { shown -> NowNext(shown, live?.channel?.id == shown.id, vm, c, nav, Modifier.weight(1f), onWatch = { openFullscreen(shown) }, onOptions = { ch -> menuVariants = groups.orEmpty().firstOrNull { g -> g.rep.id == ch.id || g.variants.any { v -> v.id == ch.id } }?.variants.orEmpty(); menuFor = ch }) }
        }
    }
    }
    }
    }

    if (sortOpen) SortSheet(ContentKind.CHANNEL, sort, avail, onApply = vm::applySort, onClose = { sortOpen = false })
    if (searchOpen) TvDialog(onDismissRequest = { searchOpen = false }, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
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
        val homeVm: app.streamsetu.tv.ui.screens.home.HomeViewModel = androidx.hilt.navigation.compose.hiltViewModel()
        val extra = menuVariants.filter { it.id != ch.id }.map { v -> MenuAction("Version: ${qualityLabel(v.name)}  ·  ${v.name}", Icons.Filled.SwapHoriz) { c.play(ChannelPlayable(v), listOf(ChannelPlayable(v))) } } +
            MenuAction("Watch fullscreen", Icons.Filled.Fullscreen) { openFullscreen(ch) } +
            MenuAction("Preview here", Icons.Filled.PlayArrow) { previewHere(ch) }
        // Watch / favorites / guide / folder / information come from the shared menu; "Watch" here selects the channel in this screen's preview.
        app.streamsetu.tv.ui.screens.home.HomeMenuHost(app.streamsetu.tv.ui.screens.home.HomeTarget.Live(ch), if (browse == Browse.Recent) app.streamsetu.tv.ui.screens.home.RowKind.RECENT_LIVE else app.streamsetu.tv.ui.screens.home.RowKind.OTHER, homeVm, c, nav, extra) { menuFor = null }
    }
}

@Composable
private fun SmallIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Focusable(onClick, Modifier.padding(start = 4.dp), shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.08f) { f ->
        Image(icon, label, Modifier.padding(6.dp).size(14.dp), colorFilter = ColorFilter.tint(if (f) Tokens.accent else Tokens.textSecondary))
    }
}

/** Under the picture: the channel, what is on and what is next, and the channel's guide for the coming hours, only from real guide data. */
@Composable
private fun NowNext(ch: Channel, playing: Boolean, vm: LiveSectionViewModel, c: AppContainer, nav: Navigator, modifier: Modifier = Modifier, onWatch: () -> Unit = {}, onOptions: (Channel) -> Unit = {}) {
    val shift = c.ui.epgOffsetMinutes.collectAsState().value * 60_000L
    // The guide is read through the same shared operation as the TV Guide (the channel's guide id, 30 minutes back to three hours ahead, the same time offset). Five different answers are kept apart:
    // loading, matched with programmes, matched with none listed, channel not matched, and the read failed. Only a real list is remembered, never an empty or failed read.
    var guide by remember(ch.id, shift) { mutableStateOf<GuideState>(GuideCache.get(ch, shift)?.let { GuideState.Ready(it.map { p -> p }, fromCache = true) } ?: GuideState.Loading) }
    var tick by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var details by remember { mutableStateOf<EpgProgram?>(null) }
    LaunchedEffect(ch.id, shift, playing) {
        if (guide is GuideState.Loading) delay(250)
        while (true) {
            if (nav.top == null) {          // not while the fullscreen player covers the screen
                val now = System.currentTimeMillis()
                val r = c.epg.channelGuide(c.db, ch, now, shift)
                guide = when (r) {
                    is ChannelGuide.Failed -> if (guide is GuideState.Ready) guide else GuideState.Failed(r.why)           // a failed read keeps what is already shown
                    is ChannelGuide.Matched -> if (r.programmes.isNotEmpty()) GuideState.Ready(r.programmes).also { GuideCache.put(ch, r.guideId, shift, c.epg.generation, r.programmes) }
                        else providerOrElse(c, ch, playing, now, GuideState.NoneListed)
                    ChannelGuide.Unmatched -> providerOrElse(c, ch, playing, now, GuideState.Unmatched)
                }
                tick = now
            }
            delay(30_000)
        }
    }
    val programmes = (guide as? GuideState.Ready)?.programmes.orEmpty()
    val loaded = guide !is GuideState.Loading
    val nowP = programmes.firstOrNull { it.isLive(tick) }
    // What the stream is doing right now, from the player: it fills the space under the picture with something useful.
    var facts by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var anyGuide by remember { mutableStateOf<Boolean?>(null) }
    var showDetails by remember { mutableStateOf(false) }
    LaunchedEffect(ch.id) { anyGuide = runCatching { c.epg.programmeCount(c.db) > 0 }.getOrNull(); while (true) { if (nav.top == null) facts = c.playback.diagnostics(); delay(2500) } }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ChannelLogo(ch.logoUrl, ch.name, 36.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Label(ch.name, Tokens.title, Tokens.text, FontWeight.Bold, maxLines = 2)
                if (nowP != null) {
                    Label("${nowP.title}  ·  ${timeText(nowP.startMs)} – ${timeText(nowP.endMs)}", Tokens.body, Tokens.textSecondary, maxLines = 1)
                    val f = ((tick - nowP.startMs).toFloat() / (nowP.endMs - nowP.startMs)).coerceIn(0f, 1f)
                    Box(Modifier.fillMaxWidth().height(3.dp).background(Tokens.elevated, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(f).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
                } else Label("Live now", Tokens.small, Tokens.gold)
            }
        }
        // The actions get a row of their own, so a long channel or programme name (or larger text) can never squeeze or push them off.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TvButton("Watch Fullscreen", { onWatch() }, icon = Icons.Filled.Fullscreen, primary = true)
            TvButton("Options", { onOptions(ch) }, icon = Icons.Filled.MoreHoriz)
            if (playing) TvButton("Stream details", { showDetails = true }, icon = Icons.Filled.Info)
        }
        // What the stream is doing (player, picture, sound, buffer) is not always on screen: it opens from the Stream details button beside the actions.
        val chips = if (!playing) emptyList() else listOfNotNull(facts["Engine"]?.let { "Player  ·  $it" }, facts["Video"]?.takeIf { it != "none" }?.let { "Video  ·  $it" }, facts["Audio"]?.takeIf { it != "none" }?.let { "Audio  ·  $it" }, facts["Buffered ahead"]?.let { "Buffer  ·  $it" })
        if (showDetails && chips.isNotEmpty()) ContextMenu("Stream details", null, chips.map { MenuAction(it, Icons.Filled.Info, enabled = false) {} }, onClose = { showDetails = false })
        if (guide is GuideState.Loading) {
            // The guide is being read: say so, instead of claiming the channel is not in it.
            Row(Modifier.fillMaxWidth().background(Tokens.card, RoundedCornerShape(12.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Spinner(); Label("Loading the guide…", Tokens.row, Tokens.textSecondary)
            }
        } else if (guide is GuideState.Failed) {
            Row(Modifier.fillMaxWidth().background(Tokens.card, RoundedCornerShape(12.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Image(Icons.Filled.CalendarMonth, null, Modifier.size(26.dp), colorFilter = ColorFilter.tint(Tokens.danger))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) { Label("The guide could not be read", Tokens.row, Tokens.text, FontWeight.SemiBold); Label((guide as GuideState.Failed).why, Tokens.small, Tokens.textSecondary, maxLines = 2) }
            }
        } else if (guide is GuideState.NoneListed) {
            Row(Modifier.fillMaxWidth().background(Tokens.card, RoundedCornerShape(12.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Image(Icons.Filled.CalendarMonth, null, Modifier.size(26.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) { Label("Nothing is listed for the next three hours", Tokens.row, Tokens.text, FontWeight.SemiBold); Label("The channel is in the guide, but it has no programmes in this window.", Tokens.small, Tokens.textSecondary) }
            }
        } else if (programmes.isEmpty()) {
            // No guide for this channel: say why, and that the channel plays normally.
            Row(Modifier.fillMaxWidth().background(Tokens.card, RoundedCornerShape(12.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Image(Icons.Filled.CalendarMonth, null, Modifier.size(26.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Label(if (anyGuide == false) "Your provider did not send a programme guide" else "This channel is not in the guide", Tokens.row, Tokens.text, FontWeight.SemiBold)
                    Label(if (anyGuide == false) "Channels still play. Refresh the connection in Settings, Libraries & Folders, to check again." else "It plays normally. Guide data only covers channels the provider lists in it.", Tokens.small, Tokens.textSecondary, maxLines = 2)
                }
            }
        }
        if (programmes.isNotEmpty()) {
            Eyebrow("Guide", color = Tokens.textTertiary)
            LazyColumn(Modifier.fillMaxWidth().weight(1f).heightIn(min = 96.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                items(programmes.size, key = { programmes[it].startMs }) { i ->
                    val p = programmes[i]; val live = p.isLive(tick)
                    Focusable({ details = p }, Modifier.fillMaxWidth(), scaleOnFocus = 1.0f, container = if (live) Tokens.elevated else Tokens.card.copy(alpha = 0f), shape = RoundedCornerShape(8.dp)) { _ ->
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Label(timeText(p.startMs), Tokens.small, if (live) Tokens.accent else Tokens.textSecondary, FontWeight.SemiBold, modifier = Modifier.width(62.dp))
                            Column(Modifier.weight(1f)) {
                                Label(p.title, Tokens.row, if (live) Tokens.text else Tokens.textSecondary, if (live) FontWeight.SemiBold else FontWeight.Normal)
                                if (live) { val f = ((tick - p.startMs).toFloat() / (p.endMs - p.startMs)).coerceIn(0f, 1f); Label("On now  ·  ${((p.endMs - tick) / 60000).coerceAtLeast(0)} min left", Tokens.caption, Tokens.accent) } else Label("${timeText(p.startMs)} – ${timeText(p.endMs)}", Tokens.caption, Tokens.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }
    details?.let { p -> ContextMenu(p.title, "${ch.name}  ·  ${timeText(p.startMs)} – ${timeText(p.endMs)}" + (p.description?.takeIf { it.isNotBlank() }?.let { "\n$it" } ?: ""), listOf(MenuAction("Close", Icons.Filled.Close) {}), onClose = { details = null }) }
}


/** What the embedded guide shows. */
private sealed interface GuideState {
    object Loading : GuideState
    class Ready(val programmes: List<EpgProgram>, val fromCache: Boolean = false) : GuideState
    object NoneListed : GuideState
    object Unmatched : GuideState
    class Failed(val why: String) : GuideState
}

/**
 * The last real guide read for a channel. The key holds the channel, its source, the guide id it resolved to and the time offset, so a channel that now resolves elsewhere, another connection or a
 * moved clock never gets another guide's list; an entry made before the guide was read again is dropped. Empty and failed reads are never kept.
 */
private object GuideCache {
    private class Entry(val guideId: String, val generation: Int, val programmes: List<EpgProgram>)
    private val map = java.util.concurrent.ConcurrentHashMap<String, Entry>()
    @Volatile private var generationNow = 0
    private fun key(ch: Channel, shift: Long) = ch.id + "|" + ch.sourceId + "|" + shift
    fun get(ch: Channel, shift: Long): List<EpgProgram>? = map[key(ch, shift)]?.takeIf { it.generation == generationNow }?.programmes?.takeIf { it.isNotEmpty() }
    fun put(ch: Channel, guideId: String, shift: Long, generation: Int, programmes: List<EpgProgram>) {
        if (programmes.isEmpty()) return
        generationNow = generation
        if (map.size > 300) map.clear()
        map[key(ch, shift)] = Entry(guideId, generation, programmes)
    }
}

/** The provider's own guide for the channel that was chosen (never because the remote moved over it), used only when the downloaded guide has nothing for it. */
private suspend fun providerOrElse(c: AppContainer, ch: Channel, playing: Boolean, now: Long, otherwise: GuideState): GuideState {
    if (!playing) return otherwise
    val p = runCatching { c.sync.shortEpg(ch, 12) }.getOrDefault(emptyList()).filter { it.endMs > now - 30 * 60_000L }
    return if (p.isNotEmpty()) GuideState.Ready(p) else otherwise
}
