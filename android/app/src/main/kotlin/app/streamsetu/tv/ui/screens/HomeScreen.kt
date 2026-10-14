package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
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
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Pin
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import java.text.DateFormat
import java.util.Date

/** Home, laid out like the Mac: the sidebar (Discover, Continue Watching, Recently Watched, Watch History, Favorites, Watch Later) and a page for each. */
@Composable
fun HomeScreen(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    var sel by rememberSaveable { mutableStateOf("discover") }
    Row(Modifier.fillMaxSize()) {
        ContextSidebar(Pin.forTab(Tab.HOME), emptyList(), sel, { sel = it })
        Box(Modifier.weight(1f).fillMaxHeight()) {
            when (sel) {
                "discover" -> Discover(vm, c, nav)
                "continue" -> ContinuePage(vm, c, nav)
                "recent" -> RecentPage(vm, c, nav)
                "history" -> HistoryPage(vm, c, nav)
                "favorites" -> FavouritesPage(vm, c, nav)
                "later" -> MoviesPage("Watch Later", vm.watchLater.collectAsState().value, c, nav)
            }
        }
    }
}

@Composable
private fun Discover(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val featured by vm.featured.collectAsState()
    val resume by vm.continueWatching.collectAsState()
    val recent by vm.recentChannels.collectAsState()
    val yours by vm.yourChannels.collectAsState()
    val favs by vm.favourites.collectAsState()
    val movies by vm.latestMovies.collectAsState()
    val series by vm.someSeries.collectAsState()

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 24.dp, top = 14.dp, end = Tokens.screenPadding, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (featured.isNotEmpty()) item {
            FeaturedBanner(featured, onOpen = { f -> if (f is SeriesFeature) nav.open(Overlay.SeriesDetail(f.series)) else if (f is MoviePlayable) nav.open(Overlay.MovieDetail(f.movie)) else play(c, nav, f) })
        }
        if (resume.isNotEmpty()) item {
            Shelf("Continue Watching") { items(resume, key = { it.playable.id }) { r -> LandscapeCard(r.playable.title, remainingText(r), r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = r.progress.fraction) } }
        }
        if (yours.isNotEmpty()) item { ChannelShelf("Your Channels", yours, c, nav) }
        if (favs.isNotEmpty()) item { ChannelShelf("Favorites", favs, c, nav) }
        if (recent.isNotEmpty()) item { ChannelShelf("Recently Watched Channels", recent, c, nav) }
        if (movies.isNotEmpty()) item {
            Shelf("New Movies") { items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = listOfNotNull(m.year?.toString(), m.rating?.takeIf { it != "0" }?.let { "★ $it" }).joinToString(" · ").ifBlank { null }) } }
        }
        if (series.isNotEmpty()) item {
            Shelf("Series") { items(series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, subtitle = s.year?.toString()) } }
        }
    }
}

@Composable
private fun PageFrame(title: String, subtitle: String?, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize().padding(start = 24.dp, top = 16.dp, end = Tokens.screenPadding)) {
        Label(title, Tokens.pageTitle, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 2.dp))
        if (subtitle != null) Label(subtitle, Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(bottom = 8.dp))
        content()
    }
}

@Composable
fun MoviesPage(title: String, movies: List<Movie>, c: AppContainer, nav: Navigator) {
    PageFrame(title, "${movies.size} ${if (movies.size == 1) "movie" else "movies"}") {
        if (movies.isEmpty()) EmptyState("Nothing here yet", "Movies you add to $title appear here.")
        else LazyVerticalGrid(GridCells.Adaptive(Tokens.posterWidth), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(top = 4.dp, bottom = 28.dp), modifier = Modifier.focusRestorer()) {
            items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString(), badge = ratingBadge(m.rating)) }
        }
    }
}

@Composable
private fun ContinuePage(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val resume by vm.continueWatching.collectAsState()
    PageFrame("Continue Watching", "${resume.size} to resume") {
        if (resume.isEmpty()) EmptyState("Nothing to resume", "Start a movie or episode and it will wait for you here.")
        else LazyVerticalGrid(GridCells.Adaptive(Tokens.landscapeWidth), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(top = 4.dp, bottom = 28.dp), modifier = Modifier.focusRestorer()) {
            items(resume, key = { it.playable.id }) { r -> LandscapeCard(r.playable.title, remainingText(r), r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = r.progress.fraction, width = Tokens.landscapeWidth) }
        }
    }
}

@Composable
private fun RecentPage(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val recent by vm.recentChannels.collectAsState()
    PageFrame("Recently Watched", "${recent.size} channels") {
        if (recent.isEmpty()) EmptyState("No channels yet", "Channels you watch show up here.")
        else ChannelList(recent, c, nav)
    }
}

@Composable
private fun HistoryPage(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val history by vm.history.collectAsState()
    val fmt = remember { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT) }
    PageFrame("Watch History", "${history.size} entries") {
        if (history.isEmpty()) EmptyState("No history yet", "What you watch is listed here, newest first.")
        else LazyColumn(Modifier.focusRestorer(), verticalArrangement = Arrangement.spacedBy(3.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
            items(history, key = { it.id }) { h ->
                Focusable({ vm.replay(h, c, nav) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.01f, hairline = true) {
                    Row(Modifier.padding(horizontal = 10.dp, vertical = 5.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Label(h.title, Tokens.row, Tokens.text, FontWeight.Medium, modifier = Modifier.weight(1f))
                        Label(h.kind.lowercase().replaceFirstChar { it.uppercase() }, Tokens.small, Tokens.textTertiary)
                        Label(fmt.format(Date(h.playedAt)), Tokens.small, Tokens.textTertiary)
                    }
                }
            }
        }
    }
}

@Composable
private fun FavouritesPage(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val chans by vm.favourites.collectAsState()
    val movies by vm.favouriteMovies.collectAsState()
    PageFrame("Favorites", "${chans.size + movies.size} saved") {
        if (chans.isEmpty() && movies.isEmpty()) EmptyState("No favorites yet", "Press the star next to a channel, or Favorite on a movie, to keep it here.")
        else LazyColumn(Modifier.focusRestorer(), verticalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
            if (chans.isNotEmpty()) item { ChannelShelf("Channels", chans, c, nav) }
            if (movies.isNotEmpty()) item { Shelf("Movies") { items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString()) } } }
        }
    }
}

private fun remainingText(r: HomeViewModel.ResumeItem): String {
    val left = ((r.progress.durationMs - r.progress.positionMs) / 60000).toInt().coerceAtLeast(0)
    return if (left >= 1) "Resume · ${left}m left" else "Almost done"
}

@Composable
fun Shelf(title: String, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column {
        SectionTitle(title)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 6.dp), modifier = Modifier.focusRestorer(), content = content)
    }
}

@Composable
fun ChannelShelf(title: String, channels: List<Channel>, c: AppContainer, nav: Navigator) {
    Shelf(title) {
        items(channels, key = { it.id }) { ch ->
            Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.width(88.dp)) {
                Column(Modifier.padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ChannelLogo(ch.logoUrl, ch.name, 40.dp)
                    Label(ch.name, Tokens.small, Tokens.text, FontWeight.Medium)
                }
            }
        }
    }
}

@Composable
fun ChannelList(channels: List<Channel>, c: AppContainer, nav: Navigator) {
    LazyColumn(Modifier.focusRestorer(), verticalArrangement = Arrangement.spacedBy(4.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
        items(channels, key = { it.id }) { ch ->
            Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.01f, hairline = true) {
                Row(Modifier.padding(6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    ChannelLogo(ch.logoUrl, ch.name, 28.dp); Label(ch.name, Tokens.row, Tokens.text, FontWeight.Medium)
                }
            }
        }
    }
}

/** "★ 7.3" for a rating worth showing (providers send 0 or nothing when they do not know). */
fun ratingBadge(r: String?): String? = r?.toDoubleOrNull()?.takeIf { it > 0.0 }?.let { "★ " + (if (it >= 10) "10" else String.format("%.1f", it)) }
