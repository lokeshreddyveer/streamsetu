package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.*
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import androidx.compose.ui.layout.ContentScale
import kotlinx.coroutines.launch

@Composable
fun MoviesScreen(vm: MoviesViewModel, c: AppContainer, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    var sel by rememberSaveable { mutableStateOf("featured") }
    val movies by remember(sel) { vm.moviesFor(sel) }.collectAsState(initial = emptyList())
    if (categories.isEmpty() && movies.isEmpty()) { EmptyState("No movies yet", "This playlist has no movies. Add one in Settings."); return }
    val title = Pin.forTab(Tab.MOVIES).firstOrNull { pinKey(it, Tab.MOVIES) == sel }?.title ?: categories.firstOrNull { it.id == sel }?.name ?: "Movies"
    Row(Modifier.fillMaxSize()) {
        ContextSidebar(Pin.forTab(Tab.MOVIES), categories, sel, { sel = it }, pinId = { pinKey(it, Tab.MOVIES) })
        Box(Modifier.weight(1f).fillMaxHeight()) { MoviesPage(title, movies, c, nav) }
    }
}

/** The sidebar's ids differ a little between sections ("Library" is "all" in Series, "All Movies" is "all" in Movies). */
private fun pinKey(p: Pin, tab: Tab): String = when (p) {
    Pin.RECENTLY_ADDED -> "added"
    Pin.CONTINUE -> "continue"
    Pin.FAVOURITES -> "favorites"
    Pin.WATCH_LATER -> "later"
    Pin.FEATURED -> "featured"
    Pin.ALL_MOVIES, Pin.LIBRARY -> "all"
    else -> p.id
}

@Composable
fun SeriesScreen(vm: SeriesViewModel, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    var sel by rememberSaveable { mutableStateOf("all") }
    val series by remember(sel) { vm.seriesFor(sel) }.collectAsState(initial = emptyList())
    if (categories.isEmpty() && series.isEmpty()) { EmptyState("No series yet", "This playlist has no series. Add an Xtream playlist in Settings."); return }
    val title = Pin.forTab(Tab.SERIES).firstOrNull { pinKey(it, Tab.SERIES) == sel }?.title ?: categories.firstOrNull { it.id == sel }?.name ?: "Series"
    Row(Modifier.fillMaxSize()) {
        ContextSidebar(Pin.forTab(Tab.SERIES), categories, sel, { sel = it }, pinId = { pinKey(it, Tab.SERIES) })
        Column(Modifier.weight(1f).fillMaxHeight().padding(start = 24.dp, top = 16.dp, end = Tokens.screenPadding)) {
            Label(title, Tokens.pageTitle, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 2.dp))
            Label("${series.size} series", Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(bottom = 8.dp))
            LazyVerticalGrid(GridCells.Adaptive(Tokens.posterWidth), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(top = 4.dp, bottom = 28.dp), modifier = Modifier.focusRestorer()) {
                items(series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, subtitle = s.year?.toString()) }
            }
        }
    }
}

/** A series, like the Mac's detail page: artwork and story on top, season chips, then the episodes. OK on an episode plays it and queues the rest. */
@Composable
fun SeriesDetailScreen(vm: SeriesDetailViewModel, c: AppContainer, nav: Navigator) {
    val episodes by vm.episodes.collectAsState()
    val loading by vm.loading.collectAsState()
    val error by vm.error.collectAsState()
    val progress by vm.progress.collectAsState()
    val s = vm.series
    val seasons = episodes.groupBy { it.season }.toSortedMap()
    var season by remember(seasons.keys) { mutableStateOf(seasons.keys.firstOrNull() ?: 1) }
    val queue = remember(episodes) { episodes.map { EpisodePlayable(it, s) } }
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsState(initial = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsState(initial = emptySet())
    val scope = rememberCoroutineScope()
    val first = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        if (!s.backdropUrl.isNullOrBlank()) AsyncImage(s.backdropUrl, null, Modifier.fillMaxWidth().height(220.dp), contentScale = ContentScale.Crop, alpha = 0.35f)
        Column(Modifier.fillMaxSize().padding(start = Tokens.screenPadding, top = 24.dp, end = Tokens.screenPadding)) {
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                Box(Modifier.width(110.dp).aspectRatio(150f / 218f)) { PosterPlaceholder(s.title, Modifier.fillMaxSize()); if (!s.posterUrl.isNullOrBlank()) AsyncImage(s.posterUrl, s.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Label(s.title, Tokens.display, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                    Label(listOfNotNull("Series", s.year?.toString(), s.rating?.takeIf { it != "0" }?.let { "★ $it" }).joinToString(" · "), Tokens.small, Tokens.textSecondary)
                    s.plot?.let { Label(it, Tokens.small, Tokens.textSecondary, maxLines = 3, modifier = Modifier.widthIn(max = 800.dp)) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 4.dp)) {
                        TvButton(if (s.id in favs) "Favorited" else "Favorite", { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in favs) } }, Modifier.focusRequester(first), icon = if (s.id in favs) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder)
                        TvButton(if (s.id in later) "In Watch Later" else "Watch Later", { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in later, UserRepository.WATCH_LATER) } }, icon = if (s.id in later) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder)
                    }
                }
            }
            if (loading && episodes.isEmpty()) Row(Modifier.padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Spinner(); Label("Loading episodes…", color = Tokens.textSecondary) }
            error?.let { if (episodes.isEmpty()) Label(it, color = Tokens.danger, modifier = Modifier.padding(top = 12.dp)) }
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 12.dp), modifier = Modifier.focusRestorer()) {
                items(seasons.keys.toList()) { n ->
                    Focusable({ season = n }, container = if (n == season) Tokens.accent.copy(alpha = 0.22f) else Tokens.card, scaleOnFocus = 1.05f) { f ->
                        LaunchedEffect(f) { if (f) season = n }
                        Label("Season $n", Tokens.small, if (n == season) Tokens.accent else Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp))
                    }
                }
            }
            LazyColumn(Modifier.focusRestorer(), verticalArrangement = Arrangement.spacedBy(3.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
                items(seasons[season].orEmpty(), key = { it.id }) { e ->
                    val p = progress[e.id]
                    Focusable({ play(c, nav, EpisodePlayable(e, s), queue) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.01f, hairline = true) {
                        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Label("${e.number}", Tokens.heading, Tokens.accent, FontWeight.Bold, modifier = Modifier.width(34.dp))
                            Column(Modifier.weight(1f)) {
                                Label(e.title, Tokens.row, Tokens.text, FontWeight.Medium)
                                e.plot?.let { Label(it, Tokens.caption, Tokens.textSecondary, maxLines = 1) }
                            }
                            if (p?.completed == true) Label("Watched", Tokens.small, Tokens.success)
                            else if (p != null && p.fraction > 0) Label("${(p.fraction * 100).toInt()}%", Tokens.small, Tokens.accent)
                        }
                    }
                }
            }
        }
    }
}

/** A movie, like the Mac's detail page: poster, facts, story, and Play / Resume, Favorite, Watch Later. */
@Composable
fun MovieDetailScreen(movie: Movie, c: AppContainer, nav: Navigator) {
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsState(initial = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsState(initial = emptySet())
    var progress by remember { mutableStateOf<WatchProgress?>(null) }
    LaunchedEffect(movie.id) { progress = c.user.progress(movie.id) }
    val scope = rememberCoroutineScope()
    val first = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { kotlinx.coroutines.delay(150); runCatching { first.requestFocus() } }
    val resumable = progress?.takeIf { !it.completed && it.positionMs > 30_000 }

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        if (!movie.posterUrl.isNullOrBlank()) AsyncImage(movie.posterUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = 0.18f)
        Row(Modifier.fillMaxSize().padding(horizontal = Tokens.screenPadding, vertical = 28.dp), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            Box(Modifier.width(230.dp).aspectRatio(150f / 218f)) { PosterPlaceholder(movie.title, Modifier.fillMaxSize()); if (!movie.posterUrl.isNullOrBlank()) AsyncImage(movie.posterUrl, movie.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label(movie.title, Tokens.display, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                Label(listOfNotNull("Movie", movie.year?.toString(), movie.rating?.takeIf { it != "0" }?.let { "★ $it" }).joinToString(" · "), Tokens.small, Tokens.textSecondary)
                movie.plot?.let { Label(it, Tokens.body, Tokens.textSecondary, maxLines = 5, modifier = Modifier.widthIn(max = 760.dp).padding(top = 4.dp)) }
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (resumable != null) TvButton("Resume · ${(resumable.durationMs - resumable.positionMs) / 60000}m left", { play(c, nav, MoviePlayable(movie)) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                    else TvButton("Play", { play(c, nav, MoviePlayable(movie)) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                    TvButton(if (movie.id in favs) "Favorited" else "Favorite", { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in favs) } }, icon = if (movie.id in favs) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder)
                    TvButton(if (movie.id in later) "In Watch Later" else "Watch Later", { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in later, UserRepository.WATCH_LATER) } }, icon = if (movie.id in later) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder)
                }
            }
        }
    }
}
