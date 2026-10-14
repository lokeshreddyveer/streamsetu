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
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

/** Home, laid out like the Mac: the banner, then shelves (Continue Watching, your channels, favourites, new movies, series). */
@Composable
fun HomeScreen(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val featured by vm.featured.collectAsState()
    val resume by vm.continueWatching.collectAsState()
    val recent by vm.recentChannels.collectAsState()
    val yours by vm.yourChannels.collectAsState()
    val favs by vm.favourites.collectAsState()
    val movies by vm.latestMovies.collectAsState()
    val series by vm.someSeries.collectAsState()

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = Tokens.screenPadding, top = 20.dp, end = Tokens.screenPadding, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(26.dp)) {
        if (featured.isNotEmpty()) item {
            FeaturedBanner(featured, onOpen = { f -> if (f is SeriesFeature) nav.open(Overlay.SeriesDetail(f.series)) else play(c, nav, f) })
        }
        if (resume.isNotEmpty()) item {
            Shelf("Continue Watching") {
                items(resume, key = { it.playable.id }) { r -> LandscapeCard(r.playable.title, remainingText(r), r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = r.progress.fraction) }
            }
        }
        if (yours.isNotEmpty()) item { ChannelShelf("Your Channels", yours, c, nav) }
        if (favs.isNotEmpty()) item { ChannelShelf("Favourites", favs, c, nav) }
        if (recent.isNotEmpty()) item { ChannelShelf("Recently Watched Channels", recent, c, nav) }
        if (movies.isNotEmpty()) item {
            Shelf("New Movies") { items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { play(c, nav, MoviePlayable(m)) }, subtitle = listOfNotNull(m.year?.toString(), m.rating?.takeIf { it != "0" }?.let { "★ $it" }).joinToString(" · ").ifBlank { null }) } }
        }
        if (series.isNotEmpty()) item {
            Shelf("Series") { items(series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, subtitle = s.year?.toString()) } }
        }
    }
}

private fun remainingText(r: HomeViewModel.ResumeItem): String {
    val left = ((r.progress.durationMs - r.progress.positionMs) / 60000).toInt().coerceAtLeast(0)
    return if (left >= 1) "Resume · ${left}m left" else "Almost done"
}

@Composable
private fun Shelf(title: String, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column {
        SectionTitle(title)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(vertical = 10.dp), content = content)
    }
}

@Composable
private fun ChannelShelf(title: String, channels: List<Channel>, c: AppContainer, nav: Navigator) {
    Shelf(title) {
        items(channels, key = { it.id }) { ch ->
            Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.width(150.dp)) {
                Column(Modifier.padding(14.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ChannelLogo(ch.logoUrl, ch.name, 72.dp)
                    Label(ch.name, Tokens.small, Tokens.text, FontWeight.Medium)
                }
            }
        }
    }
}
