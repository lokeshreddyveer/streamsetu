package app.streamsetu.tv.ui.screens.search

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.streamsetu.core.data.repo.GlobalResults
import app.streamsetu.core.data.repo.SearchItem
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchTab
import app.streamsetu.core.data.repo.SearchTarget
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.section.Card
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/**
 * The search box and its results, shared by the global Search page and the Movies / Series search. It uses the same engine as the iPhone app: "hindi movies 2024" works,
 * a misspelt word is fixed when nothing matches (and the screen says what it searched for), and the results come in groups (Live TV, Movies, Series, Episodes, TV Guide,
 * Folders, Collections). Typing waits a moment and a newer text cancels the older search. Results come from the local index, so it works offline.
 */
@Composable
fun SearchContent(
    c: AppContainer, kinds: Set<ContentKind>, modifier: Modifier = Modifier,
    onChannel: (Channel) -> Unit, onMovie: (Movie) -> Unit, onSeries: (Series) -> Unit, entry: FocusRequester? = null,
    dropdown: Boolean = false, restore: Boolean = false,
    onEpisode: (Episode, Series) -> Unit = { _, _ -> }, onFolder: (ContentKind, String) -> Unit = { _, _ -> }, onCollection: (String, ContentKind) -> Unit = { _, _ -> },
) {
    var results by remember { mutableStateOf<GlobalResults?>(null) }
    var typeFilter by remember { mutableStateOf<ContentKind?>(null) }
    // Opened from Movies, Series or Live TV: only that kind. Opened from the Search page: everything, with chips to narrow it.
    val tab = when (typeFilter ?: kinds.singleOrNull()) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; ContentKind.SERIES -> SearchTab.SERIES; else -> SearchTab.ALL }
    val scopeKey = (kinds.singleOrNull()?.let { when (it) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; else -> SearchTab.SERIES } } ?: SearchTab.ALL).name
    var query by remember { mutableStateOf(if (restore) c.search.lastIn(scopeKey) else "") }
    var recent by remember { mutableStateOf(c.search.recentIn(scopeKey)) }
    fun remember() { c.search.rememberIn(scopeKey, query); recent = c.search.recentIn(scopeKey) }

    LaunchedEffect(Unit) { c.globalSearch.warmUp() }
    LaunchedEffect(query, tab) {
        if (restore) c.search.setLastIn(scopeKey, query)
        if (query.isBlank()) { results = null; return@LaunchedEffect }
        results = null
        delay(150)
        results = runCatching { c.globalSearch.search(query, tab, if (tab == SearchTab.ALL) 12 else 60) }.getOrDefault(GlobalResults())
    }
    fun open(r: SearchItem) {
        remember()
        when (val t = r.target) {
            is SearchTarget.PlayChannel -> onChannel(t.channel)
            is SearchTarget.PlayProgramme -> onChannel(t.channel)
            is SearchTarget.OpenMovie -> onMovie(t.movie)
            is SearchTarget.OpenSeries -> onSeries(t.series)
            is SearchTarget.PlayEpisode -> onEpisode(t.episode, t.series)
            is SearchTarget.OpenFolder -> onFolder(t.kind, t.folderId)
            is SearchTarget.OpenCollection -> onCollection(t.id, t.kind)
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TvTextField(query, { query = it }, if (tab == SearchTab.ALL) "Search channels, movies, series" else "Search " + tab.label.lowercase(), Modifier.widthIn(max = 520.dp), onDone = { remember() }, leadingIcon = Icons.Filled.Search)
        if (dropdown && kinds.size > 1) {
            var open by remember { mutableStateOf(false) }
            val label = when (typeFilter) { ContentKind.CHANNEL -> "Live TV"; ContentKind.MOVIE -> "Movies"; ContentKind.SERIES -> "Series"; else -> "All" }
            Focusable({ open = true }, Modifier, shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.03f) { _ ->
                Row(Modifier.padding(horizontal = 14.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Label("Search in", Tokens.small, Tokens.textSecondary); Label(label, Tokens.small, Tokens.accent, FontWeight.SemiBold)
                    Image(Icons.Filled.ArrowDropDown, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.textSecondary))
                }
            }
            if (open) ContextMenu("Search in", null, buildList {
                add(MenuAction("All" + if (typeFilter == null) "   ✓" else "", Icons.Filled.Search) { typeFilter = null })
                if (ContentKind.MOVIE in kinds) add(MenuAction("Movies" + if (typeFilter == ContentKind.MOVIE) "   ✓" else "", Icons.Filled.Movie) { typeFilter = ContentKind.MOVIE })
                if (ContentKind.SERIES in kinds) add(MenuAction("Series" + if (typeFilter == ContentKind.SERIES) "   ✓" else "", Icons.Filled.VideoLibrary) { typeFilter = ContentKind.SERIES })
                if (ContentKind.CHANNEL in kinds) add(MenuAction("Live TV" + if (typeFilter == ContentKind.CHANNEL) "   ✓" else "", Icons.Filled.LiveTv) { typeFilter = ContentKind.CHANNEL })
            }, onClose = { open = false })
        } else if (kinds.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            TypeChip("All", typeFilter == null) { typeFilter = null }
            if (ContentKind.CHANNEL in kinds) TypeChip("Live TV", typeFilter == ContentKind.CHANNEL) { typeFilter = ContentKind.CHANNEL }
            if (ContentKind.MOVIE in kinds) TypeChip("Movies", typeFilter == ContentKind.MOVIE) { typeFilter = ContentKind.MOVIE }
            if (ContentKind.SERIES in kinds) TypeChip("Series", typeFilter == ContentKind.SERIES) { typeFilter = ContentKind.SERIES }
        }
        val r = results
        when {
            query.isBlank() -> LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (recent.isNotEmpty()) {
                    item { Eyebrow("Recent searches", Modifier.padding(vertical = 4.dp)) }
                    items(recent, key = { "r$it" }) { q -> SuggestionRow(q, Icons.Filled.History) { query = q } }
                    item { TvButton("Clear history", { c.search.clearIn(scopeKey); recent = emptyList() }, Modifier.padding(top = 6.dp), icon = Icons.Filled.Delete) }
                } else item {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Label(if (tab == SearchTab.ALL) "Search your library" else "Search " + tab.label.lowercase(), Tokens.title, Tokens.text, FontWeight.SemiBold)
                        Label(if (tab == SearchTab.ALL) "Channels, movies, series and episodes from every playlist. Works offline." else "Try a title, or something like \u201chindi movies 2024\u201d.", Tokens.body, Tokens.textSecondary, maxLines = 2)
                    }
                }
            }
            r == null -> Loading(Modifier.height(100.dp))
            r.isEmpty -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Label("No results", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label("Try fewer letters or another spelling.", Tokens.body, Tokens.textSecondary)
            }
            else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 30.dp)) {
                r.correctedTo?.let { fixed -> item { Label("Showing results for \u201c$fixed\u201d instead of \u201c${query.trim()}\u201d.", Tokens.small, Tokens.textSecondary, maxLines = 2) } }
                SearchKind.entries.forEach { kind ->
                    val rows = r.byKind[kind].orEmpty()
                    if (rows.isEmpty()) return@forEach
                    item(key = "t-${kind.name}") { SectionTitle("${kind.title}  ·  ${rows.size}") }
                    when (kind) {
                        SearchKind.CHANNEL -> item { LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(rows, key = { it.id }) { x -> ChannelCardSmall(x) { open(x) } } } }
                        SearchKind.MOVIE, SearchKind.SERIES -> item {
                            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                items(rows, key = { it.id }) { x ->
                                    val rating = (x.target as? SearchTarget.OpenMovie)?.movie?.rating ?: (x.target as? SearchTarget.OpenSeries)?.series?.rating
                                    PosterCard(x.title, x.artworkUrl, { open(x) }, itemId = (x.target as? SearchTarget.OpenMovie)?.movie?.id ?: (x.target as? SearchTarget.OpenSeries)?.series?.id, subtitle = x.subtitle.substringBefore(" · ").ifBlank { null }, badge = app.streamsetu.tv.ui.screens.section.ratingBadge(rating))
                                }
                            }
                        }
                        else -> items(rows, key = { it.id }) { x -> ResultRow(x) { open(x) } }
                    }
                }
            }
        }
    }
}

/** An episode, a programme, a folder or a collection found by search, as one line. */
@Composable
private fun ResultRow(r: SearchItem, onClick: () -> Unit) = Focusable(onClick, Modifier.widthIn(max = 620.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
    Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val icon = when (r.kind) { SearchKind.EPISODE -> Icons.Filled.PlayCircle; SearchKind.PROGRAMME -> Icons.Filled.CalendarMonth; SearchKind.FOLDER -> Icons.Filled.Folder; else -> Icons.Filled.Layers }
        Image(icon, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.accent))
        Column(Modifier.weight(1f)) {
            Label(r.title, Tokens.row, Tokens.text, FontWeight.Medium, maxLines = 1)
            if (r.subtitle.isNotBlank()) Label(r.subtitle, Tokens.caption, Tokens.textSecondary, maxLines = 1)
        }
    }
}

@Composable
private fun TypeChip(label: String, on: Boolean, onClick: () -> Unit) = Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = if (on) Tokens.elevated else Tokens.card, scaleOnFocus = 1.03f) { _ ->
    Label(label, Tokens.small, if (on) Tokens.accent else Tokens.text, if (on) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
}

@Composable
private fun SuggestionRow(text: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) = Focusable(onClick, Modifier.widthIn(max = 420.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
    Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Image(icon, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary)); Label(text, Tokens.row, Tokens.text)
    }
}

@Composable
private fun ChannelCardSmall(x: SearchItem, onClick: () -> Unit) = Focusable(onClick, Modifier.width(150.dp), scaleOnFocus = 1.03f) { _ ->
    Column(Modifier.padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ChannelLogo(x.artworkUrl, x.title, 40.dp); Label(x.title, Tokens.small, Tokens.text, maxLines = 2)
    }
}

/** Search inside Movies or Series: movies only, or series only. */
@Composable
fun SectionSearch(c: AppContainer, kind: ContentKind, onOpen: (Card) -> Unit, onClose: () -> Unit) {
    val scope = when (kind) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; else -> SearchTab.SERIES }.name
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(120); runCatching { first.requestFocus() } }
    Dialog(onDismissRequest = { c.search.setLastIn(scope, ""); onClose() }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Tokens.background).padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label(if (kind == ContentKind.MOVIE) "Search Movies" else "Search Series", Tokens.display, Tokens.text, FontWeight.Bold)
                SearchContent(c, setOf(kind), Modifier.fillMaxSize(), entry = first, restore = true,
                    onChannel = {}, onMovie = { m -> onOpen(Card(m.id, m.title, m.posterUrl, m.year, m.rating, m.sourceId, movie = m)) }, onSeries = { s -> onOpen(Card(s.id, s.title, s.posterUrl, s.year, s.rating, s.sourceId, series = s)) })
            }
        }
    }
}

/** The global Search page: channels, movies and series of the open library. */
@Composable
fun SearchScreen(c: AppContainer, nav: app.streamsetu.tv.nav.Navigator) {
    val entry = app.streamsetu.tv.ui.components.LocalContentEntry.current
    Column(Modifier.fillMaxSize().padding(start = 16.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Label("Search", Tokens.pageTitle, Tokens.text, FontWeight.Bold)
        SearchContent(c, setOf(ContentKind.CHANNEL, ContentKind.MOVIE, ContentKind.SERIES), Modifier.fillMaxSize(), entry = entry,
            onChannel = { ch -> app.streamsetu.tv.play(c, nav, ChannelPlayable(ch)) },
            onMovie = { m -> nav.open(app.streamsetu.tv.nav.Overlay.MovieDetail(m)) },
            onSeries = { s -> nav.open(app.streamsetu.tv.nav.Overlay.SeriesDetail(s)) },
            onEpisode = { e, s -> app.streamsetu.tv.play(c, nav, EpisodePlayable(e, s)) },
            onFolder = { k, id -> nav.openFolderTab(k, id) },
            onCollection = { id, k -> nav.openCollection(k, id) })
    }
}
