package app.streamsetu.tv.ui.screens.home

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.runtime.*
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
fun HomeCollectionScreen(id: String, c: AppContainer, nav: Navigator, vm: HomeViewModel = hiltViewModel()) {
    val favs by vm.favourites.collectAsState(); val later by vm.watchLater.collectAsState(); val recent by vm.recentWatched.collectAsState(); val resume by vm.continueWatching.collectAsState()
    var menuTarget by remember { mutableStateOf<HomeTarget?>(null) }
    var menuRow by remember { mutableStateOf(RowKind.OTHER) }
    val title = when (id) { "favorites" -> "Favorites"; "later" -> "Watch Later"; "recent" -> "Recently Watched"; else -> "Continue Watching" }
    val first = remember { FocusRequester() }
    LaunchedEffect(id) { delay(150); runCatching { first.requestFocus() } }
    fun longOn(t: HomeTarget, r: RowKind) { menuTarget = t; menuRow = r }
    val row = when (id) { "favorites" -> RowKind.FAVORITES; "later" -> RowKind.WATCH_LATER; else -> RowKind.OTHER }
    val all: List<FavItem> = when (id) { "favorites" -> favs; "later" -> later; "recent" -> recent; else -> emptyList() }
    // Favorites, Watch Later and Recently Watched can be narrowed to one kind: channels, movies or series.
    var only by remember(id) { mutableStateOf<String?>(null) }
    val items: List<FavItem> = if (only == null) all else all.filter { it.kind() == only }
    // After a removal the remote goes to the nearest item that is left, never to the top of the grid.
    var focusedAt by remember { mutableIntStateOf(0) }
    var lastSize by remember { mutableIntStateOf(items.size) }
    val neighbour = remember { FocusRequester() }
    LaunchedEffect(items.size) {
        if (items.size < lastSize && items.isNotEmpty()) { delay(200); runCatching { neighbour.requestFocus() } }
        lastSize = items.size
    }
    androidx.compose.runtime.CompositionLocalProvider(LocalFocusRing provides androidx.compose.ui.graphics.Color.Unspecified) {
        Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
            Label(title, Tokens.display, Tokens.text, FontWeight.Bold)
            Label(if (id == "continue") "%,d titles".format(resume.size) else "%,d items".format(items.size), Tokens.small, Tokens.textSecondary, modifier = Modifier.padding(bottom = 10.dp))
            if (id != "continue") Row(Modifier.padding(bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf<Pair<String?, String>>(null to "All", "c" to "Live Channels", "m" to "Movies", "s" to "Series").forEach { (k, label) ->
                    val on = only == k
                    Focusable({ only = k }, (if (k == null) Modifier.focusRequester(first) else Modifier), shape = androidx.compose.foundation.shape.RoundedCornerShape(Tokens.radius), container = if (on) androidx.compose.ui.graphics.Color(0xFFE9ECF0) else Tokens.card,
                        focusedContainer = if (on) androidx.compose.ui.graphics.Color.White else Tokens.focusedSurface, scaleOnFocus = 1.04f) { _ ->
                        Label(label, Tokens.row, if (on) Tokens.onBright else Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    }
                }
            }
            val empty = if (id == "continue") resume.isEmpty() else items.isEmpty()
            if (empty) Box(Modifier.fillMaxSize(), Alignment.Center) { Label(when (id) { "favorites" -> "No favorites yet. Hold OK on any title or channel to add one."; "later" -> "Nothing saved for later."; "recent" -> "Nothing watched yet."; else -> "Nothing to continue." }, Tokens.body, Tokens.textSecondary) }
            else LazyVerticalGrid(GridCells.Adaptive(if (id == "continue") 220.dp else 130.dp), Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (id == "continue") items(resume, key = { "c" + it.playable.id }) { r ->
                    val t: HomeTarget? = when (val p = r.playable) { is app.streamsetu.core.model.MoviePlayable -> HomeTarget.Film(p.movie); is EpisodePlayable -> HomeTarget.Episode(p.series, p); else -> null }
                    LandscapeCard(r.playable.title, r.subtitle, r.playable.artworkUrl, { play(c, nav, r.playable) }, progress = if (r.isNew) 0f else r.progress.fraction, badge = if (r.isNew) "NEW" else null, width = 220.dp, onLongClick = t?.let { { longOn(it, RowKind.CONTINUE) } })
                } else itemsIndexed(items, key = { _, it -> it.id }) { i, f ->
                    Box(Modifier.animateItem().then(if (i == focusedAt.coerceAtMost(items.lastIndex)) Modifier.focusRequester(neighbour) else Modifier).onFocusChanged { if (it.hasFocus) focusedAt = i }) { FavCard(f, c, nav, row, ::longOn) }
                }
            }
        }
        HomeMenuHost(menuTarget, menuRow, vm, c, nav) { menuTarget = null }
    }
}
