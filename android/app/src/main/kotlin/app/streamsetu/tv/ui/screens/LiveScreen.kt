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
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Pin
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

/** Live TV like the Mac: shortcuts and folders in the sidebar, the channels of the chosen entry on the right with what is on now. OK plays; the star favourites. */
@Composable
fun LiveScreen(vm: LiveViewModel, c: AppContainer, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    var sel by rememberSaveable { mutableStateOf("all") }
    val channels by remember(sel) { vm.channelsFor(sel) }.collectAsState(initial = emptyList())
    val favs by vm.favouriteIds.collectAsState()
    var nowOn by remember { mutableStateOf<Map<String, EpgProgram>>(emptyMap()) }
    LaunchedEffect(channels) { nowOn = vm.nowOn(channels.take(300)) }

    if (categories.isEmpty() && channels.isEmpty()) { EmptyState("No channels yet", "This playlist has no live channels. Add one in Settings."); return }
    val title = Pin.forTab(Tab.LIVE).firstOrNull { it.id == sel }?.title ?: categories.firstOrNull { it.id == sel }?.name ?: "Channels"

    Row(Modifier.fillMaxSize()) {
        ContextSidebar(Pin.forTab(Tab.LIVE), categories, sel, { sel = it })
        Column(Modifier.weight(1f).fillMaxHeight().padding(start = 24.dp, top = 16.dp, end = Tokens.screenPadding)) {
            Label(title, Tokens.pageTitle, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 2.dp))
            Label("${channels.size} channels", Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(bottom = 8.dp))
            LazyColumn(verticalArrangement = Arrangement.spacedBy(3.dp), contentPadding = PaddingValues(bottom = 28.dp), modifier = Modifier.focusRestorer()) {
                items(channels, key = { it.id }) { ch ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.weight(1f), scaleOnFocus = 1.01f, hairline = true) {
                            Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                ChannelLogo(ch.logoUrl, ch.name, 34.dp)
                                Column(Modifier.weight(1f)) {
                                    Label(ch.name, Tokens.row, Tokens.text, FontWeight.Medium)
                                    nowOn[ch.epgId]?.let { Label(it.title, Tokens.caption, Tokens.textSecondary) }
                                }
                            }
                        }
                        Focusable({ vm.toggleFavourite(ch) }, Modifier.size(40.dp), scaleOnFocus = 1.1f, hairline = true) {
                            Box(Modifier.fillMaxSize(), Alignment.Center) { Label(if (ch.id in favs) "★" else "☆", Tokens.heading, if (ch.id in favs) Tokens.accent else Tokens.textTertiary) }
                        }
                    }
                }
            }
        }
    }
}
