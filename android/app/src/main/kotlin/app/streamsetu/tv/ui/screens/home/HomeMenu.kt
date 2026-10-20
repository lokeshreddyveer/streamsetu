package app.streamsetu.tv.ui.screens.home

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.vector.ImageVector
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.ContextMenu
import app.streamsetu.tv.ui.components.MenuAction
import kotlinx.coroutines.launch

/** The title (or channel) a long press was on, as a typed identity. */
sealed interface HomeTarget {
    val kind: TargetKind
    data class Film(val movie: Movie) : HomeTarget { override val kind get() = TargetKind.MOVIE }
    data class Show(val series: Series) : HomeTarget { override val kind get() = TargetKind.SERIES }
    data class Episode(val series: Series, val episode: Playable) : HomeTarget { override val kind get() = TargetKind.EPISODE }
    data class Live(val channel: Channel) : HomeTarget { override val kind get() = TargetKind.CHANNEL }
}

/** Which row the card is in, so the menu can offer "remove from this row". */
enum class RowKind { CONTINUE, RECENT_LIVE, FAVORITES, WATCH_LATER, EPISODES, OTHER }

/**
 * One long-press menu for every row on Home. What it offers comes from [actionsFor]; what each choice does is here, in one place, using the same playback coordinator,
 * the same detail screens and the same lists as the rest of the app.
 */
@Composable
fun HomeMenuHost(target: HomeTarget?, row: RowKind, vm: HomeViewModel, c: AppContainer, nav: Navigator, extra: List<MenuAction> = emptyList(), onClose: () -> Unit) {
    if (target == null) return
    val scope = rememberCoroutineScope()
    val favs by vm.favouriteIds.collectAsState()
    val later by vm.watchLaterIds.collectAsState()
    val itemId = when (target) { is HomeTarget.Film -> target.movie.id; is HomeTarget.Show -> target.series.id; is HomeTarget.Episode -> (target.episode as? EpisodePlayable)?.episode?.id ?: target.series.id; is HomeTarget.Live -> target.channel.id }
    val favId = when (target) { is HomeTarget.Episode -> target.series.id; else -> itemId }
    var progress by remember(itemId) { mutableStateOf<WatchProgress?>(null) }
    var variants by remember(itemId) { mutableStateOf<List<Playable>>(emptyList()) }
    var guide by remember(itemId) { mutableStateOf(false) }
    val entries by c.library.entries.collectAsState(initial = emptyList())
    var chooser by remember { mutableStateOf(false) }
    var confirmSeries by remember { mutableStateOf<Boolean?>(null) }
    var nextEpisode by remember(itemId) { mutableStateOf<EpisodePlayable?>(null) }
    var seriesQueue by remember(itemId) { mutableStateOf<List<EpisodePlayable>>(emptyList()) }
    var seriesWatched by remember(itemId) { mutableStateOf(false) }
    var info by remember { mutableStateOf(false) }
    LaunchedEffect(itemId) {
        progress = vm.progressOf(itemId)
        when (target) {
            is HomeTarget.Film -> variants = vm.movieVariants(target.movie).map { MoviePlayable(it) }
            is HomeTarget.Show -> {
                variants = vm.seriesVariants(target.series).map { SeriesFeature(it) }
                val (q, next, done) = vm.seriesPlan(target.series); seriesQueue = q; nextEpisode = next; seriesWatched = done
            }
            is HomeTarget.Live -> guide = vm.hasGuide(target.channel)
            else -> {}
        }
    }
    val st = TargetState(
        kind = target.kind, inContinue = row == RowKind.CONTINUE, inRecentLive = row == RowKind.RECENT_LIVE,
        isFavorite = favId in favs, isWatchLater = favId in later,
        hasResumePoint = progress?.let { !it.completed && it.positionMs > 30_000 } == true, watched = progress?.completed == true,
        hasVariants = variants.size > 1, hasGuide = guide, hasFolder = target is HomeTarget.Live && target.channel.categoryId != null,
        fromEpisodeList = row == RowKind.EPISODES, hasNextEpisode = nextEpisode != null, seriesWatched = seriesWatched,
    )
    val contentKind = when (target) { is HomeTarget.Film -> ContentKind.MOVIE; is HomeTarget.Show, is HomeTarget.Episode -> ContentKind.SERIES; is HomeTarget.Live -> ContentKind.CHANNEL }
    val title = when (target) { is HomeTarget.Film -> target.movie.title; is HomeTarget.Show -> target.series.title; is HomeTarget.Episode -> target.episode.title; is HomeTarget.Live -> target.channel.name }

    fun label(a: HomeAction) = when (a) {
        HomeAction.PLAY -> "Play"; HomeAction.WATCH_PRIVATELY -> "Watch privately"; HomeAction.RESUME -> "Resume"; HomeAction.START_OVER -> "Start over"; HomeAction.DETAILS -> "View details"; HomeAction.OPEN_SERIES -> "Open series"
        HomeAction.CONTINUE_SERIES -> "Continue watching"; HomeAction.REMOVE_FROM_CONTINUE -> "Remove from Continue Watching"; HomeAction.MARK_WATCHED -> "Mark as watched"
        HomeAction.MARK_UNWATCHED -> "Mark as unwatched"; HomeAction.FAVORITE -> "Add to Favorites"; HomeAction.UNFAVORITE -> "Remove from Favorites"
        HomeAction.WATCH_LATER -> "Add to Watch Later"; HomeAction.REMOVE_WATCH_LATER -> "Remove from Watch Later"; HomeAction.CHOOSE_SOURCE -> "Choose source…"
        HomeAction.INFO -> "Information"; HomeAction.WATCH_CHANNEL -> "Watch channel"; HomeAction.OPEN_GUIDE -> "Open TV Guide"; HomeAction.OPEN_CHANNEL_FOLDER -> "Open channel folder"
        HomeAction.REMOVE_FROM_RECENT -> "Remove from Recently Watched"
        HomeAction.PLAY_NEXT_EPISODE -> "Play next episode"; HomeAction.MARK_SERIES_WATCHED -> "Mark series as watched…"; HomeAction.MARK_SERIES_UNWATCHED -> "Mark series as unwatched…"
    }
    fun icon(a: HomeAction): ImageVector = when (a) {
        HomeAction.PLAY, HomeAction.RESUME, HomeAction.WATCH_CHANNEL, HomeAction.CONTINUE_SERIES -> Icons.Filled.PlayArrow
        HomeAction.WATCH_PRIVATELY -> Icons.Filled.VisibilityOff
        HomeAction.START_OVER -> Icons.Filled.Replay; HomeAction.DETAILS, HomeAction.INFO -> Icons.Filled.Info; HomeAction.OPEN_SERIES -> Icons.Filled.VideoLibrary
        HomeAction.REMOVE_FROM_CONTINUE, HomeAction.REMOVE_FROM_RECENT, HomeAction.REMOVE_WATCH_LATER -> Icons.Filled.RemoveCircleOutline
        HomeAction.MARK_WATCHED, HomeAction.MARK_UNWATCHED -> Icons.Filled.Check; HomeAction.FAVORITE, HomeAction.UNFAVORITE -> Icons.Filled.Favorite
        HomeAction.PLAY_NEXT_EPISODE -> Icons.Filled.SkipNext; HomeAction.MARK_SERIES_WATCHED, HomeAction.MARK_SERIES_UNWATCHED -> Icons.Filled.Check
        HomeAction.WATCH_LATER -> Icons.Filled.Bookmark; HomeAction.CHOOSE_SOURCE -> Icons.Filled.SwapHoriz; HomeAction.OPEN_GUIDE -> Icons.Filled.CalendarMonth; HomeAction.OPEN_CHANNEL_FOLDER -> Icons.Filled.Folder
    }
    fun run(a: HomeAction) {
        when (a) {
            HomeAction.PLAY, HomeAction.RESUME -> when (target) { is HomeTarget.Film -> play(c, nav, MoviePlayable(target.movie)); is HomeTarget.Episode -> play(c, nav, target.episode); else -> {} }
            HomeAction.WATCH_PRIVATELY -> when (target) {
                is HomeTarget.Film -> c.playBestMovie(target.movie) { play(c, nav, it, privately = true) }
                is HomeTarget.Episode -> play(c, nav, target.episode, privately = true)
                is HomeTarget.Live -> play(c, nav, ChannelPlayable(target.channel), privately = true)
                is HomeTarget.Show -> nextEpisode?.let { play(c, nav, it, seriesQueue, privately = true) } ?: nav.open(Overlay.SeriesDetail(target.series))
            }
            HomeAction.START_OVER -> { val p: Playable? = when (target) { is HomeTarget.Film -> MoviePlayable(target.movie); is HomeTarget.Episode -> target.episode; else -> null }
                if (p != null) { scope.launch { c.user.clearResumePoint(p.id) }; c.play(p, listOf(p), startOver = true); if (nav.top != Overlay.Player) nav.open(Overlay.Player) } }
            HomeAction.DETAILS -> when (target) { is HomeTarget.Film -> nav.open(Overlay.MovieDetail(target.movie)); is HomeTarget.Episode -> nav.open(Overlay.SeriesDetail(target.series)); else -> {} }
            HomeAction.OPEN_SERIES, HomeAction.CONTINUE_SERIES -> (target as? HomeTarget.Show)?.let { nav.open(Overlay.SeriesDetail(it.series)) }
            HomeAction.REMOVE_FROM_CONTINUE -> vm.removeFromContinue(itemId)
            HomeAction.MARK_WATCHED -> vm.setWatched(itemId, if (target is HomeTarget.Episode) ContentKind.EPISODE else ContentKind.MOVIE, (target as? HomeTarget.Episode)?.series?.id, true)
            HomeAction.MARK_UNWATCHED -> vm.setWatched(itemId, if (target is HomeTarget.Episode) ContentKind.EPISODE else ContentKind.MOVIE, (target as? HomeTarget.Episode)?.series?.id, false)
            HomeAction.FAVORITE -> vm.setFavorite(favId, contentKind, true); HomeAction.UNFAVORITE -> vm.setFavorite(favId, contentKind, false)
            HomeAction.WATCH_LATER -> vm.setWatchLater(favId, contentKind, true); HomeAction.REMOVE_WATCH_LATER -> vm.setWatchLater(favId, contentKind, false)
            HomeAction.CHOOSE_SOURCE -> chooser = true
            HomeAction.INFO -> info = true
            HomeAction.WATCH_CHANNEL -> (target as? HomeTarget.Live)?.let { play(c, nav, ChannelPlayable(it.channel)) }
            HomeAction.OPEN_GUIDE -> nav.go(Tab.GUIDE)
            HomeAction.OPEN_CHANNEL_FOLDER -> (target as? HomeTarget.Live)?.channel?.categoryId?.let { nav.openFolderTab(ContentKind.CHANNEL, it) }
            HomeAction.REMOVE_FROM_RECENT -> vm.removeFromRecent(itemId)
            HomeAction.PLAY_NEXT_EPISODE -> nextEpisode?.let { play(c, nav, it, seriesQueue) }
            HomeAction.MARK_SERIES_WATCHED -> confirmSeries = true
            HomeAction.MARK_SERIES_UNWATCHED -> confirmSeries = false
        }
    }

    // The queue of titles to play one after another, and the person's own order of the favourites.
    val queued by c.watchQueue.items.collectAsState()
    val queueActions = if (target is HomeTarget.Film || target is HomeTarget.Show) {
        if (queued.any { it.id == favId }) listOf(MenuAction("Remove from queue", Icons.Filled.RemoveCircleOutline) { c.watchQueue.remove(favId) })
        else listOf(
            MenuAction("Play next", Icons.Filled.SkipNext) { c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(contentKind, favId, title), next = true) },
            MenuAction("Add to queue", Icons.Filled.Add) { c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(contentKind, favId, title)) })
    } else emptyList()
    val orderActions = if (favId in favs) listOf(
        MenuAction("Move to front of favorites", Icons.Filled.ArrowUpward) { vm.moveFavorite(favId, contentKind, true) },
        MenuAction("Move to end of favorites", Icons.Filled.ArrowDownward) { vm.moveFavorite(favId, contentKind, false) }) else emptyList()
    if (!chooser && !info && confirmSeries == null) ContextMenu(title, null, actionsFor(st).map { a -> MenuAction(label(a), icon(a)) { run(a) } } + queueActions + orderActions + extra, onClose = onClose)
    confirmSeries?.let { watched -> ContextMenu(if (watched) "Mark every episode watched?" else "Mark every episode unwatched?", "This changes all episodes of ${title}.", listOf(MenuAction(if (watched) "Mark all watched" else "Mark all unwatched", Icons.Filled.Check) { (target as? HomeTarget.Show)?.let { vm.setSeriesWatched(it.series, watched) } }, MenuAction("Cancel", Icons.Filled.Close) {}), onClose = { confirmSeries = null; onClose() }) }
    if (chooser) ContextMenu("Choose source", "Opens only this play. Your default is unchanged.", variants.map { v ->
        MenuAction((entries.firstOrNull { it.id == "src:${v.sourceId}" }?.name ?: "Connection") + if (v.id == itemId) "  (current)" else "", Icons.Filled.SwapHoriz) {
            when (v) { is MoviePlayable -> play(c, nav, v); is SeriesFeature -> nav.open(Overlay.SeriesDetail(v.series)); else -> {} }
        }
    }, onClose = { chooser = false; onClose() })
    if (info) {
        val lines = when (target) {
            is HomeTarget.Film -> listOfNotNull(target.movie.year?.toString(), target.movie.rating?.takeIf { it.isNotBlank() && it != "0" }?.let { "Rating $it" }, target.movie.plot)
            is HomeTarget.Show -> listOfNotNull(target.series.year?.toString(), target.series.rating?.takeIf { it.isNotBlank() && it != "0" }?.let { "Rating $it" }, target.series.plot)
            is HomeTarget.Episode -> listOfNotNull(target.series.title, target.episode.title)
            is HomeTarget.Live -> listOfNotNull(target.channel.number?.let { "Channel $it" }, if (guide) "Guide data available" else "No guide data")
        }
        ContextMenu(title, lines.joinToString("\n").ifBlank { "The provider sent no further details." }, listOf(MenuAction("Close", Icons.Filled.Close) {}), onClose = { info = false; onClose() })
    }
}
