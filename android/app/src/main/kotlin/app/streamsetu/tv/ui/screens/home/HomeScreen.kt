package app.streamsetu.tv.ui.screens.home

import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import app.streamsetu.tv.ui.theme.ui
import androidx.compose.ui.focus.focusRestorer
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.LibraryEntry
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.testTag
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.section.ratingBadge
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow

/**
 * Home: a compact header, the featured slideshow (about 40 % of the height, real titles), four shortcuts, then rows. A row with nothing in it is not drawn, and the person
 * can hide rows and reorder them (Settings, Favorites & History). Every card has the same long-press menu ([HomeMenuHost]).
 */
@Composable
fun HomeScreen(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    // The screen itself holds no row data. Each part collects only what it draws, and only the yes/no of "is there anything to show" is read here, so a favourite, a progress bar or a guide
    // change redraws the card (or at most its row), never the whole of Home.
    val bannerS = vm.banner.collectAsStateWithLifecycle()
    val bannerOn by c.ui.bannerEnabled.collectAsStateWithLifecycle()
    val hidden by vm.hiddenRows.collectAsStateWithLifecycle()
    val hasResume by vm.continueWatching.select { it.isNotEmpty() }
    val hasLive by vm.recentLive.select { it.isNotEmpty() }
    val hasTonight by vm.tonight.select { it.isNotEmpty() }
    val hasFavChannels by vm.favourites.select { l -> l.any { it is FavItem.Ch } }
    val hasFavTitles by vm.favourites.select { l -> l.any { it !is FavItem.Ch } }
    val hasLater by vm.watchLater.select { it.isNotEmpty() }
    val hasForYou by vm.forYou.select { it != null }
    val hasMoreWith by vm.moreWith.select { it != null }
    val hasMovies by vm.recentMovies.select { it.isNotEmpty() }
    val hasSeries by vm.recentSeries.select { it.isNotEmpty() }
    val hasCats by vm.categories.select { it.isNotEmpty() }
    val hasCols by vm.collections.select { it.isNotEmpty() }
    val entry = LocalContentEntry.current
    val pad = PaddingValues(horizontal = Tokens.safeHorizontal, vertical = 14.dp)          // room for a card to grow (1.06) and for its frame and glow
    val listState = rememberLazyListState()

    var menuTarget by remember { mutableStateOf<HomeTarget?>(null) }
    var menuRow by remember { mutableStateOf(RowKind.OTHER) }
    var catMenu by remember { mutableStateOf<Cat?>(null) }
    var shortcutMenu by remember { mutableStateOf<String?>(null) }
    val longOn: (HomeTarget, RowKind) -> Unit = remember { { t: HomeTarget, r: RowKind -> menuTarget = t; menuRow = r } }
    val order = remember(hidden) { vm.order }
    val restShown = true          // the lazy list composes the rows that are on screen; nothing is held back and inserted a frame later
    // Pause the slideshow while any menu is open.
    val menuOpen = menuTarget != null || catMenu != null || shortcutMenu != null
    // The slideshow also holds still while Home scrolls and while the banner is off screen. Asked when the slideshow is about to advance; nothing here is observed.
    val bannerPausedWhen = remember(listState) { { listState.isScrollInProgress } }

    // The first thing on Home is the hero (about 60 % of the screen's height). Until the person presses a key, the remote belongs to its Play button: it is taken as soon as the
    // hero exists, so nothing that loaded sooner (a shortcut, a row) can start the screen with the remote somewhere below.
    var interacted by remember { mutableStateOf(false) }
    // Only the yes/no is read here, so a change inside the banner list does not recompose the whole screen.
    val heroReady by remember { derivedStateOf { bannerOn && bannerS.value.isNotEmpty() } }
    // A library with nothing to feature must not hold the space for ever.
    var heroGaveUp by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { kotlinx.coroutines.delay(5000); heroGaveUp = true }
    LaunchedEffect(heroReady) { if (heroReady && !interacted && entry != null) { kotlinx.coroutines.delay(40); if (!interacted) { runCatching { entry.requestFocus() }; repeat(2) { kotlinx.coroutines.delay(250); if (!interacted) listState.scrollToItem(0) } } } }
    val nothingToShow by remember { derivedStateOf { bannerS.value.isEmpty() && !hasResume && !hasLive && !hasFavChannels && !hasFavTitles && !hasMovies && !hasSeries } }
    androidx.compose.runtime.CompositionLocalProvider(LocalFocusRing provides Color.Unspecified) {
      Box(Modifier.fillMaxSize()) {
        val heroHeight = 300.ui          // about half the screen, so the title and the top of the next row are always in view
        Column(Modifier.fillMaxSize()) {
        // The hero stays where it is; only the rows below it scroll.
            // While the banner is being picked, its space is held (the same height, a quiet tint with the three buttons as shapes) so the rows do not jump down when it arrives.
            val holdHero = bannerOn && !heroReady && !heroGaveUp
            if (!heroReady && !holdHero) HomeHeader(vm, c, nav)
            if (holdHero) {
                Box(Modifier.fillMaxWidth().height(heroHeight).background(Tokens.card.copy(alpha = 0.5f))) {
                    Box(Modifier.align(Alignment.TopStart)) { HomeHeader(vm, c, nav) }
                    Row(Modifier.align(Alignment.BottomStart).padding(start = Tokens.safeHorizontal, bottom = 30.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(112, 118, 140).forEach { w -> Box(Modifier.size(w.ui, 34.ui).background(Tokens.elevated.copy(alpha = 0.6f), RoundedCornerShape(50))) }
                    }
                }
            }
            if (heroReady) {
                val banner by bannerS
                val laterIds by vm.watchLaterIds.collectAsStateWithLifecycle()
                val favIds by vm.favouriteIds.collectAsStateWithLifecycle()
                FeaturedBanner(
                    banner, heroHeight, primaryEntry = entry, startPadding = Tokens.safeHorizontal, topOverlay = { Box(Modifier.align(Alignment.TopStart)) { HomeHeader(vm, c, nav) } }, intervalSeconds = c.ui.bannerSeconds.collectAsStateWithLifecycle().value, paused = menuOpen || nav.top != null || nav.sidebarMode != app.streamsetu.tv.nav.SidebarMode.HIDDEN,
                    pausedWhen = bannerPausedWhen,
                    modifier = Modifier.graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen },          // drawn once into a texture while the rows scroll underneath
                    onPrimary = { b -> vm.playableFor(b.id)?.let { p -> if (p is SeriesFeature) nav.open(Overlay.SeriesDetail(p.series)) else play(c, nav, p) } },
                    onDetails = { b -> when (val p = vm.playableFor(b.id)) { is SeriesFeature -> nav.open(Overlay.SeriesDetail(p.series)); is MoviePlayable -> nav.open(Overlay.MovieDetail(p.movie)); else -> {} } },
                    isListed = { b -> b.id in laterIds }, onToggleListed = { b -> vm.toggleWatchLater(b.id, if (vm.playableFor(b.id) is SeriesFeature) ContentKind.SERIES else ContentKind.MOVIE) },
                    isFavorite = { b -> b.id in favIds }, onToggleFavorite = { b -> vm.setFavorite(b.id, if (vm.playableFor(b.id) is SeriesFeature) ContentKind.SERIES else ContentKind.MOVIE, b.id !in favIds) },
                )
            }
        Box(Modifier.weight(1f).fillMaxWidth()) {
        LazyColumn(Modifier.fillMaxSize().onPreviewKeyEvent { interacted = true; false }, state = listState, contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item(key = "offline") { TvOfflineAndNow(c, nav) }
            item(key = "quick") { ShortcutRow(vm, c, nav, bannerOn, entry, onMenu = { shortcutMenu = it }) }
            if (hasTonight) railItem("Tonight on your channels") { TonightRail(vm, c, nav, pad, longOn) }
            // The hero and the first two rows are drawn at once; the others join on the next frame, so Home appears without waiting on every row.
            order.take(if (restShown) order.size else 2).forEach { id ->
                when (id) {
                    "continue" -> if (hasResume) railItem("Continue Watching") { ContinueRail(vm, c, nav, pad, longOn) }
                    "live" -> if (hasLive) railItem("Recently Watched Live TV") { RecentLiveRail(vm, c, nav, pad, longOn) }
                    "favorites" -> {
                        if (hasFavChannels) railItem("Favorite Channels") { FavouriteRail("Favorite Channels", vm.favourites, true, "fc", RowKind.FAVORITES, c, nav, pad, longOn) }
                        if (hasFavTitles) railItem("Favorites") { FavouriteRail("Favorites", vm.favourites, false, "f", RowKind.FAVORITES, c, nav, pad, longOn) }
                    }
                    "later" -> if (hasLater) railItem("Watch Later") { FavouriteRail("Watch Later", vm.watchLater, null, "w", RowKind.WATCH_LATER, c, nav, pad, longOn) }
                    "foryou" -> {
                        if (hasForYou) railItem("For You") { ForYouRail(vm, c, nav, pad, longOn) }
                        if (hasMoreWith) railItem("More with") { MoreWithRail(vm, c, nav, pad, longOn) }
                    }
                    "movies" -> if (hasMovies) railItem("Recently Added Movies") { MoviesRail(vm, nav, pad, longOn) }
                    "series" -> if (hasSeries) railItem("Recently Added Series") { SeriesRail(vm, nav, pad, longOn) }
                    "categories" -> if (hasCols || hasCats) railItem("Folders & Collections") { CategoriesRail(vm, nav, pad, onMenu = { catMenu = it }) }
                }
            }
            if (nothingToShow) item(key = "empty") {
                Box(Modifier.fillMaxWidth().height(260.dp), Alignment.Center) { Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Label("Nothing to show yet", Tokens.title, Tokens.text, FontWeight.SemiBold)
                    Label("This library has no content on this device yet. Refresh it or add a connection.", Tokens.body, Tokens.textSecondary)
                    TvButton("Manage libraries", { c.library.close(); nav.toChooser() }, icon = Icons.Filled.Layers, primary = true)
                } }
            }
        }
        Box(Modifier.align(Alignment.TopStart).fillMaxWidth().height(28.dp).background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Tokens.background, androidx.compose.ui.graphics.Color.Transparent))))
        }
        }
      }

        HomeMenuHost(menuTarget, menuRow, vm, c, nav) { menuTarget = null }
        catMenu?.let { t -> ContextMenu(t.title, t.subtitle.ifBlank { null }, buildList {
            add(MenuAction("Open", Icons.Filled.PlayArrow) { t.open() })
            t.folder?.let { f ->
                add(MenuAction(if (f.folder.pref.favorite) "Remove from favorite folders" else "Add to favorite folders", Icons.Filled.Star) { vm.toggleFolderFavorite(f) })
                add(MenuAction(if (f.folder.pref.pinned) "Unpin" else "Pin to the top", Icons.Filled.PushPin) { vm.toggleFolderPinned(f) })
                add(MenuAction("Hide this category", Icons.Filled.VisibilityOff) { vm.hideFolder(f) })
            }
        }, onClose = { catMenu = null }) }
        shortcutMenu?.let { id -> ContextMenu("Move this shortcut", "The order is kept.", listOf(MenuAction("Move left", Icons.Filled.ArrowBack) { vm.moveShortcut(id, -1); nav.contentFocusTick += 0 }, MenuAction("Move right", Icons.Filled.ArrowForward) { vm.moveShortcut(id, +1) }), onClose = { shortcutMenu = null }) }
    }
}

/** A value derived from a flow, read through the returned state only: the reader is redrawn when the derived value changes, not whenever the flow emits. */
@Composable
private fun <T, R> StateFlow<T>.select(transform: (T) -> R): State<R> {
    val source = collectAsStateWithLifecycle()
    return remember { derivedStateOf { transform(source.value) } }
}

/** Cards a Home row holds: a screenful and a modest buffer. The rest are one press away in the row's own screen. */
private const val RailMax = 12

private data class Cat(val key: String, val title: String, val subtitle: String, val icon: ImageVector, val open: () -> Unit, val folder: CategoryTile? = null)

private fun collectionCategories(nav: Navigator, cols: List<UserCollection>): List<Cat> = cols.map { col -> Cat("col${col.id}", col.name, "Your collection", Icons.Filled.CollectionsBookmark, { nav.openCollection(col.scope, col.id) }) }

/** One row of Home as one item of the page. The row is a composable of its own that collects its own list. */
private fun LazyListScope.railItem(title: String, content: @Composable () -> Unit) {
    item(key = "rail:$title", contentType = "rail") { content() }
}

@Composable
private fun RailFrame(title: String, pad: PaddingValues, reason: String? = null, content: LazyListScope.() -> Unit) {
    Column {
        // Each row remembers the card the remote was on (focusRestorer), so Up and Down return to it instead of whichever card is nearest.
        // A short heading, with why it is shown (if there is a reason) in smaller type beneath it.
        Column(Modifier.padding(start = Tokens.safeHorizontal, top = 10.dp, bottom = 4.dp)) {
            Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold)
            if (reason != null) Label(reason, Tokens.small, Tokens.textTertiary, maxLines = 1)
        }
        LazyRow(Modifier.railOnLeft().focusRestorer(), horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = pad, content = content)
    }
}

@Composable
private fun ShortcutRow(vm: HomeViewModel, c: AppContainer, nav: Navigator, bannerOn: Boolean, entry: androidx.compose.ui.focus.FocusRequester?, onMenu: (String) -> Unit) {
    val favCount by vm.favourites.select { it.size }
    val laterCount by vm.watchLater.select { it.size }
    val recentCount by vm.recentWatched.select { it.size }
    val resumeCount by vm.continueWatching.select { it.size }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    Row(Modifier.railOnLeft().horizontalScroll(rememberScrollState()).padding(horizontal = Tokens.safeHorizontal, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        // Straight back to the channel last watched.
        vm.shortcutOrder.forEach { id ->
            val (label, icon, n) = when (id) {
                "favorites" -> Triple("Favorites", Icons.Filled.Favorite, favCount)
                "later" -> Triple("Watch Later", Icons.Filled.Bookmark, laterCount)
                "recent" -> Triple("Recently Watched", Icons.Filled.History, recentCount)
                else -> Triple("Continue Watching", Icons.Filled.PlayArrow, resumeCount)
            }
            QuickCard(label, icon, n, { nav.open(Overlay.Collection(id)) }, { onMenu(id) }, if (id == vm.shortcutOrder.first() && !bannerOn && entry != null) Modifier.focusRequester(entry) else Modifier)
        }
    }
}

@Composable
private fun TonightRail(vm: HomeViewModel, c: AppContainer, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val all by vm.tonight.collectAsStateWithLifecycle()
    val cards = remember(all) { all.take(RailMax) }
    RailFrame("Tonight on your channels", pad) { items(cards, key = { "t" + it.channel.id }, contentType = { "card" }) { l -> LiveRailCard(l, { vm.tonight.value }, c, nav, longOn) } }
}

@Composable
private fun RecentLiveRail(vm: HomeViewModel, c: AppContainer, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val all by vm.recentLive.collectAsStateWithLifecycle()
    val cards = remember(all) { all.take(RailMax) }
    RailFrame("Recently Watched Live TV", pad) { items(cards, key = { "l" + it.channel.id }, contentType = { "card" }) { l -> LiveRailCard(l, { vm.recentLive.value }, c, nav, longOn) } }
}

@Composable
private fun LiveRailCard(l: LiveItem, playlist: () -> List<LiveItem>, c: AppContainer, nav: Navigator, longOn: (HomeTarget, RowKind) -> Unit) {
    ChannelCard(l.channel, l.now, { play(c, nav, ChannelPlayable(l.channel), playlist().map { ChannelPlayable(it.channel) }) }, { longOn(HomeTarget.Live(l.channel), RowKind.RECENT_LIVE) })
}

@Composable
private fun ContinueRail(vm: HomeViewModel, c: AppContainer, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val all by vm.continueWatching.collectAsStateWithLifecycle()
    val cards = remember(all) { all.take(RailMax) }
    RailFrame("Continue Watching", pad) { items(cards, key = { "c" + it.playable.id }, contentType = { "card" }) { r -> ContinueCard(r, c, nav, longOn) } }
}

/** The card redraws only when its own item changes (the view model hands back the same instance for a row that did not change). */
@Composable
private fun ContinueCard(r: ResumeItem, c: AppContainer, nav: Navigator, longOn: (HomeTarget, RowKind) -> Unit) {
    val t: HomeTarget? = when (val p = r.playable) { is MoviePlayable -> HomeTarget.Film(p.movie); is EpisodePlayable -> HomeTarget.Episode(p.series, p); else -> null }
    LandscapeCard(r.playable.title, r.subtitle, r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = if (r.isNew) 0f else r.progress.fraction, badge = if (r.isNew) "NEW" else null, onLongClick = t?.let { { longOn(it, RowKind.CONTINUE) } }, itemId = when (val p = r.playable) { is app.streamsetu.core.model.MoviePlayable -> p.movie.id; is EpisodePlayable -> p.series.id; else -> null })
}

/** Favourite channels (channels = true), favourite titles (false) or everything in the list (null), as one row. */
@Composable
private fun FavouriteRail(title: String, source: StateFlow<List<FavItem>>, channels: Boolean?, keyPrefix: String, row: RowKind, c: AppContainer, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val all by source.collectAsStateWithLifecycle()
    val cards = remember(all, channels) { all.filter { channels == null || (it is FavItem.Ch) == channels }.take(RailMax) }
    RailFrame(title, pad) { items(cards, key = { keyPrefix + it.id }, contentType = { "card" }) { f -> FavCard(f, c, nav, row, longOn) } }
}

@Composable
private fun ForYouRail(vm: HomeViewModel, c: AppContainer, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val fy by vm.forYou.collectAsStateWithLifecycle()
    val shown = fy ?: return
    val cards = remember(shown) { shown.items.take(RailMax) }
    RailFrame("For You", pad, reason = "Because you watched ${shown.because}") { items(cards, key = { "y" + it.id }, contentType = { "card" }) { f -> FavCard(f, c, nav, RowKind.OTHER, longOn) } }
}

@Composable
private fun MoreWithRail(vm: HomeViewModel, c: AppContainer, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val mw by vm.moreWith.collectAsStateWithLifecycle()
    val shown = mw ?: return
    val cards = remember(shown) { shown.items.take(RailMax) }
    RailFrame("More with ${shown.name}", pad, reason = "You watched ${shown.titles} of their titles lately") { items(cards, key = { "w" + it.id }, contentType = { "card" }) { f -> FavCard(f, c, nav, RowKind.OTHER, longOn) } }
}

@Composable
private fun MoviesRail(vm: HomeViewModel, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val all by vm.recentMovies.collectAsStateWithLifecycle()
    val cards = remember(all) { all.take(RailMax) }
    val favIds = vm.favouriteIds.collectAsStateWithLifecycle()
    RailFrame("Recently Added Movies", pad) { items(cards, key = { "m" + it.id }, contentType = { "card" }) { m ->
        val favourite by remember(m.id) { derivedStateOf { m.id in favIds.value } }          // a favourite changes the heart on that card alone
        PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, itemId = m.id, subtitle = m.year?.toString(), badge = if (favourite) "♥" else remember(m.rating) { ratingBadge(m.rating) }, onLongClick = { longOn(HomeTarget.Film(m), RowKind.OTHER) })
    } }
}

@Composable
private fun SeriesRail(vm: HomeViewModel, nav: Navigator, pad: PaddingValues, longOn: (HomeTarget, RowKind) -> Unit) {
    val all by vm.recentSeries.collectAsStateWithLifecycle()
    val cards = remember(all) { all.take(RailMax) }
    val favIds = vm.favouriteIds.collectAsStateWithLifecycle()
    RailFrame("Recently Added Series", pad) { items(cards, key = { "s" + it.id }, contentType = { "card" }) { s ->
        val favourite by remember(s.id) { derivedStateOf { s.id in favIds.value } }
        PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, itemId = s.id, subtitle = s.year?.toString(), badge = if (favourite) "♥" else remember(s.rating) { ratingBadge(s.rating) }, onLongClick = { longOn(HomeTarget.Show(s), RowKind.OTHER) })
    } }
}

@Composable
private fun CategoriesRail(vm: HomeViewModel, nav: Navigator, pad: PaddingValues, onMenu: (Cat) -> Unit) {
    val cols by vm.collections.collectAsStateWithLifecycle()
    val cats by vm.categories.collectAsStateWithLifecycle()
    val collectionCats = remember(cols) { collectionCategories(nav, cols) }
    val folderCats = remember(cats) { cats.take(RailMax) }
    RailFrame("Folders & Collections", pad) {
        items(collectionCats, key = { "x" + it.key }, contentType = { "card" }) { t -> CategoryCard(t.title, t.subtitle, t.icon, { t.open() }, { onMenu(t) }) }
        items(folderCats, key = { "k${it.kind}${it.folder.id}" }) { t -> CategoryCard(t.folder.title, (if (t.kind == ContentKind.MOVIE) "Movies" else "Series") + "  ·  %,d".format(t.folder.count), Icons.Filled.Folder, { nav.openFolderTab(t.kind, t.folder.id) }, { onMenu(Cat("f${t.kind}${t.folder.id}", t.folder.title, "", Icons.Filled.Folder, { nav.openFolderTab(t.kind, t.folder.id) }, t)) }) }
    }
}

@Composable
private fun HomeHeader(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val library by vm.libraryName.collectAsStateWithLifecycle()
    val ok by vm.libraryOk.collectAsStateWithLifecycle()
    HomeHeader(library, ok, c, nav)
}

/**
 * The top controls of Home: the library you are in (OK opens a compact switcher), Search, Settings and the clock. Switching library reloads Home in place; it does not go back
 * to the start screen.
 */
@Composable
private fun HomeHeader(library: String, ok: Boolean, c: AppContainer, nav: Navigator) {
    val now by rememberMinute()
    Row(Modifier.fillMaxWidth().railOnLeft().padding(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (!ok) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) { Box(Modifier.size(7.dp).background(Tokens.warning, CircleShape)); Label("Offline: showing what is saved", Tokens.small, Tokens.warning) }
        Spacer(Modifier.weight(1f))
        TopIcon(Icons.Filled.Search, "Search") { nav.go(Tab.SEARCH) }
        if (!app.streamsetu.tv.KidsLock.on) TopIcon(Icons.Filled.Settings, "Settings") { nav.go(Tab.SETTINGS) }
        Label(java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault()).format(java.util.Date(now)), Tokens.row, Tokens.textSecondary, FontWeight.Medium, modifier = Modifier.padding(start = 8.dp))
    }
}

@Composable
private fun TopIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    // The same small round button as the page toolbars and the hero actions.
    app.streamsetu.tv.ui.components.TvIconButton(icon, label, onClick, Modifier.testTag("top-$label"), plain = true)
}

@Composable
private fun QuickCard(label: String, icon: ImageVector, count: Int, onClick: () -> Unit, onLong: () -> Unit, extra: Modifier = Modifier) {
    // One line: the icon and the whole name side by side in a pill that is as wide as its name needs (nothing is cut off). It turns solid white with dark text when the remote is on it.
    Focusable(onClick, extra, shape = RoundedCornerShape(50), container = Color(0x26FFFFFF), focusedContainer = Color.White, scaleOnFocus = 1.0f, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE, ringBand = false, showRing = false, onLongClick = onLong) { f ->
        val ink = if (f) Color(0xFF101319) else Tokens.text
        Row(Modifier.padding(horizontal = 13.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, null, Modifier.size(13.dp), colorFilter = ColorFilter.tint(if (f) ink else Tokens.textSecondary))
            Label(label, Tokens.caption, ink, FontWeight.SemiBold, maxLines = 1)
        }
    }
}

@Composable
fun ChannelCard(ch: Channel, now: String?, onClick: () -> Unit, onLong: (() -> Unit)? = null) {
    Focusable(onClick, Modifier.width(220.ui), scaleOnFocus = 1.03f, onLongClick = onLong) { _ ->
        Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChannelLogo(ch.logoUrl, ch.name, 50.ui)
                Label(ch.name, Tokens.small, Tokens.text, FontWeight.SemiBold, maxLines = 2, modifier = Modifier.weight(1f))
            }
            Label(now ?: "Live", Tokens.caption, if (now != null) Tokens.textSecondary else Tokens.gold)
        }
    }
}

@Composable
internal fun FavCard(f: FavItem, c: AppContainer, nav: Navigator, row: RowKind, longOn: (HomeTarget, RowKind) -> Unit) {
    when (f) {
        is FavItem.Ch -> ChannelCard(f.channel, null, { play(c, nav, ChannelPlayable(f.channel)) }, { longOn(HomeTarget.Live(f.channel), row) })
        is FavItem.Mv -> PosterCard(f.movie.title, f.movie.posterUrl, { nav.open(Overlay.MovieDetail(f.movie)) }, itemId = f.movie.id, subtitle = f.movie.year?.toString(), badge = ratingBadge(f.movie.rating), onLongClick = { longOn(HomeTarget.Film(f.movie), row) })
        is FavItem.Sr -> PosterCard(f.series.title, f.series.posterUrl, { nav.open(Overlay.SeriesDetail(f.series)) }, itemId = f.series.id, subtitle = f.series.year?.toString(), badge = ratingBadge(f.series.rating), onLongClick = { longOn(HomeTarget.Show(f.series), row) })
    }
}

/** When there is no connection, the saved downloads that still play; and what the other devices are playing, with a button to carry on here. */
@Composable
private fun TvOfflineAndNow(c: AppContainer, nav: Navigator) {
    val online by c.online.collectAsStateWithLifecycle()
    val saved by c.downloads.items.collectAsStateWithLifecycle()
    val all by c.nowBoard.entries.collectAsStateWithLifecycle()
    val tick by rememberMinute()
    val others = remember(all, tick) { c.nowBoard.current(tick) }
    val done = saved.filter { it.state == app.streamsetu.core.data.repo.SaveState.DONE }
    androidx.compose.animation.AnimatedVisibility(!online || others.isNotEmpty()) {
        Column(Modifier.padding(horizontal = Tokens.safeHorizontal, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!online) {
                Label("You're offline", Tokens.row, Tokens.warning, FontWeight.SemiBold)
                if (done.isEmpty()) Label("Nothing is saved for offline viewing yet.", Tokens.caption, Tokens.textSecondary)
                else LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(done, key = { "o" + it.itemId }, contentType = { "card" }) { t -> Focusable({ app.streamsetu.tv.playSaved(c, nav, t) }, shape = CircleShape, container = Color(0x1AFFFFFF), hairline = false) { Label(t.title, Tokens.row, Tokens.text, modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp)) } }
                }
            }
            if (online) others.forEach { e ->
                Focusable({ c.takeOver(e, nav) }, shape = CircleShape, container = Color(0x1AFFFFFF), hairline = false) {
                    Label("Playing on ${e.deviceName}: ${e.title}  ·  Play here", Tokens.row, Tokens.text, modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp))
                }
            }
        }
    }
}
