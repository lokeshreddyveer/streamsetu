package app.streamsetu.tv.ui.screens.guide

import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.conflate
import app.streamsetu.core.sync.programmesFor
import app.streamsetu.tv.ui.theme.ui
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.core.model.*
import app.streamsetu.core.sync.programmeCount
import app.streamsetu.core.sync.window
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import javax.inject.Inject

data class GuideRow(val channel: Channel, val programmes: List<EpgProgram>)

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class GuideViewModel @Inject constructor(private val c: AppContainer) : ViewModel() {
    val favouritesOnly = MutableStateFlow(false)
    /** The category shown: All, or one of the live folders. Kept while the Guide is away. */
    val category = MutableStateFlow<Browse>(Browse.All)
    val folders: StateFlow<List<Folder>> = c.folders.folders(ContentKind.CHANNEL).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val query = MutableStateFlow("")
    /** Start of the visible window (ms), moved by the person; null means "now". */
    val windowStart = MutableStateFlow(halfHour(System.currentTimeMillis()) - 30 * 60_000L)
    val hasGuide = MutableStateFlow<Boolean?>(null)
    val offsetMin: StateFlow<Int> = c.ui.epgOffsetMinutes
    val favs: StateFlow<Set<String>> = c.user.favouriteIds().stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    /** Which channels the Guide lists (up to 250 with guide data): worked out once for a category, a search or the favourites switch, not again when the time window moves. */
    private class Picked(val channels: List<Channel>, val guideIds: Map<String, String>)

    private val picked: Flow<Picked> = combine(favouritesOnly, query, category) { f, q, cat -> Triple(f, q, cat) }.flatMapLatest { (fav, q, cat) ->
        c.browse.channels(cat, SortSpec(SortField.PROVIDER), 40000).conflate().mapLatest { all ->          // a newer channel list replaces an unfinished one; the work runs off the main thread
            val resolved = c.epg.resolve(all)
            val nq = SearchText.normalize(q)
            val favSet = if (fav) favs.value else emptySet()
            Picked(all.filter { it.id in resolved && (!fav || it.id in favSet) && (q.isBlank() || SearchText.normalize(it.name).contains(nq)) }.take(250), resolved)
        }
    }

    /** The rows: the picked channels with only the programmes that overlap the visible window (the next window is fetched when it is asked for). */
    val rows: StateFlow<List<GuideRow>?> = combine(picked, windowStart, offsetMin) { p, w, o -> Triple(p, w, o) }.mapLatest { (p, start, off) ->
        val end = start + WINDOW_MIN * 60_000L
        val shift = off * 60_000L
        val data = c.epg.programmesFor(c.db, p.channels, p.guideIds, start, end, shift)          // the same read the Live TV screen's guide uses
        hasGuide.value = c.epg.programmeCount(c.db) > 0
        p.channels.map { ch -> GuideRow(ch, data[ch.id].orEmpty()) }
    }.map<List<GuideRow>, List<GuideRow>?> { it }.onStart { emit(null) }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(120_000), null)

    init { viewModelScope.launch { c.library.sourceIds.drop(1).collect { category.value = Browse.All; favouritesOnly.value = false; query.value = "" } } }
    fun shift(hours: Int) { windowStart.value += hours * 3_600_000L }
    fun now() { windowStart.value = halfHour(System.currentTimeMillis()) - 30 * 60_000L }
    fun toggleFavourite(ch: Channel) = viewModelScope.launch { c.user.setFavourite(ch.id, ContentKind.CHANNEL, ch.id !in favs.value) }

    companion object {
        const val WINDOW_MIN = 180
        fun halfHour(ms: Long): Long = Calendar.getInstance().apply { timeInMillis = ms; set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0); set(Calendar.MINUTE, if (get(Calendar.MINUTE) >= 30) 30 else 0) }.timeInMillis
    }
}

private val labelW get() = 260.ui
private val dpPerMin get() = 4.33f * app.streamsetu.tv.ui.theme.UiScale.k
/** The height of a guide row at normal text; it grows with larger text so a programme's title and time are never cut off. */
private val rowH get() = 72.ui

private fun clock(ms: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

/**
 * The TV Guide: a time ruler across the top, one row per channel, and programmes laid out by their real start and length. Select a programme for its details
 * and to watch the channel. Channels without guide data are left out, and when the provider has no guide at all the screen says so instead of showing blanks.
 */
@Composable
fun GuideScreen(vm: GuideViewModel, c: AppContainer, nav: Navigator) {
    androidx.compose.runtime.LaunchedEffect(Unit) { c.ensureGuide() }
    val rows by vm.rows.collectAsStateWithLifecycle()
    LaunchedEffect(rows != null) { rows?.let { r -> app.streamsetu.tv.trace.SSTrace.v { "guide rows=${r.size} now=${android.os.SystemClock.uptimeMillis()}" } } }
    val start by vm.windowStart.collectAsStateWithLifecycle()
    val favOnly by vm.favouritesOnly.collectAsStateWithLifecycle()
    val hasGuide by vm.hasGuide.collectAsStateWithLifecycle()
    val query by vm.query.collectAsStateWithLifecycle()
    var details by remember { mutableStateOf<Pair<Channel, EpgProgram>?>(null) }
    var focusedProgramme by remember { mutableStateOf<Pair<Channel, EpgProgram>?>(null) }          // what the remote is on, described in full under the grid
    val category by vm.category.collectAsStateWithLifecycle()
    val liveFolders by vm.folders.collectAsStateWithLifecycle()
    // The remote goes back to the channel it was on.
    val restore = remember { FocusRequester() }
    val rowIds = remember(rows) { rows.orEmpty().map { it.channel.id } }
    var restored by remember { mutableStateOf(false) }
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    LaunchedEffect(rowIds) {
        if (restored || rowIds.isEmpty()) return@LaunchedEffect
        val at = nav.memory.target(app.streamsetu.tv.nav.Tab.GUIDE, rowIds) ?: return@LaunchedEffect
        restored = true; listState.scrollToItem((at - 1).coerceAtLeast(0)); delay(500); runCatching { restore.requestFocus() }
    }
    val entry = LocalContentEntry.current ?: remember { FocusRequester() }
    val now by rememberMinute()
    val totalW = (GuideViewModel.WINDOW_MIN * dpPerMin).dp
    val rowHeight = rowH * maxOf(1f, androidx.compose.ui.platform.LocalDensity.current.fontScale)

    Column(Modifier.fillMaxSize().padding(start = Tokens.safeHorizontal + 4.dp, end = Tokens.safeHorizontal, top = 4.dp)) {
        // Two rows. Above: the title and date, the library, and the favourites filter. Below: the time controls, which stay where they are, and the categories, which scroll sideways on their
        // own (a provider can have a hundred) and keep the one under the remote in view. Nothing in either row can be pushed off the screen by a long name.
        val libraryName = c.library.active.collectAsStateWithLifecycle().value?.name.orEmpty()
        val folderList = liveFolders.filter { !it.pref.hidden }
        val categoryState = androidx.compose.foundation.lazy.rememberLazyListState()
        val scope = rememberCoroutineScope()
        val selectedIndex = (category as? Browse.Folder)?.let { b -> folderList.indexOfFirst { it.id == b.id } + 1 }?.takeIf { it > 0 } ?: 0
        suspend fun reveal(index: Int) {
            val info = categoryState.layoutInfo
            val v = info.visibleItemsInfo.firstOrNull { it.index == index }
            when {
                v == null -> categoryState.scrollToItem(index)
                v.offset < info.viewportStartOffset -> categoryState.animateScrollBy((v.offset - info.viewportStartOffset).toFloat())
                v.offset + v.size > info.viewportEndOffset -> categoryState.animateScrollBy((v.offset + v.size - info.viewportEndOffset).toFloat())
            }
        }
        LaunchedEffect(selectedIndex, folderList.size) { reveal(selectedIndex) }
        Column(Modifier.railOnLeft(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(Modifier.weight(1f)) { Label("TV Guide", Tokens.display, Tokens.text, FontWeight.ExtraBold); Label(java.text.DateFormat.getDateInstance(DateFormat.FULL).format(Date(start)), Tokens.row, Tokens.textSecondary, maxLines = 1) }
                Chip2(if (favOnly) "Favorites" else "All channels", Icons.Filled.Favorite) { vm.favouritesOnly.value = !favOnly }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip2("Earlier", Icons.Filled.ChevronLeft, Modifier.focusRequester(entry)) { vm.shift(-2) }
                Chip2("Now", Icons.Filled.Schedule) { vm.now() }
                Chip2("Later", Icons.Filled.ChevronRight) { vm.shift(2) }
                androidx.compose.foundation.lazy.LazyRow(Modifier.weight(1f), state = categoryState, horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(start = 12.dp)) {
                    item(key = "all") { Chip2("All categories", Icons.Filled.Folder, selected = selectedIndex == 0, maxLabel = 200.dp, onFocus = { if (it) scope.launch { reveal(0) } }) { vm.category.value = Browse.All } }
                    itemsIndexed(folderList, key = { _, f -> f.id }) { index, f ->
                        Chip2(f.title, Icons.Filled.Folder, selected = selectedIndex == index + 1, maxLabel = 200.dp, onFocus = { if (it) scope.launch { reveal(index + 1) } }) { vm.category.value = Browse.Folder(f.id) }
                    }
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        TvTextField(query, { vm.query.value = it }, "Search channels in the guide", Modifier.widthIn(max = 420.dp).railOnLeft())
        Spacer(Modifier.height(6.dp))
        // Ruler
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.width(labelW))
            Box(Modifier.width(totalW).heightIn(min = 22.dp)) {
                for (m in 0 until GuideViewModel.WINDOW_MIN step 30) Label(clock(start + m * 60_000L), Tokens.small, Tokens.textSecondary, FontWeight.SemiBold, modifier = Modifier.offset(x = (m * dpPerMin).dp))
                // The current time has a marker in the ruler as well as the line down the rows.
                if (now in start..(start + GuideViewModel.WINDOW_MIN * 60_000L)) Box(Modifier.offset(x = ((now - start) / 60_000f * dpPerMin).dp - 4.dp, y = 2.dp).size(10.dp).background(Tokens.danger, RoundedCornerShape(50)))
            }
        }
        val list = rows
        // Up and Down go to the programme in the next channel that is on at the same time as this one (not to whichever cell happens to be nearest on screen), and Left and Right
        // stay on the row. Each cell has its own focus requester so the move can name it exactly.
        val cellRequesters = remember { HashMap<String, FocusRequester>() }
        val guideScope = rememberCoroutineScope()
        var guideMoving by remember { mutableStateOf(false) }
        val windowEnd = start + GuideViewModel.WINDOW_MIN * 60_000L
        fun shown(p: app.streamsetu.core.model.EpgProgram) = ((minOf(p.endMs, windowEnd) - maxOf(p.startMs, start)) / 60_000f * dpPerMin).dp - 2.dp > 40.dp
        fun cellRequester(channelId: String, p: app.streamsetu.core.model.EpgProgram?): FocusRequester =
            if (p != null && channelId == (nav.memory.recall(app.streamsetu.tv.nav.Tab.GUIDE)?.id ?: rowIds.firstOrNull()) && p.isLive(now)) restore
            else cellRequesters.getOrPut("$channelId|${p?.startMs ?: -1}") { FocusRequester() }
        fun verticalMove(rowIndex: Int, from: app.streamsetu.core.model.EpgProgram?, down: Boolean): Boolean {
            val all = rows ?: return false
            val target = rowIndex + if (down) 1 else -1
            if (target < 0) return false                         // above the first channel: the controls up there take it
            if (target >= all.size || guideMoving) return true  // the last channel stays put; a move still landing swallows repeats
            val tr = all[target]
            val at = from?.let { (maxOf(it.startMs, start) + minOf(it.endMs, windowEnd)) / 2 } ?: ((start + windowEnd) / 2)
            val candidates = tr.programmes.filter { shown(it) }
            val pick = candidates.firstOrNull { it.startMs <= at && it.endMs > at } ?: candidates.minByOrNull { kotlin.math.abs((it.startMs + it.endMs) / 2 - at) }
            val req = cellRequester(tr.channel.id, pick)
            guideMoving = true
            guideScope.launch {
                try {
                    if (listState.layoutInfo.visibleItemsInfo.none { it.index == target }) listState.scrollToItem((target - 1).coerceAtLeast(0))
                    androidx.compose.runtime.withFrameNanos { }
                    runCatching { req.requestFocus() }
                } finally { guideMoving = false }
            }
            return true
        }
        when {
            list == null -> LazyColumn(userScrollEnabled = false) { items(8) { Box(Modifier.padding(vertical = 3.dp).fillMaxWidth().height(40.dp).background(Tokens.card, RoundedCornerShape(8.dp))) } }
            hasGuide == false -> EmptyState("No guide for this connection", "The provider did not send programme information. Channels still play from Live TV.")
            list.isEmpty() -> EmptyState(if (favOnly) "No favorite channels with a guide" else "No channels with guide data", if (favOnly) "Add channels to Favorites from Live TV." else "Try another time range or clear the search.")
            else -> LazyColumn(Modifier.weight(1f).fillMaxWidth().railOnLeft(), state = listState, contentPadding = PaddingValues(bottom = 30.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(list, key = { _, it -> it.channel.id }) { rowIndex, row ->
                    Row(Modifier.fillMaxWidth().height(rowHeight)) {
                        Row(Modifier.width(labelW).fillMaxHeight().padding(end = 8.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radius)).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            row.channel.number?.let { Label("$it", Tokens.caption, Tokens.textTertiary, FontWeight.SemiBold, modifier = Modifier.width(38.dp)) }
                            ChannelLogo(row.channel.logoUrl, row.channel.name, 32.dp)
                            Label(row.channel.name, Tokens.small, Tokens.text, FontWeight.Medium, maxLines = 2, modifier = Modifier.weight(1f))
                        }
                        Box(Modifier.width(totalW).fillMaxHeight()) {
                            // A channel with no guide data is still one stop for the remote (select plays it): a row with nothing to land on makes Down search every row below it before it gives up.
                            if (row.programmes.isEmpty()) Focusable({ play(c, nav, ChannelPlayable(row.channel), rows.orEmpty().map { ChannelPlayable(it.channel) }) }, Modifier.fillMaxSize().focusRequester(cellRequester(row.channel.id, null)).onPreviewKeyEvent { e -> if (e.type != androidx.compose.ui.input.key.KeyEventType.KeyDown) false else when (e.key) { androidx.compose.ui.input.key.Key.DirectionUp -> verticalMove(rowIndex, null, false); androidx.compose.ui.input.key.Key.DirectionDown -> verticalMove(rowIndex, null, true); else -> false } },
                                onFocus = { if (it) nav.memory.remember(app.streamsetu.tv.nav.Tab.GUIDE, row.channel.id, rowIds.indexOf(row.channel.id)) }, scaleOnFocus = 1.0f, shape = RoundedCornerShape(Tokens.radiusSmall), ringWidth = 2.5.dp, container = Tokens.card.copy(alpha = 0.5f)) { _ ->
                                Box(Modifier.fillMaxSize(), Alignment.CenterStart) { Label("No information", Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(start = 8.dp)) }
                            }
                            val end = start + GuideViewModel.WINDOW_MIN * 60_000L
                            row.programmes.forEach { p ->
                                val s = maxOf(p.startMs, start); val e = minOf(p.endMs, end)
                                val w = ((e - s) / 60_000f * dpPerMin).dp - 2.dp
                                if (w > 40.dp) Focusable({ details = row.channel to p }, Modifier.focusRequester(cellRequester(row.channel.id, p)).onPreviewKeyEvent { e -> if (e.type != androidx.compose.ui.input.key.KeyEventType.KeyDown) false else when (e.key) { androidx.compose.ui.input.key.Key.DirectionUp -> verticalMove(rowIndex, p, false); androidx.compose.ui.input.key.Key.DirectionDown -> verticalMove(rowIndex, p, true); else -> false } }.offset(x = ((s - start) / 60_000f * dpPerMin).dp).width(w).fillMaxHeight(),
                                    onFocus = { if (it) { nav.memory.remember(app.streamsetu.tv.nav.Tab.GUIDE, row.channel.id, rowIds.indexOf(row.channel.id)); focusedProgramme = row.channel to p } }, scaleOnFocus = 1.0f, shape = RoundedCornerShape(Tokens.radiusSmall), ringWidth = 2.5.dp,
                                    container = if (p.isLive(now)) Tokens.elevated else Tokens.card) { _ ->
                                    val past = p.endMs <= now
                                    Column(Modifier.padding(horizontal = 10.dp, vertical = 4.dp), verticalArrangement = Arrangement.Center) {
                                        Label(p.title, Tokens.small, if (past) Tokens.textTertiary else Tokens.text, if (p.isLive(now)) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1)
                                        Label(if (p.isLive(now)) "LIVE" else clock(p.startMs), Tokens.caption, if (p.isLive(now)) Color.White else Tokens.textTertiary, maxLines = 1)
                                    }
                                    if (p.isLive(now)) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(((now - p.startMs).toFloat() / (p.endMs - p.startMs).coerceAtLeast(1)).coerceIn(0f, 1f)).height(3.dp).background(Color.White))
                                }
                            }
                            if (now in start..(start + GuideViewModel.WINDOW_MIN * 60_000L)) Box(Modifier.offset(x = ((now - start) / 60_000f * dpPerMin).dp).width(3.dp).fillMaxHeight().background(Tokens.danger, RoundedCornerShape(2.dp)))
                        }
                    }
                }
            }
        }
        // The programme under the remote, in full: its whole title, when it is on, which channel, and what it is about.
        focusedProgramme?.let { (ch, p) ->
            Column(Modifier.fillMaxWidth().padding(top = 6.dp, bottom = 10.dp).background(Tokens.card, RoundedCornerShape(Tokens.radius)).padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Label(p.title, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                Label("${clock(p.startMs)} – ${clock(p.endMs)}  ·  ${ch.name}" + if (p.isLive(now)) "  ·  LIVE" else "", Tokens.small, Tokens.textSecondary, maxLines = 1)
                p.description?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.small, Tokens.textTertiary, maxLines = 2) }
            }
        }
    }

    details?.let { (ch, p) ->
        val fav = ch.id in vm.favs.collectAsStateWithLifecycle().value
        val scope = rememberCoroutineScope(); val context = androidx.compose.ui.platform.LocalContext.current
        ContextMenu(p.title, "${ch.name}  ·  ${clock(p.startMs)} – ${clock(p.endMs)}" + (p.description?.takeIf { it.isNotBlank() }?.let { "\n$it" } ?: ""), buildList {
            add(MenuAction(if (p.isLive(now)) "Watch now" else "Watch channel", Icons.Filled.PlayArrow) { play(c, nav, ChannelPlayable(ch), rows.orEmpty().map { ChannelPlayable(it.channel) }) })
            if (p.startMs > now + 2 * 60_000L) add(MenuAction("Remind me", Icons.Filled.Notifications) { scope.launch { app.streamsetu.tv.Reminders.schedule(c, context, ch, p) } })
            if (p.endMs > now) {
                val rec = app.streamsetu.tv.record.ScheduledRecordings.isScheduled(ch.id, p.startMs)
                add(MenuAction(if (rec) "Cancel recording" else "Record", Icons.Filled.FiberManualRecord) {
                    if (rec) app.streamsetu.tv.record.ScheduledRecordings.cancel(context, app.streamsetu.tv.record.ScheduledRecordings.idOf(ch.id, p.startMs)) else app.streamsetu.tv.record.ScheduledRecordings.schedule(context, ch, p)
                })
            }
            add(MenuAction(if (fav) "Remove channel from Favorites" else "Add channel to Favorites", Icons.Filled.Favorite) { vm.toggleFavourite(ch) })
            if (ch.catchupDays > 0 && p.startMs < now && p.startMs > now - ch.catchupDays * 86_400_000L) add(MenuAction("Watch from the start (catch-up)", Icons.Filled.History) { play(c, nav, CatchUpPlayable(ch, p.title, p.startMs - vm.offsetMin.value * 60_000L, p.endMs - vm.offsetMin.value * 60_000L)) })
            else if (ch.catchupDays > 0 && p.startMs <= now - ch.catchupDays * 86_400_000L) add(MenuAction("Too old for catch-up (${ch.catchupDays} days)", Icons.Filled.History, enabled = false) {})
        }, onClose = { details = null })
    }
}

@Composable
private fun Chip2(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier = Modifier, selected: Boolean = false, maxLabel: androidx.compose.ui.unit.Dp = androidx.compose.ui.unit.Dp.Unspecified, onFocus: (Boolean) -> Unit = {}, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = if (selected) Tokens.accent.copy(alpha = 0.22f) else Tokens.elevated, scaleOnFocus = 1.05f, onFocus = onFocus) { f ->
        Row(Modifier.padding(horizontal = 16.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, null, Modifier.size(14.dp), colorFilter = ColorFilter.tint(if (f || selected) Tokens.accent else Tokens.textSecondary))
            Label(label, Tokens.small, Tokens.text, if (selected) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1, modifier = if (maxLabel != androidx.compose.ui.unit.Dp.Unspecified) Modifier.widthIn(max = maxLabel) else Modifier)
        }
    }
}
