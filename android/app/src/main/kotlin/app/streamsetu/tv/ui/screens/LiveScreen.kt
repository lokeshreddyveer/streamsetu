package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

/** Live TV like the Mac: folders in the sidebar, the channels of the chosen folder on the right with what is on now. OK plays; the star favourites. */
@Composable
fun LiveScreen(vm: LiveViewModel, c: AppContainer, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    val selected by vm.selectedCategory.collectAsState()
    val channels by vm.channels.collectAsState()
    val favs by vm.favouriteIds.collectAsState()
    val nowOn by vm.nowOn.collectAsState()
    val current = selected ?: categories.firstOrNull()?.id

    if (categories.isEmpty()) { EmptyState("No channels yet", "This playlist has no live channels. Add one in Settings."); return }

    Row(Modifier.fillMaxSize()) {
        ContextSidebar("Live TV", categories, current, vm::select)
        Column(Modifier.weight(1f).fillMaxHeight().padding(start = 28.dp, top = 22.dp, end = Tokens.screenPadding)) {
            Label(categories.firstOrNull { it.id == current }?.name ?: "Channels", Tokens.pageTitle, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 4.dp))
            Label("${channels.size} channels", Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(bottom = 12.dp))
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp), contentPadding = PaddingValues(bottom = 40.dp)) {
                items(channels, key = { it.id }) { ch ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.weight(1f), scaleOnFocus = 1.02f, hairline = true) {
                            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                ChannelLogo(ch.logoUrl, ch.name, 52.dp)
                                Column(Modifier.weight(1f)) {
                                    Label(ch.name, Tokens.body, Tokens.text, FontWeight.Medium)
                                    nowOn[ch.epgId]?.let { Label(it.title, Tokens.small, Tokens.textSecondary) }
                                }
                            }
                        }
                        Focusable({ vm.toggleFavourite(ch) }, Modifier.size(56.dp), scaleOnFocus = 1.1f, hairline = true) {
                            Box(Modifier.fillMaxSize(), Alignment.Center) { Label(if (ch.id in favs) "★" else "☆", Tokens.title, if (ch.id in favs) Tokens.accent else Tokens.textTertiary) }
                        }
                    }
                }
            }
        }
    }
}
