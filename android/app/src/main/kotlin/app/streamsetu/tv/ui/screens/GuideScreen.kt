package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import java.text.DateFormat
import java.util.Date

/** What is on now and next, channel by channel. OK plays the channel. */
@Composable
fun GuideScreen(vm: GuideViewModel, c: AppContainer, nav: Navigator) {
    val rows by vm.rows.collectAsState()
    if (rows.isEmpty()) { EmptyState("No guide yet", "Your playlist has no programme guide, or it has not been read yet. Use Refresh in Settings."); return }
    val time = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    val queue = remember(rows) { rows.map { ChannelPlayable(it.channel) } }
    val now = System.currentTimeMillis()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 36.dp, end = Tokens.screenPadding, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Label("Guide", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(bottom = 10.dp)) }
        items(rows, key = { it.channel.id }) { row ->
            Focusable({ play(c, nav, ChannelPlayable(row.channel), queue) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.02f) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    ChannelLogo(row.channel.logoUrl, row.channel.name)
                    Label(row.channel.name, weight = FontWeight.SemiBold, modifier = Modifier.width(220.dp))
                    row.programmes.take(3).forEachIndexed { i, p ->
                        Column(Modifier.weight(1f)) {
                            Label(if (p.isLive(now)) "Now" else time.format(Date(p.startMs)), Tokens.small, if (p.isLive(now)) Tokens.accent else Tokens.muted)
                            Label(p.title, Tokens.small, Tokens.text)
                        }
                    }
                }
            }
        }
    }
}
