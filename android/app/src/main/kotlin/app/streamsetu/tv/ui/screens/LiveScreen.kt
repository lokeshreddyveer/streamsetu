package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
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

/** Categories on the left, the channels of the chosen category on the right, with what is on now. OK plays; the star button favourites. */
@Composable
fun LiveScreen(vm: LiveViewModel, c: AppContainer, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    val selected by vm.selectedCategory.collectAsState()
    val channels by vm.channels.collectAsState()
    val favs by vm.favouriteIds.collectAsState()
    val nowOn by vm.nowOn.collectAsState()
    val current = selected ?: categories.firstOrNull()?.id

    if (categories.isEmpty()) { EmptyState("No channels yet", "This playlist has no live channels. Add one in Settings."); return }

    Row(Modifier.fillMaxSize().padding(top = 36.dp, end = Tokens.screenPadding), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
        LazyColumn(Modifier.width(260.dp), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 40.dp)) {
            item { Label("Live TV", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(bottom = 12.dp)) }
            items(categories, key = { it.id }) { cat ->
                Focusable({ vm.select(cat.id) }, Modifier.fillMaxWidth(), container = if (cat.id == current) Tokens.surfaceHigh else Tokens.surface, scaleOnFocus = 1.02f) {
                    Label(cat.name, color = if (cat.id == current) Tokens.accent else Tokens.text, modifier = Modifier.padding(14.dp))
                }
            }
        }
        val state = rememberLazyListState()
        LazyColumn(Modifier.weight(1f), state = state, verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 40.dp)) {
            items(channels, key = { it.id }) { ch ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.weight(1f), scaleOnFocus = 1.02f) {
                        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            ChannelLogo(ch.logoUrl, ch.name)
                            Column(Modifier.weight(1f)) {
                                Label(ch.name, weight = FontWeight.SemiBold)
                                nowOn[ch.epgId]?.let { Label(it.title, Tokens.small, Tokens.muted) }
                            }
                        }
                    }
                    Focusable({ vm.toggleFavourite(ch) }, Modifier.size(56.dp), scaleOnFocus = 1.1f) {
                        Box(Modifier.fillMaxSize(), Alignment.Center) { Label(if (ch.id in favs) "★" else "☆", 26.sp, if (ch.id in favs) Tokens.accent else Tokens.muted) }
                    }
                }
            }
        }
    }
}

private val Int.sp get() = androidx.compose.ui.unit.TextUnit(this.toFloat(), androidx.compose.ui.unit.TextUnitType.Sp)
