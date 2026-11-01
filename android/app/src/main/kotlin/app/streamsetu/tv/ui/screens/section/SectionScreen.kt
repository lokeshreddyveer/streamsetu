package app.streamsetu.tv.ui.screens.section

import androidx.compose.ui.graphics.graphicsLayer
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items as rowItems
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import app.streamsetu.core.ui.motion.Motion
import androidx.compose.ui.unit.sp
import androidx.compose.ui.layout.layout
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
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
import app.streamsetu.tv.ui.theme.ui
import app.streamsetu.tv.ui.screens.home.HomeMenuHost
import app.streamsetu.tv.ui.screens.home.HomeTarget
import app.streamsetu.tv.ui.screens.home.HomeViewModel
import app.streamsetu.tv.ui.screens.home.RowKind
import app.streamsetu.tv.ui.screens.search.SectionSearch
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.tv
import coil.compose.AsyncImage
import androidx.compose.ui.layout.ContentScale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collectLatest

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
    val cardsRaw by vm.cards.collectAsState()
    val sort by vm.sort.collectAsState()
    val filter by vm.filter.collectAsState()
    // The hero's data and the rails are asked for only once the first page of titles is on the screen, so they never queue ahead of it in the database.
    // They start only when this page is the curated landing page, its first page of titles is for the present library, sort and filter, and that page has been drawn (two frames), so they never queue ahead of it
    // and are never started for a folder, a filtered list or the plain grid.
    LaunchedEffect(Unit) { if (app.streamsetu.tv.BuildConfig.FRAME_LOG) android.util.Log.i("Entry", "shell composed ($kind)") }
    val listKey by vm.listKey.collectAsState()
    val publishedKey by vm.cardsKey.collectAsState()
    val primaryReady = cardsRaw != null && publishedKey != null && publishedKey == listKey          // the titles on screen were read for this library, profile, folder and sort (never the previous one's)
    val cards = if (primaryReady) cardsRaw else null          // a title is drawn only when it was read for this library, profile, restrictions, folder and sort: never one from before a change
    var drawnKey by remember { mutableStateOf<Any?>(null) }
    LaunchedEffect(listKey, primaryReady, vm.gridOnly) { if (primaryReady) { androidx.compose.runtime.withFrameNanos { }; androidx.compose.runtime.withFrameNanos { }; drawnKey = listKey } else drawnKey = null }
    val firstPageDrawn = primaryReady && drawnKey == listKey
    // Everything beyond the first page (folder counts, favourites, progress, new episodes, collections, filter choices) is read only now, never ahead of it.
    LaunchedEffect(firstPageDrawn) { if (firstPageDrawn) { if (app.streamsetu.tv.BuildConfig.FRAME_LOG) android.util.Log.i("Entry", "first page drawn ($kind)"); vm.secondary.value = true } }
    LaunchedEffect(cards != null) { if (cards != null && app.streamsetu.tv.BuildConfig.FRAME_LOG) android.util.Log.i("Entry", "first cards published ($kind)") }
    LaunchedEffect(publishedKey) { if (publishedKey != null && app.streamsetu.tv.BuildConfig.FRAME_LOG) android.util.Log.i("Entry", "page published ($kind) ${publishedKey?.browse}") }
    val firstPageShown = browse == Browse.All && !filter.active && !vm.gridOnly && firstPageDrawn
    val bannerFlow = remember(firstPageShown) { if (firstPageShown) vm.banner else kotlinx.coroutines.flow.flowOf(emptyList()) }
    val bannerS = bannerFlow.collectAsState(initial = emptyList())          // read only by the hero, never by the page
    val order by vm.shortcutOrder.collectAsState()
    // Held as State and read only inside the card that shows them (derivedStateOf), so a favourite or the player writing progress redraws that card, never the page, the hero or the rails.
    val favs = vm.favourites.collectAsState()
    val progress = vm.progress.collectAsState()
    val seriesNote = vm.seriesNote.collectAsState()
    val latestBySeries = remember { derivedStateOf { progress.value.values.filter { it.seriesId != null && !it.completed && it.fraction > 0f }.groupBy { it.seriesId!! }.mapValues { (_, l) -> l.maxByOrNull { it.updatedAt }!! } } }
    val newSeries = vm.newSeries.collectAsState()
    val avail by vm.availability.collectAsState()
    val sources by vm.sources.collectAsState()
    val filterOptions by vm.filterOptions.collectAsState()
    val collections by vm.collections.collectAsState()
    val posterSize by c.ui.posterSize.collectAsState()
    val showMeta by c.ui.showPosterMeta.collectAsState()
    val bannerOn by c.ui.bannerEnabled.collectAsState()
    val showShortcuts by c.ui.showShortcuts.collectAsState()
    val railsFlow = remember(firstPageShown) { if (firstPageShown) vm.rails else kotlinx.coroutines.flow.flowOf(emptyList()) }
    val rails by railsFlow.collectAsState(initial = emptyList())
    val gridOnly = vm.gridOnly
    // The curated page (hero, rails, categories) and the plain poster grid are separate: in the grid only the posters, the title bar and the filter and sort buttons are drawn.
    val landing = browse == Browse.All && !filter.active && !gridOnly

    val entry = app.streamsetu.tv.ui.components.LocalContentEntry.current ?: remember { FocusRequester() }
    // Taken whenever something asks for a folder or collection, also when this screen is already open (from the "In folder" button on a title's page).
    LaunchedEffect(nav.pendingCollection) { nav.pendingCollection?.takeIf { it.first == kind }?.let { vm.select(Browse.Collection(it.second)); nav.pendingCollection = null } }
    LaunchedEffect(nav.pendingFolder) { nav.pendingFolder?.takeIf { it.first == kind }?.let { vm.select(Browse.Folder(it.second)); nav.pendingFolder = null } }
    val gridState = rememberLazyGridState(vm.scrollIndex)
    // Pictures are not decoded while the grid scrolls; a short rest after it stops, they are asked for.
    // Pictures a little way ahead of the visible rows are fetched at the size a poster is drawn, a bounded number, and not at all while something is playing.
    val context = androidx.compose.ui.platform.LocalContext.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    // The slideshow holds still while the grid scrolls and while the hero is off screen. Asked when it is about to advance; nothing is observed.
    val bannerPausedWhen = remember(gridState) { { gridState.isScrollInProgress } }
    // A dense wall of posters on a small TV box shows focus as a ring and a fill only: no scale, no clip.
    val densePosters = remember { app.streamsetu.tv.Perf.lowEnd(context) }
    val requested = remember(browse) { HashSet<String>() }
    // Only while the grid stands still, and only for what a poster will really show (same size, same rounded corners, so the picture is found again and not decoded twice).
    // Scrolling again cancels what is still waiting: holding a direction would otherwise queue hundreds of pictures nobody will see.
    val pending = remember { ArrayList<coil.request.Disposable>() }
    DisposableEffect(Unit) { onDispose { pending.forEach { it.dispose() }; pending.clear() } }
    LaunchedEffect(gridState, cards, posterSize) {
        val list = cards ?: return@LaunchedEffect
        val w = with(density) { posterSize.tv.roundToPx() }; val h = w * 3 / 2
        val radius = with(density) { Tokens.radius.toPx() }
        val loader = coil.Coil.imageLoader(context)
        snapshotFlow { gridState.isScrollInProgress to (gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) }.collectLatest { (scrolling, last) ->
            if (scrolling) { pending.forEach { it.dispose() }; pending.clear(); return@collectLatest }
            delay(350)
            if (c.playback.state.value != app.streamsetu.core.playback.PlaybackState.Idle) return@collectLatest
            val from = (last).coerceAtLeast(0); val to = minOf(list.size, from + app.streamsetu.tv.Perf.prefetchAhead(context))
            for (i in from until to) list.getOrNull(i)?.posterUrl?.takeIf { it.isNotBlank() && requested.add(it) }?.let { url ->
                pending += loader.enqueue(app.streamsetu.tv.ui.components.artworkRequest(context, url, w, h, radius))          // the same request a card makes, so the card finds it in the cache
            }
        }
    }
    LaunchedEffect(gridState) { snapshotFlow { gridState.firstVisibleItemIndex }.collect { vm.scrollIndex = it } }
    // Near the end of what is loaded, the next page is asked for.
    LaunchedEffect(gridState) { snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last -> if (last >= (vm.cards.value?.size ?: 0) - 24) vm.loadMore() } }
    // A different folder starts at its top, so the grid does not keep an offset from the previous one.
    var shownBrowse by remember { mutableStateOf(browse) }
    LaunchedEffect(browse, cards) { if (shownBrowse != browse && cards != null) { shownBrowse = browse; gridState.scrollToItem(0) } }
    // The title the remote was on is remembered by id: coming back from the rail, a detail page or the player puts the remote on it again (or on the nearest title if it is gone).
    val tab = if (kind == ContentKind.MOVIE) app.streamsetu.tv.nav.Tab.MOVIES else app.streamsetu.tv.nav.Tab.SERIES
    val restore = remember { FocusRequester() }
    // Built once when the list changes, so a focused poster finds its place with a lookup, never a scan of the whole library.
    val indexById = remember(cards) { HashMap<String, Int>(cards.orEmpty().size * 2).also { m -> cards.orEmpty().forEachIndexed { i, card -> m[card.id] = i } } }
    val cardById = remember(cards) { cards.orEmpty().associateBy { it.id } }
    val restoreIndex = remember(indexById) {
        val spot = nav.memory.recall(tab)
        if (spot == null || indexById.isEmpty()) null else indexById[spot.id] ?: spot.index.coerceIn(0, indexById.size - 1)          // the remembered title if it is still there, else the nearest place
    }
    val shownFolders = remember(folders) { folders.filter { !it.pref.hidden } }
    val categoryFolders = remember(shownFolders) { shownFolders.take(40) }
    var restored by remember { mutableStateOf(false) }
    LaunchedEffect(restoreIndex) {
        if (restored || restoreIndex == null || indexById.isEmpty()) return@LaunchedEffect
        restored = true
        val railCount = if (landing) rails.size else 0
        gridState.scrollToItem(restoreIndex + railCount + 2)
        if (nav.contentRestoreAllowed) app.streamsetu.tv.ui.components.requestFocusOnFrames(6, { restore.requestFocus() }, { nav.contentFocused || !nav.contentRestoreAllowed })
    }
    var sortOpen by remember { mutableStateOf(false) }
    LaunchedEffect(sortOpen) { if (sortOpen) vm.loadAvailability() }
    var filterOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    val homeVm: HomeViewModel = androidx.hilt.navigation.compose.hiltViewModel()
    var menuFor by remember { mutableStateOf<Card?>(null) }
    var menuRail by remember { mutableStateOf<String?>(null) }          // the row the long press was in, so its menu can offer "remove from this row"
    val libraryName = c.library.active.collectAsState().value?.name.orEmpty()
    var colMenu by remember { mutableStateOf<UserCollection?>(null) }
    var deleteCol by remember { mutableStateOf<UserCollection?>(null) }
    var newCollectionFor by remember { mutableStateOf<Card?>(null) }
    var addTo by remember { mutableStateOf<Card?>(null) }
    var renameCol by remember { mutableStateOf<UserCollection?>(null) }
    var inContent by remember { mutableStateOf(false) }

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

    // Back from the posters shows the folders; Back from the folders opens the main sidebar (see FolderNav).
    // The folders are a column beside the page (opened with the Folders button or by choosing the page in the sidebar); the page narrows to make room and nothing is covered.
    val folderNav = remember { app.streamsetu.tv.nav.FolderNav() }
    val foldersOpen = folderNav.open
    var moreOpen by remember { mutableStateOf(false) }
    var posterOpen by remember { mutableStateOf(false) }
    val headerScope = androidx.compose.runtime.rememberCoroutineScope()
    val panelFocus = remember { FocusRequester() }
    // From the posters, Back (and Left at the edge) goes up one level to this page's folders; Back from the folders reaches the sidebar.
    DisposableEffect(foldersOpen, browse, gridOnly) {
        val hook: () -> Boolean = {
            when {
                foldersOpen -> { folderNav.back(); nav.revealSidebar(); true }
                vm.gridOnly && browse == Browse.All -> { vm.gridOnly = false; true }          // from the plain grid, Back returns to the featured page
                browse is Browse.Continue || browse is Browse.Favorites || browse is Browse.WatchLater || browse is Browse.Recent || browse is Browse.RecentlyAdded -> { vm.select(vm.lastFolder); true }
                else -> { folderNav.show(); true }
            }
        }
        nav.backHook = hook
        onDispose { if (nav.backHook === hook) nav.backHook = null }
    }
    val focusFolders = folderNav.focusTick
    var folderFocused by remember { mutableStateOf(false) }
    val folderClaim = remember { Any() }
    SideEffect { nav.holdFolders(folderClaim, foldersOpen || nav.foldersRequested) }
    DisposableEffect(Unit) { onDispose { nav.holdFolders(folderClaim, false) } }
    LaunchedEffect(foldersOpen) { if (!foldersOpen) folderFocused = false }
    LaunchedEffect(folderFocused) { if (folderFocused && app.streamsetu.tv.BuildConfig.FRAME_LOG) android.util.Log.i("Entry", "folder panel focused ($kind)") }
    LaunchedEffect(nav.foldersRequested) { if (nav.foldersRequested) folderNav.show() }
    // The request is answered (and the claim on the remote released) only when a folder row really holds the remote, or when the folders are closed again.
    LaunchedEffect(folderFocused, foldersOpen, nav.foldersRequested) { if (nav.foldersRequested && (folderFocused || !folderNav.open)) nav.foldersRequested = false }
    // The remote goes to the folders as soon as they can take it: while the column is still opening it has no width yet, so the request is repeated for up to a second.
    // (the panel puts the remote on its selected row itself, once, as it opens: see FolderPanel.openFocusTick)
    // A list opened with "See All" (Continue Watching, Favorites...) goes back to the page it was opened from.
    BackHandler(enabled = browse is Browse.Continue || browse is Browse.Favorites || browse is Browse.WatchLater || browse is Browse.Recent || browse is Browse.RecentlyAdded) { vm.select(vm.lastFolder) }

    run {
    Box(Modifier.fillMaxSize()) {
    // While the folders are open (or have been asked for) nothing in the page can take the remote; only the folder column is enabled. The page is enabled again after Right or OK from the folders.
    androidx.compose.runtime.CompositionLocalProvider(LocalFocusEnabled provides !(folderNav.open || nav.foldersRequested)) {
    Row(Modifier.fillMaxSize()) {
        // The folders take their own column beside the page (the page narrows to make room, nothing is covered); Back, Right or choosing a folder slides them away and the page has the whole width again.
        if (foldersOpen) {          // no fade, no slide, no animated width: the page is split in one pass
            androidx.compose.runtime.CompositionLocalProvider(LocalRailReveal provides null, LocalFocusEnabled provides true) {
                FolderPanel(noun, shortcuts, folders, browse, { vm.select(it) }, vm, Modifier.onFocusChanged { folderFocused = it.hasFocus }.width(Tokens.folderPanelWidth).drawBehind { drawLine(Tokens.line, androidx.compose.ui.geometry.Offset(size.width - 0.5f, 0f), androidx.compose.ui.geometry.Offset(size.width - 0.5f, size.height), 1.dp.toPx()) }, entry = panelFocus, onRight = { folderNav.hide(); nav.contentFocusTick++; true }, onLeft = { folderNav.left(); nav.revealSidebar() }, selectOnDwell = false, onConfirm = { folderNav.hide(); nav.contentFocusTick++ }, openFocusTick = focusFolders, onShortcutMenu = { sc -> collections.firstOrNull { it.id == (sc.browse as? Browse.Collection)?.id }?.let { colMenu = it } })
            }
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxHeight().onFocusChanged { inContent = it.hasFocus }) {
            val heroHeight = 300.ui          // the same hero height as Home, so the banner is the same size on every screen
            // Columns come from the room there is: about seven posters across with the folders closed, fewer beside the folder column; the posters share the width, so the page is always full.
            val gridColumns = ((maxWidth - Tokens.safeHorizontal * 2 + Tokens.gutter) / (posterSize.tv + Tokens.gutter)).toInt().coerceIn(3, 9)
            val list = cards
            val heroReady by remember(bannerOn, gridOnly) { derivedStateOf { bannerOn && !gridOnly && bannerS.value.isNotEmpty() } }
            // Until a key is pressed (and unless the remote is being put back on a title it was on), the hero's Play button holds the remote: taken as soon as the hero exists.
            var interacted by remember { mutableStateOf(false) }
            LaunchedEffect(heroReady) { if (heroReady && !interacted && !folderNav.open && !nav.foldersHoldFocus && nav.memory.recall(tab) == null) { app.streamsetu.tv.ui.components.requestFocusOnFrames(5, { if (!interacted) entry.requestFocus() }, { interacted || nav.foldersHoldFocus || nav.contentFocused }); if (!interacted && !nav.foldersHoldFocus) gridState.scrollToItem(0) } }
            val pageHeader: @Composable () -> Unit = {
            // Search and Folders stay in view; Filter, Sort and View are in More (Filter is also a button above the grid).
            BoxWithConstraints(Modifier.fillMaxWidth()) {
            val collapse = true
            Row(Modifier.fillMaxWidth().railOnLeft().padding(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = if (heroReady) Tokens.safeVertical else 6.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Label(title, 20.sp, Tokens.text, FontWeight.Bold)
                        val n = cards?.size
                        // The whole library or folder is counted, not only the first pages that are loaded so far.
                        val total = when {
                            n == null || filter.active -> n
                            browse == Browse.All -> sources.filter { filter.sourceId == null || it.id == "src:${filter.sourceId}" }.sumOf { if (kind == ContentKind.MOVIE) it.movieCount else it.seriesCount }
                            browse is Browse.Folder -> folders.firstOrNull { it.id == (browse as Browse.Folder).id }?.count
                            else -> n
                        }?.coerceAtLeast(n ?: 0)
                        val noun = if (kind == ContentKind.MOVIE) "movies" else "series"
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        // Round icon buttons, the same as on the details pages; the name of the one the remote is on appears beside them.
                        var hint by remember { mutableStateOf<String?>(null) }
                        hint?.let { Label(it, Tokens.small, Tokens.textSecondary, modifier = Modifier.padding(end = 4.dp)) }
                        TvIconButton(Icons.Filled.Search, "Search", { searchOpen = true }, if (!heroReady) Modifier.focusRequester(entry) else Modifier, onFocus = { hint = if (it) "Search" else null }, plain = heroReady)
                        TvIconButton(Icons.Filled.Folder, "Folders", { folderNav.show() }, onFocus = { hint = if (it) "Folders" else null }, plain = heroReady)
                        // A direct way to the whole library past the rails: the grid's own heading is the target.
                        if (landing && rails.isNotEmpty() && !cards.isNullOrEmpty()) TvIconButton(Icons.Filled.GridView, "Browse all", { vm.gridOnly = true; headerScope.launch { gridState.scrollToItem(0) } }, onFocus = { hint = if (it) "Browse all" else null }, plain = heroReady)
                        else if (browse == Browse.All && !filter.active && gridOnly) TvIconButton(Icons.Filled.Star, "Featured", { vm.gridOnly = false; headerScope.launch { gridState.scrollToItem(0) } }, onFocus = { hint = if (it) "Featured" else null }, plain = heroReady)
                        // Filter is on the bar with Search and Folders. Sort, the poster size and the choice of source are under More.
                        TvIconButton(Icons.Filled.FilterList, if (filter.active) "Filter · ${filter.count}" else "Filter", { filterOpen = true }, on = filter.active, onFocus = { hint = if (it) (if (filter.active) "Filter · ${filter.count}" else "Filter") else null }, plain = heroReady)
                        TvIconButton(Icons.Filled.MoreHoriz, "More", { moreOpen = true }, on = filter.active, onFocus = { hint = if (it) "More" else null }, plain = heroReady)
                    }
                }
            }
            }
            Column(Modifier.fillMaxSize()) {
            // The hero stays where it is; only what is below it scrolls.
            // The page's own header (the folder or library name, the count, the buttons) is a row above the hero, so the two never draw over each other.
            // With a hero, the page's header (the name, the count, the buttons) is drawn on the top of it, exactly where Home puts its own; the title of the slide starts below that row, so the two never touch.
            if (!heroReady) Box(Modifier.graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen }) { pageHeader() }
            if (heroReady) { val banner by bannerS; val later by vm.watchLater.collectAsState(); val favs by vm.favourites.collectAsState(); FeaturedBanner(          // the hero collects only its own lists
                        banner, heroHeight, primaryEntry = entry, startPadding = Tokens.safeHorizontal, topOverlay = { Box(Modifier.align(Alignment.TopStart)) { pageHeader() } },
                        isFavorite = { b -> b.id in favs }, onToggleFavorite = { b -> vm.toggle(b.id, UserRepository.FAVOURITES) },
                        onPrimary = { b -> cardById[b.id]?.let { onOpen(it) } },
                        onDetails = { b -> cardById[b.id]?.let { onOpen(it) } },
                        isListed = { b -> b.id in later }, onToggleListed = { b -> vm.toggle(b.id, UserRepository.WATCH_LATER) },
                        intervalSeconds = c.ui.bannerSeconds.collectAsState().value, paused = menuFor != null || sortOpen || filterOpen || searchOpen || foldersOpen, pausedWhen = bannerPausedWhen,
                        modifier = Modifier.graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen },          // drawn once into a texture; while the grid scrolls underneath it is only copied, not redrawn
                    ) }
            Box(Modifier.weight(1f).fillMaxWidth()) {
            LazyVerticalGrid(
                GridCells.Fixed(gridColumns), state = gridState, modifier = Modifier.fillMaxSize().railOnLeft().onPreviewKeyEvent { interacted = true; false },
                contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 14.dp, bottom = 40.dp),          // room for a poster to grow (1.06) and for its frame and glow at the top and sides
                horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(Tokens.gutter),
            ) {
                if (showShortcuts && (!landing || rails.isEmpty())) item(span = { GridItemSpan(maxLineSpan) }, key = "shortcuts", contentType = "shortcuts") {
                    Row(Modifier.fillMaxWidth().padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        order.forEach { name ->
                            val s = shortcutOf(name, kind)
                            ShortcutChip(s.label, s.icon, browse == s.browse, onLong = null, onMoveLeft = { vm.moveShortcut(name, -1) }, onMoveRight = { vm.moveShortcut(name, +1) }) { nav.open(Overlay.Collection(name, if (kind == ContentKind.MOVIE) "m" else "s")) }
                        }
                        Spacer(Modifier.weight(1f))
                        ShortcutChip("Search", Icons.Filled.Search, false, onLong = null, onMoveLeft = {}, onMoveRight = {}) { searchOpen = true }
                    }
                }
                if (landing) {
                    rails.forEach { rail ->
                        item(span = { GridItemSpan(maxLineSpan) }, key = "rail-${rail.key}", contentType = "rail") {
                            SectionRail(rail, posterSize.tv, showMeta, progress, newSeries, favs, indexById, tab, vm, nav, onOpen, onLong = { key, card -> menuRail = key; menuFor = card })
                        }
                    }
                    // The library's own folders, to enter one directly (the full list, with its actions, is the Folders button).
                    if (shownFolders.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }, key = "folders-row", contentType = "folders-row") {
                        Column(Modifier.padding(bottom = 4.dp)) {
                            Label("Categories", Tokens.title, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 8.dp))
                            androidx.compose.foundation.lazy.LazyRow(Modifier.bleedStart(14.dp).railOnLeft(), horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = PaddingValues(start = 14.dp, end = 24.dp, top = 8.dp, bottom = 8.dp)) {
                                rowItems(categoryFolders, key = { "folder:${it.id}" }, contentType = { "folder" }) { f ->
                                    CategoryCard(f.title, if (f.count > 0) "%,d ".format(f.count) + noun.lowercase() else "", Icons.Filled.Folder, { if (f.pref.locked && !vm.isUnlocked(f.id)) folderNav.show() else vm.select(Browse.Folder(f.id)) }, locked = f.pref.locked)
                                }
                                if (shownFolders.size > 40) item(key = "all-folders") { CategoryCard("All ${shownFolders.size} folders", "Browse every category", Icons.Filled.GridView, { folderNav.show() }) }
                            }
                        }
                    }
                    if (rails.isNotEmpty() && !list.isNullOrEmpty()) item(span = { GridItemSpan(maxLineSpan) }, key = "all-title", contentType = "heading") { Label("All $noun", Tokens.title, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp, bottom = 2.dp)) }
                }
                // Filter and Sort, immediately above the full grid (the chip shows how many filters are on).
                if (browse == Browse.All && !filter.active && list != null) item(span = { GridItemSpan(maxLineSpan) }, key = "grid-tools", contentType = "tools") {
                        Row(Modifier.railOnLeft().padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            ToolButton(if (filter.active) "Filter · ${filter.count}" else "Filter", Icons.Filled.FilterList) { filterOpen = true }
                            ToolButton("Sort", Icons.Filled.SwapVert) { sortOpen = true }
                        }
                    }
                when {
                    list == null -> items(18, key = { "sk$it" }, contentType = { "skeleton" }) { SkeletonPoster() }
                    list.isEmpty() -> item(span = { GridItemSpan(maxLineSpan) }, key = "empty", contentType = "empty") {
                        Box(Modifier.fillMaxWidth().height(200.dp), Alignment.Center) { EmptyText(browse, noun, filter.active, entry, onFilter = { filterOpen = true }, onAll = { vm.select(Browse.All) }, onFolders = { folderNav.show() }) }
                    }
                    else -> items(list, key = { it.id }, contentType = { "poster" }) { card ->
                        GridPoster(card, posterSize.tv, showMeta, densePosters, progress, latestBySeries, seriesNote, newSeries, favs, tab, vm, nav, indexById, restore, onOpen, onLong = { menuRail = null; menuFor = card })
                    }
                }
            }
            // Rows that have scrolled up under the pinned hero fade out at its edge instead of showing as a cut-off strip.
            Box(Modifier.align(Alignment.TopStart).fillMaxWidth().height(28.dp).background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Tokens.background, androidx.compose.ui.graphics.Color.Transparent))))
            }
            }
        }
    }
    }
    }
    }

    if (moreOpen) ContextMenu(title, null, listOf(
        MenuAction("Sort", Icons.Filled.SwapVert) { sortOpen = true },
        MenuAction("Source: " + (filter.sourceId?.let { id -> sources.firstOrNull { it.id == "src:$id" }?.name } ?: "All sources"), Icons.Filled.Dns) { filterOpen = true },
        MenuAction("Poster size: " + posterSize.name.lowercase().replaceFirstChar { it.uppercase() }, Icons.Filled.GridView) { posterOpen = true },
    ), onClose = { moreOpen = false })
    if (posterOpen) ContextMenu("Poster size", null, PosterSize.entries.map { sz ->
        MenuAction(sz.name.lowercase().replaceFirstChar { it.uppercase() } + if (sz == posterSize) "   ✓" else "", Icons.Filled.GridView) { c.ui.setPosterSize(sz) }
    }, onClose = { posterOpen = false })
    if (sortOpen) SortSheet(kind, sort, avail, onApply = vm::applySort, onClose = { sortOpen = false })
    if (filterOpen) FilterSheet(filter, sources, filterOptions, onApply = { vm.filter.value = it }, onClose = { filterOpen = false })
    // The search steps aside while a title is open and comes back, with the same words and results, when Back leaves it.
    if (searchOpen && nav.top == null) SectionSearch(c, kind, onOpen = onOpen, onClose = { searchOpen = false })
    menuFor?.let { card ->
        val target: HomeTarget? = card.movie?.let { HomeTarget.Film(it) } ?: card.series?.let { HomeTarget.Show(it) }
        val rowKind = when (menuRail) { "continue" -> RowKind.CONTINUE; "favorites" -> RowKind.FAVORITES; "later" -> RowKind.WATCH_LATER; "recent" -> RowKind.OTHER; null -> when (browse) { Browse.Continue -> RowKind.CONTINUE; Browse.Favorites -> RowKind.FAVORITES; Browse.WatchLater -> RowKind.WATCH_LATER; else -> RowKind.OTHER }; else -> RowKind.OTHER }
        val extra = buildList {
            add(MenuAction("Add to a collection…", Icons.Filled.CollectionsBookmark) { addTo = card })
            (browse as? Browse.Collection)?.let { b -> add(MenuAction("Remove from this collection", Icons.Filled.RemoveCircleOutline, danger = true) { vm.removeFromCollection(b.id, card.id) }) }
        }
        HomeMenuHost(target, rowKind, homeVm, c, nav, extra) { menuFor = null; menuRail = null }
    }
    addTo?.let { card ->
        var inCols by remember(card.id) { mutableStateOf<Set<String>?>(null) }
        LaunchedEffect(card.id) { inCols = vm.containing(card.id) }
        ContextMenu("Add to a collection", card.title, collections.map { col -> MenuAction(col.name + if (inCols?.contains(col.id) == true) "   ✓" else "", Icons.Filled.CollectionsBookmark) { if (inCols?.contains(col.id) == true) vm.removeFromCollection(col.id, card.id) else vm.addToCollection(col.id, card.id) } } + MenuAction("New collection…", Icons.Filled.Add) { newCollectionFor = card }, onClose = { addTo = null })
    }
    newCollectionFor?.let { card -> RenameDialog("", onSave = { n -> vm.createCollection(n) { id -> vm.addToCollection(id, card.id) }; newCollectionFor = null }, onReset = { newCollectionFor = null }, onClose = { newCollectionFor = null }, title = "New collection", hint = "Name your collection", resetLabel = "Cancel") }
    colMenu?.let { col -> ContextMenu(col.name, "Your collection", listOf(MenuAction("Rename", Icons.Filled.Edit) { renameCol = col }, MenuAction("Delete collection", Icons.Filled.Delete, danger = true) { deleteCol = col }), onClose = { colMenu = null }) }
    // Deleting names exactly what is deleted, and the cursor starts on Cancel.
    deleteCol?.let { col -> ContextMenu("Delete “${col.name}”?", "The collection is removed. The titles in it stay in your library.", listOf(MenuAction("Cancel", Icons.Filled.Close) {}, MenuAction("Delete “${col.name}”", Icons.Filled.Delete, danger = true) { vm.deleteCollection(col) }), onClose = { deleteCol = null }) }
    renameCol?.let { col -> RenameDialog(col.name, onSave = { vm.renameCollection(col, it); renameCol = null }, onReset = { renameCol = null }, onClose = { renameCol = null }, title = "Rename collection", hint = "Name", resetLabel = "Cancel") }
}


/** One horizontal rail of the landing page, as an item of its own: it reads progress, favourites and new episodes only inside its own cards. */
@Composable
private fun SectionRail(rail: Rail, posterWidth: androidx.compose.ui.unit.Dp, showMeta: Boolean, progress: State<Map<String, WatchProgress>>, newSeries: State<Set<String>>, favs: State<Set<String>>,
                        indexById: Map<String, Int>, tab: app.streamsetu.tv.nav.Tab, vm: SectionViewModel, nav: Navigator, onOpen: (Card) -> Unit, onLong: (String, Card) -> Unit) {
    Column(Modifier.padding(bottom = 4.dp)) {
        Row(Modifier.padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Label(rail.title, Tokens.title, Tokens.text, FontWeight.SemiBold)
            if (rail.seeAll) Focusable({ vm.select(rail.browse) }, Modifier, shape = RoundedCornerShape(Tokens.radiusSmall), container = Color.Transparent, scaleOnFocus = 1.04f) { f ->
                Label("See All", Tokens.small, if (f) Color.White else Tokens.textSecondary, FontWeight.Medium, modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp))
            }
        }
        androidx.compose.foundation.lazy.LazyRow(Modifier.bleedStart(14.dp).railOnLeft(), horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = PaddingValues(start = 14.dp, end = 24.dp, top = 8.dp, bottom = 8.dp)) {
            rowItems(rail.cards, key = { "${rail.key}:${it.id}" }, contentType = { "rail-poster" }) { card ->
                val p by remember(card.id) { derivedStateOf { progress.value[card.id] } }
                val isNew by remember(card.id) { derivedStateOf { card.id in newSeries.value } }
                val isFav by remember(card.id) { derivedStateOf { card.id in favs.value } }
                PosterCard(card.title, card.posterUrl, { onOpen(card) }, width = posterWidth, progress = p?.takeIf { !it.completed }?.fraction ?: 0f, itemId = card.id,
                    subtitle = p?.takeIf { rail.key == "continue" && !it.completed }?.let { "${((it.durationMs - it.positionMs) / 60_000).coerceAtLeast(1)} min left" } ?: if (showMeta) card.year?.toString() else null, badge = if (isNew) "NEW" else if (isFav) "♥" else null,
                    onFocusChange = { if (it) { vm.focusedId = card.id; nav.memory.remember(tab, card.id, indexById[card.id] ?: 0) } }, onLongClick = { onLong(rail.key, card) })
            }
        }
    }
}

/** One poster of the full grid. Everything that changes while the person watches (progress, favourites, new episodes) is read here, for this card only. */
@Composable
private fun GridPoster(card: Card, posterWidth: androidx.compose.ui.unit.Dp, showMeta: Boolean, dense: Boolean, progress: State<Map<String, WatchProgress>>, latestBySeries: State<Map<String, WatchProgress>>, seriesNote: State<Map<String, String>>,
                       newSeries: State<Set<String>>, favs: State<Set<String>>, tab: app.streamsetu.tv.nav.Tab, vm: SectionViewModel, nav: Navigator, indexById: Map<String, Int>, restore: FocusRequester, onOpen: (Card) -> Unit, onLong: () -> Unit) {
    val p by remember(card.id) { derivedStateOf { progress.value[card.id] ?: latestBySeries.value[card.id] } }          // a series shows the bar of the episode begun last
    val note by remember(card.id) { derivedStateOf { seriesNote.value[card.id] } }
    val isNew by remember(card.id) { derivedStateOf { card.id in newSeries.value } }
    val isFav by remember(card.id) { derivedStateOf { card.id in favs.value } }
    val rating = remember(card.rating) { ratingBadge(card.rating) }
    PosterCard(
        card.title, card.posterUrl, { onOpen(card) }, width = posterWidth,
        progress = p?.takeIf { !it.completed }?.fraction ?: 0f,
        itemId = card.id,
        subtitle = note ?: if (showMeta) card.year?.toString() else null,
        badge = if (isNew) "NEW" else rating ?: if (isFav) "♥" else null,          // one badge: new episode, else rating, else favourite
        focusRequester = if (card.id == nav.memory.recall(tab)?.id) restore else null,
        onFocusChange = { if (it) { vm.focusedId = card.id; nav.memory.remember(tab, card.id, indexById[card.id] ?: 0) } },
        onLongClick = onLong, dense = dense,
    )
}

fun ratingBadge(r: String?): String? = r?.toDoubleOrNull()?.takeIf { it > 0 }?.let { "★ %.1f".format(it) }

@Composable
private fun EmptyText(browse: Browse, noun: String, filtered: Boolean, entry: FocusRequester, onFilter: () -> Unit, onAll: () -> Unit, onFolders: () -> Unit) {
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
        // Something for the remote to land on when the folders hand it to an empty page.
        TvButton(if (filtered) "Open Filter" else if (browse != Browse.All) "Show all ${noun.lowercase()}" else "Choose a folder", { if (filtered) onFilter() else if (browse != Browse.All) onAll() else onFolders() }, Modifier.padding(top = 8.dp).focusRequester(entry), primary = true)
    }
}

@Composable
private fun ToolButton(label: String, icon: ImageVector, modifier: Modifier = Modifier, compact: Boolean = false, onClick: () -> Unit) {
    // The same pill as every other button: a light glass fill, solid white with dark text while the remote is on it. Every button on the bar carries its name.
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = Color(0x26FFFFFF), focusedContainer = Color.White, scaleOnFocus = 1.0f, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE, hairline = false, showRing = false, ringBand = false) { f ->
        val ink = if (f) Tokens.onBright else Tokens.text
        Row(Modifier.padding(horizontal = 13.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, label, Modifier.size(13.dp), colorFilter = ColorFilter.tint(ink))
            Label(label, Tokens.caption, ink, FontWeight.SemiBold)
        }
    }
}

/** Lets a child use the whole width of its parent, past the parent's side padding (a full-bleed picture inside a padded list). */
private fun Modifier.fullBleed(start: androidx.compose.ui.unit.Dp, end: androidx.compose.ui.unit.Dp): Modifier = layout { measurable, c ->
    val s = start.roundToPx(); val e = end.roundToPx()
    val p = measurable.measure(c.copy(minWidth = c.maxWidth + s + e, maxWidth = c.maxWidth + s + e))
    layout(c.maxWidth, p.height) { p.place(-s, 0) }
}

@Composable
private fun ShortcutChip(label: String, icon: ImageVector, active: Boolean, onLong: (() -> Unit)?, onMoveLeft: () -> Unit, onMoveRight: () -> Unit, onClick: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    // The same pill as Home's shortcuts: frosted at rest, solid white with dark text while the remote is on it. The lists open in the same sheet as on Home.
    Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = Color(0x26FFFFFF), focusedContainer = Color.White, scaleOnFocus = 1.0f, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE, showRing = false, ringBand = false, onLongClick = { menu = true }) { f ->
        val ink = if (f) Tokens.onBright else Tokens.text
        Row(Modifier.padding(horizontal = 13.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, null, Modifier.size(13.dp), colorFilter = ColorFilter.tint(if (f) ink else Tokens.textSecondary))
            Label(label, Tokens.caption, ink, FontWeight.SemiBold)
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
    LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
    val q = query.trim()
    fun shown(label: String) = q.isEmpty() || label.contains(q, ignoreCase = true)
    val connections = if (sources.size > 1) sources.map { it.name to it.id.removePrefix("src:") }.sortedBy { it.first.lowercase() } else emptyList()
    TvDialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
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
