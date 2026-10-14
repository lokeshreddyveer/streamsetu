package app.streamsetu.tv.ui.screens.home

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.section.ratingBadge
import app.streamsetu.tv.ui.theme.Tokens

/**
 * Home: a compact header, a featured banner (about 40 % of the height, real titles from the library), then rows. A row with nothing in it is not drawn.
 * The order of the rows is the person's (Settings, Favorites and History).
 */
@Composable
fun HomeScreen(vm: HomeViewModel, c: AppContainer, nav: Navigator) {
    val libraryName by vm.libraryName.collectAsState()
    val libraryOk by vm.libraryOk.collectAsState()
    val banner by vm.banner.collectAsState()
    val resume by vm.continueWatching.collectAsState()
    val live by vm.recentLive.collectAsState()
    val favs by vm.favourites.collectAsState()
    val later by vm.watchLater.collectAsState()
    val laterIds by vm.watchLaterIds.collectAsState()
    val movies by vm.recentMovies.collectAsState()
    val series by vm.recentSeries.collectAsState()
    val cats by vm.categories.collectAsState()
    val bannerOn by c.ui.bannerEnabled.collectAsState()
    val entry = LocalContentEntry.current
    val pad = PaddingValues(horizontal = Tokens.safeHorizontal, vertical = 4.dp)

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item(key = "header") { HomeHeader(libraryName, libraryOk, nav, c) }
        if (bannerOn && banner.isNotEmpty()) item(key = "banner") {
            FeaturedBanner(
                banner, 200.dp, primaryEntry = entry, startPadding = Tokens.safeHorizontal, intervalSeconds = c.ui.bannerSeconds.collectAsState().value,
                onPrimary = { b -> vm.playableFor(b.id)?.let { p -> if (p is SeriesFeature) nav.open(Overlay.SeriesDetail(p.series)) else play(c, nav, p) } },
                onDetails = { b -> when (val p = vm.playableFor(b.id)) { is SeriesFeature -> nav.open(Overlay.SeriesDetail(p.series)); is MoviePlayable -> nav.open(Overlay.MovieDetail(p.movie)); else -> {} } },
                isListed = { b -> b.id in laterIds }, onToggleListed = { b -> vm.toggleWatchLater(b.id, if (vm.playableFor(b.id) is SeriesFeature) ContentKind.SERIES else ContentKind.MOVIE) },
            )
        }
        vm.order.forEach { id ->
            when (id) {
                "continue" -> if (resume.isNotEmpty()) rail("Continue Watching", pad) { items(resume, key = { it.playable.id }) { r ->
                    LandscapeCard(r.playable.title, r.subtitle, r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = if (r.isNew) 0f else r.progress.fraction, badge = if (r.isNew) "NEW" else null)
                } }
                "live" -> if (live.isNotEmpty()) rail("Recently Watched Live TV", pad) { items(live, key = { it.channel.id }) { l -> ChannelCard(l.channel, l.now) { play(c, nav, ChannelPlayable(l.channel), live.map { ChannelPlayable(it.channel) }) } } }
                "favorites" -> if (favs.isNotEmpty()) rail("Favorites", pad) { items(favs, key = { it.id }) { f -> FavCard(f, c, nav) { ch -> play(c, nav, ChannelPlayable(ch)) } } }
                "later" -> if (later.isNotEmpty()) rail("Watch Later", pad) { items(later, key = { it.id }) { f -> FavCard(f, c, nav) {} } }
                "movies" -> if (movies.isNotEmpty()) rail("Recently Added Movies", pad) { items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { nav.open(Overlay.MovieDetail(m)) }, subtitle = m.year?.toString(), badge = ratingBadge(m.rating)) } }
                "series" -> if (series.isNotEmpty()) rail("Recently Added Series", pad) { items(series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }, subtitle = s.year?.toString(), badge = ratingBadge(s.rating)) } }
                "categories" -> if (cats.isNotEmpty()) rail("Browse by Category", pad) { items(cats, key = { "${it.kind}${it.folder.id}" }) { t -> CategoryCard(t) { nav.openFolder(t.kind, t.folder.id) } } }
            }
        }
        if (banner.isEmpty() && resume.isEmpty() && live.isEmpty() && favs.isEmpty() && movies.isEmpty() && series.isEmpty()) item(key = "empty") {
            Box(Modifier.fillMaxWidth().height(260.dp), Alignment.Center) { Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Label("Nothing to show yet", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label("Open Movies, Series or Live TV from the sidebar to start browsing.", Tokens.body, Tokens.textSecondary)
            } }
        }
    }
}

private fun LazyListScope.rail(title: String, pad: PaddingValues, content: LazyListScope.() -> Unit) {
    item(key = "rail:$title") {
        Column {
            Label(title, Tokens.heading, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(start = Tokens.safeHorizontal, top = 6.dp, bottom = 2.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = pad, content = content)
        }
    }
}

@Composable
private fun HomeHeader(library: String, ok: Boolean, nav: Navigator, c: AppContainer) {
    Row(Modifier.fillMaxWidth().padding(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(30.dp).clip(RoundedCornerShape(7.dp)))
        Spacer(Modifier.width(8.dp))
        Label("StreamSetu", Tokens.title, Tokens.text, FontWeight.Bold)
        Label("  ·  $library", Tokens.body, Tokens.textSecondary)
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            HeaderIcon(Icons.Filled.Search, "Search") { nav.go(Tab.SEARCH) }
            HeaderIcon(Icons.Filled.Layers, "Switch library") { c.library.close(); c.folders.lockAgain(); nav.toChooser() }
            Box(Modifier.size(8.dp).background(if (ok) Tokens.success else Tokens.warning, RoundedCornerShape(50)))
            HeaderIcon(Icons.Filled.Settings, "Settings") { nav.go(Tab.SETTINGS) }
        }
    }
}

@Composable
private fun HeaderIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.06f) { f ->
        Image(icon, label, Modifier.padding(8.dp).size(16.dp), colorFilter = ColorFilter.tint(if (f) Tokens.accent else Tokens.textSecondary))
    }
}

@Composable
fun ChannelCard(ch: Channel, now: String?, onClick: () -> Unit) {
    Focusable(onClick, Modifier.width(150.dp), scaleOnFocus = 1.03f) { _ ->
        Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChannelLogo(ch.logoUrl, ch.name, 34.dp)
                Label(ch.name, Tokens.small, Tokens.text, FontWeight.SemiBold, maxLines = 2, modifier = Modifier.weight(1f))
            }
            Label(now ?: "Live", Tokens.caption, if (now != null) Tokens.textSecondary else Tokens.accent)
        }
    }
}

@Composable
private fun FavCard(f: FavItem, c: AppContainer, nav: Navigator, onChannel: (Channel) -> Unit) {
    when (f) {
        is FavItem.Ch -> ChannelCard(f.channel, null) { onChannel(f.channel) }
        is FavItem.Mv -> PosterCard(f.movie.title, f.movie.posterUrl, { nav.open(Overlay.MovieDetail(f.movie)) }, subtitle = f.movie.year?.toString(), badge = ratingBadge(f.movie.rating))
        is FavItem.Sr -> PosterCard(f.series.title, f.series.posterUrl, { nav.open(Overlay.SeriesDetail(f.series)) }, subtitle = f.series.year?.toString(), badge = ratingBadge(f.series.rating))
    }
}

@Composable
private fun CategoryCard(t: CategoryTile, onClick: () -> Unit) {
    Focusable(onClick, Modifier.width(150.dp).height(70.dp), scaleOnFocus = 1.03f) { _ ->
        Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
            Eyebrow(if (t.kind == ContentKind.MOVIE) "Movies" else "Series", color = Tokens.accent)
            Label(t.folder.title, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 2)
            Label("%,d titles".format(t.folder.count), Tokens.caption, Tokens.textTertiary)
        }
    }
}
