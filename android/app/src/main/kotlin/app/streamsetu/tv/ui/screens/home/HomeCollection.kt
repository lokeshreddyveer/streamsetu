package app.streamsetu.tv.ui.screens.home

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/** The full list behind a Home shortcut (Favorites, Watch Later, Recently Watched, Continue Watching), with the same long-press menu as the rows. */
@Composable
fun HomeCollectionScreen(id: String, c: AppContainer, nav: Navigator, initialOnly: String? = null, vm: HomeViewModel = hiltViewModel()) {
    val favs by vm.favourites.collectAsState(); val later by vm.watchLater.collectAsState(); val recent by vm.recentWatched.collectAsState(); val resume by vm.continueWatching.collectAsState()
    var menuTarget by remember { mutableStateOf<HomeTarget?>(null) }
    var menuRow by remember { mutableStateOf(RowKind.OTHER) }
    val title = when (id) { "favorites" -> "Favorites"; "later" -> "Watch Later"; "recent" -> "Recently Watched"; else -> "Continue Watching" }
    val first = remember { FocusRequester() }
    LaunchedEffect(id) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
    fun longOn(t: HomeTarget, r: RowKind) { menuTarget = t; menuRow = r }
    val row = when (id) { "favorites" -> RowKind.FAVORITES; "later" -> RowKind.WATCH_LATER; else -> RowKind.OTHER }
    val all: List<FavItem> = when (id) { "favorites" -> favs; "later" -> later; "recent" -> recent; else -> emptyList() }
    // Favorites, Watch Later and Recently Watched can be narrowed to one kind: channels, movies or series.
    var only by remember(id) { mutableStateOf<String?>(initialOnly) }
    val items: List<FavItem> = if (only == null) all else all.filter { it.kind() == only }
    // After a removal the remote goes to the nearest item that is left, never to the top of the grid.
    var focusedAt by remember { mutableIntStateOf(0) }
    var lastSize by remember { mutableIntStateOf(items.size) }
    val neighbour = remember { FocusRequester() }
    LaunchedEffect(items.size) {
        if (items.size < lastSize && items.isNotEmpty()) { app.streamsetu.tv.ui.components.requestFocusSoon(neighbour, 8) }
        lastSize = items.size
    }
    androidx.compose.runtime.CompositionLocalProvider(LocalFocusRing provides androidx.compose.ui.graphics.Color.Unspecified) {
        // A compact sheet from the bottom edge over Home: the dimming fades in on its own and only the sheet slides, so no dark layer ever moves across the screen.
        val reducedMotion = app.streamsetu.core.ui.motion.LocalReducedMotion.current
        var sheetShown by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { sheetShown = true }
        val sheetIn by androidx.compose.animation.core.animateFloatAsState(if (sheetShown) 1f else 0f, if (reducedMotion) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(220, easing = app.streamsetu.core.ui.motion.Motion.Standard), label = "sheetIn")
        Box(Modifier.fillMaxSize().drawBehind { drawRect(androidx.compose.ui.graphics.Brush.verticalGradient(0.35f to androidx.compose.ui.graphics.Color.Transparent, 1f to Tokens.background.copy(alpha = 0.85f)), alpha = sheetIn) }, Alignment.BottomCenter) {
        Column(Modifier.padding(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, bottom = 24.dp).fillMaxWidth().graphicsLayer { translationY = (1f - sheetIn) * (size.height + 48.dp.toPx()) }.background(Tokens.elevated.copy(alpha = 0.95f), androidx.compose.foundation.shape.RoundedCornerShape(24.dp)).border(1.dp, Tokens.line, androidx.compose.foundation.shape.RoundedCornerShape(24.dp)).padding(horizontal = 24.dp, vertical = 20.dp)) {
            Row(Modifier.padding(bottom = 10.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Label(title, Tokens.pageTitle, Tokens.text, FontWeight.Bold)
            }
            if (id != "continue") Row(Modifier.padding(bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf<Pair<String?, String>>(null to "All", "c" to "Live Channels", "m" to "Movies", "s" to "Series").forEach { (k, label) ->
                    val on = only == k
                    Focusable({ only = k }, (if (k == null) Modifier.focusRequester(first) else Modifier), shape = androidx.compose.foundation.shape.RoundedCornerShape(50), container = if (on) androidx.compose.ui.graphics.Color(0xFFE9ECF0) else androidx.compose.ui.graphics.Color(0x26FFFFFF),
                        focusedContainer = androidx.compose.ui.graphics.Color.White, scaleOnFocus = 1.05f, showRing = false, ringBand = false) { f ->
                        Label(label, Tokens.small, if (on || f) Tokens.onBright else Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                    }
                }
            }
            val empty = if (id == "continue") resume.isEmpty() else items.isEmpty()
            if (empty) Box(Modifier.fillMaxWidth().height(110.dp), Alignment.CenterStart) { Label(when (id) { "favorites" -> "No favorites yet. Hold OK on any title or channel to add one."; "later" -> "Nothing saved for later."; "recent" -> "Nothing watched yet."; else -> "Nothing to continue." }, Tokens.body, Tokens.textSecondary) }
            else LazyRow(Modifier.fillMaxWidth().bleedStart(14.dp), contentPadding = PaddingValues(start = 14.dp, end = 24.dp, top = 8.dp, bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (id == "continue") items(resume, key = { "c" + it.playable.id }) { r ->
                    val t: HomeTarget? = when (val p = r.playable) { is app.streamsetu.core.model.MoviePlayable -> HomeTarget.Film(p.movie); is EpisodePlayable -> HomeTarget.Episode(p.series, p); else -> null }
                    LandscapeCard(r.playable.title, r.subtitle, r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = if (r.isNew) 0f else r.progress.fraction, badge = if (r.isNew) "NEW" else null, width = 220.dp, onLongClick = t?.let { { longOn(it, RowKind.CONTINUE) } }, itemId = when (val p = r.playable) { is app.streamsetu.core.model.MoviePlayable -> p.movie.id; is EpisodePlayable -> p.series.id; else -> null })
                } else itemsIndexed(items, key = { _, it -> it.id }) { i, f ->
                    Box(Modifier.then(if (i == focusedAt.coerceAtMost(items.lastIndex)) Modifier.focusRequester(neighbour) else Modifier).onFocusChanged { if (it.hasFocus) focusedAt = i }) { FavCard(f, c, nav, row, ::longOn) }
                }
            }
        }
        }
        HomeMenuHost(menuTarget, menuRow, vm, c, nav) { menuTarget = null }
    }
}
