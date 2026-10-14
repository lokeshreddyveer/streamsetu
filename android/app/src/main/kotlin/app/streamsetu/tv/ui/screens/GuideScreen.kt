package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.ui.focus.focusRequester
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import java.text.DateFormat
import java.util.Date

/** The TV Guide: what is on now and next, channel by channel. OK plays the channel. */
@Composable
fun GuideScreen(vm: GuideViewModel, c: AppContainer, nav: Navigator) {
    var sel by rememberSaveable { mutableStateOf("all") }
    val rows by remember(sel) { vm.rows(sel) }.collectAsState(initial = emptyList())
    val time = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    val queue = remember(rows) { rows.map { ChannelPlayable(it.channel) } }
    val now = System.currentTimeMillis()
    val firstRow = remember { androidx.compose.ui.focus.FocusRequester() }
    Column(Modifier.fillMaxSize()) {
        ChipRow(listOf(Chip("all", "All Channels"), Chip("favorites", "Favorites")), sel, { sel = it }, below = firstRow)
        Column(Modifier.weight(1f).fillMaxWidth().padding(start = Tokens.screenPadding, end = Tokens.screenPadding, top = 4.dp)) {
            if (rows.isEmpty()) EmptyState("No guide yet", "Your playlist has no programme guide, or it has not been read yet. Use Refresh in Settings → Library.")
            else LazyColumn(verticalArrangement = Arrangement.spacedBy(3.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
                itemsIndexed(rows, key = { _, it -> it.channel.id }) { i, row ->
                    Focusable({ play(c, nav, ChannelPlayable(row.channel), queue) }, (if (i == 0) Modifier.focusRequester(firstRow) else Modifier).fillMaxWidth(), scaleOnFocus = 1.0f, container = Tokens.card) {
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            ChannelLogo(row.channel.logoUrl, row.channel.name, 28.dp)
                            Label(row.channel.name, Tokens.row, Tokens.text, FontWeight.SemiBold, modifier = Modifier.width(180.dp))
                            row.programmes.take(3).forEach { p ->
                                Column(Modifier.weight(1f)) {
                                    Label(if (p.isLive(now)) "NOW" else time.format(Date(p.startMs)), Tokens.caption, if (p.isLive(now)) Tokens.accent else Tokens.textTertiary, FontWeight.Bold)
                                    Label(p.title, Tokens.small, Tokens.text)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
