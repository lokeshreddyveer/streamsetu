package app.streamsetu.tv.ui.screens.guide

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
    val query = MutableStateFlow("")
    /** Start of the visible window (ms), moved by the person; null means "now". */
    val windowStart = MutableStateFlow(halfHour(System.currentTimeMillis()) - 30 * 60_000L)
    val hasGuide = MutableStateFlow<Boolean?>(null)
    val offsetMin: StateFlow<Int> = c.ui.epgOffsetMinutes
    val favs: StateFlow<Set<String>> = c.user.favouriteIds().stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    val rows: StateFlow<List<GuideRow>?> = combine(favouritesOnly, windowStart, offsetMin, query) { f, w, o, q -> arrayOf<Any>(f, w, o, q) }.flatMapLatest { a ->
        val fav = a[0] as Boolean; val start = a[1] as Long; val off = a[2] as Int; val q = a[3] as String
        c.browse.channels(Browse.All, SortSpec(SortField.PROVIDER), 40000).map { all ->
            val resolved = c.epg.resolve(all)
            val withGuide = all.filter { it.id in resolved }
            val picked = withGuide.filter { !fav || it.id in favs.value }.filter { q.isBlank() || SearchText.normalize(it.name).contains(SearchText.normalize(q)) }.take(250)
            val end = start + WINDOW_MIN * 60_000L
            val shift = off * 60_000L
            val data = c.epg.window(c.db, picked.mapNotNull { resolved[it.id] }.distinct(), start - shift, end - shift)
            hasGuide.value = c.epg.programmeCount(c.db) > 0
            picked.map { ch -> GuideRow(ch, data[resolved[ch.id]].orEmpty().map { it.copy(startMs = it.startMs + shift, endMs = it.endMs + shift) }) }
        }.map<List<GuideRow>, List<GuideRow>?> { it }.onStart { emit(null) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    fun shift(hours: Int) { windowStart.value += hours * 3_600_000L }
    fun now() { windowStart.value = halfHour(System.currentTimeMillis()) - 30 * 60_000L }
    fun toggleFavourite(ch: Channel) = viewModelScope.launch { c.user.setFavourite(ch.id, ContentKind.CHANNEL, ch.id !in favs.value) }

    companion object {
        const val WINDOW_MIN = 180
        fun halfHour(ms: Long): Long = Calendar.getInstance().apply { timeInMillis = ms; set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0); set(Calendar.MINUTE, if (get(Calendar.MINUTE) >= 30) 30 else 0) }.timeInMillis
    }
}

private val labelW = 112.dp
private val dpPerMin = 3.1f

private fun clock(ms: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

/**
 * The TV Guide: a time ruler across the top, one row per channel, and programmes laid out by their real start and length. Select a programme for its details
 * and to watch the channel. Channels without guide data are left out, and when the provider has no guide at all the screen says so instead of showing blanks.
 */
@Composable
fun GuideScreen(vm: GuideViewModel, c: AppContainer, nav: Navigator) {
    val rows by vm.rows.collectAsState()
    val start by vm.windowStart.collectAsState()
    val favOnly by vm.favouritesOnly.collectAsState()
    val hasGuide by vm.hasGuide.collectAsState()
    val query by vm.query.collectAsState()
    var details by remember { mutableStateOf<Pair<Channel, EpgProgram>?>(null) }
    val entry = LocalContentEntry.current ?: remember { FocusRequester() }
    val now = System.currentTimeMillis()
    val totalW = (GuideViewModel.WINDOW_MIN * dpPerMin).dp

    Column(Modifier.fillMaxSize().padding(start = 16.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) { Label("TV Guide", Tokens.pageTitle, Tokens.text, FontWeight.Bold); Label(java.text.DateFormat.getDateInstance(DateFormat.FULL).format(Date(start)), Tokens.small, Tokens.textSecondary) }
            Chip2("Earlier", Icons.Filled.ChevronLeft, Modifier.focusRequester(entry)) { vm.shift(-2) }
            Chip2("Now", Icons.Filled.Schedule) { vm.now() }
            Chip2("Later", Icons.Filled.ChevronRight) { vm.shift(2) }
            Chip2(if (favOnly) "Favorites" else "All channels", Icons.Filled.Favorite) { vm.favouritesOnly.value = !favOnly }
        }
        Spacer(Modifier.height(6.dp))
        TvTextField(query, { vm.query.value = it }, "Search channels in the guide", Modifier.widthIn(max = 420.dp))
        Spacer(Modifier.height(6.dp))
        // Ruler
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.width(labelW))
            Box(Modifier.width(totalW).height(18.dp)) {
                for (m in 0 until GuideViewModel.WINDOW_MIN step 30) Label(clock(start + m * 60_000L), Tokens.caption, Tokens.textSecondary, modifier = Modifier.offset(x = (m * dpPerMin).dp))
            }
        }
        val list = rows
        when {
            list == null -> LazyColumn(userScrollEnabled = false) { items(8) { Box(Modifier.padding(vertical = 3.dp).fillMaxWidth().height(40.dp).background(Tokens.card, RoundedCornerShape(8.dp))) } }
            hasGuide == false -> EmptyState("No guide for this connection", "The provider did not send programme information. Channels still play from Live TV.")
            list.isEmpty() -> EmptyState(if (favOnly) "No favorite channels with a guide" else "No channels with guide data", if (favOnly) "Add channels to Favorites from Live TV." else "Try another time range or clear the search.")
            else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 30.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                items(list, key = { it.channel.id }) { row ->
                    Row(Modifier.fillMaxWidth().height(42.dp)) {
                        Row(Modifier.width(labelW).fillMaxHeight().padding(end = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            ChannelLogo(row.channel.logoUrl, row.channel.name, 24.dp)
                            Label(row.channel.name, Tokens.caption, Tokens.text, FontWeight.Medium, maxLines = 2, modifier = Modifier.weight(1f))
                        }
                        Box(Modifier.width(totalW).fillMaxHeight()) {
                            if (row.programmes.isEmpty()) Box(Modifier.fillMaxSize().background(Tokens.card.copy(alpha = 0.5f), RoundedCornerShape(6.dp)), Alignment.CenterStart) { Label("No information", Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(start = 8.dp)) }
                            val end = start + GuideViewModel.WINDOW_MIN * 60_000L
                            row.programmes.forEach { p ->
                                val s = maxOf(p.startMs, start); val e = minOf(p.endMs, end)
                                val w = ((e - s) / 60_000f * dpPerMin).dp - 2.dp
                                if (w > 14.dp) Focusable({ details = row.channel to p }, Modifier.offset(x = ((s - start) / 60_000f * dpPerMin).dp).width(w).fillMaxHeight(), scaleOnFocus = 1.0f, shape = RoundedCornerShape(6.dp),
                                    container = if (p.isLive(now)) Tokens.elevated else Tokens.card) { _ ->
                                    Column(Modifier.padding(horizontal = 6.dp, vertical = 3.dp), verticalArrangement = Arrangement.Center) {
                                        Label(p.title, Tokens.caption, if (p.isLive(now)) Tokens.accent else Tokens.text, FontWeight.Medium, maxLines = 1)
                                        Label(clock(p.startMs), Tokens.caption, Tokens.textTertiary, maxLines = 1)
                                    }
                                }
                            }
                            if (now in start..(start + GuideViewModel.WINDOW_MIN * 60_000L)) Box(Modifier.offset(x = ((now - start) / 60_000f * dpPerMin).dp).width(1.5.dp).fillMaxHeight().background(Tokens.danger))
                        }
                    }
                }
            }
        }
    }

    details?.let { (ch, p) ->
        val fav = ch.id in vm.favs.collectAsState().value
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
private fun Chip2(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.04f) { f ->
        Row(Modifier.padding(horizontal = 11.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, null, Modifier.size(14.dp), colorFilter = ColorFilter.tint(if (f) Tokens.accent else Tokens.textSecondary))
            Label(label, Tokens.small, Tokens.text, FontWeight.Medium)
        }
    }
}
