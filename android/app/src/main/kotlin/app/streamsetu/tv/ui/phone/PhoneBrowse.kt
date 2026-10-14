package app.streamsetu.tv.ui.phone

import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.background
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.data.repo.SearchTab
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.ChannelLogo
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.Loading
import app.streamsetu.tv.ui.screens.live.LiveSectionViewModel
import app.streamsetu.tv.ui.screens.section.SectionViewModel
import app.streamsetu.tv.ui.screens.section.ratingBadge
import app.streamsetu.tv.ui.theme.Tokens

private val shortcuts = listOf<Pair<String, Browse>>("All" to Browse.All, "Recently added" to Browse.RecentlyAdded, "Favorites" to Browse.Favorites, "Watch Later" to Browse.WatchLater, "Continue" to Browse.Continue, "Recent" to Browse.Recent)

/** Movies or Series: the shortcuts and folders as chips, then a grid of posters. */
@Composable
fun PhoneSection(vm: SectionViewModel, title: String, c: AppContainer, nav: Navigator) {
    val cards by vm.cards.collectAsState()
    val browse by vm.browse.collectAsState()
    val folders by vm.folders.collectAsState()
    val favs by vm.favourites.collectAsState()
    val later by vm.watchLater.collectAsState()
    val progress by vm.progress.collectAsState()
    val newSeries by vm.newSeries.collectAsState()
    var sheet by remember { mutableStateOf<Pair<String, List<SheetItem>>?>(null) }
    var folderSheet by remember { mutableStateOf(false) }
    val grid = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
    LaunchedEffect(browse) { grid.scrollToItem(0) }
    val shown = folders.filter { !it.pref.hidden }
    val folderName = (browse as? Browse.Folder)?.let { b -> folders.firstOrNull { it.id == b.id }?.title }

    val banner by vm.banner.collectAsState()
    Column(Modifier.fillMaxSize()) {
        PhoneTopBar(title) {
            RoundTap(Icons.Filled.Search, "Search") { nav.openSearch(if (vm.kind == ContentKind.SERIES) SearchTab.SERIES else SearchTab.MOVIES) }
            RoundTap(Icons.Filled.Folder, "Folders") { folderSheet = true }
        }
        val list = cards
        when {
            list == null -> Loading(Modifier.weight(1f))
            else -> LazyVerticalGrid(GridCells.Fixed(3), Modifier.weight(1f), state = grid, contentPadding = PaddingValues(start = Ph.gutter, end = Ph.gutter, bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (banner.isNotEmpty()) item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                    Box(Modifier.layout { m, c -> val p = m.measure(c.copy(maxWidth = c.maxWidth + 32.dp.roundToPx())); layout(c.maxWidth, p.height) { p.place(-16.dp.roundToPx(), 0) } }) {
                        PhoneBanner(banner, onPrimary = { b -> list.firstOrNull { it.id == b.id }?.let { cd -> cd.movie?.let { play(c, nav, MoviePlayable(it)) } ?: cd.series?.let { nav.open(Overlay.SeriesDetail(it)) } } },
                            onDetails = { b -> list.firstOrNull { it.id == b.id }?.let { cd -> cd.movie?.let { nav.open(Overlay.MovieDetail(it)) } ?: cd.series?.let { nav.open(Overlay.SeriesDetail(it)) } } })
                    }
                }
                item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.layout { m, c -> val p = m.measure(c.copy(maxWidth = c.maxWidth + 32.dp.roundToPx())); layout(c.maxWidth, p.height) { p.place(-16.dp.roundToPx(), 0) } }, contentPadding = PaddingValues(horizontal = Ph.gutter)) {
                            item { Chip("All", browse == Browse.All, { vm.select(Browse.All) }, icon = Icons.Filled.GridView) }
                            item { Chip("Favourites", browse == Browse.Favorites, { vm.select(Browse.Favorites) }, icon = Icons.Filled.Favorite) }
                            item { Chip("Watch Later", browse == Browse.WatchLater, { vm.select(Browse.WatchLater) }, icon = Icons.Filled.Bookmark) }
                            item { Chip("Recently added", browse == Browse.RecentlyAdded, { vm.select(Browse.RecentlyAdded) }) }
                            item { Chip("Continue", browse == Browse.Continue, { vm.select(Browse.Continue) }) }
                            item { Chip(folderName ?: "Folders", folderName != null, { folderSheet = true }, icon = Icons.Filled.Folder) }
                        }
                        Label((folderName?.let { "$it  ·  " } ?: "") + "%,d titles".format(list.size), Ph.small, Tokens.textTertiary)
                    }
                }
                if (list.isEmpty()) item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) { Empty("Nothing here", when (browse) { Browse.Favorites -> "Touch and hold a title to add it to your favorites."; Browse.WatchLater -> "Nothing saved for later yet."; else -> "This list is empty." }) }
                items(list, key = { it.id }) { card ->
                    val p = progress[card.id]
                    PhonePoster(
                        card.title, card.posterUrl, { card.movie?.let { nav.open(Overlay.MovieDetail(it)) } ?: card.series?.let { nav.open(Overlay.SeriesDetail(it)) } },
                        subtitle = card.year?.toString(),
                        badge = listOfNotNull(if (card.id in favs) "♥" else null, if (card.id in newSeries) "NEW" else if (p?.completed == true) "✓" else ratingBadge(card.rating)).joinToString(" ").ifBlank { null },
                        progress = if (p != null && !p.completed) p.fraction else 0f,
                        onLong = { sheet = card.title to buildList {
                            add(SheetItem("Open", Icons.Filled.PlayArrow) { card.movie?.let { nav.open(Overlay.MovieDetail(it)) } ?: card.series?.let { nav.open(Overlay.SeriesDetail(it)) } })
                            add(SheetItem(if (card.id in favs) "Remove from favorites" else "Add to favorites", Icons.Filled.Favorite) { vm.toggle(card.id, UserRepository.FAVOURITES) })
                            add(SheetItem(if (card.id in later) "Remove from Watch Later" else "Watch Later", Icons.Filled.Bookmark) { vm.toggle(card.id, UserRepository.WATCH_LATER) })
                            if (card.movie != null) add(SheetItem(if (p?.completed == true) "Mark as unwatched" else "Mark as watched", Icons.Filled.CheckCircle) { vm.setWatched(card, p?.completed != true) })
                        } },
                    )
                }
            }
        }
    }
    if (folderSheet) Sheet("Folders", buildList {
        add(SheetItem("All $title", Icons.Filled.GridView, browse == Browse.All) { vm.select(Browse.All) })
        shown.forEach { f -> add(SheetItem(f.title, if (f.pref.favorite) Icons.Filled.Star else Icons.Filled.Folder, (browse as? Browse.Folder)?.id == f.id, "%,d".format(f.count), enabled = !f.pref.locked) { vm.select(Browse.Folder(f.id)) }) }
    }, onClose = { folderSheet = false }, subtitle = "${shown.size} folders")
    sheet?.let { (t, items) -> Sheet(t, items, onClose = { sheet = null }) }
}

/** Live TV: folders as chips, then the channels. A tap plays and opens the player. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PhoneLive(vm: LiveSectionViewModel, c: AppContainer, nav: Navigator) {
    val groups by vm.groups.collectAsState()
    val browse by vm.browse.collectAsState()
    val folders by vm.folders.collectAsState()
    val now by vm.now.collectAsState()
    val epgIds by vm.epgIds.collectAsState()
    val favs by vm.favourites.collectAsState()
    val state = rememberLazyListState()
    var folderSheet by remember { mutableStateOf(false) }
    var sheet by remember { mutableStateOf<Pair<String, List<SheetItem>>?>(null) }
    LaunchedEffect(browse) { state.scrollToItem(0) }
    val shown = folders.filter { !it.pref.hidden }
    val folderName = (browse as? Browse.Folder)?.let { b -> folders.firstOrNull { it.id == b.id }?.title }

    val gridState = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
    LaunchedEffect(browse) { gridState.scrollToItem(0) }
    Column(Modifier.fillMaxSize()) {
        PhoneTopBar("Live TV") {
            RoundTap(Icons.Filled.CalendarMonth, "TV Guide") { nav.tab = Tab.GUIDE }
            RoundTap(Icons.Filled.Search, "Search") { nav.openSearch(SearchTab.LIVE) }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Chip("All", browse == Browse.All, { vm.select(Browse.All) }, icon = Icons.Filled.GridView) }
            item { Chip("Favourites", browse == Browse.Favorites, { vm.select(Browse.Favorites) }, icon = Icons.Filled.Favorite) }
            item { Chip("Recent", browse == Browse.Recent, { vm.select(Browse.Recent) }, icon = Icons.Filled.History) }
            item { Chip(folderName ?: "Groups", folderName != null, { folderSheet = true }, icon = Icons.Filled.Folder) }
        }
        Spacer(Modifier.height(10.dp))
        val list = groups
        if (list == null) Loading(Modifier.weight(1f))
        else if (list.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth()) { Empty("No channels", "Nothing in this group.") }
        else LazyVerticalGrid(GridCells.Fixed(3), Modifier.weight(1f), state = gridState, contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(list, key = { it.rep.id }) { g ->
                val ch = g.rep
                val program = epgIds[ch.id]?.let { now[it] }
                Column(
                    Modifier.fillMaxWidth().clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp)).background(Tokens.card).combinedClickable(onClick = { play(c, nav, ChannelPlayable(ch), list.map { ChannelPlayable(it.rep) }) }, onLongClick = { vm.toggleFavourite(ch) }).padding(horizontal = 8.dp, vertical = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box { ChannelLogo(ch.logoUrl, ch.name, 60.dp); if (ch.id in favs) Icon(Icons.Filled.Favorite, Tokens.gold, 14.dp, Modifier.align(Alignment.TopEnd)) }
                    Label((ch.number?.let { "$it " } ?: "") + ch.name, Ph.caption, Tokens.text, FontWeight.Medium, maxLines = 2)
                    Label(program?.title ?: if (g.variants.size > 1) "${g.variants.size} streams" else "Live", 11.sp, Tokens.textTertiary)
                }
            }
        }
    }
    if (folderSheet) Sheet("Groups", shown.map { f -> SheetItem(f.title, if (f.pref.favorite) Icons.Filled.Star else Icons.Filled.Folder, (browse as? Browse.Folder)?.id == f.id, "%,d".format(f.count), enabled = !f.pref.locked) { vm.select(Browse.Folder(f.id)) } }, onClose = { folderSheet = false }, subtitle = "${shown.size} groups")
    sheet?.let { (t, items) -> Sheet(t, items, onClose = { sheet = null }) }
}
