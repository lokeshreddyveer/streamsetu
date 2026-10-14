package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Pin
import app.streamsetu.tv.nav.Tab
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
    Row(Modifier.fillMaxSize()) {
        ContextSidebar(Pin.forTab(Tab.GUIDE), emptyList(), sel, { sel = it }, pinId = { if (it == Pin.FAVOURITES) "favorites" else "all" })
        Column(Modifier.weight(1f).fillMaxHeight().padding(start = 24.dp, top = 16.dp, end = Tokens.screenPadding)) {
            Label("TV Guide", Tokens.pageTitle, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 8.dp))
            if (rows.isEmpty()) EmptyState("No guide yet", "Your playlist has no programme guide, or it has not been read yet. Use Refresh in Settings → Library.")
            else LazyColumn(Modifier.focusRestorer(), verticalArrangement = Arrangement.spacedBy(3.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
                items(rows, key = { it.channel.id }) { row ->
                    Focusable({ play(c, nav, ChannelPlayable(row.channel), queue) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.01f, hairline = true) {
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            ChannelLogo(row.channel.logoUrl, row.channel.name, 34.dp)
                            Label(row.channel.name, Tokens.row, Tokens.text, FontWeight.Medium, modifier = Modifier.width(190.dp))
                            row.programmes.take(3).forEach { p ->
                                Column(Modifier.weight(1f)) {
                                    Label(if (p.isLive(now)) "Now" else time.format(Date(p.startMs)), Tokens.caption, if (p.isLive(now)) Tokens.accent else Tokens.textTertiary)
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
