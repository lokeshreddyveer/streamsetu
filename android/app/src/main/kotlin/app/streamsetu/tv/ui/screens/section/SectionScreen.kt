package app.streamsetu.tv.ui.screens.section

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.settings.PosterSize
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.search.SectionSearch
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import androidx.compose.ui.layout.ContentScale
import kotlinx.coroutines.delay

private fun shortcutOf(name: String, kind: ContentKind): Shortcut = when (name) {
    "favorites" -> Shortcut(Browse.Favorites, "Favorites", Icons.Filled.Favorite)
    "later" -> Shortcut(Browse.WatchLater, "Watch Later", Icons.Filled.Bookmark)
    "recent" -> Shortcut(Browse.Recent, "Recently Watched", Icons.Filled.History)
    else -> Shortcut(Browse.Continue, "Continue Watching", Icons.Filled.PlayArrow)
}

/**
 * Movies and Series. Left: the folder panel. Right: a header (title, count, source, Search / Filter / Sort / View), then one scrolling grid whose first rows are the
 * featured banner and the shortcut chips, followed by the posters. Posters open the fullscreen detail page; holding OK opens a menu.
 */
@Composable
fun SectionScreen(vm: SectionViewModel, c: AppContainer, nav: Navigator, onOpen: (Card) -> Unit) {
    val kind = vm.kind
    val noun = if (kind == ContentKind.MOVIE) "Movies" else "Series"
    val folders by vm.folders.collectAsState()
    val browse by vm.browse.collectAsState()
    val cards by vm.cards.collectAsState()
    val sort by vm.sort.collectAsState()
    val filter by vm.filter.collectAsState()
    val banner by vm.banner.collectAsState()
    val order by vm.shortcutOrder.collectAsState()
    val favs by vm.favourites.collectAsState()
    val later by vm.watchLater.collectAsState()
    val progress by vm.progress.collectAsState()
    val avail by vm.availability.collectAsState()
    val sources by vm.sources.collectAsState()
    val posterSize by c.ui.posterSize.collectAsState()
    val showMeta by c.ui.showPosterMeta.collectAsState()
    val bannerOn by c.ui.bannerEnabled.collectAsState()
    val showShortcuts by c.ui.showShortcuts.collectAsState()

    val entry = app.streamsetu.tv.ui.components.LocalContentEntry.current ?: remember { FocusRequester() }
    LaunchedEffect(Unit) { nav.pendingFolder?.takeIf { it.first == kind }?.let { vm.select(Browse.Folder(it.second)); nav.pendingFolder = null } }
    val gridState = rememberLazyGridState(vm.scrollIndex)
    LaunchedEffect(gridState) { snapshotFlow { gridState.firstVisibleItemIndex }.collect { vm.scrollIndex = it } }
    var sortOpen by remember { mutableStateOf(false) }
    var filterOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<Card?>(null) }
    var inContent by remember { mutableStateOf(false) }
    val panelEntry = entry

    val folderTitle = (browse as? Browse.Folder)?.let { b -> folders.firstOrNull { it.id == b.id }?.title }
    val title = when (browse) {
        Browse.All -> "All $noun"; Browse.Favorites -> "Favorites"; Browse.WatchLater -> "Watch Later"; Browse.Continue -> "Continue Watching"
        Browse.Recent -> "Recently Watched"; Browse.RecentlyAdded -> "Recently Added"; Browse.FavoriteFolders -> "Favorite Folders"; is Browse.Folder -> folderTitle ?: noun
    }
    val shortcuts = buildList {
        add(Shortcut(Browse.All, "All $noun", Icons.Filled.GridView))
        if (folders.any { it.pref.favorite }) add(Shortcut(Browse.FavoriteFolders, "Favorite Folders", Icons.Filled.Star))
        add(Shortcut(Browse.Favorites, "Favorites", Icons.Filled.Favorite)); add(Shortcut(Browse.WatchLater, "Watch Later", Icons.Filled.Bookmark))
        add(Shortcut(Browse.Continue, "Continue Watching", Icons.Filled.PlayArrow)); add(Shortcut(Browse.Recent, "Recently Watched", Icons.Filled.History))
        add(Shortcut(Browse.RecentlyAdded, "Recently Added", Icons.Filled.NewReleases))
    }

    // Back from the posters returns to the folders; back from the folders reveals the sidebar (handled by the shell).
    BackHandler(enabled = inContent) { runCatching { panelEntry.requestFocus() } }

    Row(Modifier.fillMaxSize()) {
        FolderPanel(noun, shortcuts, folders, browse, vm::select, vm, Modifier.width(Tokens.folderPanelWidth), entry = panelEntry)
        Column(Modifier.weight(1f).fillMaxHeight().onFocusChanged { inContent = it.hasFocus }) {
            // Header
            Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Label(title, Tokens.pageTitle, Tokens.text, FontWeight.Bold)
                    val n = cards?.size
                    Label((if (n == null) "Loading…" else "%,d ${if (kind == ContentKind.MOVIE) "movies" else "series"}".format(n)) + "  ·  " + (filter.sourceId?.let { id -> sources.firstOrNull { it.id == "src:$id" }?.name } ?: "All sources") + (if (!sort.isDefault) "  ·  Sort: ${sort.field.label}" else ""), Tokens.small, Tokens.textSecondary)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ToolButton("Search", Icons.Filled.Search) { searchOpen = true }
                    ToolButton(if (filter.active) "Filter •" else "Filter", Icons.Filled.FilterList) { filterOpen = true }
                    ToolButton("Sort", Icons.Filled.SwapVert) { sortOpen = true }
                    ToolButton("View", Icons.Filled.GridView) { c.ui.setPosterSize(PosterSize.entries[(posterSize.ordinal + 1) % PosterSize.entries.size]) }
                }
            }
            val list = cards
            LazyVerticalGrid(
                GridCells.Adaptive(posterSize.dp.dp), state = gridState, modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 18.dp, end = Tokens.safeHorizontal, top = 0.dp, bottom = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (bannerOn && banner.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }, key = "banner") {
                    FeaturedBanner(
                        banner, 190.dp,
                        onPrimary = { b -> list?.firstOrNull { it.id == b.id }?.let { onOpen(it) } },
                        onDetails = { b -> list?.firstOrNull { it.id == b.id }?.let { onOpen(it) } },
                        isListed = { b -> b.id in later }, onToggleListed = { b -> vm.toggle(b.id, UserRepository.WATCH_LATER) },
                        startPadding = 0.dp,
                        modifier = Modifier.padding(bottom = 4.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).clip(RoundedCornerShape(Tokens.radiusLarge)),
                    )
                }
                if (showShortcuts) item(span = { GridItemSpan(maxLineSpan) }, key = "shortcuts") {
                    Row(Modifier.padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        order.forEach { name ->
                            val s = shortcutOf(name, kind)
                            ShortcutChip(s.label, s.icon, browse == s.browse, onLong = null, onMoveLeft = { vm.moveShortcut(name, -1) }, onMoveRight = { vm.moveShortcut(name, +1) }) { vm.select(if (browse == s.browse) Browse.All else s.browse) }
                        }
                    }
                }
                when {
                    list == null -> items(18, key = { "sk$it" }) { SkeletonPoster() }
                    list.isEmpty() -> item(span = { GridItemSpan(maxLineSpan) }, key = "empty") {
                        Box(Modifier.fillMaxWidth().height(200.dp), Alignment.Center) { EmptyText(browse, noun, filter.active) }
                    }
                    else -> items(list, key = { it.id }) { card ->
                        val p = progress[card.id]
                        PosterCard(
                            card.title, card.posterUrl, { onOpen(card) }, width = posterSize.dp.dp,
                            progress = if (p != null && !p.completed) p.fraction else 0f,
                            subtitle = if (showMeta) card.year?.toString() else null,
                            badge = if (p?.completed == true) "✓" else ratingBadge(card.rating),
                            onLongClick = { menuFor = card },
                        )
                    }
                }
            }
        }
    }

    if (sortOpen) SortSheet(kind, sort, avail, onApply = vm::applySort, onClose = { sortOpen = false })
    if (filterOpen) FilterSheet(filter, sources, onApply = { vm.filter.value = it }, onClose = { filterOpen = false })
    if (searchOpen) SectionSearch(c, kind, onOpen = { card -> searchOpen = false; onOpen(card) }, onClose = { searchOpen = false })
    menuFor?.let { card ->
        val isFav = card.id in favs; val isLater = card.id in later; val p = progress[card.id]
        ContextMenu(card.title, null, buildList {
            add(MenuAction("Open", Icons.Filled.PlayArrow) { onOpen(card) })
            add(MenuAction(if (isFav) "Remove from Favorites" else "Add to Favorites", Icons.Filled.Favorite) { vm.toggle(card.id, UserRepository.FAVOURITES) })
            add(MenuAction(if (isLater) "Remove from Watch Later" else "Add to Watch Later", Icons.Filled.Bookmark) { vm.toggle(card.id, UserRepository.WATCH_LATER) })
            if (kind == ContentKind.MOVIE) add(MenuAction(if (p?.completed == true) "Mark as unwatched" else "Mark as watched", Icons.Filled.Check) { vm.setWatched(card, p?.completed != true) })
        }, onClose = { menuFor = null })
    }
}


fun ratingBadge(r: String?): String? = r?.toDoubleOrNull()?.takeIf { it > 0 }?.let { "★ %.1f".format(it) }

@Composable
private fun EmptyText(browse: Browse, noun: String, filtered: Boolean) {
    val (t, m) = when {
        filtered -> "No matches" to "Nothing here fits the current filter. Open Filter to change it."
        browse == Browse.Favorites -> "No favorites yet" to "Hold OK on a poster and choose Add to Favorites."
        browse == Browse.WatchLater -> "Nothing saved for later" to "Hold OK on a poster and choose Add to Watch Later."
        browse == Browse.Continue -> "Nothing to continue" to "Titles you start and leave partway appear here."
        browse == Browse.Recent -> "Nothing watched yet" to "What you watch appears here."
        browse == Browse.FavoriteFolders -> "No favorite folders" to "Hold OK on a folder and choose Add to favorite folders."
        else -> "Nothing here" to "This folder has no ${noun.lowercase()} in your library."
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Label(t, Tokens.title, Tokens.text, FontWeight.SemiBold); Label(m, Tokens.body, Tokens.textSecondary, maxLines = 2)
    }
}

@Composable
private fun ToolButton(label: String, icon: ImageVector, onClick: () -> Unit) {
    Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.04f) { f ->
        Row(Modifier.padding(horizontal = 11.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, null, Modifier.size(14.dp), colorFilter = ColorFilter.tint(if (f) Tokens.accent else Tokens.textSecondary))
            Label(label, Tokens.small, Tokens.text, FontWeight.Medium)
        }
    }
}

@Composable
private fun ShortcutChip(label: String, icon: ImageVector, active: Boolean, onLong: (() -> Unit)?, onMoveLeft: () -> Unit, onMoveRight: () -> Unit, onClick: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = if (active) Tokens.elevated else Tokens.card, scaleOnFocus = 1.03f, onLongClick = { menu = true }) { f ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, null, Modifier.size(14.dp), colorFilter = ColorFilter.tint(if (active || f) Tokens.accent else Tokens.textSecondary))
            Label(label, Tokens.small, if (active) Tokens.text else Tokens.textSecondary, if (active) FontWeight.SemiBold else FontWeight.Medium)
        }
    }
    if (menu) ContextMenu(label, "Order of these shortcuts", listOf(MenuAction("Move left", Icons.Filled.ArrowBack) { onMoveLeft() }, MenuAction("Move right", Icons.Filled.ArrowForward) { onMoveRight() }), onClose = { menu = false })
}

@Composable
private fun SkeletonPoster() {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).background(Tokens.card, RoundedCornerShape(Tokens.radius)))
        Box(Modifier.fillMaxWidth(0.7f).height(8.dp).background(Tokens.card, RoundedCornerShape(4.dp)))
    }
}

/** Which connection and which decade to show. Only the connection choice appears when the library has several. */
@Composable
private fun FilterSheet(current: ContentFilter, sources: List<LibraryEntry>, onApply: (ContentFilter) -> Unit, onClose: () -> Unit) {
    var draft by remember { mutableStateOf(current) }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(100); runCatching { first.requestFocus() } }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.CenterEnd) {
            Column(Modifier.padding(end = 16.dp).width(290.dp).fillMaxHeight(0.92f).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Label("Filter", Tokens.title, Tokens.text, FontWeight.Bold)
                androidx.compose.foundation.lazy.LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (sources.size > 1) {
                        item { Eyebrow("Connection", Modifier.padding(vertical = 4.dp)) }
                        item { OptionLine("All connections", draft.sourceId == null, Modifier.focusRequester(first)) { draft = draft.copy(sourceId = null) } }
                        sources.forEach { s -> item(key = s.id) { OptionLine(s.name, draft.sourceId == s.id.removePrefix("src:"), Modifier) { draft = draft.copy(sourceId = s.id.removePrefix("src:")) } } }
                    }
                    item { Eyebrow("Release decade", Modifier.padding(top = 10.dp, bottom = 4.dp)) }
                    item { OptionLine("Any year", draft.decade == null, if (sources.size <= 1) Modifier.focusRequester(first) else Modifier) { draft = draft.copy(decade = null) } }
                    listOf(2020, 2010, 2000, 1990, 1980, 1970).forEach { d -> item(key = "d$d") { OptionLine("${d}s", draft.decade == d, Modifier) { draft = draft.copy(decade = d) } } }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { TvButton("Apply", { onApply(draft); onClose() }, primary = true); TvButton("Reset", { draft = ContentFilter() }) }
            }
        }
    }
}

@Composable
private fun OptionLine(label: String, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier.fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Label(label, Tokens.row, if (on) Tokens.accent else Tokens.text, modifier = Modifier.weight(1f))
            if (on) Image(Icons.Filled.Check, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(Tokens.accent))
        }
    }
}
