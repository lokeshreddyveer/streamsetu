package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.core.sync.upcoming
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import java.text.DateFormat
import java.util.Date

/**
 * Live TV like a TV-guide app: category pills on top; the channel list on the left; on the right a panel for the highlighted channel
 * with what is on now (with progress), what is next, and the story. OK plays; the star favourites.
 */
@Composable
fun LiveScreen(vm: LiveViewModel, c: AppContainer, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    var sel by rememberSaveable { mutableStateOf("all") }
    val channelsOrNull by remember(sel) { vm.channelsFor(sel) }.collectAsState(initial = null)
    val channels = channelsOrNull ?: emptyList()
    val favs by vm.favouriteIds.collectAsState()
    var nowOn by remember { mutableStateOf<Map<String, EpgProgram>>(emptyMap()) }
    LaunchedEffect(channels) { nowOn = vm.nowOn(channels.take(300)) }
    var highlighted by remember(sel) { mutableStateOf<Channel?>(null) }
    var upcoming by remember { mutableStateOf<List<EpgProgram>>(emptyList()) }
    LaunchedEffect(highlighted?.id) { upcoming = highlighted?.epgId?.let { runCatching { c.epg.upcoming(c.db, it, 3) }.getOrNull() }.orEmpty() }

    if (channelsOrNull == null && categories.isEmpty()) { Loading(); return }
    if (categories.isEmpty() && channels.isEmpty()) { EmptyState("No channels yet", "This playlist has no live channels. Add one in Settings."); return }
    val chips = listOf(Chip("all", "All Channels", Icons.Filled.LiveTv), Chip("recent", "Recently Watched", Icons.Filled.History), Chip("favorites", "Favorites", Icons.Filled.FavoriteBorder))
    val folders = categories.map { Chip(it.id, it.name) }
    val folder = folders.firstOrNull { it.id == sel }
    val firstRow = remember { androidx.compose.ui.focus.FocusRequester() }
    var picking by remember { mutableStateOf(false) }
    if (picking) CategoryPicker("Channel categories", folders, sel, { sel = it; picking = false }, { picking = false })

    Column(Modifier.fillMaxSize()) {
        ChipRow(chips, sel, { sel = it }, moreLabel = folder?.title, moreSelected = folder != null, onMore = { picking = true }, below = firstRow)
        Row(Modifier.fillMaxSize().padding(start = Tokens.screenPadding, end = Tokens.screenPadding, top = 4.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            LazyColumn(Modifier.weight(1.15f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(3.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
                itemsIndexed(channels, key = { _, ch -> ch.id }) { index, ch ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, (if (index == 0) Modifier.focusRequester(firstRow) else Modifier).weight(1f), scaleOnFocus = 1.0f, container = Tokens.card, onFocus = { if (it) highlighted = ch }) { f ->
                            Row(Modifier.padding(horizontal = 8.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                                Label("${ch.number ?: index + 1}", Tokens.caption, if (f) Tokens.accent else Tokens.textTertiary, FontWeight.Bold, modifier = Modifier.width(28.dp))
                                ChannelLogo(ch.logoUrl, ch.name, 26.dp)
                                Column(Modifier.weight(1f)) {
                                    Label(ch.name, Tokens.row, Tokens.text, FontWeight.SemiBold)
                                    nowOn[ch.epgId]?.let { p ->
                                        Label(p.title, Tokens.caption, Tokens.textSecondary)
                                        val frac = ((System.currentTimeMillis() - p.startMs).toFloat() / (p.endMs - p.startMs).coerceAtLeast(1)).coerceIn(0f, 1f)
                                        Box(Modifier.padding(top = 2.dp).fillMaxWidth().height(2.dp).background(Tokens.line)) { Box(Modifier.fillMaxWidth(frac).fillMaxHeight().background(Tokens.accent)) }
                                    }
                                }
                            }
                        }
                        Focusable({ vm.toggleFavourite(ch) }, Modifier.size(30.dp), scaleOnFocus = 1.1f, container = Tokens.card) {
                            Box(Modifier.fillMaxSize(), Alignment.Center) { Label(if (ch.id in favs) "★" else "☆", Tokens.heading, if (ch.id in favs) Tokens.accent else Tokens.textTertiary) }
                        }
                    }
                }
            }
            ChannelPanel(highlighted ?: channels.firstOrNull(), upcoming, Modifier.weight(1f).fillMaxHeight().padding(bottom = 24.dp))
        }
    }
}

@Composable
private fun ChannelPanel(ch: Channel?, programmes: List<EpgProgram>, modifier: Modifier) {
    val time = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    Column(modifier.background(Tokens.card, RoundedCornerShape(Tokens.radiusLarge)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (ch == null) { Label("Pick a channel", Tokens.heading, Tokens.textSecondary); return@Column }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ChannelLogo(ch.logoUrl, ch.name, 46.dp)
            Column {
                Label(ch.name, Tokens.title, Tokens.text, FontWeight.Bold, maxLines = 2)
                Label(listOfNotNull(ch.number?.let { "Channel $it" }, if (ch.catchupDays > 0) "Catch-up ${ch.catchupDays} days" else null).joinToString("  ·  ").ifBlank { "Live" }, Tokens.caption, Tokens.textTertiary)
            }
        }
        val now = System.currentTimeMillis()
        val current = programmes.firstOrNull { it.isLive(now) }
        val next = programmes.firstOrNull { it.startMs > now }
        if (current == null && next == null) {
            Spacer(Modifier.height(6.dp)); Label("No programme guide for this channel.", Tokens.small, Tokens.textTertiary)
        }
        if (current != null) {
            Spacer(Modifier.height(4.dp))
            Eyebrow("On now", color = Tokens.accent)
            Label(current.title, Tokens.heading, Tokens.text, FontWeight.SemiBold, maxLines = 2)
            Label("${time.format(Date(current.startMs))} – ${time.format(Date(current.endMs))}", Tokens.caption, Tokens.textSecondary)
            val frac = ((now - current.startMs).toFloat() / (current.endMs - current.startMs).coerceAtLeast(1)).coerceIn(0f, 1f)
            Box(Modifier.fillMaxWidth().height(3.dp).background(Tokens.line, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(frac).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
            current.description?.let { Label(it, Tokens.small, Tokens.textSecondary, maxLines = 4) }
        }
        if (next != null) {
            Spacer(Modifier.height(6.dp))
            Eyebrow("Next · ${time.format(Date(next.startMs))}")
            Label(next.title, Tokens.row, Tokens.text, FontWeight.Medium, maxLines = 2)
        }
    }
}
