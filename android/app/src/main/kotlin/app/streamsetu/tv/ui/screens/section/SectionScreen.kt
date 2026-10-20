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
import app.streamsetu.tv.ui.screens.home.HomeMenuHost
import app.streamsetu.tv.ui.screens.home.HomeTarget
import app.streamsetu.tv.ui.screens.home.HomeViewModel
import app.streamsetu.tv.ui.screens.home.RowKind
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
    val newSeries by vm.newSeries.collectAsState()
    val avail by vm.availability.collectAsState()
    val sources by vm.sources.collectAsState()
    val filterOptions by vm.filterOptions.collectAsState()
    val collections by vm.collections.collectAsState()
    val posterSize by c.ui.posterSize.collectAsState()
    val showMeta by c.ui.showPosterMeta.collectAsState()
    val bannerOn by c.ui.bannerEnabled.collectAsState()
    val showShortcuts by c.ui.showShortcuts.collectAsState()

    val entry = app.streamsetu.tv.ui.components.LocalContentEntry.current ?: remember { FocusRequester() }
    // Taken whenever something asks for a folder or collection, also when this screen is already open (from the "In folder" button on a title's page).
    LaunchedEffect(nav.pendingCollection) { nav.pendingCollection?.takeIf { it.first == kind }?.let { vm.select(Browse.Collection(it.second)); nav.pendingCollection = null } }
    LaunchedEffect(nav.pendingFolder) { nav.pendingFolder?.takeIf { it.first == kind }?.let { vm.select(Browse.Folder(it.second)); nav.pendingFolder = null } }
    val gridState = rememberLazyGridState(vm.scrollIndex)
    // Pictures a little way ahead of the visible rows are fetched at the size a poster is drawn, a bounded number, and not at all while something is playing.
    val context = androidx.compose.ui.platform.LocalContext.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    val requested = remember(browse) { HashSet<String>() }
    LaunchedEffect(gridState, cards, posterSize) {
        val list = cards ?: return@LaunchedEffect
        val w = with(density) { posterSize.dp.dp.roundToPx() }; val h = w * 3 / 2
        val loader = coil.Coil.imageLoader(context)
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last ->
            if (c.playback.state.value != app.streamsetu.core.playback.PlaybackState.Idle) return@collect
            val from = (last).coerceAtLeast(0); val to = minOf(list.size, from + app.streamsetu.tv.Perf.prefetchAhead(context))
            for (i in from until to) list.getOrNull(i)?.posterUrl?.takeIf { it.isNotBlank() && requested.add(it) }?.let { url ->
                loader.enqueue(coil.request.ImageRequest.Builder(context).data(url).size(w, h).build())
            }
        }
    }
    LaunchedEffect(gridState) { snapshotFlow { gridState.firstVisibleItemIndex }.collect { vm.scrollIndex = it } }
    // Near the end of what is loaded, the next page is asked for.
    LaunchedEffect(gridState) { snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last -> if (last >= (vm.cards.value?.size ?: 0) - 90) vm.loadMore() } }
    // A different folder starts at its top, so the grid does not keep an offset from the previous one.
    var shownBrowse by remember { mutableStateOf(browse) }
    LaunchedEffect(browse, cards) { if (shownBrowse != browse && cards != null) { shownBrowse = browse; gridState.scrollToItem(0) } }
    var sortOpen by remember { mutableStateOf(false) }
    var filterOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    val homeVm: HomeViewModel = androidx.hilt.navigation.compose.hiltViewModel()
    var menuFor by remember { mutableStateOf<Card?>(null) }
    var colMenu by remember { mutableStateOf<UserCollection?>(null) }
    var newCollectionFor by remember { mutableStateOf<Card?>(null) }
    var addTo by remember { mutableStateOf<Card?>(null) }
    var renameCol by remember { mutableStateOf<UserCollection?>(null) }
    var inContent by remember { mutableStateOf(false) }
    val panelEntry = entry

    val folderTitle = (browse as? Browse.Folder)?.let { b -> folders.firstOrNull { it.id == b.id }?.title }
    val title = when (browse) {
        Browse.All -> "All $noun"; Browse.Favorites -> "Favorites"; Browse.WatchLater -> "Watch Later"; Browse.Continue -> "Continue Watching"
        Browse.Recent -> "Recently Watched"; Browse.RecentlyAdded -> "Recently Added"; Browse.FavoriteFolders -> "Favorite Folders"; is Browse.Folder -> folderTitle ?: noun
        is Browse.Collection -> collections.firstOrNull { it.id == (browse as Browse.Collection).id }?.name ?: "Collection"
        is Browse.Smart -> (browse as Browse.Smart).rule.label
    }
    // The folder panel has only All, the provider's folders and the person's own folders. Favorites, Watch Later, Recently Watched and Continue Watching are the chips under the banner.
    val shortcuts = buildList {
        add(Shortcut(Browse.All, "All $noun", Icons.Filled.GridView))
        collections.forEach { add(Shortcut(Browse.Collection(it.id), it.name, Icons.Filled.CollectionsBookmark)) }
    }

    // Back from the posters returns to the folders; back from the folders reveals the sidebar (handled by the shell).
    BackHandler(enabled = inContent) { runCatching { panelEntry.requestFocus() } }

    Row(Modifier.fillMaxSize()) {
        FolderPanel(noun, shortcuts, folders, browse, vm::select, vm, Modifier.width(Tokens.folderPanelWidth), entry = panelEntry, selectOnDwell = c.settings.foldersOpenOnFocus.collectAsState().value, onShortcutMenu = { sc -> collections.firstOrNull { it.id == (sc.browse as? Browse.Collection)?.id }?.let { colMenu = it } })
        Column(Modifier.weight(1f).fillMaxHeight().onFocusChanged { inContent = it.hasFocus }) {
            // Header
            Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Label(title, Tokens.pageTitle, Tokens.text, FontWeight.Bold)
                    val n = cards?.size
                    // The whole library or folder is counted, not only the first pages that are loaded so far.
                    val total = when {
                        n == null || filter.active -> n
                        browse == Browse.All -> sources.filter { filter.sourceId == null || it.id == "src:${filter.sourceId}" }.sumOf { if (kind == ContentKind.MOVIE) it.movieCount else it.seriesCount }
                        browse is Browse.Folder -> folders.firstOrNull { it.id == (browse as Browse.Folder).id }?.count
                        else -> n
                    }?.coerceAtLeast(n ?: 0)
                    val noun = if (kind == ContentKind.MOVIE) "movies" else "series"
                    Label((if (n == null) "Loading…" else if (total != null && total > n) "%,d of %,d $noun".format(n, total) else "%,d $noun".format(n)) + "  ·  " + (filter.sourceId?.let { id -> sources.firstOrNull { it.id == "src:$id" }?.name } ?: "All sources") + (if (sort != SortSpec.defaultFor(kind)) "  ·  Sort: ${sort.field.label}" else "  ·  Newest first".takeIf { sort.field == SortField.ADDED && sort.ascending }.orEmpty()), Tokens.small, Tokens.textSecondary)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ToolButton(if (filter.active) "Filter · ${filter.count}" else "Filter", Icons.Filled.FilterList) { filterOpen = true }
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
                        startPadding = 0.dp, intervalSeconds = c.ui.bannerSeconds.collectAsState().value, paused = menuFor != null || sortOpen || filterOpen || searchOpen,
                        modifier = Modifier.padding(bottom = 4.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).clip(RoundedCornerShape(Tokens.radiusLarge)),
                    )
                }
                if (showShortcuts) item(span = { GridItemSpan(maxLineSpan) }, key = "shortcuts") {
                    Row(Modifier.fillMaxWidth().padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        order.forEach { name ->
                            val s = shortcutOf(name, kind)
                            ShortcutChip(s.label, s.icon, browse == s.browse, onLong = null, onMoveLeft = { vm.moveShortcut(name, -1) }, onMoveRight = { vm.moveShortcut(name, +1) }) { vm.select(if (browse == s.browse) vm.lastFolder else s.browse) }
                        }
                        Spacer(Modifier.weight(1f))
                        ShortcutChip("Search", Icons.Filled.Search, false, onLong = null, onMoveLeft = {}, onMoveRight = {}) { searchOpen = true }
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
                            itemId = card.id,
                            subtitle = if (showMeta) card.year?.toString() else null,
                            badge = listOfNotNull(if (card.id in favs) "♥" else null, if (card.id in newSeries) "NEW" else ratingBadge(card.rating)).joinToString(" ").ifBlank { null },
                            onLongClick = { menuFor = card },
                        )
                    }
                }
            }
        }
    }

    if (sortOpen) SortSheet(kind, sort, avail, onApply = vm::applySort, onClose = { sortOpen = false })
    if (filterOpen) FilterSheet(filter, sources, filterOptions, onApply = { vm.filter.value = it }, onClose = { filterOpen = false })
    // The search steps aside while a title is open and comes back, with the same words and results, when Back leaves it.
    if (searchOpen && nav.top == null) SectionSearch(c, kind, onOpen = onOpen, onClose = { searchOpen = false })
    menuFor?.let { card ->
        val target: HomeTarget? = card.movie?.let { HomeTarget.Film(it) } ?: card.series?.let { HomeTarget.Show(it) }
        val rowKind = when (browse) { Browse.Continue -> RowKind.CONTINUE; Browse.Favorites -> RowKind.FAVORITES; Browse.WatchLater -> RowKind.WATCH_LATER; else -> RowKind.OTHER }
        val extra = buildList {
            add(MenuAction("Add to a collection…", Icons.Filled.CollectionsBookmark) { addTo = card })
            (browse as? Browse.Collection)?.let { b -> add(MenuAction("Remove from this collection", Icons.Filled.RemoveCircleOutline) { vm.removeFromCollection(b.id, card.id) }) }
        }
        HomeMenuHost(target, rowKind, homeVm, c, nav, extra) { menuFor = null }
    }
    addTo?.let { card ->
        var inCols by remember(card.id) { mutableStateOf<Set<String>?>(null) }
        LaunchedEffect(card.id) { inCols = vm.containing(card.id) }
        ContextMenu("Add to a collection", card.title, collections.map { col -> MenuAction(col.name + if (inCols?.contains(col.id) == true) "   ✓" else "", Icons.Filled.CollectionsBookmark) { if (inCols?.contains(col.id) == true) vm.removeFromCollection(col.id, card.id) else vm.addToCollection(col.id, card.id) } } + MenuAction("New collection…", Icons.Filled.Add) { newCollectionFor = card }, onClose = { addTo = null })
    }
    newCollectionFor?.let { card -> RenameDialog("", onSave = { n -> vm.createCollection(n) { id -> vm.addToCollection(id, card.id) }; newCollectionFor = null }, onReset = { newCollectionFor = null }, onClose = { newCollectionFor = null }, title = "New collection", hint = "Name your collection", resetLabel = "Cancel") }
    colMenu?.let { col -> ContextMenu(col.name, "Your collection", listOf(MenuAction("Rename", Icons.Filled.Edit) { renameCol = col }, MenuAction("Delete collection", Icons.Filled.Delete) { vm.deleteCollection(col) }), onClose = { colMenu = null }) }
    renameCol?.let { col -> RenameDialog(col.name, onSave = { vm.renameCollection(col, it); renameCol = null }, onReset = { renameCol = null }, onClose = { renameCol = null }, title = "Rename collection", hint = "Name", resetLabel = "Cancel") }
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
        browse is Browse.Collection -> "This collection is empty" to "Hold OK on a poster and choose Add to a collection."
        browse is Browse.Smart -> "Nothing matches yet" to "This list fills itself from what you watch and what is added."
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

/**
 * What to narrow the list by: connection, language, folder, quality, release decade, rating and how far along a title is. Choices that depend on the list (languages, folders,
 * qualities, connections) are the ones it really has, in alphabetical order, and the box at the top finds a choice by its name.
 */
@Composable
private fun FilterSheet(current: ContentFilter, sources: List<LibraryEntry>, options: FilterOptions, onApply: (ContentFilter) -> Unit, onClose: () -> Unit) {
    var draft by remember { mutableStateOf(current) }
    var query by remember { mutableStateOf("") }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(100); runCatching { first.requestFocus() } }
    val q = query.trim()
    fun shown(label: String) = q.isEmpty() || label.contains(q, ignoreCase = true)
    val connections = if (sources.size > 1) sources.map { it.name to it.id.removePrefix("src:") }.sortedBy { it.first.lowercase() } else emptyList()
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.CenterEnd) {
            Column(Modifier.padding(end = 16.dp).width(340.dp).fillMaxHeight(0.94f).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Label(if (draft.count > 0) "Filter  ·  ${draft.count}" else "Filter", Tokens.title, Tokens.text, FontWeight.Bold)
                TvTextField(query, { query = it }, "Search the filters", Modifier.fillMaxWidth().focusRequester(first), leadingIcon = Icons.Filled.Search)
                androidx.compose.foundation.lazy.LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    fun section(title: String, rows: List<Triple<String, Boolean, () -> Unit>>, anyLabel: String? = null, anyOn: Boolean = false, onAny: () -> Unit = {}) {
                        val visible = rows.filter { shown(it.first) }
                        val anyVisible = anyLabel != null && (q.isEmpty() || shown(anyLabel) || shown(title))
                        if (visible.isEmpty() && !anyVisible) return
                        item(key = "h-$title") { Eyebrow(title, Modifier.padding(top = 10.dp, bottom = 4.dp)) }
                        if (anyVisible) item(key = "any-$title") { OptionLine(anyLabel!!, anyOn, Modifier) { onAny() } }
                        visible.forEach { (label, on, pick) -> item(key = "$title|$label") { OptionLine(label, on, Modifier, pick) } }
                    }
                    section("Connection", connections.map { (name, id) -> Triple(name, draft.sourceId == id) { draft = draft.copy(sourceId = id) } }, "All connections", draft.sourceId == null) { draft = draft.copy(sourceId = null) }
                    section("Language", options.languages.map { l -> Triple(l, draft.language == l) { draft = draft.copy(language = l) } }, "Any language", draft.language == null) { draft = draft.copy(language = null) }
                    section("Quality", options.qualities.map { l -> Triple(l, draft.quality == l) { draft = draft.copy(quality = l) } }, "Any quality", draft.quality == null) { draft = draft.copy(quality = null) }
                    section("Status", WatchStatus.entries.map { st -> Triple(st.label, draft.status == st) { draft = draft.copy(status = st) } }, "Everything", draft.status == null) { draft = draft.copy(status = null) }
                    section("Rating", listOf(9f, 8f, 7f, 6f).map { r -> Triple("${r.toInt()}+ stars", draft.minRating == r) { draft = draft.copy(minRating = r) } }, "Any rating", draft.minRating == null) { draft = draft.copy(minRating = null) }
                    section("Release decade", listOf(2020, 2010, 2000, 1990, 1980, 1970).map { d -> Triple("${d}s", draft.decade == d) { draft = draft.copy(decade = d) } }, "Any year", draft.decade == null) { draft = draft.copy(decade = null) }
                    if (q.isNotEmpty()) item(key = "none") { Label("Nothing is called that. Clear the box to see every filter.", Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(8.dp)) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { TvButton("Apply", { onApply(draft); onClose() }, primary = true); TvButton("Reset", { draft = ContentFilter(); query = "" }) }
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
