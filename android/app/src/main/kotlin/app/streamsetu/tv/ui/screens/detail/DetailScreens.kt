package app.streamsetu.tv.ui.screens.detail

import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.lazy.rememberLazyListState
import app.streamsetu.tv.ui.theme.ui
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
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
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

private fun minutes(ms: Long) = (ms / 60000).toInt().coerceAtLeast(0)

@Composable
private fun Backdrop(url: String?, title: String, dim: Float = 0.9f) {
    Box(Modifier.fillMaxSize()) {
        PosterPlaceholder(title, Modifier.fillMaxSize())
        if (!url.isNullOrBlank()) AsyncImage(url, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Tokens.background.copy(alpha = 0.97f), 0.55f to Tokens.background.copy(alpha = 0.86f), 0.85f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Tokens.background.copy(alpha = dim))))
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
    var related by remember { mutableStateOf<List<app.streamsetu.core.data.repo.SearchRepository.Suggestion<Movie>>>(emptyList()) }
    var franchise by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var more by remember { mutableStateOf(false) }
    var chooseOpen by remember { mutableStateOf(false) }
    var moreMenu by remember { mutableStateOf(false) }
    val sources by c.library.entries.collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    val first = remember { FocusRequester() }
    // Each part of the page loads on its own, so none waits for another (the provider's details are the slowest and used to hold everything else back).
    LaunchedEffect(movie.id) { delay(120); runCatching { first.requestFocus() } }
    LaunchedEffect(movie.id) { info = runCatching { c.sync.movieInfo(movie) }.getOrNull() }
    LaunchedEffect(movie.id) { variants = runCatching { c.search.movieVariants(movie.title) }.getOrDefault(emptyList()) }
    LaunchedEffect(movie.id) { franchise = runCatching { c.search.franchiseOf(movie) }.getOrDefault(emptyList()) }
    // "More like this" is ranked once, from what is already on the device, and shown as it is: it does not grow or reshuffle a few seconds later.
    var relatedLoaded by remember(movie.id) { mutableStateOf(false) }
    LaunchedEffect(movie.id) {
        runCatching { c.search.similarMovies(movie, null) { null }.collect { related = it } }
        relatedLoaded = true
    }
    val resumable = progress?.takeIf { !it.completed && it.positionMs > 30_000 }
    val container = movie.streamRef.substringAfterLast(':', "").uppercase().takeIf { it.length in 2..4 }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        Backdrop(info?.backdrop?.takeIf { it.isNotBlank() }, movie.title)          // never the poster blown up to fill the screen: with no backdrop the poster is shown at its own size beside the text
        // When the remote comes back up into the title block (Play, Watch Later, Favorite, More), the page goes back to the top, so the title is never left cut off above the screen edge.
        val pageList = rememberLazyListState()
        val pageScope = rememberCoroutineScope()
        LazyColumn(Modifier.fillMaxSize(), state = pageList, contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 72.dp, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item {
              Row(Modifier.onFocusChanged { if (it.hasFocus && pageList.firstVisibleItemIndex == 0 && pageList.firstVisibleItemScrollOffset > 0) pageScope.launch { pageList.animateScrollToItem(0) } }, horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.Top) {
                // The poster, large, as the left half of the page: a title page, not a list of buttons.
                movie.posterUrl?.takeIf { it.isNotBlank() && info?.backdrop.isNullOrBlank() }?.let { url ->
                    androidx.compose.foundation.layout.Box(Modifier.width(200.ui).aspectRatio(2f / 3f).clip(RoundedCornerShape(Tokens.radiusPanel)).background(Tokens.card)) {
                        coil.compose.AsyncImage(url, null, Modifier.fillMaxSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                    }
                }
                Column(Modifier.widthIn(max = 540.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {          // the left 55 % of the screen
                    Label(movie.title, Tokens.display, Tokens.text, FontWeight.Bold, maxLines = 2)
                    Label(listOfNotNull(movie.year?.toString(), info?.duration?.takeIf { it.isNotBlank() && it != "00:00:00" }, info?.genre?.takeIf { it.isNotBlank() }, ratingBadge(movie.rating)).joinToString("  ·  "), Tokens.small, Tokens.textSecondary)
                    // One short line about the title, its story in at most four lines, then the actions: Play or Resume, Watch Later, Favorite, More. Everything else is under More.
                    (info?.plot ?: movie.plot)?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.body, Tokens.textSecondary, maxLines = if (more) 12 else 4) }
                    if (resumable != null) Box(Modifier.width(220.dp).height(4.dp).background(Tokens.elevated, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(resumable.fraction).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
                    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (resumable != null) TvButton("Resume", { c.playBestMovie(movie) { play(c, nav, it) } }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                        else TvButton("Play", { c.playBestMovie(movie) { play(c, nav, it) } }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                        TvButton(if (movie.id in later) "In Watch Later" else "Watch Later", { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in later, UserRepository.WATCH_LATER) } }, icon = if (movie.id in later) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder)
                        TvButton(if (movie.id in favs) "Favorited" else "Favorite", { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in favs) } }, icon = if (movie.id in favs) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder)
                        TvButton("More", { moreMenu = true }, icon = Icons.Filled.MoreHoriz)
                    }
                    QueueButtonTv(c, ContentKind.MOVIE, movie.id, movie.title)
                    if (more) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        app.streamsetu.core.data.repo.QualityBadges.from(listOf(movie.title)).takeIf { it.isNotEmpty() }?.let { Label(it.joinToString("  ·  "), Tokens.small, Tokens.accent, FontWeight.Bold) }
                        FolderPath(c, app.streamsetu.core.model.ContentKind.MOVIE, movie.categoryId, phone = false) { id -> nav.close(); nav.openFolderTab(app.streamsetu.core.model.ContentKind.MOVIE, id) }
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            container?.let { Chip(it) }; Chip(sourceName(movie.sourceId))
                            if (progress?.completed == true) Chip("Watched", Tokens.success) else if (resumable != null) Chip("${minutes(resumable.durationMs - resumable.positionMs)}m left", Tokens.accent)
                        }
                    }
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
            if (franchise.size > 1) item { FranchiseTimeline(franchise, movie.id) { m -> nav.close(); nav.open(Overlay.MovieDetail(m)) } }
            if (!relatedLoaded) item { RelatedPlaceholders() }
            if (related.isNotEmpty()) item {
                Column {
                    SectionTitle("More like this")
                    // Down from the buttons lands on the first poster (or the one the remote was last on), never on one in the middle; the row has room at both ends so a focused poster is not cut off.
                    val firstRelated = remember { FocusRequester() }
                    LazyRow(Modifier.bleedStart(24.dp).focusRestorer { firstRelated }, horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(start = 32.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)) { itemsIndexed(related, key = { _, r -> r.item.id }) { idx, r -> val m = r.item; PosterCard(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.MovieDetail(m)) }, itemId = m.id, subtitle = r.reason, badge = ratingBadge(m.rating), focusRequester = if (idx == 0) firstRelated else null) } }
                }
            }
        }
    }
    if (moreMenu) ContextMenu(movie.title, null, buildList {
        if (resumable != null || progress?.completed == true) add(MenuAction("Start Over", Icons.Filled.Replay) { scope.launch { c.user.clearResumePoint(movie.id) }; c.play(MoviePlayable(movie), listOf(MoviePlayable(movie)), startOver = true); if (nav.top != Overlay.Player) nav.open(Overlay.Player) })
        add(MenuAction("Watch privately", Icons.Filled.VisibilityOff) { c.playBestMovie(movie) { play(c, nav, it, privately = true) } })
        if (variants.size > 1) add(MenuAction("Choose Stream", Icons.Filled.SwapHoriz) { chooseOpen = true })
        add(MenuAction(if (more) "Less information" else "More information (cast, details)", Icons.Filled.Info) { more = !more })
        add(MenuAction("Edit title and poster", Icons.Filled.Edit) { editing = true })
    }, onClose = { moreMenu = false })
    if (editing) OverrideDialog(movie.title, overrides[movie0.id]?.posterUrl.orEmpty(), onSave = { t, p -> scope.launch { c.collections.setOverride(movie0.id, t.takeIf { it != movie0.title }, p) }; editing = false }, onReset = { scope.launch { c.collections.clearOverride(movie0.id) }; editing = false }, onClose = { editing = false })
    if (chooseOpen) ContextMenu("Choose Stream", "Opens only this play. Your default is unchanged.", variants.map { v -> MenuAction("${sourceName(v.sourceId)}  ·  ${v.streamRef.substringAfterLast(':', "").uppercase()}", Icons.Filled.PlayArrow) { play(c, nav, MoviePlayable(v)) } }, onClose = { chooseOpen = false })
}

@Composable
private fun Chip(text: String, color: Color = Tokens.textSecondary) {
    Box(Modifier.background(Tokens.elevated, RoundedCornerShape(Tokens.radiusSmall)).padding(horizontal = 10.dp, vertical = 4.dp)) { Label(text, Tokens.caption, color, FontWeight.Medium) }
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
    var similar by remember { mutableStateOf<List<app.streamsetu.core.data.repo.SearchRepository.Suggestion<Series>>>(emptyList()) }
    var similarLoaded by remember(series0.id) { mutableStateOf(false) }
    LaunchedEffect(series0.id) { similar = runCatching { c.search.similarSeries(series0) }.getOrDefault(emptyList()); similarLoaded = true }
    var chooseOpen by remember { mutableStateOf(false) }
    var episodeMenu by remember { mutableStateOf<Episode?>(null) }
    val homeVm: app.streamsetu.tv.ui.screens.home.HomeViewModel = androidx.hilt.navigation.compose.hiltViewModel()
    val seasons = episodes.groupBy { it.season }.toSortedMap()
    val plan = remember(episodes, progress) { EpisodePlan.of(episodes, progress) }
    val forward = plan.forward; val catchUp = plan.catchUp; val inProgress = plan.inProgress
    val saved = remember { nav.seriesView[series0.id] }                           // where the remote was when the page was last left
    var season by remember { mutableStateOf<Int?>(saved?.first) }
    val restoreEpisodeId = saved?.second
    val episodeTarget = remember { FocusRequester() }
    var episodeRestored by remember { mutableStateOf(restoreEpisodeId == null) }
    val newIds by remember(series0.id) { c.db.extras().newEpisodes().map { l -> l.filter { it.seriesId == series0.id }.map { it.episodeId }.toSet() } }.collectAsState(initial = emptySet())
    LaunchedEffect(episodes.size, season) {
        if (!episodeRestored && episodes.isNotEmpty() && season != null) { delay(350); runCatching { episodeTarget.requestFocus() }; episodeRestored = true }
    }
    LaunchedEffect(seasons.keys, plan) { if (season == null || season !in seasons.keys) season = (inProgress ?: forward ?: episodes.firstOrNull())?.season ?: seasons.keys.firstOrNull() }
    val queue = remember(episodes) { episodes.sortedWith(compareBy({ it.season }, { it.number })).map { EpisodePlayable(it, s) } }
    val scope = rememberCoroutineScope()
    val activeSeasonChip = remember { FocusRequester() }
    val first = remember { FocusRequester() }
    LaunchedEffect(s.id) { delay(120); runCatching { first.requestFocus() }; variants = runCatching { c.search.seriesVariants(s.title) }.getOrDefault(emptyList()) }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"
    fun playEp(e: Episode) = play(c, nav, EpisodePlayable(e, s), queue)
    val watchedCount = episodes.count { progress[it.id]?.completed == true }

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        Backdrop(s.backdropUrl?.takeIf { it.isNotBlank() } ?: s.posterUrl, s.title)
        val pageList = rememberLazyListState()
        val pageScope = rememberCoroutineScope()
        LazyColumn(Modifier.fillMaxSize(), state = pageList, contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 72.dp, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item {
                Column(Modifier.onFocusChanged { if (it.hasFocus && pageList.firstVisibleItemIndex == 0 && pageList.firstVisibleItemScrollOffset > 0) pageScope.launch { pageList.animateScrollToItem(0) } }.widthIn(max = 600.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Label(s.title, Tokens.display, Tokens.text, FontWeight.Bold, maxLines = 2)
                    Label(listOfNotNull(s.year?.toString(), if (seasons.isNotEmpty()) "${seasons.size} season${if (seasons.size == 1) "" else "s"}" else null, ratingBadge(s.rating)).joinToString("  ·  "), Tokens.small, Tokens.textSecondary)
                    app.streamsetu.core.data.repo.QualityBadges.from(listOf(s.title)).takeIf { it.isNotEmpty() }?.let { Label(it.joinToString("  ·  "), Tokens.small, Tokens.accent, FontWeight.Bold) }
                    FolderPath(c, app.streamsetu.core.model.ContentKind.SERIES, s.categoryId, phone = false) { id -> nav.close(); nav.openFolderTab(app.streamsetu.core.model.ContentKind.SERIES, id) }
                    s.plot?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.body, Tokens.textSecondary, maxLines = 4) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip(sourceName(s.sourceId))
                        if (episodes.isNotEmpty()) Chip(if (plan.allFinished) "All watched" else "$watchedCount of ${episodes.size} watched", if (plan.allFinished) Tokens.success else Tokens.textSecondary)
                    }
                    if (plan.gapBefore && forward != null) Label("Episode ${forward.number - 1} is not available. The next one on offer is episode ${forward.number}.", Tokens.small, Tokens.warning, maxLines = 2)
                    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        val ip = inProgress
                        when {
                            ip != null -> TvButton("Continue Watching — S%02d E%02d".format(ip.season, ip.number), { playEp(ip) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                            forward != null && watchedCount > 0 -> TvButton(if (catchUp != null) "Continue Forward S${forward.season} E${forward.number}" else "Continue S${forward.season} E${forward.number}", { playEp(forward) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                            episodes.isNotEmpty() && plan.allFinished -> TvButton("Watch Again", { playEp(episodes.minWith(compareBy({ it.season }, { it.number }))) }, Modifier.focusRequester(first), icon = Icons.Filled.Replay, primary = true)
                            episodes.isNotEmpty() -> TvButton("Start Series", { playEp(episodes.minWith(compareBy({ it.season }, { it.number }))) }, Modifier.focusRequester(first), icon = Icons.Filled.PlayArrow, primary = true)
                            else -> TvButton(if (loading) "Loading episodes…" else "View Episodes", {}, Modifier.focusRequester(first), icon = Icons.Filled.List, primary = true)
                        }
                        catchUp?.let { cu -> TvButton("Catch Up S${cu.season} E${cu.number}", { playEp(cu) }, icon = Icons.Filled.History) }
                        if (episodes.isNotEmpty() && (ip != null || watchedCount > 0) && !plan.allFinished) TvButton("Start from Beginning", { playEp(episodes.minWith(compareBy({ it.season }, { it.number }))) }, icon = Icons.Filled.Replay)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TvButton(if (s.id in favs) "Favorited" else "Favorite", { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in favs) } }, icon = if (s.id in favs) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder)
                        TvButton(if (s.id in later) "In Watch Later" else "Watch Later", { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in later, UserRepository.WATCH_LATER) } }, icon = if (s.id in later) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder)
                        QueueButtonTv(c, ContentKind.SERIES, s.id, s.title)
                        if (variants.size > 1) TvButton("Choose Source", { chooseOpen = true }, icon = Icons.Filled.SwapHoriz)
                        TvButton("Edit", { editing = true }, icon = Icons.Filled.Edit)
                    }
                }
            }
            if (loading && episodes.isEmpty()) item { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Spinner(); Label("Loading episodes…", Tokens.body, Tokens.textSecondary) } }
            error?.let { e -> if (episodes.isEmpty()) item { Label(e, Tokens.body, Tokens.danger, maxLines = 2) } }
            if (seasons.isNotEmpty()) item {
                // Entering the seasons from the actions above or the episodes below always lands on the open season (not on whichever chip is nearest).
                LazyRow(Modifier.focusProperties { enter = { activeSeasonChip } }, horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
                    items(seasons.keys.toList(), key = { it }) { n ->
                        Focusable({ season = n }, if (n == season) Modifier.focusRequester(activeSeasonChip) else Modifier, shape = RoundedCornerShape(50), container = if (n == season) Color(0xFFE9ECF0) else Tokens.card, focusedContainer = if (n == season) Color.White else Tokens.focusedSurface, scaleOnFocus = 1.05f) { f ->
                            Label("Season $n", Tokens.row, if (n == season) Tokens.onBright else Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 18.dp, vertical = 8.dp))
                        }
                    }
                }
            }
            // Changing season fades the episodes over to the new list in place; the rest of the page does not move.
            item(key = "episodes") {
                androidx.compose.animation.Crossfade(season, animationSpec = androidx.compose.animation.core.tween(if (app.streamsetu.core.ui.motion.LocalReducedMotion.current) 0 else app.streamsetu.core.ui.motion.Motion.SHORT), label = "season") { sn ->
                    // The episodes remember which one the remote was on, so coming back from the seasons or the related titles returns to it.
                    Column(Modifier.focusRestorer(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        (sn?.let { seasons[it] }).orEmpty().sortedBy { it.number }.forEach { e ->
                            key(e.id) {

                val p = progress[e.id]
                Focusable({ playEp(e) }, Modifier.then(if (e.id == restoreEpisodeId) Modifier.focusRequester(episodeTarget) else Modifier).fillMaxWidth().widthIn(max = 820.dp), scaleOnFocus = 1.02f, hairline = true, onLongClick = { episodeMenu = e },
                    onFocus = { if (it) nav.seriesView[s.id] = season to e.id }) { f ->
                    Row(Modifier.padding(8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.width(260.ui).aspectRatio(16f / 9f).clip(RoundedCornerShape(Tokens.radiusSmall)).background(Tokens.elevated)) {
                            if (!e.imageUrl.isNullOrBlank()) AsyncImage(e.imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Label("E${e.number}", Tokens.title, Tokens.textTertiary, modifier = Modifier.align(Alignment.Center))
                            // NEW is an episode that arrived after the series was read and has not been started.
                            if (e.id in newIds && p == null) Label("NEW", Tokens.caption, Tokens.onBright, FontWeight.Bold, modifier = Modifier.align(Alignment.TopStart).padding(4.dp).background(Tokens.accent, RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 1.dp))
                            if (p != null && !p.completed && p.fraction > 0) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(p.fraction).fillMaxHeight().background(Tokens.accent)) }
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Label("${e.number}. ${e.title}", Tokens.row, Tokens.text, FontWeight.SemiBold)
                            Label(listOfNotNull(e.durationSec?.takeIf { it > 0 }?.let { "${it / 60} min" }, if (p?.completed == true) "Watched" else if (p != null && p.fraction > 0) "${minutes(p.durationMs - p.positionMs)}m left" else null).joinToString("  ·  "), Tokens.caption, if (p?.completed == true) Tokens.success else Tokens.textSecondary)
                            // What the episode is about opens up on the one under the remote, so more episodes fit on the screen.
                            if (f) e.plot?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.caption, Tokens.textSecondary, maxLines = 3) }
                        }
                        if (p?.completed == true) Image(Icons.Filled.CheckCircle, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.success))
                    }
                }
                                        }
                        }
                    }
                }
            }
            if (!similarLoaded) item { RelatedPlaceholders() }
            if (similar.isNotEmpty()) item {
                Column(Modifier.padding(top = 10.dp)) {
                    SectionTitle("More like this")
                    val firstSimilar = remember { FocusRequester() }
                    LazyRow(Modifier.bleedStart(24.dp).focusRestorer { firstSimilar }, horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(start = 32.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)) { itemsIndexed(similar, key = { _, r -> r.item.id }) { idx, r -> val m = r.item; PosterCard(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.SeriesDetail(m)) }, itemId = m.id, subtitle = r.reason, badge = ratingBadge(m.rating), focusRequester = if (idx == 0) firstSimilar else null) } }
                }
            }
        }
    }
    episodeMenu?.let { ep -> app.streamsetu.tv.ui.screens.home.HomeMenuHost(app.streamsetu.tv.ui.screens.home.HomeTarget.Episode(s, EpisodePlayable(ep, s)), app.streamsetu.tv.ui.screens.home.RowKind.EPISODES, homeVm, c, nav) { episodeMenu = null } }
    if (editing) OverrideDialog(s.title, overrides[series0.id]?.posterUrl.orEmpty(), onSave = { t, p -> scope.launch { c.collections.setOverride(series0.id, t.takeIf { it != series0.title }, p) }; editing = false }, onReset = { scope.launch { c.collections.clearOverride(series0.id) }; editing = false }, onClose = { editing = false })
    if (chooseOpen) ContextMenu("Choose Source", "Opens that connection's copy of this series.", variants.map { v -> MenuAction(sourceName(v.sourceId) + if (v.id == s.id) "  (current)" else "", Icons.Filled.SwapHoriz, enabled = v.id != s.id) { nav.close(); nav.open(Overlay.SeriesDetail(v)) } }, onClose = { chooseOpen = false })
}

/** "Add to Queue" or "In Queue" on a title's page: the line of titles that play one after another. A press adds it; a press on one already there takes it out. */
@Composable
fun QueueButtonTv(c: AppContainer, kind: ContentKind, id: String, title: String) {
    val queued by c.watchQueue.items.collectAsState()
    val inQueue = queued.any { it.id == id }
    TvButton(if (inQueue) "In Queue" else "Add to Queue", { if (inQueue) c.watchQueue.remove(id) else c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(kind, id, title)) }, icon = if (inQueue) Icons.Filled.Check else Icons.Filled.Add)
}


/** The shape of the "More like this" row while it is being worked out: quiet tiles in the place the posters will take, so nothing appears or shifts later. */
@Composable
private fun RelatedPlaceholders() {
    Column {
        SectionTitle("More like this")
        Row(Modifier.padding(horizontal = 8.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            repeat(7) { Box(Modifier.width(Tokens.posterWidth).aspectRatio(2f / 3f).background(Tokens.card.copy(alpha = 0.6f), RoundedCornerShape(Tokens.radius))) }
        }
    }
}
