package app.streamsetu.tv.ui.screens.home

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

/**
 * Home: a compact header, the featured slideshow (about 40 % of the height, real titles), four shortcuts, then rows. A row with nothing in it is not drawn, and the person
 * can hide rows and reorder them (Settings, Favorites & History). Every card has the same long-press menu ([HomeMenuHost]).
 */
@Composable
fun HomeScreen(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val libraryName by vm.libraryName.collectAsState()
    val libraryOk by vm.libraryOk.collectAsState()
    val banner by vm.banner.collectAsState()
    val resume by vm.continueWatching.collectAsState()
    val live by vm.recentLive.collectAsState()
    val tonight by vm.tonight.collectAsState()
    val favs by vm.favourites.collectAsState()
    val later by vm.watchLater.collectAsState()
    val recent by vm.recentWatched.collectAsState()
    val forYou by vm.forYou.collectAsState()
    val moreWith by vm.moreWith.collectAsState()
    val laterIds by vm.watchLaterIds.collectAsState()
    val favIds by vm.favouriteIds.collectAsState()
    val movies by vm.recentMovies.collectAsState()
    val series by vm.recentSeries.collectAsState()
    val cats by vm.categories.collectAsState()
    val cols by vm.collections.collectAsState()
    val hidden by vm.hiddenRows.collectAsState()
    val bannerOn by c.ui.bannerEnabled.collectAsState()
    val entry = LocalContentEntry.current
    val pad = PaddingValues(horizontal = Tokens.safeHorizontal, vertical = 6.dp)
    val listState = rememberLazyListState()

    var menuTarget by remember { mutableStateOf<HomeTarget?>(null) }
    var menuRow by remember { mutableStateOf(RowKind.OTHER) }
    var catMenu by remember { mutableStateOf<Cat?>(null) }
    var shortcutMenu by remember { mutableStateOf<String?>(null) }
    fun longOn(t: HomeTarget, r: RowKind) { menuTarget = t; menuRow = r }
    val order = remember(hidden, favs, later) { vm.order }
    // Pause the slideshow while any menu is open.
    val menuOpen = menuTarget != null || catMenu != null || shortcutMenu != null

    // The first thing on Home is the hero (about 60 % of the screen's height). Until the person presses a key, the remote belongs to its Play button: it is taken as soon as the
    // hero exists, so nothing that loaded sooner (a shortcut, a row) can start the screen with the remote somewhere below.
    var interacted by remember { mutableStateOf(false) }
    val heroReady = bannerOn && banner.isNotEmpty()
    LaunchedEffect(heroReady) { if (heroReady && !interacted && entry != null) { kotlinx.coroutines.delay(200); if (!interacted) { runCatching { entry.requestFocus() }; repeat(3) { kotlinx.coroutines.delay(350); if (!interacted) listState.scrollToItem(0) } } } }
    androidx.compose.runtime.CompositionLocalProvider(LocalFocusRing provides Color.Unspecified) {
      BoxWithConstraints(Modifier.fillMaxSize()) {
        val heroHeight = maxHeight * 0.6f
        LazyColumn(Modifier.fillMaxSize().onPreviewKeyEvent { interacted = true; false }, state = listState, contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!heroReady) item(key = "header") { HomeHeader(libraryName, libraryOk, c, nav) }
            item(key = "offline") { TvOfflineAndNow(c, nav) }
            if (bannerOn && banner.isNotEmpty()) item(key = "banner") {
                FeaturedBanner(
                    banner, heroHeight, primaryEntry = entry, startPadding = Tokens.safeHorizontal, topOverlay = { Box(Modifier.align(Alignment.TopStart)) { HomeHeader(libraryName, libraryOk, c, nav) } }, intervalSeconds = c.ui.bannerSeconds.collectAsState().value, paused = menuOpen,
                    onPrimary = { b -> vm.playableFor(b.id)?.let { p -> if (p is SeriesFeature) nav.open(Overlay.SeriesDetail(p.series)) else play(c, nav, p) } },
                    onDetails = { b -> when (val p = vm.playableFor(b.id)) { is SeriesFeature -> nav.open(Overlay.SeriesDetail(p.series)); is MoviePlayable -> nav.open(Overlay.MovieDetail(p.movie)); else -> {} } },
                    isListed = { b -> b.id in laterIds }, onToggleListed = { b -> vm.toggleWatchLater(b.id, if (vm.playableFor(b.id) is SeriesFeature) ContentKind.SERIES else ContentKind.MOVIE) },
                    isFavorite = { b -> b.id in favIds }, onToggleFavorite = { b -> vm.setFavorite(b.id, if (vm.playableFor(b.id) is SeriesFeature) ContentKind.SERIES else ContentKind.MOVIE, b.id !in favIds) },
                )
            }
            item(key = "quick") {
                Row(Modifier.railOnLeft().padding(horizontal = Tokens.safeHorizontal, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    vm.shortcutOrder.forEach { id ->
                        val (label, icon, n) = when (id) {
                            "favorites" -> Triple("Favorites", Icons.Filled.Favorite, favs.size)
                            "later" -> Triple("Watch Later", Icons.Filled.Bookmark, later.size)
                            "recent" -> Triple("Recently Watched", Icons.Filled.History, recent.size)
                            else -> Triple("Continue Watching", Icons.Filled.PlayArrow, resume.size)
                        }
                        QuickCard(label, icon, n, { nav.open(Overlay.Collection(id)) }, { shortcutMenu = id }, if (id == vm.shortcutOrder.first() && !bannerOn && entry != null) Modifier.focusRequester(entry) else Modifier)
                    }
                }
            }
            if (tonight.isNotEmpty()) rail("Tonight on your channels", pad) { items(tonight, key = { "t" + it.channel.id }) { l ->
                ChannelCard(l.channel, l.now, { play(c, nav, ChannelPlayable(l.channel), tonight.map { ChannelPlayable(it.channel) }) }, { longOn(HomeTarget.Live(l.channel), RowKind.RECENT_LIVE) })
            } }
            order.forEach { id ->
                when (id) {
                    "continue" -> if (resume.isNotEmpty()) rail("Continue Watching", pad) { items(resume, key = { "c" + it.playable.id }) { r ->
                        val t: HomeTarget? = when (val p = r.playable) { is MoviePlayable -> HomeTarget.Film(p.movie); is EpisodePlayable -> HomeTarget.Episode(p.series, p); else -> null }
                        LandscapeCard(r.playable.title, r.subtitle, r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = if (r.isNew) 0f else r.progress.fraction, badge = if (r.isNew) "NEW" else null, onLongClick = t?.let { { longOn(it, RowKind.CONTINUE) } })
                    } }
                    "live" -> if (live.isNotEmpty()) rail("Recently Watched Live TV", pad) { items(live, key = { "l" + it.channel.id }) { l ->
                        ChannelCard(l.channel, l.now, { play(c, nav, ChannelPlayable(l.channel), live.map { ChannelPlayable(it.channel) }) }, { longOn(HomeTarget.Live(l.channel), RowKind.RECENT_LIVE) })
                    } }
                    "favorites" -> {
                        val favChannels = favs.filterIsInstance<FavItem.Ch>(); val favTitles = favs.filter { it !is FavItem.Ch }
                        if (favChannels.isNotEmpty()) rail("Favorite Channels", pad) { items(favChannels, key = { "fc" + it.id }) { f -> FavCard(f, c, nav, RowKind.FAVORITES, ::longOn) } }
                        if (favTitles.isNotEmpty()) rail("Favorites", pad) { items(favTitles, key = { "f" + it.id }) { f -> FavCard(f, c, nav, RowKind.FAVORITES, ::longOn) } }
                    }
                    "later" -> if (later.isNotEmpty()) rail("Watch Later", pad) { items(later, key = { "w" + it.id }) { f -> FavCard(f, c, nav, RowKind.WATCH_LATER, ::longOn) } }
                    "foryou" -> { forYou?.let { fy -> rail("For You  ·  Because you watched ${fy.because}", pad) { items(fy.items, key = { "y" + it.id }) { f -> FavCard(f, c, nav, RowKind.OTHER, ::longOn) } } }
                        moreWith?.let { mw -> rail("More with ${mw.name}  ·  You watched ${mw.titles} of their titles lately", pad) { items(mw.items, key = { "w" + it.id }) { f -> FavCard(f, c, nav, RowKind.OTHER, ::longOn) } } } }
                    "movies" -> if (movies.isNotEmpty()) rail("Recently Added Movies", pad) { items(movies, key = { "m" + it.id }) { m ->
                        PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, itemId = m.id, subtitle = m.year?.toString(), badge = if (m.id in favIds) "♥" else ratingBadge(m.rating), onLongClick = { longOn(HomeTarget.Film(m), RowKind.OTHER) })
                    } }
                    "series" -> if (series.isNotEmpty()) rail("Recently Added Series", pad) { items(series, key = { "s" + it.id }) { s ->
                        PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, itemId = s.id, subtitle = s.year?.toString(), badge = if (s.id in favIds) "♥" else ratingBadge(s.rating), onLongClick = { longOn(HomeTarget.Show(s), RowKind.OTHER) })
                    } }
                    "categories" -> if (cols.isNotEmpty() || cats.isNotEmpty()) rail("Folders & Collections", pad) {
                        items(collectionCategories(nav, cols), key = { "x" + it.key }) { t -> CategoryCard(t.title, t.subtitle, t.icon, { t.open() }, { catMenu = t }) }
                        items(cats, key = { "k${it.kind}${it.folder.id}" }) { t -> CategoryCard(t.folder.title, (if (t.kind == ContentKind.MOVIE) "Movies" else "Series") + "  ·  %,d".format(t.folder.count), Icons.Filled.Folder, { nav.openFolderTab(t.kind, t.folder.id) }, { catMenu = Cat("f${t.kind}${t.folder.id}", t.folder.title, "", Icons.Filled.Folder, { nav.openFolderTab(t.kind, t.folder.id) }, t) }) }
                    }
                }
            }
            if (banner.isEmpty() && resume.isEmpty() && live.isEmpty() && favs.isEmpty() && movies.isEmpty() && series.isEmpty()) item(key = "empty") {
                Box(Modifier.fillMaxWidth().height(260.dp), Alignment.Center) { Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Label("Nothing to show yet", Tokens.title, Tokens.text, FontWeight.SemiBold)
                    Label("This library has no content on this device yet. Refresh it or add a connection.", Tokens.body, Tokens.textSecondary)
                    TvButton("Manage libraries", { c.library.close(); nav.toChooser() }, icon = Icons.Filled.Layers, primary = true)
                } }
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

private data class Cat(val key: String, val title: String, val subtitle: String, val icon: ImageVector, val open: () -> Unit, val folder: CategoryTile? = null)

private fun collectionCategories(nav: Navigator, cols: List<UserCollection>): List<Cat> = cols.map { col -> Cat("col${col.id}", col.name, "Your collection", Icons.Filled.CollectionsBookmark, { nav.openCollection(col.scope, col.id) }) }

private fun LazyListScope.rail(title: String, pad: PaddingValues, content: LazyListScope.() -> Unit) {
    item(key = "rail:$title") {
        Column(Modifier.animateItem()) {
            Row(Modifier.padding(start = Tokens.safeHorizontal, top = 10.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold)
            }
            LazyRow(Modifier.railOnLeft(), horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = pad, content = content)
        }
    }
}

/**
 * The top controls of Home: the library you are in (OK opens a compact switcher), Search, Settings and the clock. Switching library reloads Home in place; it does not go back
 * to the start screen.
 */
@Composable
private fun HomeHeader(library: String, ok: Boolean, c: AppContainer, nav: Navigator) {
    val now by produceState(System.currentTimeMillis()) { while (true) { value = System.currentTimeMillis(); delay(15_000) } }
    Row(Modifier.fillMaxWidth().railOnLeft().padding(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        LibrarySwitcher(library, c, nav)
        if (!ok) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) { Box(Modifier.size(7.dp).background(Tokens.warning, CircleShape)); Label("Offline: showing what is saved", Tokens.small, Tokens.warning) }
        Spacer(Modifier.weight(1f))
        TopIcon(Icons.Filled.Search, "Search") { nav.go(Tab.SEARCH) }
        TopIcon(Icons.Filled.Settings, "Settings") { nav.go(Tab.SETTINGS) }
        Label(java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault()).format(java.util.Date(now)), Tokens.row, Tokens.textSecondary, FontWeight.Medium, modifier = Modifier.padding(start = 8.dp))
    }
}

@Composable
private fun TopIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    Focusable(onClick, Modifier.size(40.dp).testTag("top-$label"), shape = RoundedCornerShape(Tokens.radius), container = Tokens.elevated, scaleOnFocus = 1.06f) { f ->
        Box(Modifier.fillMaxSize(), Alignment.Center) { Image(icon, label, Modifier.size(20.dp), colorFilter = ColorFilter.tint(if (f) Color.White else Tokens.textSecondary)) }
    }
}

@Composable
private fun QuickCard(label: String, icon: ImageVector, count: Int, onClick: () -> Unit, onLong: () -> Unit, extra: Modifier = Modifier) {
    Focusable(onClick, extra, shape = RoundedCornerShape(Tokens.radius), container = Color.Transparent, scaleOnFocus = 1.04f, onLongClick = onLong) { f ->
        Row(Modifier.padding(horizontal = 14.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Image(icon, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(if (f) Color.White else Tokens.textSecondary))
            Label(label, Tokens.row, if (f) Color.White else Tokens.text, FontWeight.Medium, maxLines = 1)
            if (count > 0) Label("%,d".format(count), Tokens.caption, Tokens.textTertiary)
        }
    }
}

@Composable
fun ChannelCard(ch: Channel, now: String?, onClick: () -> Unit, onLong: (() -> Unit)? = null) {
    Focusable(onClick, Modifier.width(172.dp), scaleOnFocus = 1.03f, onLongClick = onLong) { _ ->
        Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChannelLogo(ch.logoUrl, ch.name, 36.dp)
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

@Composable
private fun CategoryCard(title: String, subtitle: String, icon: ImageVector, onClick: () -> Unit, onLong: () -> Unit) {
    Focusable(onClick, Modifier.width(168.dp).height(76.dp), scaleOnFocus = 1.03f, onLongClick = onLong) { f ->
        Row(Modifier.fillMaxSize().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Image(icon, null, Modifier.size(22.dp), colorFilter = ColorFilter.tint(if (f) Tokens.goldHighlight else Tokens.gold))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically)) {
                Label(title, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                if (subtitle.isNotBlank()) Label(subtitle, Tokens.caption, Tokens.textTertiary, maxLines = 1)
            }
        }
    }
}

/** When there is no connection, the saved downloads that still play; and what the other devices are playing, with a button to carry on here. */
@Composable
private fun TvOfflineAndNow(c: AppContainer, nav: Navigator) {
    val online by c.online.collectAsState()
    val saved by c.downloads.items.collectAsState()
    val all by c.nowBoard.entries.collectAsState()
    var tick by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); tick = System.currentTimeMillis() } }
    val others = remember(all, tick) { c.nowBoard.current(tick) }
    val done = saved.filter { it.state == app.streamsetu.core.data.repo.SaveState.DONE }
    androidx.compose.animation.AnimatedVisibility(!online || others.isNotEmpty()) {
        Column(Modifier.padding(horizontal = Tokens.safeHorizontal, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!online) {
                Label("You're offline", Tokens.row, Tokens.warning, FontWeight.SemiBold)
                if (done.isEmpty()) Label("Nothing is saved for offline viewing yet.", Tokens.caption, Tokens.textSecondary)
                else LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(done, key = { "o" + it.itemId }) { t -> Focusable({ app.streamsetu.tv.playSaved(c, nav, t) }, shape = CircleShape, container = Color(0x1AFFFFFF), hairline = true) { Label(t.title, Tokens.row, Tokens.text, modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp)) } }
                }
            }
            if (online) others.forEach { e ->
                Focusable({ c.takeOver(e, nav) }, shape = CircleShape, container = Color(0x1AFFFFFF), hairline = true) {
                    Label("Playing on ${e.deviceName}: ${e.title}  ·  Play here", Tokens.row, Tokens.text, modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp))
                }
            }
        }
    }
}
