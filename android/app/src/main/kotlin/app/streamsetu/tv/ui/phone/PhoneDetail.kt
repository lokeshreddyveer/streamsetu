package app.streamsetu.tv.ui.phone

import androidx.compose.ui.platform.testTag
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

private fun minutes(ms: Long) = (ms / 60000).toInt().coerceAtLeast(0)

@Composable
fun PhoneMovieDetail(movie0: Movie, c: AppContainer, nav: Navigator) {
    val overrides by c.collections.overrides.collectAsStateWithLifecycle(initialValue = emptyMap())
    val movie = overrides[movie0.id]?.let { o -> movie0.copy(title = o.title ?: movie0.title, posterUrl = o.posterUrl ?: movie0.posterUrl, plot = movie0.plot ?: o.plot) } ?: movie0
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsStateWithLifecycle(initialValue = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsStateWithLifecycle(initialValue = emptySet())
    val allProgress by c.user.allProgress().collectAsStateWithLifecycle(initialValue = emptyMap())
    val progress = allProgress[movie.id]
    var info by remember { mutableStateOf<SyncService.MovieInfo?>(null) }
    var variants by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var franchise by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var otherLanguages by remember { mutableStateOf<List<Pair<app.streamsetu.core.data.repo.OtherVersions.Version, Movie>>?>(null) }
    val tmdbState = app.streamsetu.tv.ui.components.rememberTmdbDetailsState(c, movie.id, movie.title, movie.year, false, movie.categoryId)
    val tmdb = tmdbState.details
    val cast = tmdb.cast
    var openVersion by remember(movie.id) { mutableStateOf<app.streamsetu.core.data.repo.OtherVersions.Version?>(null) }
    LaunchedEffect(movie.id) { openVersion = runCatching { c.search.versionOf(movie) }.getOrNull() }
    var related by remember { mutableStateOf<List<app.streamsetu.core.data.repo.SearchRepository.Suggestion<Movie>>>(emptyList()) }
    var chooseOpen by remember { mutableStateOf(false) }
    val sources by c.library.entries.collectAsStateWithLifecycle(initialValue = emptyList())
    val scope = rememberCoroutineScope()
    LaunchedEffect(movie.id) {
        info = runCatching { c.sync.movieInfo(movie) }.getOrNull()
        variants = runCatching { c.search.movieVariants(movie.title) }.getOrDefault(emptyList())
        franchise = runCatching { c.search.franchiseOf(movie) }.getOrDefault(emptyList())
        otherLanguages = runCatching { c.search.otherVersionsOf(movie, app.streamsetu.tv.ui.components.preferredLanguage(c)) }.getOrDefault(emptyList())
        val facts = info?.let { app.streamsetu.core.data.repo.Similarity.facts(it.genre, it.cast, it.director) }
        runCatching { c.search.similarMovies(movie, facts) { m -> c.sync.movieInfo(m)?.let { app.streamsetu.core.data.repo.Similarity.facts(it.genre, it.cast, it.director) } }.collect { related = it } }
    }
    val resumable = progress?.takeIf { !it.completed && it.positionMs > 30_000 }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"

    val queued by c.watchQueue.items.collectAsStateWithLifecycle()
    val inQueue = queued.any { it.id == movie.id }
    val saved by c.downloads.items.collectAsStateWithLifecycle(); val saving = saved.firstOrNull { it.itemId == movie.id }
    var versionOpen by remember(movie.id) { mutableStateOf(false) }
    var menuOpen by remember(movie.id) { mutableStateOf(false) }
    val versionRows = otherLanguages.orEmpty()
    val isFav = movie.id in favs; val isLater = movie.id in later
    val hubView = app.streamsetu.tv.ui.components.rememberTitleHub(c, movie.id, false)
    val top = app.streamsetu.tv.ui.components.TitleTop(
        title = movie.title, logo = hubView.logo, nextEpisode = hubView.nextEpisode, backdrop = hubView.backdrop ?: info?.backdrop?.takeIf { it.isNotBlank() } ?: tmdb.backdrop, poster = movie.posterUrl,
        meta = app.streamsetu.core.data.repo.TitlePageText.metaLine(movie.year, app.streamsetu.core.data.repo.TitlePageText.runtime(info?.duration), null, app.streamsetu.core.data.repo.TitlePageText.quality(movie.title, movie.streamRef.substringAfterLast(':', "")), tmdb.ratingOr(movie.rating)),
        pickerLabel = app.streamsetu.core.data.repo.TitlePageText.pickerLabel(openVersion?.let { it.language ?: it.label }, versionRows.size), onPicker = { versionOpen = true },
        playLabel = app.streamsetu.core.data.repo.TitlePageText.playMovie(resumable?.positionMs ?: 0L, resumable?.durationMs ?: 0L, resumable != null), playProgress = resumable?.fraction,
        onPlay = { c.playBestMovie(movie) { play(c, nav, it) } }, playFocus = null,
        actions = buildList {
            add(app.streamsetu.tv.ui.components.TitleAction(if (isFav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, "Favourite", isFav, "Favourite, " + if (isFav) "on" else "off", "action-favourite") { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, !isFav) } })
            add(app.streamsetu.tv.ui.components.TitleAction(if (isLater) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, "Watch Later", isLater, "Watch Later, " + if (isLater) "on" else "off", "action-later") { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, !isLater, UserRepository.WATCH_LATER) } })
            tmdb.trailerKey?.let { k -> add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Movie, "Trailer", tag = "action-trailer") { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }) }
            add(app.streamsetu.tv.ui.components.TitleAction(if (saving?.state == app.streamsetu.core.data.repo.SaveState.DONE) Icons.Filled.DownloadDone else Icons.Filled.Download, downloadLabel(saving), saving?.state == app.streamsetu.core.data.repo.SaveState.DONE, downloadLabel(saving), "action-download") { downloadTap(c, saving) { c.downloads.enqueue(movie) } })
            add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Share, "Share", tag = "action-share") { shareTitle(c.context, "movie", movie.title) })
        },
        synopsis = (info?.plot ?: movie.plot ?: tmdb.plot), genres = app.streamsetu.core.data.repo.TitlePageText.genres(info?.genre), onBack = { nav.close() }, onMenu = { menuOpen = true })
    val rows = app.streamsetu.core.data.repo.TitlePageText.details(info?.director, info?.cast ?: tmdb.cast.take(6).joinToString(", ") { it.name }, null, null, info?.releaseDate, movie.categoryId != null)
    val detailsAndMore: androidx.compose.foundation.lazy.LazyListScope.() -> Unit = {
        if (rows.isNotEmpty()) item(key = "details") {
            Box(Modifier.padding(horizontal = Ph.gutter)) { app.streamsetu.tv.ui.components.DetailsList(rows, false, { n -> nav.open(Overlay.Person(n, null, null, movie.title, movie.year)) }, if (movie.categoryId != null) { { app.streamsetu.tv.ui.components.FolderPath(c, ContentKind.MOVIE, movie.categoryId, phone = true) { id -> nav.close(); nav.openFolderTab(ContentKind.MOVIE, id) } } } else null) }
        }
        if (cast.isEmpty() && tmdbState.problem != null) item(key = "cast-problem") { app.streamsetu.tv.ui.components.TmdbProblemLine(tmdbState, tv = false) }
        if (cast.isNotEmpty()) item(key = "cast") { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionHeader("Cast"); app.streamsetu.tv.ui.components.CastRow(cast, false) { m -> nav.open(Overlay.Person(m.name, m.photo, m.id, movie.title, movie.year)) } } }
        if (versionRows.size > 1) item(key = "versions") { app.streamsetu.tv.ui.components.PhoneOtherLanguages(otherLanguages, { it.posterUrl }, { m -> nav.close(); nav.open(Overlay.MovieDetail(m)) }) }
        tmdb.trailerKey?.let { k -> item(key = "extras") { Column(Modifier.padding(horizontal = Ph.gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionHeader("Trailers & extras"); PillButton("Official trailer", { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }, Modifier.fillMaxWidth().testTag("extras-trailer"), icon = Icons.Filled.Movie) } } }
            if (franchise.size > 1) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Timeline  ·  ${franchise.size} films")
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                        items(franchise.withIndex().toList(), key = { it.value.id }) { (i, m) ->
                            val here = m.id == movie.id
                            Column(Modifier.width(122.dp).padding(end = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                PhonePoster(m.title, m.posterUrl, { if (!here) { nav.close(); nav.open(Overlay.MovieDetail(m)) } }, Modifier.fillMaxWidth(), itemId = m.id)
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
                        items(related, key = { it.item.id }) { r -> val m = r.item; PhonePoster(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.MovieDetail(m)) }, Modifier.width(112.dp), subtitle = r.reason, itemId = m.id) }
                    }
                }
            }
    }
    TitlePageScaffold(top, detailsAndMore)
    if (versionOpen) Sheet("Versions", versionRows.map { (v, m) -> SheetItem(v.label, Icons.Filled.SwapHoriz, v.current) { if (!v.current) { nav.close(); nav.open(Overlay.MovieDetail(m)) } } }, onClose = { versionOpen = false })
    if (menuOpen) Sheet(movie.title, buildList {
        add(SheetItem("Play privately", Icons.Filled.VisibilityOff) { c.playBestMovie(movie) { play(c, nav, it, privately = true) } })
        if (resumable != null || progress?.completed == true) add(SheetItem("Start over", Icons.Filled.Replay) { scope.launch { c.user.clearResumePoint(movie.id) }; c.play(MoviePlayable(movie), listOf(MoviePlayable(movie)), startOver = true); if (nav.top != Overlay.Player) nav.open(Overlay.Player) })
        add(SheetItem(if (inQueue) "In queue" else "Add to queue", Icons.Filled.Add, inQueue) { if (inQueue) c.watchQueue.remove(movie.id) else c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(ContentKind.MOVIE, movie.id, movie.title)) })
        if (variants.size > 1) add(SheetItem("Choose stream", Icons.Filled.SwapHoriz) { chooseOpen = true })
    }, onClose = { menuOpen = false })
    if (chooseOpen) Sheet("Choose stream", variants.map { v -> SheetItem("${sourceName(v.sourceId)}  ·  ${v.streamRef.substringAfterLast(':', "").uppercase()}", Icons.Filled.PlayArrow, v.id == movie.id) { play(c, nav, MoviePlayable(v)) } }, onClose = { chooseOpen = false }, subtitle = "Plays only this time. Your default is unchanged.")
}

@Composable
fun PhoneSeriesDetail(vm: SeriesDetailViewModel, c: AppContainer, nav: Navigator) {
    val episodes by vm.episodes.collectAsStateWithLifecycle()
    val loading by vm.loading.collectAsStateWithLifecycle()
    val error by vm.error.collectAsStateWithLifecycle()
    val progress by vm.progress.collectAsStateWithLifecycle()
    val series0 = vm.series
    val overrides by c.collections.overrides.collectAsStateWithLifecycle(initialValue = emptyMap())
    val s = overrides[series0.id]?.let { o -> series0.copy(title = o.title ?: series0.title, posterUrl = o.posterUrl ?: series0.posterUrl, plot = series0.plot ?: o.plot) } ?: series0
    val favs by c.user.favouriteIds(UserRepository.FAVOURITES).collectAsStateWithLifecycle(initialValue = emptySet())
    val later by c.user.favouriteIds(UserRepository.WATCH_LATER).collectAsStateWithLifecycle(initialValue = emptySet())
    var similar by remember { mutableStateOf<List<app.streamsetu.core.data.repo.SearchRepository.Suggestion<Series>>>(emptyList()) }
    LaunchedEffect(series0.id) { similar = runCatching { c.search.similarSeries(series0) }.getOrDefault(emptyList()) }
    var otherLanguages by remember { mutableStateOf<List<Pair<app.streamsetu.core.data.repo.OtherVersions.Version, Series>>?>(null) }
    val tmdbState = app.streamsetu.tv.ui.components.rememberTmdbDetailsState(c, series0.id, series0.title, series0.year, true, series0.categoryId)
    val tmdb = tmdbState.details
    val cast = tmdb.cast
    var openVersion by remember(series0.id) { mutableStateOf<app.streamsetu.core.data.repo.OtherVersions.Version?>(null) }
    LaunchedEffect(series0.id) { openVersion = runCatching { c.search.versionOf(series0) }.getOrNull() }
    LaunchedEffect(series0.id) { otherLanguages = runCatching { c.search.otherVersionsOf(series0, app.streamsetu.tv.ui.components.preferredLanguage(c)) }.getOrDefault(emptyList()) }
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

    val queued by c.watchQueue.items.collectAsStateWithLifecycle()
    val inQueue = queued.any { it.id == s.id }
    var versionOpen by remember(s.id) { mutableStateOf(false) }
    var menuOpen by remember(s.id) { mutableStateOf(false) }
    val versionRows = otherLanguages.orEmpty()
    val isFav = s.id in favs; val isLater = s.id in later
    val ip = inProgress
    val playAction: () -> Unit = when {
        ip != null -> { { playEp(ip) } }
        forward != null && watchedCount > 0 -> { { playEp(forward) } }
        firstEp != null -> { { playEp(firstEp) } }
        else -> { {} }
    }
    val hubView = app.streamsetu.tv.ui.components.rememberTitleHub(c, s.id, true)
    val top = app.streamsetu.tv.ui.components.TitleTop(
        title = s.title, logo = hubView.logo, nextEpisode = hubView.nextEpisode, backdrop = hubView.backdrop ?: s.backdropUrl?.takeIf { it.isNotBlank() } ?: tmdb.backdrop, poster = s.posterUrl,
        meta = app.streamsetu.core.data.repo.TitlePageText.metaLine(s.year, if (seasons.isNotEmpty()) app.streamsetu.core.model.Plurals.format("season", seasons.size) else null, null, app.streamsetu.core.data.repo.TitlePageText.quality(s.title), tmdb.ratingOr(s.rating)),
        pickerLabel = app.streamsetu.core.data.repo.TitlePageText.pickerLabel(openVersion?.let { it.language ?: it.label }, versionRows.size), onPicker = { versionOpen = true },
        playLabel = app.streamsetu.core.data.repo.TitlePageText.playSeries(ip?.let { it.season to it.number }, if (watchedCount > 0) forward?.let { it.season to it.number } else null, firstEp?.let { it.season to it.number }, plan.allFinished, loading), playProgress = null,
        onPlay = playAction, playFocus = null,
        actions = buildList {
            add(app.streamsetu.tv.ui.components.TitleAction(if (isFav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, "Favourite", isFav, "Favourite, " + if (isFav) "on" else "off", "action-favourite") { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, !isFav) } })
            add(app.streamsetu.tv.ui.components.TitleAction(if (isLater) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, "Watch Later", isLater, "Watch Later, " + if (isLater) "on" else "off", "action-later") { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, !isLater, UserRepository.WATCH_LATER) } })
            tmdb.trailerKey?.let { k -> add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Movie, "Trailer", tag = "action-trailer") { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }) }
            add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Share, "Share", tag = "action-share") { shareTitle(c.context, "series", s.title) })
        },
        synopsis = s.plot ?: tmdb.plot, genres = emptyList(), onBack = { nav.close() }, onMenu = { menuOpen = true })
    val rows = app.streamsetu.core.data.repo.TitlePageText.details(null, tmdb.cast.take(6).joinToString(", ") { it.name }, null, null, s.year?.toString(), s.categoryId != null)
    val content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit = {
        // Episodes come right after the actions, synopsis and genres, before the details and the cast.
        item(key = "episodesHead") { Column(Modifier.padding(horizontal = Ph.gutter), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            SectionHeader("Episodes")
            if (episodes.isNotEmpty()) Label(if (plan.allFinished) "All watched" else "$watchedCount of ${episodes.size} watched", Ph.small, if (plan.allFinished) Tokens.success else Tokens.textSecondary)
            if (plan.gapBefore && forward != null) Label("Episode ${forward.number - 1} is not available. The next one on offer is episode ${forward.number}.", Ph.small, Tokens.warning, maxLines = 2)
        } }
            if (loading && episodes.isEmpty()) item { Row(Modifier.padding(horizontal = Ph.gutter), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { app.streamsetu.tv.ui.components.BrandLoader(size = 30.dp); Label("Loading episodes…", Ph.body, Tokens.textSecondary) } }
            error?.let { e -> if (episodes.isEmpty()) item { Label(e, Ph.body, Tokens.danger, maxLines = 3, modifier = Modifier.padding(horizontal = Ph.gutter)) } }
            if (seasons.size > 1) item(key = "seasons") {
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
                    val saved by c.downloads.items.collectAsStateWithLifecycle(); val saving = saved.firstOrNull { it.itemId == e.id }
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
        if (rows.isNotEmpty()) item(key = "details") {
            Box(Modifier.padding(horizontal = Ph.gutter)) { app.streamsetu.tv.ui.components.DetailsList(rows, false, { n -> nav.open(Overlay.Person(n, null, null, series0.title, series0.year)) }, if (s.categoryId != null) { { app.streamsetu.tv.ui.components.FolderPath(c, ContentKind.SERIES, s.categoryId, phone = true) { id -> nav.close(); nav.openFolderTab(ContentKind.SERIES, id) } } } else null) }
        }
        if (cast.isEmpty() && tmdbState.problem != null) item(key = "cast-problem") { app.streamsetu.tv.ui.components.TmdbProblemLine(tmdbState, tv = false) }
        if (cast.isNotEmpty()) item(key = "cast") { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionHeader("Cast"); app.streamsetu.tv.ui.components.CastRow(cast, false) { m -> nav.open(Overlay.Person(m.name, m.photo, m.id, series0.title, series0.year)) } } }
        if (versionRows.size > 1) item(key = "versions") { app.streamsetu.tv.ui.components.PhoneOtherLanguages(otherLanguages, { it.posterUrl }, { sr -> nav.close(); nav.open(Overlay.SeriesDetail(sr)) }) }
        tmdb.trailerKey?.let { k -> item(key = "extras") { Column(Modifier.padding(horizontal = Ph.gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionHeader("Trailers & extras"); PillButton("Official trailer", { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }, Modifier.fillMaxWidth().testTag("extras-trailer"), icon = Icons.Filled.Movie) } } }
            if (similar.isNotEmpty()) item {
                Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("More like this")
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(similar, key = { it.item.id }) { r -> val m = r.item; PhonePoster(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.SeriesDetail(m)) }, Modifier.width(112.dp), subtitle = r.reason, itemId = m.id) }
                    }
                }
            }
    }
    TitlePageScaffold(top, content)
    if (versionOpen) Sheet("Versions", versionRows.map { (v, m) -> SheetItem(v.label, Icons.Filled.SwapHoriz, v.current) { if (!v.current) { nav.close(); nav.open(Overlay.SeriesDetail(m)) } } }, onClose = { versionOpen = false })
    if (menuOpen) Sheet(s.title, buildList {
        add(SheetItem("Play privately", Icons.Filled.VisibilityOff) { c.appScope.launch { c.playSeries(s, privately = true); kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { if (nav.top != Overlay.Player) nav.open(Overlay.Player) } } })
        catchUp?.let { cu -> add(SheetItem("Catch up S${cu.season} E${cu.number}", Icons.Filled.History) { playEp(cu) }) }
        add(SheetItem(if (inQueue) "In queue" else "Add to queue", Icons.Filled.Add, inQueue) { if (inQueue) c.watchQueue.remove(s.id) else c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(ContentKind.SERIES, s.id, s.title)) })
    }, onClose = { menuOpen = false })
}

/** The page: one list, hero first. On a wide screen (a tablet, a phone on its side) the hero and the first block share a row. */
@Composable
internal fun TitlePageScaffold(top: app.streamsetu.tv.ui.components.TitleTop, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Tokens.background)) {
        val wide = maxWidth >= 840.dp
        LazyColumn(Modifier.fillMaxSize().testTag("title-page"), contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (wide) item(key = "top") {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    app.streamsetu.tv.ui.components.TitleHero(false, top, Modifier.weight(1f), height = 420.dp)
                    app.streamsetu.tv.ui.components.TitleBody(false, top, Modifier.weight(1f).padding(end = Ph.gutter, top = 48.dp))
                }
            } else {
                item(key = "hero") { app.streamsetu.tv.ui.components.TitleHero(false, top) }
                item(key = "top") { app.streamsetu.tv.ui.components.TitleBody(false, top, Modifier.padding(horizontal = Ph.gutter)) }
            }
            content()
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
