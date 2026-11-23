package app.streamsetu.tv.ui.phone

import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.screens.home.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Opens the one shared menu for a title by its id (search results, the person screen, folder rows, related titles: every poster that has no menu of its own). */
val LocalTileMenu = compositionLocalOf<((String) -> Unit)?> { null }

/** One screen-reader action for a menu item: the same label the menu shows. */
class TileA11yAction(val label: String, val run: () -> Unit)

/** What TalkBack is offered on a poster: every item of its menu as an action of its own. [rev] changes when a list the labels depend on (favourites, watch later) changes. */
class TileActionSource(val revOf: () -> Int, val load: suspend (String) -> List<TileA11yAction>) {
    constructor(rev: Int, load: suspend (String) -> List<TileA11yAction>) : this({ rev }, load)
    /** Read only by a tile while a screen reader is on, so a favourite change does not recompose the posters of everyone else. */
    val rev: Int get() = revOf()
}
val LocalTileActions = compositionLocalOf<TileActionSource?> { null }

/** True while TalkBack (touch exploration) is on. Posters read their menu items for the screen reader only then, so nobody else pays for it. */
val LocalScreenReaderOn = compositionLocalOf { false }

/** One listener for the whole app (not one per poster): the screen-reader state as a value that follows the system setting. */
@Composable
fun rememberScreenReaderOn(): Boolean {
    val context = androidx.compose.ui.platform.LocalContext.current
    var on by remember { mutableStateOf(false) }
    DisposableEffect(context) {
        val am = context.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as? android.view.accessibility.AccessibilityManager
        if (am == null) { on = false; return@DisposableEffect onDispose { } }
        on = am.isEnabled && am.isTouchExplorationEnabled
        val l = android.view.accessibility.AccessibilityManager.TouchExplorationStateChangeListener { on = am.isEnabled && it }
        am.addTouchExplorationStateChangeListener(l)
        onDispose { am.removeTouchExplorationStateChangeListener(l) }
    }
    return on
}

/** The menu items of a title as screen-reader actions. Loaded only while a screen reader is on; empty (and free) otherwise. */
@Composable
fun rememberTileA11y(itemId: String?): List<Pair<String, () -> Unit>> {
    if (!LocalScreenReaderOn.current) return emptyList()
    val source = LocalTileActions.current
    var a11y by remember { mutableStateOf(emptyList<TileA11yAction>()) }
    val rev = source?.rev
    LaunchedEffect(itemId, rev) { a11y = if (itemId != null && source != null) runCatching { source.load(itemId) }.getOrDefault(emptyList()) else emptyList() }
    return a11y.map { it.label to it.run }
}

/** The state behind the phone's shared tile menu: which title is open, how an id becomes a title, and what each menu item does without opening the menu. */
class TileMenuState(val c: AppContainer, val nav: Navigator, val vm: HomeViewModel, val phone: Boolean = true) {
    var open by mutableStateOf<HomeTarget?>(null)
    private val cache = object : LinkedHashMap<String, HomeTarget?>(64, 0.75f, true) { override fun removeEldestEntry(e: MutableMap.MutableEntry<String, HomeTarget?>?) = size > 200 }

    suspend fun resolve(id: String): HomeTarget? {
        synchronized(cache) { if (cache.containsKey(id)) return cache[id] }
        return withContext(Dispatchers.IO) {
            val t: HomeTarget? = c.db.catalog().moviesByIds(listOf(id)).firstOrNull()?.let { HomeTarget.Film(it.toModel()) } ?: c.db.catalog().seriesByIds(listOf(id)).firstOrNull()?.let { HomeTarget.Show(it.toModel()) }
            synchronized(cache) { cache[id] = t }; t
        }
    }

    fun openMenu(id: String) { c.appScope.launchResolve(this, id) }

    /** The menu items of a title as screen-reader actions: the shared table, the same labels; an item that needs the menu's own questions (choose a source, information) opens the menu. */
    suspend fun actionsFor(id: String): List<TileA11yAction> {
        val target = resolve(id) ?: return emptyList()
        val categoryId = when (target) { is HomeTarget.Film -> target.movie.categoryId; is HomeTarget.Show -> target.series.categoryId; else -> null }
        val progress = runCatching { vm.progressOf(id) }.getOrNull()
        val st = TargetState(target.kind, isFavorite = id in vm.favouriteIds.value, isWatchLater = id in vm.watchLaterIds.value,
            hasResumePoint = progress?.let { !it.completed && it.positionMs > 30_000 } == true, watched = progress?.completed == true,
            hasFolder = categoryId != null, hasCast = c.tmdbAuth.available, canShare = phone, canDismiss = true)
        return actionsFor(st).map { a -> TileA11yAction(homeActionLabel(a)) { if (!runDirect(a, target)) open = target } }
    }

    private fun runDirect(a: HomeAction, t: HomeTarget): Boolean {
        val kind = if (t is HomeTarget.Film) ContentKind.MOVIE else ContentKind.SERIES
        val id = when (t) { is HomeTarget.Film -> t.movie.id; is HomeTarget.Show -> t.series.id; else -> return false }
        val cat = when (t) { is HomeTarget.Film -> t.movie.categoryId; is HomeTarget.Show -> t.series.categoryId; else -> null }
        val title = when (t) { is HomeTarget.Film -> t.movie.title; is HomeTarget.Show -> t.series.title; else -> "" }
        when (a) {
            HomeAction.PLAY, HomeAction.RESUME -> if (t is HomeTarget.Film) play(c, nav, MoviePlayable(t.movie)) else return false
            HomeAction.DETAILS, HomeAction.GO_TO_CAST, HomeAction.OPEN_SERIES -> nav.open(if (t is HomeTarget.Film) Overlay.MovieDetail(t.movie) else Overlay.SeriesDetail((t as HomeTarget.Show).series))
            HomeAction.OPEN_FOLDER -> cat?.let { nav.openFolderTab(kind, it) } ?: return false
            HomeAction.FAVORITE -> vm.setFavorite(id, kind, true); HomeAction.UNFAVORITE -> vm.setFavorite(id, kind, false)
            HomeAction.WATCH_LATER -> vm.setWatchLater(id, kind, true); HomeAction.REMOVE_WATCH_LATER -> vm.setWatchLater(id, kind, false)
            HomeAction.DONT_RECOMMEND -> vm.dontRecommend(t)          // marker only, with Undo (the bar below)
            HomeAction.SHARE -> shareTitle(c.context, if (kind == ContentKind.MOVIE) "movie" else "series", title)
            else -> return false
        }
        return true
    }
}

private fun kotlinx.coroutines.CoroutineScope.launchResolve(s: TileMenuState, id: String) { launch(Dispatchers.Main) { s.open = s.resolve(id) } }

/** Mounted once for the whole phone UI: it provides the menu and the screen-reader actions to every poster, and draws the menu and the Undo bar. */
@Composable
fun rememberTileMenu(c: AppContainer, nav: Navigator, phone: Boolean = true): TileMenuState {
    val vm: HomeViewModel = androidx.hilt.navigation.compose.hiltViewModel()
    return remember(c, nav, vm, phone) { TileMenuState(c, nav, vm, phone) }
}

@Composable
fun TileMenuHost(state: TileMenuState, modifier: Modifier = Modifier) {
    state.open?.let { t -> HomeMenuHost(t, RowKind.OTHER, state.vm, state.c, state.nav, phone = state.phone) { state.open = null } }
    ContinueUndoBar(state.vm, tv = !state.phone, modifier = modifier)
}
