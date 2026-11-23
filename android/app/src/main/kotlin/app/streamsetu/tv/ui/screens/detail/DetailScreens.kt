package app.streamsetu.tv.ui.screens.detail

import app.streamsetu.tv.ui.screens.library.riseIn
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawBehind
import androidx.compose.animation.togetherWith
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
import app.streamsetu.tv.ui.theme.Tokens
import androidx.compose.ui.platform.testTag
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

private fun minutes(ms: Long) = (ms / 60000).toInt().coerceAtLeast(0)

@Composable
private fun Backdrop(url: String?, title: String, dim: Float = 0.9f) {
    val context = androidx.compose.ui.platform.LocalContext.current
    // The page's first frame is the plain background with its title and buttons; the picture and its shading come two frames later, so they do not hold up the page that has just opened.
    var ready by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { androidx.compose.runtime.withFrameNanos { }; androidx.compose.runtime.withFrameNanos { }; ready = true }
    if (!ready) return
    // The picture and its shading are drawn once into a texture; each frame after that is one copy of it, however the page above moves. The shading covers only the part of the screen it darkens.
    Box(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen }) {
        if (!url.isNullOrBlank()) AsyncImage(artworkRequest(context, url, 1280, 720), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else PosterPlaceholder(title, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().drawBehind {
            val w = size.width; val h = size.height
            drawRect(Brush.horizontalGradient(0f to Tokens.background.copy(alpha = 0.97f), 0.64f to Tokens.background.copy(alpha = 0.86f), 1f to Color.Transparent, startX = 0f, endX = w * 0.85f), size = androidx.compose.ui.geometry.Size(w * 0.85f, h))
            drawRect(Brush.verticalGradient(0f to Color.Transparent, 1f to Tokens.background.copy(alpha = dim), startY = h * 0.5f, endY = h), topLeft = androidx.compose.ui.geometry.Offset(0f, h * 0.5f), size = androidx.compose.ui.geometry.Size(w, h * 0.5f))
        })
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
    LaunchedEffect(movie.id) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
    // The extra parts start after the page has come in, so their work does not land on the frames of the opening transition.
    LaunchedEffect(movie.id) { kotlinx.coroutines.delay(350); info = runCatching { c.sync.movieInfo(movie) }.getOrNull() }
    LaunchedEffect(movie.id) { kotlinx.coroutines.delay(350); variants = runCatching { c.search.movieVariants(movie.title) }.getOrDefault(emptyList()) }
    val pictures by c.artwork.filled.collectAsState()          // the timeline is read again when another picture has been found
    LaunchedEffect(movie.id, pictures) { kotlinx.coroutines.delay(400); franchise = runCatching { c.search.franchiseOf(movie) }.getOrDefault(emptyList()) }
    // The same film in other languages (or in another playlist), read off the screen's thread after the page has come in.
    var otherLanguages by remember { mutableStateOf<List<Pair<app.streamsetu.core.data.repo.OtherVersions.Version, Movie>>?>(null) }
    val tmdbState = app.streamsetu.tv.ui.components.rememberTmdbDetailsState(c, movie.id, movie.title, movie.year, false, movie.categoryId)
    val tmdb = tmdbState.details
    val cast = tmdb.cast
    var openVersion by remember(movie.id) { mutableStateOf<app.streamsetu.core.data.repo.OtherVersions.Version?>(null) }
    LaunchedEffect(movie.id) { openVersion = runCatching { c.search.versionOf(movie) }.getOrNull() }
    LaunchedEffect(movie.id) { kotlinx.coroutines.delay(450); otherLanguages = runCatching { c.search.otherVersionsOf(movie, app.streamsetu.tv.ui.components.preferredLanguage(c)) }.getOrDefault(emptyList()) }
    // "More like this" is ranked once, from what is already on the device, and shown as it is: it does not grow or reshuffle a few seconds later.
    var relatedLoaded by remember(movie.id) { mutableStateOf(false) }
    LaunchedEffect(movie.id, pictures) {          // read again when another picture has been found: the same titles in the same order, now with the picture
        kotlinx.coroutines.delay(450)
        runCatching { c.search.similarMovies(movie, null) { null }.collect { related = it } }
        relatedLoaded = true
    }
    val resumable = progress?.takeIf { !it.completed && it.positionMs > 30_000 }
    val container = movie.streamRef.substringAfterLast(':', "").uppercase().takeIf { it.length in 2..4 }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"

    val queued by c.watchQueue.items.collectAsState()
    val inQueue = queued.any { it.id == movie.id }
    var versionOpen by remember(movie.id) { mutableStateOf(false) }
    val versionRows = otherLanguages.orEmpty()
    val isFav = movie.id in favs; val isLater = movie.id in later
    val hubView = app.streamsetu.tv.ui.components.rememberTitleHub(c, movie.id, false)
    val top = app.streamsetu.tv.ui.components.TitleTop(
        title = movie.title, logo = hubView.logo, nextEpisode = hubView.nextEpisode, backdrop = hubView.backdrop ?: info?.backdrop?.takeIf { it.isNotBlank() } ?: tmdb.backdrop, poster = movie.posterUrl,
        meta = app.streamsetu.core.data.repo.TitlePageText.metaLine(movie.year, app.streamsetu.core.data.repo.TitlePageText.runtime(info?.duration), null, app.streamsetu.core.data.repo.TitlePageText.quality(movie.title, container), tmdb.ratingOr(movie.rating)),
        pickerLabel = app.streamsetu.core.data.repo.TitlePageText.pickerLabel(openVersion?.let { it.language ?: it.label }, versionRows.size), onPicker = { versionOpen = true },
        playLabel = app.streamsetu.core.data.repo.TitlePageText.playMovie(resumable?.positionMs ?: 0L, resumable?.durationMs ?: 0L, resumable != null), playProgress = resumable?.fraction,
        onPlay = { c.playBestMovie(movie) { play(c, nav, it) } }, playFocus = first,
        actions = buildList {
            add(app.streamsetu.tv.ui.components.TitleAction(if (isFav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, "Favourite", isFav, "Favourite, " + if (isFav) "on" else "off", "action-favourite") { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, !isFav) } })
            add(app.streamsetu.tv.ui.components.TitleAction(if (isLater) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, "Watch Later", isLater, "Watch Later, " + if (isLater) "on" else "off", "action-later") { scope.launch { c.user.setFavourite(movie.id, ContentKind.MOVIE, !isLater, UserRepository.WATCH_LATER) } })
            tmdb.trailerKey?.let { k -> add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Movie, "Trailer", tag = "action-trailer") { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }) }
            add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Share, "Share", tag = "action-share") { app.streamsetu.tv.ui.phone.shareTitle(c.context, "movie", movie.title) })
        },
        synopsis = (info?.plot ?: movie.plot ?: tmdb.plot), genres = app.streamsetu.core.data.repo.TitlePageText.genres(info?.genre), onMenu = { moreMenu = true })
    val rows = app.streamsetu.core.data.repo.TitlePageText.details(info?.director, info?.cast ?: tmdb.cast.take(6).joinToString(", ") { it.name }, null, null, info?.releaseDate, movie.categoryId != null)
    val pad = Modifier.padding(horizontal = Tokens.safeHorizontal)
    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        LazyColumn(Modifier.fillMaxSize(), state = rememberLazyListState(), contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            item(key = "hero") { app.streamsetu.tv.ui.components.TitleHero(true, top, inset = Tokens.safeHorizontal) }
            item(key = "top") { app.streamsetu.tv.ui.components.TitleBody(true, top, pad.widthIn(max = 720.dp)) }
            if (rows.isNotEmpty()) item(key = "details") {
                Box(pad.widthIn(max = 720.dp)) { app.streamsetu.tv.ui.components.DetailsList(rows, true, { n -> nav.open(Overlay.Person(n, null, null, movie.title, movie.year)) }, if (movie.categoryId != null) { { FolderPath(c, ContentKind.MOVIE, movie.categoryId, phone = false) { id -> nav.close(); nav.openFolderTab(ContentKind.MOVIE, id) } } } else null) }
            }
            if (cast.isEmpty() && tmdbState.problem != null) item(key = "cast-problem") { app.streamsetu.tv.ui.components.TmdbProblemLine(tmdbState, tv = true) }
            if (cast.isNotEmpty()) item(key = "cast") { Column(pad, verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionTitle("Cast"); app.streamsetu.tv.ui.components.CastRow(cast, true) { m -> nav.open(Overlay.Person(m.name, m.photo, m.id, movie.title, movie.year)) } } }
            if (versionRows.size > 1) item(key = "versions") { Box(pad) { app.streamsetu.tv.ui.components.TvOtherLanguages(otherLanguages, { it.posterUrl }) { m -> nav.close(); nav.open(Overlay.MovieDetail(m)) } } }
            tmdb.trailerKey?.let { k -> item(key = "extras") { Column(pad, verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionTitle("Trailers & extras"); TvButton("Official trailer", { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }, Modifier.testTag("extras-trailer"), icon = Icons.Filled.Movie) } } }
            if (franchise.size > 1) item(key = "franchise") { Box(pad) { FranchiseTimeline(franchise, movie.id) { m -> nav.close(); nav.open(Overlay.MovieDetail(m)) } } }
            if (!relatedLoaded) item(key = "relatedSkeleton") { Box(pad) { RelatedPlaceholders() } }
            if (related.isNotEmpty()) item(key = "related") {
                Column(pad) {
                    SectionTitle("More like this")
                    val firstRelated = remember { FocusRequester() }
                    LazyRow(Modifier.bleedStart(24.dp).focusRestorer { firstRelated }, horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(start = 32.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)) { itemsIndexed(related, key = { _, r -> r.item.id }) { idx, r -> val m = r.item; PosterCard(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.MovieDetail(m)) }, itemId = m.id, subtitle = r.reason, width = 150.ui, focusRequester = if (idx == 0) firstRelated else null) } }
                }
            }
        }
    }
    if (versionOpen) ContextMenu("Versions", null, versionRows.map { (v, m) -> MenuAction(v.label + if (v.current) "  (current)" else "", Icons.Filled.SwapHoriz, enabled = !v.current) { nav.close(); nav.open(Overlay.MovieDetail(m)) } }, onClose = { versionOpen = false })
    if (moreMenu) ContextMenu(movie.title, null, buildList {
        if (resumable != null || progress?.completed == true) add(MenuAction("Start Over", Icons.Filled.Replay) { scope.launch { c.user.clearResumePoint(movie.id) }; c.play(MoviePlayable(movie), listOf(MoviePlayable(movie)), startOver = true); if (nav.top != Overlay.Player) nav.open(Overlay.Player) })
        add(MenuAction("Watch privately", Icons.Filled.VisibilityOff) { c.playBestMovie(movie) { play(c, nav, it, privately = true) } })
        if (variants.size > 1) add(MenuAction("Choose Stream", Icons.Filled.SwapHoriz) { chooseOpen = true })
        add(MenuAction(if (inQueue) "Remove from queue" else "Add to queue", if (inQueue) Icons.Filled.Check else Icons.Filled.Add) { if (inQueue) c.watchQueue.remove(movie.id) else c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(ContentKind.MOVIE, movie.id, movie.title)) })
        add(MenuAction("Edit title and poster", Icons.Filled.Edit) { editing = true })
    }, onClose = { moreMenu = false })
    if (editing) OverrideDialog(movie.title, overrides[movie0.id]?.posterUrl.orEmpty(), onSave = { t, p -> scope.launch { c.collections.setOverride(movie0.id, t.takeIf { it != movie0.title }, p) }; editing = false }, onReset = { scope.launch { c.collections.clearOverride(movie0.id) }; editing = false }, onClose = { editing = false })
    if (chooseOpen) ContextMenu("Choose Stream", "Opens only this play. Your default is unchanged.", variants.map { v -> MenuAction("${sourceName(v.sourceId)}  ·  ${v.streamRef.substringAfterLast(':', "").uppercase()}", Icons.Filled.PlayArrow) { play(c, nav, MoviePlayable(v)) } }, onClose = { chooseOpen = false })
}

@Composable
private fun StatusChip(text: String, color: Color = Tokens.textSecondary) {
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
    val seriesPictures by c.artwork.filled.collectAsState()
    LaunchedEffect(series0.id, seriesPictures) { kotlinx.coroutines.delay(450); similar = runCatching { c.search.similarSeries(series0) }.getOrDefault(emptyList()); similarLoaded = true }
    var otherLanguages by remember { mutableStateOf<List<Pair<app.streamsetu.core.data.repo.OtherVersions.Version, Series>>?>(null) }
    val tmdbState = app.streamsetu.tv.ui.components.rememberTmdbDetailsState(c, series0.id, series0.title, series0.year, true, series0.categoryId)
    val tmdb = tmdbState.details
    val cast = tmdb.cast
    var openVersion by remember(series0.id) { mutableStateOf<app.streamsetu.core.data.repo.OtherVersions.Version?>(null) }
    LaunchedEffect(series0.id) { openVersion = runCatching { c.search.versionOf(series0) }.getOrNull() }
    LaunchedEffect(series0.id) { kotlinx.coroutines.delay(450); otherLanguages = runCatching { c.search.otherVersionsOf(series0, app.streamsetu.tv.ui.components.preferredLanguage(c)) }.getOrDefault(emptyList()) }
    var chooseOpen by remember { mutableStateOf(false) }
    var episodesOpen by remember { mutableStateOf(false) }
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
        if (!episodeRestored && episodes.isNotEmpty() && season != null) { app.streamsetu.tv.ui.components.requestFocusSoon(episodeTarget, 30); episodeRestored = true }
    }
    LaunchedEffect(seasons.keys, plan) { if (season == null || season !in seasons.keys) season = (inProgress ?: forward ?: episodes.firstOrNull())?.season ?: seasons.keys.firstOrNull() }
    val queue = remember(episodes) { episodes.sortedWith(compareBy({ it.season }, { it.number })).map { EpisodePlayable(it, s) } }
    val scope = rememberCoroutineScope()
    val activeSeasonChip = remember { FocusRequester() }
    val first = remember { FocusRequester() }
    LaunchedEffect(s.id) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 8); kotlinx.coroutines.delay(350); variants = runCatching { c.search.seriesVariants(s.title) }.getOrDefault(emptyList()) }
    fun sourceName(id: String) = sources.firstOrNull { it.id == "src:$id" }?.name ?: "Connection"
    fun playEp(e: Episode) = play(c, nav, EpisodePlayable(e, s), queue)
    val watchedCount = episodes.count { progress[it.id]?.completed == true }

    val queued by c.watchQueue.items.collectAsState()
    val inQueue = queued.any { it.id == s.id }
    var versionOpen by remember(s.id) { mutableStateOf(false) }
    var menuOpen by remember(s.id) { mutableStateOf(false) }
    val versionRows = otherLanguages.orEmpty()
    val isFav = s.id in favs; val isLater = s.id in later
    val first0 = episodes.minWithOrNull(compareBy({ it.season }, { it.number }))
    val ip = inProgress
    val playAction: () -> Unit = when {
        ip != null -> { { playEp(ip) } }
        forward != null && watchedCount > 0 -> { { playEp(forward) } }
        first0 != null -> { { playEp(first0) } }
        else -> { {} }
    }
    val hubView = app.streamsetu.tv.ui.components.rememberTitleHub(c, s.id, true)
    val top = app.streamsetu.tv.ui.components.TitleTop(
        title = s.title, logo = hubView.logo, nextEpisode = hubView.nextEpisode, backdrop = hubView.backdrop ?: s.backdropUrl?.takeIf { it.isNotBlank() } ?: tmdb.backdrop, poster = s.posterUrl,
        meta = app.streamsetu.core.data.repo.TitlePageText.metaLine(s.year, if (seasons.isNotEmpty()) app.streamsetu.core.model.Plurals.format("season", seasons.size) else null, null, app.streamsetu.core.data.repo.TitlePageText.quality(s.title), tmdb.ratingOr(s.rating)),
        pickerLabel = app.streamsetu.core.data.repo.TitlePageText.pickerLabel(openVersion?.let { it.language ?: it.label }, versionRows.size), onPicker = { versionOpen = true },
        playLabel = app.streamsetu.core.data.repo.TitlePageText.playSeries(ip?.let { it.season to it.number }, if (watchedCount > 0) forward?.let { it.season to it.number } else null, first0?.let { it.season to it.number }, plan.allFinished, loading), playProgress = null,
        onPlay = playAction, playFocus = first,
        actions = buildList {
            add(app.streamsetu.tv.ui.components.TitleAction(if (isFav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, "Favourite", isFav, "Favourite, " + if (isFav) "on" else "off", "action-favourite") { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, !isFav) } })
            add(app.streamsetu.tv.ui.components.TitleAction(if (isLater) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, "Watch Later", isLater, "Watch Later, " + if (isLater) "on" else "off", "action-later") { scope.launch { c.user.setFavourite(s.id, ContentKind.SERIES, !isLater, UserRepository.WATCH_LATER) } })
            tmdb.trailerKey?.let { k -> add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Movie, "Trailer", tag = "action-trailer") { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }) }
            add(app.streamsetu.tv.ui.components.TitleAction(Icons.Filled.Share, "Share", tag = "action-share") { app.streamsetu.tv.ui.phone.shareTitle(c.context, "series", s.title) })
        },
        synopsis = s.plot ?: tmdb.plot, genres = emptyList(), onMenu = { menuOpen = true })
    val rows = app.streamsetu.core.data.repo.TitlePageText.details(null, tmdb.cast.take(6).joinToString(", ") { it.name }, null, null, s.year?.toString(), s.categoryId != null)
    val pad = Modifier.padding(horizontal = Tokens.safeHorizontal)
    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        LazyColumn(Modifier.fillMaxSize(), state = rememberLazyListState(), contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            item(key = "hero") { app.streamsetu.tv.ui.components.TitleHero(true, top, inset = Tokens.safeHorizontal) }
            item(key = "top") { app.streamsetu.tv.ui.components.TitleBody(true, top, pad.widthIn(max = 720.dp)) }
            // Episodes come right after the actions, synopsis and genres: the season picker opens the list of that season.
            item(key = "episodesHead") {
                Column(pad, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SectionTitle("Episodes")
                    if (episodes.isNotEmpty()) StatusChip(if (plan.allFinished) "All watched" else "$watchedCount of ${episodes.size} watched", if (plan.allFinished) Tokens.success else Tokens.textSecondary)
                    if (plan.gapBefore && forward != null) Label("Episode ${forward.number - 1} is not available. The next one on offer is episode ${forward.number}.", Tokens.small, Tokens.warning, maxLines = 2)
                    if (loading && episodes.isEmpty()) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { app.streamsetu.tv.ui.components.BrandLoader(size = 30.dp); Label("Loading episodes…", Tokens.body, Tokens.textSecondary) }
                    error?.let { e -> if (episodes.isEmpty()) Label(e, Tokens.body, Tokens.danger, maxLines = 2) }
                }
            }
            if (seasons.isNotEmpty()) item(key = "seasons") {
                // Entering the seasons from the actions above or the episodes below always lands on the open season (not on whichever chip is nearest).
                LazyRow(pad.bleedStart(14.dp).focusProperties { enter = { activeSeasonChip } }, horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 6.dp, bottom = 6.dp)) {
                    items(seasons.keys.toList(), key = { it }) { n ->
                        Focusable({ season = n; episodesOpen = true }, if (n == season) Modifier.focusRequester(activeSeasonChip) else Modifier, shape = RoundedCornerShape(50), container = if (n == season) Tokens.accent.copy(alpha = 0.35f) else Color(0x26FFFFFF), focusedContainer = Color.White, scaleOnFocus = 1.0f, showRing = false, ringBand = false, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE) { f ->
                            // The same as the hero buttons: soft at rest, the open season tinted with the accent, and solid white with dark text where the remote is, so it is never in doubt which pill will open.
                            Label("Season $n", Tokens.caption, if (f) Tokens.onBright else Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 13.dp, vertical = 4.dp))
                        }
                    }
                }
            }
            if (rows.isNotEmpty()) item(key = "details") {
                Box(pad.widthIn(max = 720.dp)) { app.streamsetu.tv.ui.components.DetailsList(rows, true, { n -> nav.open(Overlay.Person(n, null, null, series0.title, series0.year)) }, if (s.categoryId != null) { { FolderPath(c, ContentKind.SERIES, s.categoryId, phone = false) { id -> nav.close(); nav.openFolderTab(ContentKind.SERIES, id) } } } else null) }
            }
            if (cast.isEmpty() && tmdbState.problem != null) item(key = "cast-problem") { app.streamsetu.tv.ui.components.TmdbProblemLine(tmdbState, tv = true) }
            if (cast.isNotEmpty()) item(key = "cast") { Column(pad, verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionTitle("Cast"); app.streamsetu.tv.ui.components.CastRow(cast, true) { m -> nav.open(Overlay.Person(m.name, m.photo, m.id, series0.title, series0.year)) } } }
            if (versionRows.size > 1) item(key = "versions") { Box(pad) { app.streamsetu.tv.ui.components.TvOtherLanguages(otherLanguages, { it.posterUrl }) { sr -> nav.close(); nav.open(Overlay.SeriesDetail(sr)) } } }
            tmdb.trailerKey?.let { k -> item(key = "extras") { Column(pad, verticalArrangement = Arrangement.spacedBy(8.dp)) { SectionTitle("Trailers & extras"); TvButton("Official trailer", { app.streamsetu.tv.ui.components.openTrailer(c.context, k) }, Modifier.testTag("extras-trailer"), icon = Icons.Filled.Movie) } } }
            if (!similarLoaded) item(key = "similarSkeleton") { Box(pad) { RelatedPlaceholders() } }
            if (similar.isNotEmpty()) item(key = "similar") {
                Column(pad) {
                    SectionTitle("More like this")
                    val firstSimilar = remember { FocusRequester() }
                    LazyRow(Modifier.bleedStart(24.dp).focusRestorer { firstSimilar }, horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(start = 32.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)) { itemsIndexed(similar, key = { _, r -> r.item.id }) { idx, r -> val m = r.item; PosterCard(m.title, m.posterUrl, { nav.close(); nav.open(Overlay.SeriesDetail(m)) }, itemId = m.id, subtitle = r.reason, width = 150.ui, focusRequester = if (idx == 0) firstSimilar else null) } }
                }
            }
        }
    }
    if (versionOpen) ContextMenu("Versions", null, versionRows.map { (v, m) -> MenuAction(v.label + if (v.current) "  (current)" else "", Icons.Filled.SwapHoriz, enabled = !v.current) { nav.close(); nav.open(Overlay.SeriesDetail(m)) } }, onClose = { versionOpen = false })
    if (menuOpen) ContextMenu(s.title, null, buildList {
        add(MenuAction("Watch privately", Icons.Filled.VisibilityOff) { c.appScope.launch { c.playSeries(s, privately = true); kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { if (nav.top != Overlay.Player) nav.open(Overlay.Player) } } })
        catchUp?.let { cu -> add(MenuAction("Catch Up S${cu.season} E${cu.number}", Icons.Filled.History) { playEp(cu) }) }
        if (episodes.isNotEmpty() && (ip != null || watchedCount > 0) && !plan.allFinished) add(MenuAction("Start from Beginning", Icons.Filled.Replay) { playEp(episodes.minWith(compareBy({ it.season }, { it.number }))) })
        add(MenuAction(if (inQueue) "Remove from queue" else "Add to queue", if (inQueue) Icons.Filled.Check else Icons.Filled.Add) { if (inQueue) c.watchQueue.remove(s.id) else c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(ContentKind.SERIES, s.id, s.title)) })
        if (variants.size > 1) add(MenuAction("Choose Source", Icons.Filled.SwapHoriz) { chooseOpen = true })
        add(MenuAction("Edit title and poster", Icons.Filled.Edit) { editing = true })
    }, onClose = { menuOpen = false })
    // A season opens its episodes in a panel from the right edge, over the page; the page does not move.
    if (episodesOpen) {
        val sheetEps = (season?.let { seasons[it] }).orEmpty().sortedBy { it.number }
        val reducedMotion = app.streamsetu.core.ui.motion.LocalReducedMotion.current
        var panelShown by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { panelShown = true }
        val panelIn by androidx.compose.animation.core.animateFloatAsState(if (panelShown) 1f else 0f, if (reducedMotion) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(220, easing = app.streamsetu.core.ui.motion.Motion.Standard), label = "episodesIn")
        val sheetFirst = remember { FocusRequester() }
        LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusSoon(if (restoreEpisodeId != null) episodeTarget else sheetFirst, 12) }
        app.streamsetu.tv.ui.components.TvDialog(onDismissRequest = { episodesOpen = false }, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize().drawBehind { drawRect(androidx.compose.ui.graphics.Brush.horizontalGradient(0.35f to Color.Transparent, 0.7f to Tokens.sheetScrimMidStrong, 1f to Tokens.background.copy(alpha = 0.95f)), alpha = panelIn) }, Alignment.CenterEnd) {
                Column(Modifier.fillMaxHeight().width(520.ui).graphicsLayer { alpha = panelIn; translationX = (1f - panelIn) * 60.dp.toPx() }.padding(end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Label("Season " + (season ?: ""), Tokens.pageTitle, Tokens.text, FontWeight.Bold)
                    Label("${sheetEps.size} episodes", Tokens.small, Tokens.textSecondary)
                    LazyColumn(Modifier.weight(1f).focusRestorer(), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 6.dp)) {
                        itemsIndexed(sheetEps, key = { _, e -> e.id }) { idx, e ->
                            val p = progress[e.id]
                            Focusable({ episodesOpen = false; playEp(e) }, Modifier.then(if (e.id == restoreEpisodeId) Modifier.focusRequester(episodeTarget) else if (idx == 0 && restoreEpisodeId == null) Modifier.focusRequester(sheetFirst) else Modifier).fillMaxWidth(), scaleOnFocus = 1.02f, hairline = true, onLongClick = { episodeMenu = e },
                                onFocus = { if (it) nav.seriesView[s.id] = season to e.id }) { f ->
                                Row(Modifier.padding(8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Box(Modifier.width(150.ui).aspectRatio(16f / 9f).clip(RoundedCornerShape(Tokens.radiusSmall)).background(Tokens.elevated)) {
                            if (!e.imageUrl.isNullOrBlank()) AsyncImage(e.imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Label("E${e.number}", Tokens.title, Tokens.textTertiary, modifier = Modifier.align(Alignment.Center))
                            // NEW is an episode that arrived after the series was read and has not been started.
                            if (e.id in newIds && p == null) Label("NEW", Tokens.caption, Tokens.onBright, FontWeight.Bold, modifier = Modifier.align(Alignment.TopStart).padding(4.dp).background(Tokens.accent, RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 1.dp))
                            if (p != null && !p.completed && p.fraction > 0) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Tokens.progressTrack)) { Box(Modifier.fillMaxWidth(p.fraction).fillMaxHeight().background(Tokens.accent)) }
                        }
                                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Label("${e.number}. ${e.title}", Tokens.small, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                                        Label(listOfNotNull(e.durationSec?.takeIf { it > 0 }?.let { "${it / 60} min" }, if (p?.completed == true) "Watched" else if (p != null && p.fraction > 0) "${minutes(p.durationMs - p.positionMs)}m left" else null).joinToString("  ·  "), Tokens.caption, if (p?.completed == true) Tokens.success else Tokens.textSecondary)
                                        if (f) e.plot?.takeIf { it.isNotBlank() }?.let { Label(it, Tokens.caption, Tokens.textSecondary, maxLines = 2) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    episodeMenu?.let { ep -> app.streamsetu.tv.ui.screens.home.HomeMenuHost(app.streamsetu.tv.ui.screens.home.HomeTarget.Episode(s, EpisodePlayable(ep, s)), app.streamsetu.tv.ui.screens.home.RowKind.EPISODES, homeVm, c, nav) { episodeMenu = null } }
    if (editing) OverrideDialog(s.title, overrides[series0.id]?.posterUrl.orEmpty(), onSave = { t, p -> scope.launch { c.collections.setOverride(series0.id, t.takeIf { it != series0.title }, p) }; editing = false }, onReset = { scope.launch { c.collections.clearOverride(series0.id) }; editing = false }, onClose = { editing = false })
    if (chooseOpen) ContextMenu("Choose Source", "Opens that connection's copy of this series.", variants.map { v -> MenuAction(sourceName(v.sourceId) + if (v.id == s.id) "  (current)" else "", Icons.Filled.SwapHoriz, enabled = v.id != s.id) { nav.close(); nav.open(Overlay.SeriesDetail(v)) } }, onClose = { chooseOpen = false })
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

