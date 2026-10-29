package app.streamsetu.tv.ui.phone

import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.ui.unit.sp
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.ChannelLogo
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.PosterPlaceholder
import app.streamsetu.tv.ui.screens.home.FavItem
import app.streamsetu.tv.ui.screens.home.HomeViewModel
import app.streamsetu.tv.ui.screens.section.ratingBadge
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Home: a featured title, shortcuts, then rows. Everything scrolls with a finger; a tap opens, touch and hold gives the menu. */
@Composable
fun PhoneHome(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val banner by vm.banner.collectAsStateWithLifecycle()
    val resume by vm.continueWatching.collectAsStateWithLifecycle()
    val live by vm.recentLive.collectAsStateWithLifecycle()
    val tonight by vm.tonight.collectAsStateWithLifecycle()
    val favs by vm.favourites.collectAsStateWithLifecycle()
    val later by vm.watchLater.collectAsStateWithLifecycle()
    val recent by vm.recentWatched.collectAsStateWithLifecycle()
    val forYou by vm.forYou.collectAsStateWithLifecycle()
    val moreWith by vm.moreWith.collectAsStateWithLifecycle()
    val movies by vm.recentMovies.collectAsStateWithLifecycle()
    val series by vm.recentSeries.collectAsStateWithLifecycle()
    val favIds by vm.favouriteIds.collectAsStateWithLifecycle()
    val name by vm.libraryName.collectAsStateWithLifecycle()
    var sheet by remember { mutableStateOf<Pair<String, List<SheetItem>>?>(null) }

    fun movieMenu(m: Movie) { sheet = m.title to listOf(
        SheetItem("Play", Icons.Filled.PlayArrow) { play(c, nav, MoviePlayable(m)) },
        SheetItem("Watch privately", Icons.Filled.VisibilityOff) { c.playBestMovie(m) { play(c, nav, it, privately = true) } },
        SheetItem(if (m.id in favIds) "Remove from favorites" else "Add to favorites", Icons.Filled.Favorite) { vm.setFavorite(m.id, ContentKind.MOVIE, m.id !in favIds) },
        SheetItem("Watch later", Icons.Filled.Bookmark) { vm.toggleWatchLater(m.id, ContentKind.MOVIE) },
        SheetItem("Details", Icons.Filled.Info) { nav.open(Overlay.MovieDetail(m)) },
    ) + queueItems(c, m.id, ContentKind.MOVIE, m.title) + favoriteOrderItems(m.id in favIds) { front -> vm.moveFavorite(m.id, ContentKind.MOVIE, front) } }
    fun seriesMenu(s: Series) { sheet = s.title to listOf(
        SheetItem("Open", Icons.Filled.PlayArrow) { nav.open(Overlay.SeriesDetail(s)) },
        SheetItem("Watch privately", Icons.Filled.VisibilityOff) { c.appScope.launch { c.playSeries(s, privately = true); kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { if (nav.top != Overlay.Player) nav.open(Overlay.Player) } } },
        SheetItem(if (s.id in favIds) "Remove from favorites" else "Add to favorites", Icons.Filled.Favorite) { vm.setFavorite(s.id, ContentKind.SERIES, s.id !in favIds) },
        SheetItem("Watch later", Icons.Filled.Bookmark) { vm.toggleWatchLater(s.id, ContentKind.SERIES) },
    ) + queueItems(c, s.id, ContentKind.SERIES, s.title) + favoriteOrderItems(s.id in favIds) { front -> vm.moveFavorite(s.id, ContentKind.SERIES, front) } }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            item { OfflineCard(c, nav) }
            item { NowPlayingStrip(c, nav) }
            item {
                PhoneTopBar("Home", leading = { RoundTap(Icons.Filled.Layers, "Libraries") { c.library.close(); nav.toChooser() } }) { RoundTap(Icons.Filled.Search, "Search") { nav.openSearch() } }
            }
            item {
                PhoneBanner(banner,
                    onPrimary = { b -> vm.playableFor(b.id)?.let { p -> if (p is SeriesFeature) nav.open(Overlay.SeriesDetail(p.series)) else play(c, nav, p) } },
                    onDetails = { b -> when (val p = vm.playableFor(b.id)) { is SeriesFeature -> nav.open(Overlay.SeriesDetail(p.series)); is MoviePlayable -> nav.open(Overlay.MovieDetail(p.movie)); else -> {} } })
            }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(vm.shortcutOrder.distinct(), key = { it }) { id ->
                        val (label, icon) = when (id) {
                            "favorites" -> "Favorites" to Icons.Filled.Favorite
                            "later" -> "Watch Later" to Icons.Filled.Bookmark
                            "recent" -> "Recently Watched" to Icons.Filled.History
                            else -> "Continue Watching" to Icons.Filled.PlayArrow
                        }
                        Chip(label, false, { nav.open(Overlay.Collection(id)) }, icon = icon)
                    }
                }
            }
            if (resume.isNotEmpty()) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Continue Watching", action = "See all", onAction = { nav.open(Overlay.Collection("continue")) })
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(resume, key = { "c" + it.playable.id }) { r ->
                            PhoneWide(r.playable.title, r.subtitle, r.playable.artworkUrl, { play(c, nav, r.playable) }, Modifier.width(240.dp), progress = if (r.isNew) 0f else r.progress.fraction, badge = if (r.isNew) "NEW" else null,
                                onLong = { sheet = r.playable.title to listOf(SheetItem("Play", Icons.Filled.PlayArrow) { play(c, nav, r.playable) }, SheetItem("Remove from Continue Watching", Icons.Filled.Close) { vm.removeFromContinue(r.playable.id) }) })
                        }
                    }
                }
            }
            if (tonight.isNotEmpty()) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Tonight on your channels")
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(tonight, key = { "t" + it.channel.id }) { l -> ChannelTile(l.channel, l.now, onLong = { sheet = l.channel.name to listOf(SheetItem("Watch privately", Icons.Filled.VisibilityOff) { play(c, nav, ChannelPlayable(l.channel), tonight.map { ChannelPlayable(it.channel) }, privately = true) }) }) { play(c, nav, ChannelPlayable(l.channel), tonight.map { ChannelPlayable(it.channel) }) } }
                    }
                }
            }
            if (live.isNotEmpty()) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Recently Watched Channels")
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(live, key = { "l" + it.channel.id }) { l -> ChannelTile(l.channel, l.now, onLong = { sheet = l.channel.name to listOf(SheetItem("Watch privately", Icons.Filled.VisibilityOff) { play(c, nav, ChannelPlayable(l.channel), live.map { ChannelPlayable(it.channel) }, privately = true) }) }) { play(c, nav, ChannelPlayable(l.channel), live.map { ChannelPlayable(it.channel) }) } }
                    }
                }
            }
            if (favs.isNotEmpty()) item { Rail("Favorites", favs, c, nav, onMovie = ::movieMenu, onSeries = ::seriesMenu) { nav.open(Overlay.Collection("favorites")) } }
            if (later.isNotEmpty()) item { Rail("Watch Later", later, c, nav, onMovie = ::movieMenu, onSeries = ::seriesMenu) { nav.open(Overlay.Collection("later")) } }
            moreWith?.let { mw -> item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("More with ${mw.name}")
                    Label("You watched ${mw.titles} of their titles lately", Ph.small, Tokens.textSecondary, modifier = Modifier.padding(horizontal = Ph.gutter))
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(mw.items, key = { "mw" + it.kind() + it.id }) { f ->
                            when (f) {
                                is FavItem.Mv -> PhonePoster(f.movie.title, f.movie.posterUrl, { nav.open(Overlay.MovieDetail(f.movie)) }, Modifier.width(112.dp), itemId = f.movie.id, subtitle = f.movie.year?.toString())
                                is FavItem.Sr -> PhonePoster(f.series.title, f.series.posterUrl, { nav.open(Overlay.SeriesDetail(f.series)) }, Modifier.width(112.dp), itemId = f.series.id, subtitle = f.series.year?.toString())
                                is FavItem.Ch -> {}
                            }
                        }
                    }
                }
            } }
            forYou?.let { fy -> item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("For You")
                    Label("Because you watched ${fy.because}", Ph.small, Tokens.textSecondary, modifier = Modifier.padding(horizontal = Ph.gutter))
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(fy.items, key = { "y" + it.kind() + it.id }) { f ->
                            when (f) {
                                is FavItem.Mv -> PhonePoster(f.movie.title, f.movie.posterUrl, { nav.open(Overlay.MovieDetail(f.movie)) }, Modifier.width(112.dp), itemId = f.movie.id, subtitle = f.movie.year?.toString())
                                is FavItem.Sr -> PhonePoster(f.series.title, f.series.posterUrl, { nav.open(Overlay.SeriesDetail(f.series)) }, Modifier.width(112.dp), itemId = f.series.id, subtitle = f.series.year?.toString())
                                is FavItem.Ch -> {}
                            }
                        }
                    }
                }
            } }
            if (movies.isNotEmpty()) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Recently Added Movies", action = "See all", onAction = { nav.tab = Tab.MOVIES })
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(movies, key = { "m" + it.id }) { m -> PhonePoster(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, Modifier.width(112.dp), itemId = m.id, subtitle = m.year?.toString(), badge = if (m.id in favIds) "♥" else ratingBadge(m.rating), onLong = { movieMenu(m) }) }
                    }
                }
            }
            if (series.isNotEmpty()) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Recently Added Series", action = "See all", onAction = { nav.tab = Tab.SERIES })
                    LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(series, key = { "s" + it.id }) { s -> PhonePoster(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, Modifier.width(112.dp), itemId = s.id, subtitle = s.year?.toString(), badge = if (s.id in favIds) "♥" else ratingBadge(s.rating), onLong = { seriesMenu(s) }) }
                    }
                }
            }
            if (banner.isEmpty() && resume.isEmpty() && live.isEmpty() && favs.isEmpty() && movies.isEmpty() && series.isEmpty()) item {
                Empty("Nothing to show yet", "This library has no content on this phone yet. Open Libraries and refresh it.")
            }
        }
        sheet?.let { (t, items) -> Sheet(t, items, onClose = { sheet = null }) }
    }
}

@Composable
private fun Rail(title: String, items: List<FavItem>, c: AppContainer, nav: Navigator, onMovie: (Movie) -> Unit, onSeries: (Series) -> Unit, onAll: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionHeader(title, action = "See all", onAction = onAll)
        LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(items, key = { it.kind() + it.id }) { f ->
                when (f) {
                    is FavItem.Mv -> PhonePoster(f.movie.title, f.movie.posterUrl, { nav.open(Overlay.MovieDetail(f.movie)) }, Modifier.width(112.dp), itemId = f.movie.id, subtitle = f.movie.year?.toString(), badge = ratingBadge(f.movie.rating), onLong = { onMovie(f.movie) })
                    is FavItem.Sr -> PhonePoster(f.series.title, f.series.posterUrl, { nav.open(Overlay.SeriesDetail(f.series)) }, Modifier.width(112.dp), itemId = f.series.id, subtitle = f.series.year?.toString(), badge = ratingBadge(f.series.rating), onLong = { onSeries(f.series) })
                    is FavItem.Ch -> ChannelTile(f.channel, null) { play(c, nav, ChannelPlayable(f.channel)) }
                }
            }
        }
    }
}

/** A channel tile: its logo, name, and what is on. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun ChannelTile(ch: app.streamsetu.core.model.Channel, now: String?, onLong: (() -> Unit)? = null, onClick: () -> Unit) {
    Column(Modifier.width(112.dp).clip(RoundedCornerShape(12.dp)).background(Tokens.card).combinedClickable(onClick = onClick, onLongClick = onLong).padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ChannelLogo(ch.logoUrl, ch.name, 56.dp)
        Label(ch.name, Ph.caption, Tokens.text, FontWeight.Medium)
        if (now != null) Label(now, 11.sp, Tokens.textTertiary)
    }
}

/** "Play next", "Add to queue" or "Remove from queue" for a movie or series in a long-press sheet. */
internal fun queueItems(c: AppContainer, id: String, kind: ContentKind, title: String): List<SheetItem> =
    if (c.watchQueue.contains(id)) listOf(SheetItem("Remove from queue", Icons.Filled.Close) { c.watchQueue.remove(id) })
    else listOf(
        SheetItem("Play next", Icons.Filled.SkipNext) { c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(kind, id, title), next = true) },
        SheetItem("Add to queue", Icons.Filled.Add) { c.watchQueue.add(app.streamsetu.core.data.repo.QueuedTitle(kind, id, title)) })

/** "Move to front" and "Move to end" for a favourite, so the order of the favourites is the person's own. */
internal fun favoriteOrderItems(isFavorite: Boolean, move: (front: Boolean) -> Unit): List<SheetItem> =
    if (!isFavorite) emptyList() else listOf(
        SheetItem("Move to front of favorites", Icons.Filled.ArrowUpward) { move(true) },
        SheetItem("Move to end of favorites", Icons.Filled.ArrowDownward) { move(false) })

/** At the top of Home when there is no connection: says so and offers what plays without one, the saved downloads. */
@Composable
private fun OfflineCard(c: AppContainer, nav: Navigator) {
    val online by c.online.collectAsStateWithLifecycle()
    val saved by c.downloads.items.collectAsStateWithLifecycle()
    androidx.compose.animation.AnimatedVisibility(!online) {
        val done = saved.filter { it.state == app.streamsetu.core.data.repo.SaveState.DONE }
        Column(Modifier.fillMaxWidth().padding(horizontal = Ph.gutter).background(Tokens.surface, RoundedCornerShape(14.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label("You're offline", Ph.body, Tokens.text, FontWeight.SemiBold)
            if (done.isEmpty()) Label("Nothing is saved for offline viewing yet. Choose Download on a movie or an episode while you are online.", Ph.small, Tokens.textSecondary)
            else {
                Label("These are saved on this device and play without a connection.", Ph.small, Tokens.textSecondary)
                done.forEach { t -> Chip(t.title, false, { app.streamsetu.tv.playSaved(c, nav, t) }, icon = Icons.Filled.PlayArrow) }
            }
        }
    }
}

/** On Home: what your other devices are playing right now, with a button to carry on here. */
@Composable
private fun NowPlayingStrip(c: AppContainer, nav: Navigator) {
    val all by c.nowBoard.entries.collectAsStateWithLifecycle()
    var tick by remember { mutableStateOf(System.currentTimeMillis()) }
    app.streamsetu.tv.ui.components.PollWhileShown(30_000) { tick = System.currentTimeMillis() }          // only while the app is on screen
    val entries = remember(all, tick) { c.nowBoard.current(tick) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Ph.gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        entries.forEach { e ->
            Row(Modifier.fillMaxWidth().background(Tokens.surface, RoundedCornerShape(14.dp)).padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f)) {
                    Label(e.title, Ph.body, Tokens.text, FontWeight.Medium, maxLines = 1)
                    Label("Playing on ${e.deviceName}", Ph.small, Tokens.textSecondary, maxLines = 1)
                }
                Chip("Play here", false, { c.takeOver(e, nav) }, icon = Icons.Filled.PlayArrow)
            }
        }
    }
}
