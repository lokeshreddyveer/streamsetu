package app.streamsetu.tv.ui.screens.search

import app.streamsetu.tv.ui.theme.ui
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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
import app.streamsetu.core.data.repo.badge
import app.streamsetu.core.data.repo.SearchResultOrder
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
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun SearchContent(
    c: AppContainer, kinds: Set<ContentKind>, modifier: Modifier = Modifier,
    onChannel: (Channel) -> Unit, onMovie: (Movie) -> Unit, onSeries: (Series) -> Unit, entry: FocusRequester? = null,
    dropdown: Boolean = false, restore: Boolean = false,
    /** Keeps the words, scroll position, focused result and AI suggestions while the person goes elsewhere and comes back. The key says whose they are (library, profile, scope). */
    session: app.streamsetu.tv.nav.SearchSession? = null, sessionKey: String = "",
    /** The type to narrow to when the page opens (the section it was opened from); the chips still offer All. A type the person chose before leaving wins. */
    initialType: ContentKind? = null,
    /** What goes between the filters and the results, as rows of the screen's one list (see [rememberSearchActions]). */
    above: @Composable (String, FocusRequester) -> Pair<androidx.compose.foundation.lazy.LazyListScope.() -> Unit, androidx.compose.foundation.lazy.LazyListScope.() -> Unit> = { _, _ -> Pair({ }, { }) },
    onEpisode: (Episode, Series) -> Unit = { _, _ -> }, onFolder: (ContentKind, String) -> Unit = { _, _ -> }, onCollection: (String, ContentKind) -> Unit = { _, _ -> },
) {
    val held = remember { session?.open(sessionKey) }
    var results by remember { mutableStateOf<GlobalResults?>(null) }
    var typeFilter by remember { mutableStateOf<ContentKind?>(if (held?.typeSet == true) held.type else initialType) }
    // Opened from Movies, Series or Live TV: only that kind. Opened from the Search page: everything, with chips to narrow it.
    val tab = when (typeFilter ?: kinds.singleOrNull()) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; ContentKind.SERIES -> SearchTab.SERIES; else -> SearchTab.ALL }
    val scopeKey = (kinds.singleOrNull()?.let { when (it) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; else -> SearchTab.SERIES } } ?: SearchTab.ALL).name
    var query by remember { mutableStateOf(if (restore) c.search.lastIn(scopeKey) else held?.query.orEmpty()) }
    var recent by remember { mutableStateOf(c.search.recentIn(scopeKey)) }
    fun remember() { c.search.rememberIn(scopeKey, query); recent = c.search.recentIn(scopeKey) }

    LaunchedEffect(Unit) { c.globalSearch.warmUp() }
    // A search is not just "results or nothing": the results shown stay while the next ones are looked up (with a small spinner by the field), "No titles found" appears only after a
    // search that worked and found nothing, and a search that failed says so and offers Retry. What went wrong is logged, never shown.
    var searching by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var retryTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(query, tab, retryTick) {
        if (restore) c.search.setLastIn(scopeKey, query)
        if (query.isBlank()) { results = null; searching = false; failed = false; return@LaunchedEffect }
        searching = true; failed = false
        delay(150)
        try {
            results = c.globalSearch.search(query, tab, if (tab == SearchTab.ALL) 12 else 60)
        } catch (e: kotlinx.coroutines.CancellationException) { throw e
        } catch (e: Exception) { android.util.Log.w("Search", "search failed: ${e.javaClass.simpleName}: ${e.message?.take(120)}"); failed = true }
        searching = false
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

    // One vertical list for the whole screen (the field, the filters, what the typed words can do, the AI's matches, then the results), so Up and Down move through one thing and
    // nothing is pushed off the screen by something above it. The rails of posters inside it are horizontal.
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val focusTarget = remember { FocusRequester() }
    val restoreId = remember { held?.focusedId }                        // the result that had the remote when the person left
    var targetId by remember { mutableStateOf(restoreId) }              // the result that [focusTarget] is on: the one to go back to, or the first one after the keyboard closes
    val firstAction = remember { FocusRequester() }                      // the first command, or the Ask AI row
    var doneTick by remember { mutableIntStateOf(0) }
    // The keyboard's Done: the remote goes to the first thing worth acting on, in this order: the result that matches the words exactly, the first result, a command the words make, Ask AI.
    // Ask AI is only focused, never started. With nothing to go to, the remote stays on the field.
    LaunchedEffect(doneTick) {
        if (doneTick == 0) return@LaunchedEffect
        delay(200)
        val first = results?.let { doneResultId(it, query) }
        for (step in doneSteps(first != null)) {
            val requester = if (step == DoneStep.ACTION) firstAction else { targetId = first; delay(120); focusTarget }
            runCatching { requester.requestFocus() }
            delay(80)
            if (app.streamsetu.tv.ui.components.FocusMemory.focused === requester) break
        }
    }
    var settled by remember { mutableStateOf(held == null || (held.query.isBlank() && held.focusedId == null)) }
    LaunchedEffect(query, typeFilter) { held?.query = query; held?.type = typeFilter; held?.typeSet = true }
    // Where the list is scrolled is kept (once what was kept has been put back, so the start of the list does not overwrite it).
    LaunchedEffect(held) { if (held != null) androidx.compose.runtime.snapshotFlow { listState.firstVisibleItemIndex to listState.firstVisibleItemScrollOffset }.collect { (i, o) -> if (settled) { held.scrollIndex = i; held.scrollOffset = o } } }
    // Coming back: the list goes to where it was and the remote to the result it was on, found by its id (the rail that holds it is scrolled to it first). A result that is gone leaves the remote where the page puts it.
    LaunchedEffect(results) {
        val r = results
        if (settled || held == null || r == null) return@LaunchedEffect
        listState.scrollToItem(held.scrollIndex, held.scrollOffset)
        val kind = SearchKind.entries.firstOrNull { k -> r.byKind[k].orEmpty().any { it.id == restoreId } }
        if (kind != null) {
            delay(150); runCatching { focusTarget.requestFocus() }
        }
        settled = true
    }
    val actionRows = if (query.isNotBlank()) above(query, firstAction) else Pair<androidx.compose.foundation.lazy.LazyListScope.() -> Unit, androidx.compose.foundation.lazy.LazyListScope.() -> Unit>({ }, { })
    val aboveItems = actionRows.first            // commands and the Ask AI row, before the results
    val belowItems = actionRows.second           // what the AI suggested, after the results: it never comes before or delays what the app itself found
    LazyColumn(modifier, state = listState, contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // The field stays at the top while the list scrolls under it.
        stickyHeader(key = "search-field") {
        Box(Modifier.fillMaxWidth().background(Tokens.background).padding(bottom = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        TvTextField(query, { query = it; held?.focusedId = null; held?.scrollIndex = 0; held?.scrollOffset = 0 }, if (tab == SearchTab.ALL) "Search channels, movies, series" else "Search " + tab.label.lowercase(), Modifier.widthIn(max = 760.dp).then(if (entry != null) Modifier.focusRequester(entry) else Modifier), onDone = { remember(); doneTick++ }, leadingIcon = Icons.Filled.Search)
        if (searching && results != null) Spinner()
        }
        }
        }
        if (kinds.size > 1) item(key = "type-filters") { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // With larger text four chips would crowd, so the choice becomes one dropdown.
        if ((dropdown || androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.3f) && kinds.size > 1) {
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
        } else if (kinds.size > 1) Row(Modifier.railOnLeft(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TypeChip("All", typeFilter == null) { typeFilter = null }
            if (ContentKind.CHANNEL in kinds) TypeChip("Live TV", typeFilter == ContentKind.CHANNEL) { typeFilter = ContentKind.CHANNEL }
            if (ContentKind.MOVIE in kinds) TypeChip("Movies", typeFilter == ContentKind.MOVIE) { typeFilter = ContentKind.MOVIE }
            if (ContentKind.SERIES in kinds) TypeChip("Series", typeFilter == ContentKind.SERIES) { typeFilter = ContentKind.SERIES }
        } } }
        // A title in the library that is exactly what was typed comes first, ahead of the commands and anything the AI suggested.
        run {
            val r0 = results ?: return@run
            val exact = bestMatchOf(r0, query) ?: return@run
            item(key = "best-match") {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Eyebrow("Best match", Modifier.padding(top = 4.dp))
                    SearchResultRow(exact, if (exact.id == targetId) Modifier.focusRequester(focusTarget) else Modifier, { if (it) held?.focusedId = exact.id }) { open(exact) }
                }
            }
        }
        aboveItems()
        if (failed && query.isNotBlank()) item(key = "search-failed") {
            TvStatusState("Search could not be completed", detail = "Try again in a moment.", icon = Icons.Filled.ErrorOutline, actionLabel = "Retry", onAction = { retryTick++ })
        }
        val r = results
        when {
            query.isBlank() -> {
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
            r == null -> { if (!failed) item(key = "loading") { Loading(Modifier.height(100.dp)) } }
            r.isEmpty -> { if (!searching && !failed) item(key = "no-results") { TvStatusState("No titles found", detail = "Try fewer letters or another spelling.") } }
            else -> {
                if (r.understood.isNotEmpty()) item { Label("Understood as  " + r.understood.joinToString("  \u00b7  "), Tokens.small, Tokens.accent, maxLines = 2) }
                r.correctedTo?.let { fixed -> item { Label("Showing results for \u201c$fixed\u201d instead of \u201c${query.trim()}\u201d.", Tokens.small, Tokens.textSecondary, maxLines = 2) } }
                // The exact match is shown once, as the best match above; it is left out of its group below.
                val best = bestMatchOf(r, query)
                SearchResultOrder.forEach { kind ->
                    val rows = withoutBest(r.byKind[kind].orEmpty(), best)
                    if (rows.isEmpty()) return@forEach
                    item(key = "t-${kind.name}") { SectionTitle("${kind.title}  ·  ${rows.size}") }
                    // Every kind of result is the same row: artwork, a title, one line about it, and what kind it is.
                    items(rows, key = { it.id }) { x -> SearchResultRow(x, (if (x.id == targetId) Modifier.focusRequester(focusTarget) else Modifier), { if (it) held?.focusedId = x.id }) { open(x) } }
                }
            }
        }
        belowItems()
    }
}

/** One search result, whatever it is: 48 dp artwork, a title (two lines at most), one line about it, and its kind on the right. At least 72 dp tall, the same focus frame everywhere. */
@Composable
internal fun SearchResultRow(x: SearchItem, extra: Modifier, onFocus: (Boolean) -> Unit, provenance: String? = null, onOpen: () -> Unit) {
    Focusable(onOpen, extra.onPreviewKeyEvent { e -> e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown && e.key == androidx.compose.ui.input.key.Key.DirectionRight }.fillMaxWidth().widthIn(max = 860.ui).heightIn(min = 90.ui), onFocus = onFocus, shape = RoundedCornerShape(Tokens.radius), container = Tokens.card.copy(alpha = 0.55f), scaleOnFocus = 1.02f) { _ ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(58.ui).clip(RoundedCornerShape(8.dp)).background(Tokens.elevated), Alignment.Center) {
                if (!x.artworkUrl.isNullOrBlank()) coil.compose.AsyncImage(x.artworkUrl, null, Modifier.fillMaxSize(), contentScale = if (x.kind == SearchKind.CHANNEL) androidx.compose.ui.layout.ContentScale.Fit else androidx.compose.ui.layout.ContentScale.Crop)
                else Image(when (x.kind) { SearchKind.CHANNEL -> Icons.Filled.LiveTv; SearchKind.MOVIE -> Icons.Filled.Movie; SearchKind.SERIES -> Icons.Filled.VideoLibrary; SearchKind.EPISODE -> Icons.Filled.PlayCircle; SearchKind.PROGRAMME -> Icons.Filled.CalendarMonth; SearchKind.FOLDER -> Icons.Filled.Folder; SearchKind.COLLECTION -> Icons.Filled.Layers },
                    null, Modifier.size(22.dp), colorFilter = ColorFilter.tint(Tokens.accent))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Label(x.title, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 2)
                if (x.subtitle.isNotBlank()) Label(x.subtitle, Tokens.caption, Tokens.textSecondary, maxLines = 1)
                if (!provenance.isNullOrBlank()) Label(provenance, Tokens.caption, Tokens.textTertiary, maxLines = 1)
            }
            Label(x.kind.badge(), Tokens.caption, Tokens.textTertiary, FontWeight.Bold)
        }
    }
}

@Composable
private fun TypeChip(label: String, on: Boolean, onClick: () -> Unit) = Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = if (on) Color(0xFFE9ECF0) else Tokens.card, focusedContainer = if (on) Color.White else Tokens.focusedSurface, scaleOnFocus = 1.05f, ringWidth = 0.dp) { _ ->
    Label(label, Tokens.row, if (on) Tokens.onBright else Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 18.dp, vertical = 8.dp))
}

@Composable
private fun SuggestionRow(text: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) = Focusable(onClick, Modifier.widthIn(max = 420.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
    Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Image(icon, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary)); Label(text, Tokens.row, Tokens.text)
    }
}


/** Search inside Movies or Series: movies only, or series only. */
@Composable
fun SectionSearch(c: AppContainer, kind: ContentKind, onOpen: (Card) -> Unit, onClose: () -> Unit) {
    val scope = when (kind) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; else -> SearchTab.SERIES }.name
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(120); runCatching { first.requestFocus() } }
    TvDialog(onDismissRequest = { c.search.setLastIn(scope, ""); onClose() }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
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
    Column(Modifier.fillMaxSize().padding(start = Tokens.safeHorizontal + 4.dp, end = Tokens.safeHorizontal, top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Label("Search", Tokens.display, Tokens.text, FontWeight.ExtraBold)
        SearchContent(c, setOf(ContentKind.CHANNEL, ContentKind.MOVIE, ContentKind.SERIES), Modifier.fillMaxSize(), entry = entry,
            onChannel = { ch -> app.streamsetu.tv.play(c, nav, ChannelPlayable(ch)) },
            onMovie = { m -> nav.open(app.streamsetu.tv.nav.Overlay.MovieDetail(m)) },
            onSeries = { s -> nav.open(app.streamsetu.tv.nav.Overlay.SeriesDetail(s)) },
            onEpisode = { e, s -> app.streamsetu.tv.play(c, nav, EpisodePlayable(e, s)) },
            onFolder = { k, id -> nav.openFolderTab(k, id) },
            onCollection = { id, k -> nav.openCollection(k, id) },
            session = nav.search, sessionKey = "${c.library.activeId.value}|${c.profiles.activeId.value}|${nav.searchScope.name}",
            initialType = when (nav.searchScope) { app.streamsetu.core.data.repo.SearchTab.LIVE -> ContentKind.CHANNEL; app.streamsetu.core.data.repo.SearchTab.MOVIES -> ContentKind.MOVIE; app.streamsetu.core.data.repo.SearchTab.SERIES -> ContentKind.SERIES; else -> null },
            above = { typed, first -> rememberSearchActions(c, nav, typed, nav.search, first) })
    }
}
