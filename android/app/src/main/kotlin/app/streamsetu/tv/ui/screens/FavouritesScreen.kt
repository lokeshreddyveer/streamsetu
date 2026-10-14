package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
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

/** Favourite channels (OK plays, the star removes) and movies saved for later. */
@Composable
fun FavouritesScreen(vm: FavouritesViewModel, c: AppContainer, nav: Navigator) {
    val channels by vm.channels.collectAsState()
    val later by vm.watchLater.collectAsState()
    if (channels.isEmpty() && later.isEmpty()) { EmptyState("No favourites yet", "In Live TV, press the star next to a channel to keep it here."); return }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 36.dp, end = Tokens.screenPadding, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item { Label("Favourites", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(bottom = 10.dp)) }
        items(channels, key = { it.id }) { ch ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.weight(1f), scaleOnFocus = 1.02f) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        ChannelLogo(ch.logoUrl, ch.name); Label(ch.name, weight = FontWeight.SemiBold)
                    }
                }
                TvButton("Remove", { vm.remove(ch) })
            }
        }
        if (later.isNotEmpty()) item {
            Column(Modifier.padding(top = 20.dp)) { SectionTitle("Watch Later")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp)) { items(later, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { play(c, nav, MoviePlayable(m)) }) } } }
        }
    }
}
