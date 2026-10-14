package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
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

private val movieShortcuts = listOf(Chip("featured", "Featured", Icons.Filled.AutoAwesome), Chip("all", "All Movies", Icons.Filled.GridView), Chip("added", "Recently Added", Icons.Filled.History),
    Chip("continue", "Continue Watching", Icons.Filled.PlayArrow), Chip("favorites", "Favorites", Icons.Filled.FavoriteBorder), Chip("later", "Watch Later", Icons.Filled.BookmarkBorder))
private val seriesShortcuts = listOf(Chip("all", "All Series", Icons.Filled.GridView), Chip("added", "Recently Added", Icons.Filled.History), Chip("continue", "Continue Watching", Icons.Filled.PlayArrow),
    Chip("favorites", "Favorites", Icons.Filled.FavoriteBorder), Chip("later", "Watch Later", Icons.Filled.BookmarkBorder))

/** Movies: category pills under the top bar, then a grid of posters. */
@Composable
fun MoviesScreen(vm: MoviesViewModel, c: AppContainer, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    var sel by rememberSaveable { mutableStateOf("featured") }
    val moviesOrNull by remember(sel) { vm.moviesFor(sel) }.collectAsState(initial = null)
    val movies = moviesOrNull ?: emptyList()
    if (moviesOrNull == null && categories.isEmpty()) { Loading(); return }
    if (categories.isEmpty() && movies.isEmpty()) { EmptyState("No movies yet", "This playlist has no movies. Add one in Settings."); return }
    val folders = categories.map { Chip(it.id, it.name) }
    val chips = movieShortcuts
    val folder = folders.firstOrNull { it.id == sel }
    val title = chips.firstOrNull { it.id == sel }?.title ?: folder?.title ?: "Movies"
    val firstItem = remember { androidx.compose.ui.focus.FocusRequester() }
    var picking by remember { mutableStateOf(false) }
    if (picking) CategoryPicker("Movie categories", folders, sel, { sel = it; picking = false }, { picking = false })
    Column(Modifier.fillMaxSize()) {
        ChipRow(chips, sel, { sel = it }, moreLabel = folder?.title, moreSelected = folder != null, onMore = { picking = true }, below = firstItem)
        Row(Modifier.padding(start = Tokens.screenPadding, top = 2.dp, bottom = 4.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Label(title, Tokens.pageTitle, Tokens.text, FontWeight.Bold); Label("${movies.size} movies", Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(bottom = 2.dp))
        }
        if (movies.isEmpty()) EmptyState("Nothing here yet", "Movies you add to $title appear here.")
        else LazyVerticalGrid(GridCells.Adaptive(Tokens.posterWidth), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(start = Tokens.screenPadding, end = Tokens.screenPadding, top = 4.dp, bottom = 28.dp)) {
            itemsIndexed(movies, key = { _, it -> it.id }) { i, m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString(), badge = ratingBadge(m.rating), focusRequester = if (i == 0) firstItem else null) }
        }
    }
}

@Composable
fun SeriesScreen(vm: SeriesViewModel, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    var sel by rememberSaveable { mutableStateOf("all") }
    val seriesOrNull by remember(sel) { vm.seriesFor(sel) }.collectAsState(initial = null)
    val series = seriesOrNull ?: emptyList()
    if (seriesOrNull == null && categories.isEmpty()) { Loading(); return }
    if (categories.isEmpty() && series.isEmpty()) { EmptyState("No series yet", "This playlist has no series. Add an Xtream playlist in Settings."); return }
    val folders = categories.map { Chip(it.id, it.name) }
    val chips = seriesShortcuts
    val folder = folders.firstOrNull { it.id == sel }
    val title = chips.firstOrNull { it.id == sel }?.title ?: folder?.title ?: "Series"
    val firstItem = remember { androidx.compose.ui.focus.FocusRequester() }
    var picking by remember { mutableStateOf(false) }
    if (picking) CategoryPicker("Series categories", folders, sel, { sel = it; picking = false }, { picking = false })
    Column(Modifier.fillMaxSize()) {
        ChipRow(chips, sel, { sel = it }, moreLabel = folder?.title, moreSelected = folder != null, onMore = { picking = true }, below = firstItem)
        Row(Modifier.padding(start = Tokens.screenPadding, top = 2.dp, bottom = 4.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Label(title, Tokens.pageTitle, Tokens.text, FontWeight.Bold); Label("${series.size} series", Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(bottom = 2.dp))
        }
        if (series.isEmpty()) EmptyState("Nothing here yet", "Series you add to $title appear here.")
        else LazyVerticalGrid(GridCells.Adaptive(Tokens.posterWidth), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(start = Tokens.screenPadding, end = Tokens.screenPadding, top = 4.dp, bottom = 28.dp)) {
            itemsIndexed(series, key = { _, it -> it.id }) { i, s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, subtitle = s.year?.toString(), badge = ratingBadge(s.rating), focusRequester = if (i == 0) firstItem else null) }
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
                Box(Modifier.width(86.dp).aspectRatio(150f / 218f)) { PosterPlaceholder(s.title, Modifier.fillMaxSize()); if (!s.posterUrl.isNullOrBlank()) AsyncImage(s.posterUrl, s.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
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
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 12.dp), modifier = Modifier) {
                items(seasons.keys.toList()) { n ->
                    Focusable({ season = n }, container = if (n == season) Tokens.accent.copy(alpha = 0.22f) else Tokens.card, scaleOnFocus = 1.05f) { f ->
                        LaunchedEffect(f) { if (f) season = n }
                        Label("Season $n", Tokens.small, if (n == season) Tokens.accent else Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp))
                    }
                }
            }
            LazyColumn(Modifier, verticalArrangement = Arrangement.spacedBy(3.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
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
    var info by remember { mutableStateOf<app.streamsetu.core.sync.SyncService.MovieInfo?>(null) }
    LaunchedEffect(movie.id) { info = runCatching { c.sync.movieInfo(movie) }.getOrNull() }
    val scope = rememberCoroutineScope()
    val first = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { kotlinx.coroutines.delay(150); runCatching { first.requestFocus() } }
    val resumable = progress?.takeIf { !it.completed && it.positionMs > 30_000 }

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        val backdrop = info?.backdrop ?: movie.posterUrl
        if (!backdrop.isNullOrBlank()) AsyncImage(backdrop, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = if (info?.backdrop != null) 0.9f else 0.25f)
        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.horizontalGradient(0f to androidx.compose.ui.graphics.Color(0xF50B0D12), 0.6f to androidx.compose.ui.graphics.Color(0xB00B0D12), 1f to androidx.compose.ui.graphics.Color(0x330B0D12))))
        Row(Modifier.fillMaxSize().padding(horizontal = Tokens.screenPadding, vertical = 20.dp), horizontalArrangement = Arrangement.spacedBy(22.dp)) {
            Box(Modifier.width(150.dp).aspectRatio(150f / 218f)) { PosterPlaceholder(movie.title, Modifier.fillMaxSize()); if (!movie.posterUrl.isNullOrBlank()) AsyncImage(movie.posterUrl, movie.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label(movie.title, Tokens.display, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                Label(listOfNotNull("Movie", movie.year?.toString(), info?.genre, info?.duration?.takeIf { it.isNotBlank() && it != "00:00:00" }, movie.rating?.takeIf { it != "0" }?.let { "★ $it" }).joinToString(" · "), Tokens.small, Tokens.textSecondary)
                (info?.plot ?: movie.plot)?.let { Label(it, Tokens.body, Tokens.textSecondary, maxLines = 6, modifier = Modifier.widthIn(max = 760.dp).padding(top = 4.dp)) }
                info?.director?.let { Label("Director: $it", Tokens.small, Tokens.textTertiary, maxLines = 1) }
                info?.cast?.let { Label("Cast: $it", Tokens.small, Tokens.textTertiary, maxLines = 2, modifier = Modifier.widthIn(max = 760.dp)) }
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
