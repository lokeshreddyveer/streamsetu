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

/** Home, like a streaming service: a full-bleed hero, then rows (Continue Watching, Watch Later, your channels, new movies, series). */
@Composable
fun HomeScreen(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val featured by vm.featured.collectAsState()
    val resume by vm.continueWatching.collectAsState()
    val later by vm.watchLater.collectAsState()
    val recent by vm.recentChannels.collectAsState()
    val yours by vm.yourChannels.collectAsState()
    val favs by vm.favourites.collectAsState()
    val favMovies by vm.favouriteMovies.collectAsState()
    val movies by vm.latestMovies.collectAsState()
    val series by vm.someSeries.collectAsState()
    val rowPad = PaddingValues(horizontal = Tokens.screenPadding, vertical = 6.dp)

    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val atTop by remember { derivedStateOf { listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 40 } }
    LaunchedEffect(atTop) { nav.homeAtTop = atTop }
    DisposableEffect(Unit) { onDispose { nav.homeAtTop = true } }
    LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(bottom = 36.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (featured.isNotEmpty()) item {
            Hero(featured, loadInfo = { c.sync.movieInfo(it) },
                onPlay = { f -> play(c, nav, f) },
                onDetails = { f -> if (f is SeriesFeature) nav.open(Overlay.SeriesDetail(f.series)) else if (f is MoviePlayable) nav.open(Overlay.MovieDetail(f.movie)) })
        }
        if (resume.isNotEmpty()) item { Shelf("Continue Watching", rowPad) { items(resume, key = { it.playable.id }) { r -> LandscapeCard(r.playable.title, remainingText(r), r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = r.progress.fraction) } } }
        if (later.isNotEmpty()) item { Shelf("Watch Later", rowPad) { items(later, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString(), badge = ratingBadge(m.rating)) } } }
        if (yours.isNotEmpty()) item { ChannelShelf("Your Channels", yours, c, nav, rowPad) }
        if (favs.isNotEmpty()) item { ChannelShelf("Favorite Channels", favs, c, nav, rowPad) }
        if (favMovies.isNotEmpty()) item { Shelf("Favorite Movies", rowPad) { items(favMovies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString(), badge = ratingBadge(m.rating)) } } }
        if (recent.isNotEmpty()) item { ChannelShelf("Recently Watched", recent, c, nav, rowPad) }
        if (movies.isNotEmpty()) item { Shelf("New Movies", rowPad) { items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString(), badge = ratingBadge(m.rating)) } } }
        if (series.isNotEmpty()) item { Shelf("Series", rowPad) { items(series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, subtitle = s.year?.toString(), badge = ratingBadge(s.rating)) } } }
    }
}

private fun remainingText(r: HomeViewModel.ResumeItem): String {
    val left = ((r.progress.durationMs - r.progress.positionMs) / 60000).toInt().coerceAtLeast(0)
    return if (left >= 1) "${left}m left" else "Almost done"
}

@Composable
fun Shelf(title: String, padding: PaddingValues = PaddingValues(horizontal = Tokens.screenPadding, vertical = 6.dp), content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column {
        Label(title, Tokens.heading, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(start = Tokens.screenPadding, top = 4.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = padding, content = content)
    }
}

@Composable
fun ChannelShelf(title: String, channels: List<Channel>, c: AppContainer, nav: Navigator, padding: PaddingValues) {
    Shelf(title, padding) {
        items(channels, key = { it.id }) { ch ->
            Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.width(96.dp), shape = androidx.compose.foundation.shape.RoundedCornerShape(Tokens.radius)) {
                Column(Modifier.padding(horizontal = 8.dp, vertical = 10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    ChannelLogo(ch.logoUrl, ch.name, 44.dp)
                    Label(ch.name, Tokens.caption, Tokens.text, FontWeight.Medium)
                }
            }
        }
    }
}

/** "★ 7.3" for a rating worth showing (providers send 0 or nothing when they do not know). */
fun ratingBadge(r: String?): String? = r?.toDoubleOrNull()?.takeIf { it > 0.0 }?.let { "★ " + (if (it >= 10) "10" else String.format("%.1f", it)) }
