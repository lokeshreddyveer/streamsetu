package app.streamsetu.tv.ui.phone

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.EpisodePlan
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.sync.SyncService
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.TimelineRail
import app.streamsetu.tv.ui.components.PosterPlaceholder
import app.streamsetu.tv.ui.components.Spinner
import app.streamsetu.tv.ui.screens.SeriesDetailViewModel
import app.streamsetu.tv.ui.screens.section.ratingBadge
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

private fun minutes(ms: Long) = (ms / 60000).toInt().coerceAtLeast(0)

@Composable
private fun DetailHeader(imageUrl: String?, title: String, onBack: () -> Unit) {
    Box(Modifier.fillMaxWidth().height(260.dp).background(Tokens.card)) {
        if (imageUrl.isNullOrBlank()) PosterPlaceholder(title, Modifier.fillMaxSize()) else AsyncImage(imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color(0x99000000), 0.4f to Color.Transparent, 1f to Tokens.background)))
        IconTap(Icons.Filled.ArrowBack, "Back", onBack, Modifier.windowInsetsPadding(WindowInsets.statusBars).padding(start = 4.dp, top = 4.dp), filled = true)
    }
}

@Composable
fun PhoneMovieDetail(movie0: Movie, c: AppContainer, nav: Navigator) {
    val overrides by c.collections.overrides.collectAsState(initial = emptyMap())
    val movie = overrides[movie0.id]?.let { o -> movie0.copy(title = o.title ?: movie0.title, posterUrl = o.posterUrl ?: movie0.posterUrl, plot = movie0.plot ?: o.plot) } ?: movie0
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsState(initial = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsState(initial = emptySet())
    val allProgress by c.user.allProgress().collectAsState(initial = emptyMap())
    val progress = allProgress[movie.id]
    var info by remember { mutableStateOf<SyncService.MovieInfo?>(null) }
    var variants by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var franchise by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var related by remember { mutableStateOf<List<app.streamsetu.core.data.repo.SearchRepository.Suggestion<Movie>>>(emptyList()) }
    var chooseOpen by remember { mutableStateOf(false) }
    val sources by c.library.entries.collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    LaunchedEffect(movie.id) {
        info = runCatching { c.sync.movieInfo(movie) }.getOrNull()
        variants = runCatching { c.search.movieVariants(movie.title) }.getOrDefault(emptyList())
        franchise = runCatching { c.search.franchiseOf(movie) }.getOrDefault(emptyList())
        val facts = info?.let { app.streamsetu.core.data.repo.Similarity.facts(it.genre, it.cast, it.director) }
        runCatching { c.search.similarMovies(movie, facts) { m -> c.sync.movieInfo(m)?.let { app.streamsetu.core.data.repo.Similarity.facts(it.genre, it.cast, it.director) } }.collect { related = it } }
    }
    val resumable = progress?.takeIf { !it.completed && it.positionMs > 30_000 }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item { DetailHeader(info?.backdrop?.takeIf { it.isNotBlank() } ?: movie.posterUrl, movie.title) { nav.close() } }
            item {
                Column(Modifier.padding(horizontal = Ph.gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(movie.title, Ph.title, Tokens.text, FontWeight.Bold, maxLines = 3)
                    Label(listOfNotNull(movie.year?.toString(), info?.duration?.takeIf { it.isNotBlank() && it != "00:00:00" }, info?.genre?.takeIf { it.isNotBlank() }, ratingBadge(movie.rating)).joinToString("  ·  "), Ph.small, Tokens.textSecondary, maxLines = 2)
                    app.streamsetu.core.data.repo.QualityBadges.from(listOf(movie.title)).takeIf { it.isNotEmpty() }?.let { Label(it.joinToString("  ·  "), Ph.small, Tokens.accent, FontWeight.Bold) }
                    if (resumable != null) {
                        androidx.compose.foundation.layout.Box(Modifier.fillMaxWidth().height(4.dp).background(Tokens.elevated, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(resumable.fraction).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
                        Label("${minutes(resumable.durationMs - resumable.positionMs)} min left", Ph.caption, Tokens.textSecondary)
                    } else if (progress?.completed == true) Label("Watched", Ph.caption, Tokens.success)
                    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        PillButton(if (resumable != null) "Resume" else "Play", { play(c, nav, MoviePlayable(movie)) }, Modifier.weight(1f), icon = Icons.Filled.PlayArrow, primary = true)
                        if (resumable != null || progress?.completed == true) PillButton("Start over", { scope.launch { c.user.clearResumePoint(movie.id) }; c.play(MoviePlayable(movie), listOf(MoviePlayable(movie)), startOver = true); if (nav.top != Overlay.Player) nav.open(Overlay.Player) }, Modifier.weight(1f), icon = Icons.Filled.Replay)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip(if (movie.id in favs) "Favorited" else "Favorite", movie.id in favs, { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in favs) } }, icon = Icons.Filled.Favorite)
                        Chip(if (movie.id in later) "In Watch Later" else "Watch Later", movie.id in later, { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, movie.id !in later, UserRepository.WATCH_LATER) } }, icon = Icons.Filled.Bookmark)
                        val saved by c.downloads.items.collectAsState(); val saving = saved.firstOrNull { it.itemId == movie.id }
                        Chip(downloadLabel(saving), saving?.state == app.streamsetu.core.data.repo.SaveState.DONE, { downloadTap(c, saving) { c.downloads.enqueue(movie) } }, icon = Icons.Filled.Download, progress = saving?.takeIf { it.state == app.streamsetu.core.data.repo.SaveState.DOWNLOADING }?.fraction)
                        val queued by c.watchQueue.items.collectAsState(); val inQueue = queued.any { it.id == movie.id }
                        Chip(if (inQueue) "In queue" else "Add to queue", inQueue, { if (inQueue) c.watchQueue.remove(movie.id) else c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(ContentKind.MOVIE, movie.id, movie.title)) }, icon = Icons.Filled.Add)
                        Chip("Share link", false, { shareTitle(c.context, "movie", movie.title) }, icon = Icons.Filled.Share)
                        if (variants.size > 1) Chip("Choose stream", false, { chooseOpen = true }, icon = Icons.Filled.SwapHoriz)
                    }
                    (info?.plot ?: movie.plot)?.takeIf { it.isNotBlank() }?.let { Label(it, Ph.body, Tokens.textSecondary, maxLines = 12, modifier = Modifier.padding(top = 4.dp)) }
                    info?.director?.takeIf { it.isNotBlank() }?.let { Label("Director  ·  $it", Ph.small, Tokens.textSecondary, maxLines = 2) }
                    info?.cast?.takeIf { it.isNotBlank() }?.let { Label("Cast  ·  $it", Ph.small, Tokens.textSecondary, maxLines = 4) }
                    Label("From  ·  ${sourceName(movie.sourceId)}", Ph.caption, Tokens.textTertiary)
                }
            }
            if (franchise.size > 1) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Timeline  ·  ${franchise.size} films")
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                        items(franchise.withIndex().toList(), key = { it.value.id }) { (i, m) ->
                            val here = m.id == movie.id
                            Column(Modifier.width(122.dp).padding(end = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                PhonePoster(m.title, m.posterUrl, { if (!here) { nav.close(); nav.open(Overlay.MovieDetail(m)) } }, Modifier.fillMaxWidth())
                                TimelineRail(i, franchise.size, franchise.indexOfFirst { it.id == movie.id }.coerceAtLeast(0))
                                Label(m.year?.toString() ?: "", Ph.small, if (here) Tokens.accent else Tokens.text, FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
            if (related.isNotEmpty()) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("More like this")
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(related, key = { it.item.id }) { r -> val m = r.item; PhonePoster(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.MovieDetail(m)) }, Modifier.width(112.dp), subtitle = r.reason, badge = ratingBadge(m.rating)) }
                    }
                }
            }
        }
    }
    if (chooseOpen) Sheet("Choose stream", variants.map { v -> SheetItem("${sourceName(v.sourceId)}  ·  ${v.streamRef.substringAfterLast(':', "").uppercase()}", Icons.Filled.PlayArrow, v.id == movie.id) { play(c, nav, MoviePlayable(v)) } }, onClose = { chooseOpen = false }, subtitle = "Plays only this time. Your default is unchanged.")
}

@Composable
fun PhoneSeriesDetail(vm: SeriesDetailViewModel, c: AppContainer, nav: Navigator) {
    val episodes by vm.episodes.collectAsState()
    val loading by vm.loading.collectAsState()
    val error by vm.error.collectAsState()
    val progress by vm.progress.collectAsState()
    val series0 = vm.series
    val overrides by c.collections.overrides.collectAsState(initial = emptyMap())
    val s = overrides[series0.id]?.let { o -> series0.copy(title = o.title ?: series0.title, posterUrl = o.posterUrl ?: series0.posterUrl, plot = series0.plot ?: o.plot) } ?: series0
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsState(initial = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsState(initial = emptySet())
    var similar by remember { mutableStateOf<List<app.streamsetu.core.data.repo.SearchRepository.Suggestion<Series>>>(emptyList()) }
    LaunchedEffect(series0.id) { similar = runCatching { c.search.similarSeries(series0) }.getOrDefault(emptyList()) }
    val seasons = episodes.groupBy { it.season }.toSortedMap()
    val plan = remember(episodes, progress) { EpisodePlan.of(episodes, progress) }
    val forward = plan.forward; val catchUp = plan.catchUp; val inProgress = plan.inProgress
    var season by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(seasons.keys, plan) { if (season == null || season !in seasons.keys) season = (inProgress ?: forward ?: episodes.firstOrNull())?.season ?: seasons.keys.firstOrNull() }
    val queue = remember(episodes) { episodes.sortedWith(compareBy({ it.season }, { it.number })).map { EpisodePlayable(it, s) } }
    val scope = rememberCoroutineScope()
    fun playEp(e: Episode) = play(c, nav, EpisodePlayable(e, s), queue)
    val watchedCount = episodes.count { progress[it.id]?.completed == true }
    val firstEp = episodes.minWithOrNull(compareBy({ it.season }, { it.number }))

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { DetailHeader(s.backdropUrl?.takeIf { it.isNotBlank() } ?: s.posterUrl, s.title) { nav.close() } }
            item {
                Column(Modifier.padding(horizontal = Ph.gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(s.title, Ph.title, Tokens.text, FontWeight.Bold, maxLines = 3)
                    Label(listOfNotNull(s.year?.toString(), if (seasons.isNotEmpty()) "${seasons.size} season${if (seasons.size == 1) "" else "s"}" else null, ratingBadge(s.rating), if (episodes.isNotEmpty()) (if (plan.allFinished) "All watched" else "$watchedCount of ${episodes.size} watched") else null).joinToString("  ·  "), Ph.small, Tokens.textSecondary, maxLines = 2)
                    app.streamsetu.core.data.repo.QualityBadges.from(listOf(s.title)).takeIf { it.isNotEmpty() }?.let { Label(it.joinToString("  ·  "), Ph.small, Tokens.accent, FontWeight.Bold) }
                    if (plan.gapBefore && forward != null) Label("Episode ${forward.number - 1} is not available. The next one on offer is episode ${forward.number}.", Ph.small, Tokens.warning, maxLines = 2)
                    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        val ip = inProgress
                        when {
                            ip != null -> PillButton("Continue S${ip.season} E${ip.number}", { playEp(ip) }, Modifier.weight(1f), icon = Icons.Filled.PlayArrow, primary = true)
                            forward != null && watchedCount > 0 -> PillButton(if (catchUp != null) "Continue Forward S${forward.season} E${forward.number}" else "Continue S${forward.season} E${forward.number}", { playEp(forward) }, Modifier.weight(1f), icon = Icons.Filled.PlayArrow, primary = true)
                            firstEp != null && plan.allFinished -> PillButton("Watch again", { playEp(firstEp) }, Modifier.weight(1f), icon = Icons.Filled.Replay, primary = true)
                            firstEp != null -> PillButton("Start series", { playEp(firstEp) }, Modifier.weight(1f), icon = Icons.Filled.PlayArrow, primary = true)
                            else -> PillButton(if (loading) "Loading episodes…" else "No episodes", {}, Modifier.weight(1f), primary = true)
                        }
                        catchUp?.let { cu -> PillButton("Catch up S${cu.season} E${cu.number}", { playEp(cu) }, Modifier.weight(1f), icon = Icons.Filled.History) }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip(if (s.id in favs) "Favorited" else "Favorite", s.id in favs, { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in favs) } }, icon = Icons.Filled.Favorite)
                        Chip(if (s.id in later) "In Watch Later" else "Watch Later", s.id in later, { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, s.id !in later, UserRepository.WATCH_LATER) } }, icon = Icons.Filled.Bookmark)
                        val queued by c.watchQueue.items.collectAsState(); val inQueue = queued.any { it.id == s.id }
                        Chip(if (inQueue) "In queue" else "Add to queue", inQueue, { if (inQueue) c.watchQueue.remove(s.id) else c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(ContentKind.SERIES, s.id, s.title)) }, icon = Icons.Filled.Add)
                        Chip("Share link", false, { shareTitle(c.context, "series", s.title) }, icon = Icons.Filled.Share)
                    }
                    s.plot?.takeIf { it.isNotBlank() }?.let { Label(it, Ph.body, Tokens.textSecondary, maxLines = 8, modifier = Modifier.padding(top = 4.dp)) }
                }
            }
            if (loading && episodes.isEmpty()) item { Row(Modifier.padding(horizontal = Ph.gutter), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Spinner(); Label("Loading episodes…", Ph.body, Tokens.textSecondary) } }
            error?.let { e -> if (episodes.isEmpty()) item { Label(e, Ph.body, Tokens.danger, maxLines = 3, modifier = Modifier.padding(horizontal = Ph.gutter)) } }
            if (seasons.size > 1) item {
                LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(seasons.keys.toList(), key = { it }) { n -> Chip("Season $n", n == season, { season = n }) } }
            }
            items((season?.let { seasons[it] }).orEmpty().sortedBy { it.number }, key = { it.id }) { e ->
                val p = progress[e.id]
                Row(Modifier.fillMaxWidth().clickable { playEp(e) }.padding(horizontal = Ph.gutter, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(128.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(8.dp)).background(Tokens.elevated)) {
                        if (!e.imageUrl.isNullOrBlank()) AsyncImage(e.imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Label("E${e.number}", Ph.heading, Tokens.textTertiary, modifier = Modifier.align(Alignment.Center))
                        if (p != null && !p.completed && p.fraction > 0) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(p.fraction).fillMaxHeight().background(Tokens.accent)) }
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Label("${e.number}. ${e.title}", Ph.body, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                        Label(listOfNotNull(e.durationSec?.takeIf { it > 0 }?.let { "${it / 60} min" }, if (p?.completed == true) "Watched" else if (p != null && p.fraction > 0) "${minutes(p.durationMs - p.positionMs)}m left" else null).joinToString("  ·  "), Ph.caption, Tokens.textSecondary)
                    }
                    if (p?.completed == true) Icon(Icons.Filled.CheckCircle, Tokens.success, 18.dp)
                    val saved by c.downloads.items.collectAsState(); val saving = saved.firstOrNull { it.itemId == e.id }
                    Tap({ downloadTap(c, saving) { c.downloads.enqueue(e, s) } }, Modifier.size(40.dp)) {
                        Box(Modifier.fillMaxSize(), Alignment.Center) {
                            when (saving?.state) {
                                app.streamsetu.core.data.repo.SaveState.DONE -> Icon(Icons.Filled.DownloadDone, Tokens.success, 22.dp)
                                app.streamsetu.core.data.repo.SaveState.DOWNLOADING -> Column(horizontalAlignment = Alignment.CenterHorizontally) { DownloadRing(saving.fraction, Tokens.accent, 22.dp); Label("${(saving.fraction * 100).toInt()}%", Ph.caption, Tokens.accent, FontWeight.SemiBold) }
                                app.streamsetu.core.data.repo.SaveState.QUEUED, app.streamsetu.core.data.repo.SaveState.PAUSED -> Icon(Icons.Filled.Pause, Tokens.textSecondary, 22.dp)
                                else -> Icon(Icons.Filled.Download, Tokens.textSecondary, 22.dp)
                            }
                        }
                    }
                }
            }
            if (similar.isNotEmpty()) item {
                Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("More like this")
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(similar, key = { it.item.id }) { r -> val m = r.item; PhonePoster(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.SeriesDetail(m)) }, Modifier.width(112.dp), subtitle = r.reason, badge = ratingBadge(m.rating)) }
                    }
                }
            }
        }
    }
}

/** The words on the Download chip for a title's state: what it does when pressed is in [downloadTap]. */
internal fun downloadLabel(t: app.streamsetu.core.data.repo.SavedTitle?): String = when (t?.state) {
    null -> "Download"
    app.streamsetu.core.data.repo.SaveState.QUEUED -> "Waiting"
    app.streamsetu.core.data.repo.SaveState.DOWNLOADING -> "Saving ${(t.fraction * 100).toInt()}%"
    app.streamsetu.core.data.repo.SaveState.PAUSED -> "Paused"
    app.streamsetu.core.data.repo.SaveState.DONE -> "Saved"
    app.streamsetu.core.data.repo.SaveState.FAILED -> "Try again"
}

/** One press: start it, pause it, carry on, or (when it is saved) remove the saved copy. */
internal fun downloadTap(c: AppContainer, t: app.streamsetu.core.data.repo.SavedTitle?, start: () -> Unit) {
    when (t?.state) {
        null -> start()
        app.streamsetu.core.data.repo.SaveState.FAILED -> { c.downloads.remove(t.itemId); start() }
        app.streamsetu.core.data.repo.SaveState.QUEUED, app.streamsetu.core.data.repo.SaveState.DOWNLOADING -> c.downloads.pause(t.itemId)
        app.streamsetu.core.data.repo.SaveState.PAUSED -> c.downloads.resume(t.itemId)
        app.streamsetu.core.data.repo.SaveState.DONE -> c.downloads.remove(t.itemId)
    }
}
