package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

@Composable
fun HomeScreen(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val resume by vm.continueWatching.collectAsState()
    val recent by vm.recentChannels.collectAsState()
    val yours by vm.yourChannels.collectAsState()
    val favs by vm.favourites.collectAsState()
    val movies by vm.latestMovies.collectAsState()
    val series by vm.someSeries.collectAsState()

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 36.dp, end = Tokens.screenPadding, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) {
        item { Label("Home", Tokens.title, Tokens.text, androidx.compose.ui.text.font.FontWeight.Bold) }
        if (resume.isNotEmpty()) item {
            Column { SectionTitle("Continue Watching")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
                    items(resume, key = { it.playable.id }) { r -> PosterCard(r.playable.title, r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = r.progress.fraction) }
                } }
        }
        if (yours.isNotEmpty()) item { ChannelRow("Your Channels", yours, c, nav) }
        if (favs.isNotEmpty()) item { ChannelRow("Favourites", favs, c, nav) }
        if (recent.isNotEmpty()) item { ChannelRow("Recently Watched Channels", recent, c, nav) }
        if (movies.isNotEmpty()) item {
            Column { SectionTitle("New Movies")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
                    items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { play(c, nav, MoviePlayable(m)) }) }
                } }
        }
        if (series.isNotEmpty()) item {
            Column { SectionTitle("Series")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
                    items(series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }) }
                } }
        }
        if (resume.isEmpty() && recent.isEmpty() && movies.isEmpty() && series.isEmpty() && favs.isEmpty())
            item { Label("Pick Live TV, Movies or Series on the left to start watching.", color = Tokens.muted) }
    }
}

@Composable
private fun ChannelRow(title: String, channels: List<Channel>, c: AppContainer, nav: Navigator) {
    Column {
        SectionTitle(title)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
            items(channels, key = { it.id }) { ch ->
                Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.width(150.dp)) {
                    Column(Modifier.padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        ChannelLogo(ch.logoUrl, ch.name, 72.dp)
                        Label(ch.name, Tokens.small, Tokens.text)
                    }
                }
            }
        }
    }
}
