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
import app.streamsetu.core.data.repo.SearchResults
import app.streamsetu.core.data.repo.SearchScope
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.section.Card
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/**
 * The search box and its results, shared by the global Search page and the Movies / Series search. Typing waits a moment (so each letter does not start a search),
 * and a newer text cancels the older search. Results come from the local index, so it works offline.
 */
@Composable
fun SearchContent(
    c: AppContainer, kinds: Set<ContentKind>, modifier: Modifier = Modifier,
    onChannel: (Channel) -> Unit, onMovie: (Movie) -> Unit, onSeries: (Series) -> Unit, entry: FocusRequester? = null,
) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<SearchResults?>(null) }
    var suggestions by remember { mutableStateOf<List<String>>(emptyList()) }
    var typeFilter by remember { mutableStateOf<ContentKind?>(null) }
    val recent by c.search.recent.collectAsState()
    val scopeKinds = typeFilter?.let { setOf(it) } ?: kinds

    LaunchedEffect(query, scopeKinds) {
        if (query.trim().length < 2) { results = null; suggestions = emptyList(); return@LaunchedEffect }
        delay(130)
        results = c.search.search(query, SearchScope(kinds = scopeKinds))
        suggestions = c.search.suggestions(query)
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TvTextField(query, { query = it }, "Search " + when { kinds.size == 1 && ContentKind.MOVIE in kinds -> "movies"; kinds.size == 1 && ContentKind.SERIES in kinds -> "series"; kinds.size == 1 -> "channels"; else -> "channels, movies and series" }, Modifier.widthIn(max = 640.dp).fillMaxWidth().then(if (entry != null) Modifier.focusRequester(entry) else Modifier))
        if (kinds.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            TypeChip("All", typeFilter == null) { typeFilter = null }
            if (ContentKind.CHANNEL in kinds) TypeChip("Live TV", typeFilter == ContentKind.CHANNEL) { typeFilter = ContentKind.CHANNEL }
            if (ContentKind.MOVIE in kinds) TypeChip("Movies", typeFilter == ContentKind.MOVIE) { typeFilter = ContentKind.MOVIE }
            if (ContentKind.SERIES in kinds) TypeChip("Series", typeFilter == ContentKind.SERIES) { typeFilter = ContentKind.SERIES }
        }
        val r = results
        when {
            query.trim().length < 2 -> LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (recent.isNotEmpty()) {
                    item { Eyebrow("Recent searches", Modifier.padding(vertical = 4.dp)) }
                    items(recent, key = { "r$it" }) { q -> SuggestionRow(q, Icons.Filled.History) { query = q } }
                    item { TvButton("Clear history", { c.search.clearHistory() }, Modifier.padding(top = 6.dp), icon = Icons.Filled.Delete) }
                } else item { Label("Type at least two letters. Search works offline, on what is already in your library.", Tokens.body, Tokens.textSecondary, maxLines = 2) }
            }
            r == null -> Loading(Modifier.height(100.dp))
            r.isEmpty -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Label("No matches for “${query.trim()}”", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label("Check the spelling, or try fewer words.", Tokens.body, Tokens.textSecondary)
            }
            else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 30.dp)) {
                if (suggestions.size > 1) item { LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) { items(suggestions.take(5), key = { "s$it" }) { s -> TypeChip(s, false) { query = s } } } }
                if (r.channels.isNotEmpty()) { item { SectionTitle("Live TV  ·  ${r.channels.size}") }; item { LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(r.channels, key = { it.id }) { ch -> ChannelCardSmall(ch) { c.search.remember(query); onChannel(ch) } } } } }
                if (r.movies.isNotEmpty()) { item { SectionTitle("Movies  ·  ${r.movies.size}") }; item { LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) { items(r.movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { c.search.remember(query); onMovie(m) }, subtitle = m.year?.toString()) } } } }
                if (r.series.isNotEmpty()) { item { SectionTitle("Series  ·  ${r.series.size}") }; item { LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) { items(r.series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { c.search.remember(query); onSeries(s) }, subtitle = s.year?.toString()) } } } }
            }
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
private fun ChannelCardSmall(ch: Channel, onClick: () -> Unit) = Focusable(onClick, Modifier.width(150.dp), scaleOnFocus = 1.03f) { _ ->
    Column(Modifier.padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ChannelLogo(ch.logoUrl, ch.name, 40.dp); Label(ch.name, Tokens.small, Tokens.text, maxLines = 2)
    }
}

/** Search inside Movies or Series: movies only, or series only. */
@Composable
fun SectionSearch(c: AppContainer, kind: ContentKind, onOpen: (Card) -> Unit, onClose: () -> Unit) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(120); runCatching { first.requestFocus() } }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Tokens.background).padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label(if (kind == ContentKind.MOVIE) "Search Movies" else "Search Series", Tokens.display, Tokens.text, FontWeight.Bold)
                SearchContent(c, setOf(kind), Modifier.fillMaxSize(), entry = first,
                    onChannel = {}, onMovie = { m -> onOpen(Card(m.id, m.title, m.posterUrl, m.year, m.rating, m.sourceId, movie = m)) }, onSeries = { s -> onOpen(Card(s.id, s.title, s.posterUrl, s.year, s.rating, s.sourceId, series = s)) })
            }
        }
    }
}
