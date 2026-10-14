package app.streamsetu.tv.ui.screens.detail

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.data.repo.EpisodePlan
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.SeriesDetailViewModel
import app.streamsetu.tv.ui.screens.section.ratingBadge
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

private fun minutes(ms: Long) = (ms / 60000).toInt().coerceAtLeast(0)

@Composable
private fun Backdrop(url: String?, title: String, dim: Float = 0.9f) {
    Box(Modifier.fillMaxSize()) {
        PosterPlaceholder(title, Modifier.fillMaxSize())
        if (!url.isNullOrBlank()) AsyncImage(url, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Tokens.background.copy(alpha = 0.97f), 0.55f to Tokens.background.copy(alpha = 0.78f), 1f to Tokens.background.copy(alpha = 0.25f))))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.55f to Color.Transparent, 1f to Tokens.background.copy(alpha = dim))))
    }
}

/** A movie, full screen. The sidebar and folders are gone; Back returns to the exact poster you came from. */
@Composable
fun MovieDetailScreen(movie0: Movie, c: AppContainer, nav: Navigator) {
    val overrides by c.collections.overrides.collectAsState(initial = emptyMap())
    val movie = overrides[movie0.id]?.let { o -> movie0.copy(title = o.title ?: movie0.title, posterUrl = o.posterUrl ?: movie0.posterUrl, plot = movie0.plot ?: o.plot) } ?: movie0
    var editing by remember { mutableStateOf(false) }
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsState(initial = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsState(initial = emptySet())
    val allProgress by c.user.allProgress().collectAsState(initial = emptyMap())
    val progress = allProgress[movie.id]
    var info by remember { mutableStateOf<app.streamsetu.core.sync.SyncService.MovieInfo?>(null) }
    var variants by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var related by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var more by remember { mutableStateOf(false) }
    var chooseOpen by remember { mutableStateOf(false) }
    val sources by c.library.entries.collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    val first = remember { FocusRequester() }
    LaunchedEffect(movie.id) {
        delay(120); runCatching { first.requestFocus() }
        info = runCatching { c.sync.movieInfo(movie) }.getOrNull()
        variants = runCatching { c.search.movieVariants(movie.title) }.getOrDefault(emptyList())
        related = movie.categoryId?.let { id -> runCatching { c.browse.movies(Browse.Folder(id), SortSpec(SortField.NAME), 40).first().filter { it.id != movie.id }.take(14) }.getOrDefault(emptyList<Movie>()) } ?: emptyList()
    }
    val resumable = progress?.takeIf { !it.completed && it.positionMs > 30_000 }
    val container = movie.streamRef.substringAfterLast(':', "").uppercase().takeIf { it.length in 2..4 }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        Backdrop(info?.backdrop?.takeIf { it.isNotBlank() } ?: movie.posterUrl, movie.title)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 40.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Column(Modifier.widthIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Label(movie.title, Tokens.display, Tokens.text, FontWeight.Bold, maxLines = 2)
                    Label(listOfNotNull(movie.year?.toString(), info?.duration?.takeIf { it.isNotBlank() && it != "00:00:00" }, info?.genre?.takeIf { it.isNotBlank() }, ratingBadge(movie.rating)).joinToString("  ·  "), Tokens.small, Tokens.textSecondary)
                    (info?.plot ?: movie.plot)?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.body, Tokens.textSecondary, maxLines = if (more) 12 else 5) }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        container?.let { Chip(it) }; Chip(sourceName(movie.sourceId))
                        if (progress?.completed == true) Chip("Watched", Tokens.success) else if (resumable != null) Chip("${minutes(resumable.durationMs - resumable.positionMs)}m left", Tokens.accent)
                    }
                    if (resumable != null) Box(Modifier.width(220.dp).height(4.dp).background(Tokens.elevated, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(resumable.fraction).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
                    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (resumable != null) TvButton("Resume", { play(c, nav, MoviePlayable(movie)) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                        else TvButton("Play", { play(c, nav, MoviePlayable(movie)) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                        if (resumable != null || progress?.completed == true) TvButton("Start Over", { scope.launch { c.user.clearResumePoint(movie.id) }; c.play(MoviePlayable(movie), listOf(MoviePlayable(movie)), startOver = true); if (nav.top != Overlay.Player) nav.open(Overlay.Player) }, icon = Icons.Filled.Replay)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TvButton(if (movie.id in favs) "Favorited" else "Favorite", { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in favs) } }, icon = if (movie.id in favs) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder)
                        TvButton(if (movie.id in later) "In Watch Later" else "Watch Later", { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in later, UserRepository.WATCH_LATER) } }, icon = if (movie.id in later) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder)
                        if (variants.size > 1) TvButton("Choose Stream", { chooseOpen = true }, icon = Icons.Filled.SwapHoriz)
                        TvButton(if (more) "Less" else "More Information", { more = !more }, icon = Icons.Filled.Info)
                        TvButton("Edit", { editing = true }, icon = Icons.Filled.Edit)
                    }
                }
            }
            if (more) item {
                Column(Modifier.widthIn(max = 620.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    info?.director?.takeIf { it.isNotBlank() }?.let { Label("Director  ·  $it", Tokens.small, Tokens.textSecondary, maxLines = 2) }
                    info?.cast?.takeIf { it.isNotBlank() }?.let { Label("Cast  ·  $it", Tokens.small, Tokens.textSecondary, maxLines = 4) }
                    info?.releaseDate?.takeIf { it.isNotBlank() }?.let { Label("Released  ·  $it", Tokens.small, Tokens.textSecondary) }
                    if (info == null) Label("The provider has no further details for this title.", Tokens.small, Tokens.textTertiary)
                }
            }
            if (variants.size > 1) item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    SectionTitle("Available from")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { variants.forEach { v -> Chip("${sourceName(v.sourceId)}  ·  ${v.streamRef.substringAfterLast(':', "").uppercase()}", if (v.id == movie.id) Tokens.accent else Tokens.textSecondary) } }
                }
            }
            if (related.isNotEmpty()) item {
                Column {
                    SectionTitle("More like this in this folder")
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) { items(related, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString(), badge = ratingBadge(m.rating)) } }
                }
            }
        }
    }
    if (editing) OverrideDialog(movie.title, overrides[movie0.id]?.posterUrl.orEmpty(), onSave = { t, p -> scope.launch { c.collections.setOverride(movie0.id, t.takeIf { it != movie0.title }, p) }; editing = false }, onReset = { scope.launch { c.collections.clearOverride(movie0.id) }; editing = false }, onClose = { editing = false })
    if (chooseOpen) ContextMenu("Choose Stream", "Opens only this play. Your default is unchanged.", variants.map { v -> MenuAction("${sourceName(v.sourceId)}  ·  ${v.streamRef.substringAfterLast(':', "").uppercase()}", Icons.Filled.PlayArrow) { play(c, nav, MoviePlayable(v)) } }, onClose = { chooseOpen = false })
}

@Composable
private fun Chip(text: String, color: Color = Tokens.textSecondary) {
    Box(Modifier.background(Tokens.card, RoundedCornerShape(6.dp)).padding(horizontal = 8.dp, vertical = 3.dp)) { Label(text, Tokens.caption, color, FontWeight.Medium) }
}

/** A series, full screen: story, the right action for where you are (Continue, Catch Up, Start Series), a season selector, and wide episode cards. */
@Composable
fun SeriesDetailScreen(vm: SeriesDetailViewModel, c: AppContainer, nav: Navigator) {
    val episodes by vm.episodes.collectAsState()
    val loading by vm.loading.collectAsState()
    val error by vm.error.collectAsState()
    val progress by vm.progress.collectAsState()
    val series0 = vm.series
    val overrides by c.collections.overrides.collectAsState(initial = emptyMap())
    val s = overrides[series0.id]?.let { o -> series0.copy(title = o.title ?: series0.title, posterUrl = o.posterUrl ?: series0.posterUrl, plot = series0.plot ?: o.plot) } ?: series0
    var editing by remember { mutableStateOf(false) }
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsState(initial = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsState(initial = emptySet())
    val sources by c.library.entries.collectAsState(initial = emptyList())
    var variants by remember { mutableStateOf<List<Series>>(emptyList()) }
    var chooseOpen by remember { mutableStateOf(false) }
    var episodeMenu by remember { mutableStateOf<Episode?>(null) }
    val homeVm: app.streamsetu.tv.ui.screens.home.HomeViewModel = androidx.hilt.navigation.compose.hiltViewModel()
    val seasons = episodes.groupBy { it.season }.toSortedMap()
    val plan = remember(episodes, progress) { EpisodePlan.of(episodes, progress) }
    val forward = plan.forward; val catchUp = plan.catchUp; val inProgress = plan.inProgress
    var season by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(seasons.keys, plan) { if (season == null || season !in seasons.keys) season = (inProgress ?: forward ?: episodes.firstOrNull())?.season ?: seasons.keys.firstOrNull() }
    val queue = remember(episodes) { episodes.sortedWith(compareBy({ it.season }, { it.number })).map { EpisodePlayable(it, s) } }
    val scope = rememberCoroutineScope()
    val first = remember { FocusRequester() }
    LaunchedEffect(s.id) { delay(120); runCatching { first.requestFocus() }; variants = runCatching { c.search.seriesVariants(s.title) }.getOrDefault(emptyList()) }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"
    fun playEp(e: Episode) = play(c, nav, EpisodePlayable(e, s), queue)
    val watchedCount = episodes.count { progress[it.id]?.completed == true }

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        Backdrop(s.backdropUrl?.takeIf { it.isNotBlank() } ?: s.posterUrl, s.title)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 36.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Column(Modifier.widthIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Label(s.title, Tokens.display, Tokens.text, FontWeight.Bold, maxLines = 2)
                    Label(listOfNotNull(s.year?.toString(), if (seasons.isNotEmpty()) "${seasons.size} season${if (seasons.size == 1) "" else "s"}" else null, ratingBadge(s.rating)).joinToString("  ·  "), Tokens.small, Tokens.textSecondary)
                    s.plot?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.body, Tokens.textSecondary, maxLines = 4) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip(sourceName(s.sourceId))
                        if (episodes.isNotEmpty()) Chip(if (plan.allFinished) "All watched" else "$watchedCount of ${episodes.size} watched", if (plan.allFinished) Tokens.success else Tokens.textSecondary)
                    }
                    if (plan.gapBefore && forward != null) Label("Episode ${forward.number - 1} is not available. The next one on offer is episode ${forward.number}.", Tokens.small, Tokens.warning, maxLines = 2)
                    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        val ip = inProgress
                        when {
                            ip != null -> TvButton("Continue S${ip.season} E${ip.number}", { playEp(ip) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                            forward != null && watchedCount > 0 -> TvButton(if (catchUp != null) "Continue Forward S${forward.season} E${forward.number}" else "Continue S${forward.season} E${forward.number}", { playEp(forward) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                            episodes.isNotEmpty() && plan.allFinished -> TvButton("Watch Again", { playEp(episodes.minWith(compareBy({ it.season }, { it.number }))) }, Modifier.focusRequester(first), icon = Icons.Filled.Replay, primary = true)
                            episodes.isNotEmpty() -> TvButton("Start Series", { playEp(episodes.minWith(compareBy({ it.season }, { it.number }))) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                            else -> TvButton(if (loading) "Loading episodes…" else "View Episodes", {}, Modifier.focusRequester(first), icon = Icons.Filled.List, primary = true)
                        }
                        catchUp?.let { cu -> TvButton("Catch Up S${cu.season} E${cu.number}", { playEp(cu) }, icon = Icons.Filled.History) }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TvButton(if (s.id in favs) "Favorited" else "Favorite", { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in favs) } }, icon = if (s.id in favs) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder)
                        TvButton(if (s.id in later) "In Watch Later" else "Watch Later", { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in later, UserRepository.WATCH_LATER) } }, icon = if (s.id in later) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder)
                        if (variants.size > 1) TvButton("Choose Source", { chooseOpen = true }, icon = Icons.Filled.SwapHoriz)
                        TvButton("Edit", { editing = true }, icon = Icons.Filled.Edit)
                    }
                }
            }
            if (loading && episodes.isEmpty()) item { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Spinner(); Label("Loading episodes…", Tokens.body, Tokens.textSecondary) } }
            error?.let { e -> if (episodes.isEmpty()) item { Label(e, Tokens.body, Tokens.danger, maxLines = 2) } }
            if (seasons.isNotEmpty()) item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
                    items(seasons.keys.toList(), key = { it }) { n ->
                        Focusable({ season = n }, Modifier, shape = RoundedCornerShape(50), container = if (n == season) Tokens.elevated else Tokens.card, scaleOnFocus = 1.04f) { f ->
                            Label("Season $n", Tokens.small, if (n == season) Tokens.accent else Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp))
                        }
                    }
                }
            }
            items((season?.let { seasons[it] }).orEmpty().sortedBy { it.number }, key = { it.id }) { e ->
                val p = progress[e.id]
                Focusable({ playEp(e) }, Modifier.fillMaxWidth().widthIn(max = 760.dp), scaleOnFocus = 1.01f, hairline = true, onLongClick = { episodeMenu = e }) { _ ->
                    Row(Modifier.padding(8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.width(132.dp).aspectRatio(16f / 9f).background(Tokens.elevated, RoundedCornerShape(6.dp))) {
                            if (!e.imageUrl.isNullOrBlank()) AsyncImage(e.imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Label("E${e.number}", Tokens.title, Tokens.textTertiary, modifier = Modifier.align(Alignment.Center))
                            if (p != null && !p.completed && p.fraction > 0) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(p.fraction).fillMaxHeight().background(Tokens.accent)) }
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Label("${e.number}. ${e.title}", Tokens.row, Tokens.text, FontWeight.SemiBold)
                            Label(listOfNotNull(e.durationSec?.takeIf { it > 0 }?.let { "${it / 60} min" }, if (p?.completed == true) "Watched" else if (p != null && p.fraction > 0) "${minutes(p.durationMs - p.positionMs)}m left" else null).joinToString("  ·  "), Tokens.caption, if (p?.completed == true) Tokens.success else Tokens.textSecondary)
                            e.plot?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.caption, Tokens.textSecondary, maxLines = 2) }
                        }
                        if (p?.completed == true) Image(Icons.Filled.CheckCircle, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.success))
                    }
                }
            }
        }
    }
    episodeMenu?.let { ep -> app.streamsetu.tv.ui.screens.home.HomeMenuHost(app.streamsetu.tv.ui.screens.home.HomeTarget.Episode(s, EpisodePlayable(ep, s)), app.streamsetu.tv.ui.screens.home.RowKind.EPISODES, homeVm, c, nav) { episodeMenu = null } }
    if (editing) OverrideDialog(s.title, overrides[series0.id]?.posterUrl.orEmpty(), onSave = { t, p -> scope.launch { c.collections.setOverride(series0.id, t.takeIf { it != series0.title }, p) }; editing = false }, onReset = { scope.launch { c.collections.clearOverride(series0.id) }; editing = false }, onClose = { editing = false })
    if (chooseOpen) ContextMenu("Choose Source", "Opens that connection's copy of this series.", variants.map { v -> MenuAction(sourceName(v.sourceId) + if (v.id == s.id) "  (current)" else "", Icons.Filled.SwapHoriz, enabled = v.id != s.id) { nav.close(); nav.open(Overlay.SeriesDetail(v)) } }, onClose = { chooseOpen = false })
}
