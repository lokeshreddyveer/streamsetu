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
import androidx.compose.ui.platform.testTag
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
    /** Set only by the Search page: Sports results are merged into this list and open the Sports screens. Null everywhere else, which then shows none. */
    onSports: ((SearchTarget.OpenSports) -> Unit)? = null,
    /** A guide result chosen: the channel and when the programme starts (as stored). Where this is set the Guide opens on that programme; elsewhere the channel plays, as before. */
    onProgramme: ((Channel, Long) -> Unit)? = null,
) {
    val held = remember { session?.open(sessionKey) }
    // Who may see what. Everything below that was found under an earlier value is dropped in the same frame the value changes: results, what the AI suggested, the focused result and the words kept.
    val ctx by c.searchContext.collectAsState(initial = null)
    var shownCtx by remember { mutableStateOf<String?>(null) }
    var resultsRaw by remember { mutableStateOf<GlobalResults?>(null) }
    val results = if (shownCtx == ctx) resultsRaw else null
    fun setResults(r: GlobalResults?, forContext: String? = ctx) { resultsRaw = r; shownCtx = forContext }
    var contextSeen by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(ctx) {
        val now = ctx ?: return@LaunchedEffect
        if (contextSeen != null && contextSeen != now) { resultsRaw = null; shownCtx = null; held?.forgetContext(); session?.clear() }
        contextSeen = now
    }
    var typeFilter by remember { mutableStateOf<ContentKind?>(if (held?.typeSet == true) held.type else initialType) }
    // Opened from Movies, Series or Live TV: only that kind. Opened from the Search page: everything, with chips to narrow it.
    // Episodes and TV Guide are searched types too, but they are not kinds of library content: they are chosen on their own and never together with a ContentKind.
    var extraTab by remember { mutableStateOf<SearchTab?>(held?.extraTab) }
    val tab = extraTab ?: when (typeFilter ?: kinds.singleOrNull()) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; ContentKind.SERIES -> SearchTab.SERIES; else -> SearchTab.ALL }
    // "Show more" for a group: how many extra rows each group has been asked for. Asking again for the same words keeps what was asked; new words start again.
    var asked by remember(ctx) { mutableStateOf<Map<SearchKind, Int>>(emptyMap()) }
    val scopeKey = (kinds.singleOrNull()?.let { when (it) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; else -> SearchTab.SERIES } } ?: SearchTab.ALL).name
    var query by remember { mutableStateOf(if (restore) c.search.lastIn(scopeKey) else held?.query.orEmpty()) }
    var recent by remember { mutableStateOf(c.search.recentIn(scopeKey)) }
    LaunchedEffect(query, tab) { asked = emptyMap() }
    fun remember() { c.search.rememberIn(scopeKey, query); recent = c.search.recentIn(scopeKey) }

    LaunchedEffect(Unit) { c.globalSearch.warmUp() }
    // A search is not just "results or nothing": the results shown stay while the next ones are looked up (with a small spinner by the field), "No titles found" appears only after a
    // search that worked and found nothing, and a search that failed says so and offers Retry. What went wrong is logged, never shown.
    var searching by remember { mutableStateOf(false) }
    var typedQuery by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf(false) }
    var retryTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(query, tab, retryTick, ctx, asked) {
        val mine = ctx ?: return@LaunchedEffect
        if (restore) c.search.setLastIn(scopeKey, query)
        if (query.isBlank()) { setResults(null, mine); searching = false; failed = false; return@LaunchedEffect }
        searching = true; failed = false
        if (typedQuery != query) { delay(150); typedQuery = query }          // the pause is for typing only: a new tab, a retry or "show more" for the same words starts at once
        try {
            // Titles first, then the slower sources, each added below what is on screen. The remote's row never moves, and a slow guide never holds back a movie.
            val base = if (tab == SearchTab.ALL) 12 else 60
            // First look: titles first, then the slower sources below them. When a group was asked for more, the whole answer arrives at once, so the "Show more" row the remote is on never leaves.
            if (asked.isEmpty()) c.globalSearch.searchProgressive(query, tab, base).collect { setResults(it, mine) } else setResults(c.globalSearch.search(query, tab, base, asked), mine)                                                   // this effect is restarted (and this search cancelled) whenever the context changes, so what lands here is for the context it started under
        } catch (e: kotlinx.coroutines.CancellationException) { throw e
        } catch (e: Exception) { android.util.Log.w("Search", "search failed: ${e.javaClass.simpleName}: ${e.message?.take(120)}"); failed = true }
        searching = false
    }
    // Sports results come from a second, separate lookup. They are added to the list when they arrive and never wait for, replace or reorder what the library found; if the lookup fails or is
    // cancelled, the library's results stay exactly as they are. A change to who may see what drops them at once.
    val sportsOn = sportsSearchActive(app.streamsetu.tv.sports.SportsFeature.enabled, onSports != null, typeFilter == null, tab == SearchTab.ALL)
    val sportsContext by (if (sportsOn) c.sportsSearchSource.contextFlow else kotlinx.coroutines.flow.flowOf("")).collectAsState("")
    var sportsItems by remember(sportsContext) { mutableStateOf<List<SearchItem>>(emptyList()) }
    LaunchedEffect(query, sportsOn, retryTick, sportsContext) {
        if (!sportsOn || query.isBlank()) { sportsItems = emptyList(); return@LaunchedEffect }
        delay(150)
        try { sportsItems = c.sportsSearch.search(query) }
        catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: Exception) { android.util.Log.w("Search", "sports search failed: ${e.javaClass.simpleName}"); sportsItems = emptyList() }
    }
    fun open(r: SearchItem) {
        remember()
        when (val t = r.target) {
            is SearchTarget.PlayChannel -> onChannel(t.channel)
            is SearchTarget.PlayProgramme -> if (onProgramme != null && t.startMs > 0L) onProgramme(t.channel, t.startMs) else onChannel(t.channel)
            is SearchTarget.OpenMovie -> onMovie(t.movie)
            is SearchTarget.OpenSeries -> onSeries(t.series)
            is SearchTarget.PlayEpisode -> onEpisode(t.episode, t.series)
            is SearchTarget.OpenFolder -> onFolder(t.kind, t.folderId)
            is SearchTarget.OpenCollection -> onCollection(t.id, t.kind)
            is SearchTarget.OpenSports -> onSports?.invoke(t)
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
        // By frames, not by guessing how long the keyboard takes to leave: wait for the first frame after it closed, then ask for focus until it is held (or give up after a few frames).
        androidx.compose.runtime.withFrameNanos { }
        val first = results?.let { doneResultId(it, query) }
        for (step in doneSteps(first != null)) {
            val requester = if (step == DoneStep.ACTION) firstAction else { targetId = first; androidx.compose.runtime.withFrameNanos { }; focusTarget }       // one frame for the row to take its requester
            app.streamsetu.tv.ui.components.requestFocusOnFrames(6, { requester.requestFocus() }, { app.streamsetu.tv.ui.components.FocusMemory.focused === requester })
            if (app.streamsetu.tv.ui.components.FocusMemory.focused === requester) break
        }
    }
    var settled by remember { mutableStateOf(held == null || (held.query.isBlank() && held.focusedId == null)) }
    LaunchedEffect(query, typeFilter, extraTab) { held?.query = query; held?.type = typeFilter; held?.typeSet = true; held?.extraTab = extraTab }
    // Where the list is scrolled is kept (once what was kept has been put back, so the start of the list does not overwrite it).
    LaunchedEffect(held) { if (held != null) androidx.compose.runtime.snapshotFlow { listState.firstVisibleItemIndex to listState.firstVisibleItemScrollOffset }.collect { (i, o) -> if (settled) { held.scrollIndex = i; held.scrollOffset = o } } }
    // Coming back: the list goes to where it was and the remote to the result it was on, found by its id (the rail that holds it is scrolled to it first). A result that is gone leaves the remote where the page puts it.
    LaunchedEffect(results) {
        val r = results
        if (settled || held == null || r == null) return@LaunchedEffect
        listState.scrollToItem(held.scrollIndex, held.scrollOffset)
        // The exact row when it still exists; otherwise the first result, the nearest valid one (the row it was on is gone). By frames, never by a fixed wait.
        val exact = shownOrder.any { k -> r.byKind[k].orEmpty().any { it.id == restoreId } }
        if (!exact && restoreId != null) targetId = doneResultId(r, "")
        if (exact || (restoreId != null && targetId != null)) {
            androidx.compose.runtime.withFrameNanos { }
            app.streamsetu.tv.ui.components.requestFocusOnFrames(8, { focusTarget.requestFocus() }, { app.streamsetu.tv.ui.components.FocusMemory.focused === focusTarget })
        }
        settled = true
    }
    val actionRows = if (query.isNotBlank()) above(query, firstAction) else Pair<androidx.compose.foundation.lazy.LazyListScope.() -> Unit, androidx.compose.foundation.lazy.LazyListScope.() -> Unit>({ }, { })
    var castStale by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { castStale = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { c.people.isStale() } }
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
            val label = extraTab?.label ?: when (typeFilter) { ContentKind.CHANNEL -> "Live TV"; ContentKind.MOVIE -> "Movies"; ContentKind.SERIES -> "Series"; else -> "All" }
            Focusable({ open = true }, Modifier, shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.03f) { _ ->
                Row(Modifier.padding(horizontal = 14.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Label("Search in", Tokens.small, Tokens.textSecondary); Label(label, Tokens.small, Tokens.accent, FontWeight.SemiBold)
                    Image(Icons.Filled.ArrowDropDown, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.textSecondary))
                }
            }
            if (open) ContextMenu("Search in", null, buildList {
                add(MenuAction("All" + if (typeFilter == null && extraTab == null) "   ✓" else "", Icons.Filled.Search) { typeFilter = null; extraTab = null })
                if (ContentKind.MOVIE in kinds) add(MenuAction("Movies" + if (typeFilter == ContentKind.MOVIE) "   ✓" else "", Icons.Filled.Movie) { typeFilter = ContentKind.MOVIE; extraTab = null })
                if (ContentKind.SERIES in kinds) add(MenuAction("Series" + if (typeFilter == ContentKind.SERIES) "   ✓" else "", Icons.Filled.VideoLibrary) { typeFilter = ContentKind.SERIES; extraTab = null })
                if (ContentKind.CHANNEL in kinds) add(MenuAction("Live TV" + if (typeFilter == ContentKind.CHANNEL) "   ✓" else "", Icons.Filled.LiveTv) { typeFilter = ContentKind.CHANNEL; extraTab = null })
                if (onProgramme != null || kinds.size > 2) { add(MenuAction("Episodes" + if (extraTab == SearchTab.EPISODES) "   ✓" else "", Icons.Filled.PlayCircle) { typeFilter = null; extraTab = SearchTab.EPISODES }); add(MenuAction("TV Guide" + if (extraTab == SearchTab.GUIDE) "   ✓" else "", Icons.Filled.CalendarMonth) { typeFilter = null; extraTab = SearchTab.GUIDE }) }
            }, onClose = { open = false })
        } else if (kinds.size > 1) Row(Modifier.railOnLeft(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TypeChip("All", typeFilter == null && extraTab == null) { typeFilter = null; extraTab = null }
            if (ContentKind.CHANNEL in kinds) TypeChip("Live TV", typeFilter == ContentKind.CHANNEL) { typeFilter = ContentKind.CHANNEL; extraTab = null }
            if (ContentKind.MOVIE in kinds) TypeChip("Movies", typeFilter == ContentKind.MOVIE) { typeFilter = ContentKind.MOVIE; extraTab = null }
            if (ContentKind.SERIES in kinds) TypeChip("Series", typeFilter == ContentKind.SERIES) { typeFilter = ContentKind.SERIES; extraTab = null }
            if (kinds.size > 2) { TypeChip("Episodes", extraTab == SearchTab.EPISODES) { typeFilter = null; extraTab = SearchTab.EPISODES }; TypeChip("TV Guide", extraTab == SearchTab.GUIDE) { typeFilter = null; extraTab = SearchTab.GUIDE } }
        } } }
        // A title in the library that is exactly what was typed comes first, ahead of the commands and anything the AI suggested.
        run {
            val r0 = results ?: return@run
            val exact = bestMatchOf(r0, query) ?: return@run
            item(key = "best-match") {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Eyebrow("Best match", Modifier.padding(top = 4.dp))
                    BestMatchCard(exact, if (exact.id == targetId) Modifier.focusRequester(focusTarget) else Modifier, { if (it) held?.focusedId = exact.id }) { open(exact) }
                }
            }
        }
        aboveItems()
        // Cast and director matches come from an index that is updated only on request (Settings) or when idle, so say so when it has not caught up.
        if (castStale && query.isNotBlank() && (ContentKind.MOVIE in kinds || ContentKind.SERIES in kinds)) item(key = "cast-stale") {
            Label("Cast results may be incomplete. Update the cast search index in Settings.", Tokens.small, Tokens.textTertiary, maxLines = 2)
        }
        if (failed && query.isNotBlank()) item(key = "search-failed") {
            TvStatusState("Search could not be completed", detail = "Try again in a moment.", icon = Icons.Filled.ErrorOutline, actionLabel = "Retry", onAction = { retryTick++ })
        }
        val r = results
        val phase = searchPhase(query.isBlank(), r, searching, failed, sportsItems.isNotEmpty())
        when {
            phase == SearchPhase.IDLE -> {
                if (recent.isNotEmpty()) {
                    item { Eyebrow("Recent searches", Modifier.padding(vertical = 4.dp)) }
                    item(key = "recent-chips") { androidx.compose.foundation.lazy.LazyRow(Modifier.bleedStart(14.dp).railOnLeft(), horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp)) { items(recent.take(8), key = { "r$it" }) { q -> RecentChip(q) { query = q } } } }
                    item { TvButton("Clear history", { c.search.clearIn(scopeKey); recent = emptyList() }, Modifier.padding(top = 6.dp), icon = Icons.Filled.Delete) }
                } else item {
                    // An empty page says what it can do and offers a few searches to start from, picked with the remote.
                    Column(Modifier.widthIn(max = 760.dp).padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                            Box(Modifier.size(64.dp).clip(androidx.compose.foundation.shape.CircleShape).background(Tokens.card), Alignment.Center) { Image(Icons.Filled.Search, null, Modifier.size(30.dp), colorFilter = ColorFilter.tint(Tokens.accent)) }
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Label(if (tab == SearchTab.ALL) "Search your library" else "Search " + tab.label.lowercase(), Tokens.title, Tokens.text, FontWeight.SemiBold)
                                Label(if (tab == SearchTab.ALL) "Channels, movies, series and episodes from every playlist. Works offline." else "Try a title, or something like \u201chindi movies 2024\u201d.", Tokens.body, Tokens.textSecondary, maxLines = 2)
                            }
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Eyebrow("Try searching for")
                            Row(Modifier.railOnLeft(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf("hindi movies 2024", "telugu series", "news", "cricket").forEach { q -> TypeChip(q, false) { query = q } }
                            }
                        }
                    }
                }
            }
            phase == SearchPhase.LOADING -> item(key = "loading") { Loading(Modifier.height(100.dp)) }
            phase == SearchPhase.FAILED -> { }                                                                   // the Retry row above is the whole answer
            phase == SearchPhase.EMPTY -> item(key = "no-results") { TvStatusState("No titles found", detail = "Try fewer letters or another spelling.") }
            r == null -> sportsRows(sportsItems, targetId, focusTarget, held, ::open)
            else -> {
                if (r.understood.isNotEmpty()) item { Label("Understood as  " + r.understood.joinToString("  \u00b7  "), Tokens.small, Tokens.accent, maxLines = 2) }
                r.correctedTo?.let { fixed -> item { Label("Showing results for \u201c$fixed\u201d instead of \u201c${query.trim()}\u201d.", Tokens.small, Tokens.textSecondary, maxLines = 2) } }
                // The exact match is shown once, as the best match above; it is left out of its group below.
                val best = bestMatchOf(r, query)
                shownOrder.filter { it !in app.streamsetu.core.data.repo.SportsSearchOrder }.forEach { kind ->
                    val rows = withoutBest(r.byKind[kind].orEmpty(), best)
                    if (rows.isEmpty()) return@forEach
                    // "12+" when there are more than the group shows: the number is how many are listed here, not how many exist.
                    item(key = "t-${kind.name}") { SectionTitle("${kind.title}  ·  ${rows.size}" + if (kind in r.more) "+" else "") }
                    // Every kind of result is the same row: artwork, a title, one line about it, and what kind it is.
                    if (kind == SearchKind.MOVIE || kind == SearchKind.SERIES || kind == SearchKind.CHANNEL) item(key = "r-${kind.name}") {
                        androidx.compose.foundation.lazy.LazyRow(Modifier.bleedStart(14.dp).railOnLeft(), horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(start = 14.dp, end = 24.dp, top = 6.dp, bottom = 10.dp)) {
                            items(rows, key = { it.id }, contentType = { "tile" }) { x -> SearchTile(x, (if (x.id == targetId) Modifier.focusRequester(focusTarget) else Modifier), { if (it) held?.focusedId = x.id }) { open(x) } }
                        }
                    } else items(rows, key = { it.id }) { x -> SearchResultRow(x, (if (x.id == targetId) Modifier.focusRequester(focusTarget) else Modifier), { if (it) held?.focusedId = x.id }) { open(x) } }
                    // More of this group, on request. The row keeps its place in the list while the rows above it grow, so the remote stays on it.
                    if (kind in r.more) item(key = "more-${kind.name}") {
                        val next = (asked[kind] ?: 0) + SHOW_MORE_STEP
                        Focusable({ asked = asked + (kind to next) }, Modifier.widthIn(max = 420.dp).fillMaxWidth().testTag("search-more-${kind.name}"), scaleOnFocus = 1.0f) { _ ->
                            Label("Show more ${kind.title.lowercase()}", Tokens.row, Tokens.accent, FontWeight.Medium, modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp))
                        }
                    }
                }
                sportsRows(sportsItems, targetId, focusTarget, held, ::open)
            }
        }
        belowItems()
    }
}

/** The Sports groups, after the library's own, each row the same row as any other result. */
private fun androidx.compose.foundation.lazy.LazyListScope.sportsRows(items: List<SearchItem>, targetId: String?, focusTarget: FocusRequester, held: app.streamsetu.tv.nav.SearchSession?, open: (SearchItem) -> Unit) {
    if (items.isEmpty()) return
    app.streamsetu.core.data.repo.SportsSearchOrder.forEach { kind ->
        val rows = items.filter { it.kind == kind }
        if (rows.isEmpty()) return@forEach
        item(key = "t-${kind.name}") { SectionTitle("${kind.title}  ·  ${rows.size}") }
        items(rows, key = { it.id }) { x -> SearchResultRow(x, (if (x.id == targetId) Modifier.focusRequester(focusTarget) else Modifier), { if (it) held?.focusedId = x.id }) { open(x) } }
    }
}

/** One search result, whatever it is: 48 dp artwork, a title (two lines at most), one line about it, and its kind on the right. At least 72 dp tall, the same focus frame everywhere. */
@Composable
internal fun SearchResultRow(x: SearchItem, extra: Modifier, onFocus: (Boolean) -> Unit, provenance: String? = null, onOpen: () -> Unit) {
    Focusable(onOpen, extra.fillMaxWidth().widthIn(max = 860.ui).heightIn(min = 90.ui), onFocus = onFocus, shape = RoundedCornerShape(Tokens.radius), container = Tokens.card.copy(alpha = 0.55f), scaleOnFocus = 1.02f, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE) { _ ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(58.ui).clip(RoundedCornerShape(8.dp)).background(Tokens.elevated), Alignment.Center) {
                SearchArtworkFill(x)
                if (!x.artworkUrl.isNullOrBlank()) coil.compose.AsyncImage(x.artworkUrl, null, Modifier.fillMaxSize(), contentScale = if (x.kind == SearchKind.CHANNEL) androidx.compose.ui.layout.ContentScale.Fit else androidx.compose.ui.layout.ContentScale.Crop)
                else Image(when (x.kind) { SearchKind.CHANNEL -> Icons.Filled.LiveTv; SearchKind.MOVIE -> Icons.Filled.Movie; SearchKind.SERIES -> Icons.Filled.VideoLibrary; SearchKind.EPISODE -> Icons.Filled.PlayCircle; SearchKind.PROGRAMME -> Icons.Filled.CalendarMonth; SearchKind.FOLDER -> Icons.Filled.Folder; SearchKind.COLLECTION -> Icons.Filled.Layers
                        SearchKind.SPORTS_EVENT, SearchKind.SPORTS_RECORDING -> Icons.Filled.SportsScore; SearchKind.SPORTS_TEAM -> Icons.Filled.Groups; SearchKind.SPORTS_COMPETITION -> Icons.Filled.EmojiEvents },
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

/** A result as a tile: the poster (or the channel logo) with the title and one line under it. Movies, series and channels are laid out as a sideways rail. */
@Composable
internal fun SearchTile(x: SearchItem, extra: Modifier, onFocus: (Boolean) -> Unit, onOpen: () -> Unit) {
    val channel = x.kind == SearchKind.CHANNEL
    Focusable(onOpen, extra.width(if (channel) 176.ui else 150.ui), onFocus = onFocus, shape = RoundedCornerShape(Tokens.radius), container = Color.Transparent, focusedContainer = Color(0x24FFFFFF), scaleOnFocus = 1.05f, showRing = false, ringBand = false) { _ ->
        Column(Modifier.padding(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.fillMaxWidth().aspectRatio(if (channel) 16f / 10f else 2f / 3f).clip(RoundedCornerShape(10.dp)).background(Tokens.elevated), Alignment.Center) {
                SearchArtworkFill(x)
                if (!x.artworkUrl.isNullOrBlank()) coil.compose.AsyncImage(x.artworkUrl, null, Modifier.fillMaxSize().then(if (channel) Modifier.padding(14.dp) else Modifier), contentScale = if (channel) androidx.compose.ui.layout.ContentScale.Fit else androidx.compose.ui.layout.ContentScale.Crop)
                else if (channel) Image(Icons.Filled.LiveTv, null, Modifier.size(28.dp), colorFilter = ColorFilter.tint(Tokens.accent)) else PosterPlaceholder(x.title, Modifier.fillMaxSize())
            }
            Label(x.title, Tokens.small, Tokens.text, FontWeight.SemiBold, maxLines = 2)
            if (x.subtitle.isNotBlank()) Label(x.subtitle, Tokens.caption, Tokens.textSecondary, maxLines = 1)
        }
    }
}

/** The title that matches what was typed best, larger than the rest, with its picture. */
@Composable
private fun BestMatchCard(x: SearchItem, extra: Modifier, onFocus: (Boolean) -> Unit, onOpen: () -> Unit) {
    Focusable(onOpen, extra.fillMaxWidth().widthIn(max = 860.ui), onFocus = onFocus, shape = RoundedCornerShape(Tokens.radiusLarge), container = Color(0x14FFFFFF), focusedContainer = Color(0x2EFFFFFF), scaleOnFocus = 1.02f, hairline = true) { _ ->
        Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(84.ui).aspectRatio(2f / 3f).clip(RoundedCornerShape(10.dp)).background(Tokens.elevated), Alignment.Center) {
                SearchArtworkFill(x)
                if (!x.artworkUrl.isNullOrBlank()) coil.compose.AsyncImage(x.artworkUrl, null, Modifier.fillMaxSize(), contentScale = if (x.kind == SearchKind.CHANNEL) androidx.compose.ui.layout.ContentScale.Fit else androidx.compose.ui.layout.ContentScale.Crop)
                else PosterPlaceholder(x.title, Modifier.fillMaxSize())
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Label(x.kind.badge(), Tokens.caption, Tokens.accent, FontWeight.Bold)
                Label(x.title, Tokens.title, Tokens.text, FontWeight.Bold, maxLines = 2)
                if (x.subtitle.isNotBlank()) Label(x.subtitle, Tokens.small, Tokens.textSecondary, maxLines = 2)
            }
            Image(Icons.Filled.PlayArrow, null, Modifier.size(28.dp), colorFilter = ColorFilter.tint(Tokens.text))
        }
    }
}

/** A recent search as a chip: one press runs it again. */
@Composable
private fun RecentChip(text: String, onClick: () -> Unit) = Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = Color(0x1FFFFFFF), focusedContainer = Color.White, scaleOnFocus = 1.0f, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE, showRing = false, ringBand = false) { f ->
    Row(Modifier.padding(horizontal = 14.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Image(Icons.Filled.History, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(if (f) Tokens.onBright else Tokens.textSecondary))
        Label(text, Tokens.small, if (f) Tokens.onBright else Tokens.text, FontWeight.SemiBold)
    }
}

@Composable
private fun TypeChip(label: String, on: Boolean, onClick: () -> Unit) = Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = if (on) Color(0xFFE9ECF0) else Tokens.card, focusedContainer = if (on) Color.White else Tokens.focusedSurface, scaleOnFocus = 1.05f, ringWidth = 0.dp) { _ ->
    Label(label, Tokens.row, if (on) Tokens.onBright else Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 18.dp, vertical = 8.dp))
}

@Composable
private fun SuggestionRow(text: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) = Focusable(onClick, Modifier.widthIn(max = 420.dp).fillMaxWidth(), scaleOnFocus = 1.0f, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE) { _ ->
    Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Image(icon, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary)); Label(text, Tokens.row, Tokens.text)
    }
}


/** Search inside Movies or Series: movies only, or series only. */
@Composable
fun SectionSearch(c: AppContainer, kind: ContentKind, onOpen: (Card) -> Unit, onClose: () -> Unit) {
    val scope = when (kind) { ContentKind.CHANNEL -> SearchTab.LIVE; ContentKind.MOVIE -> SearchTab.MOVIES; else -> SearchTab.SERIES }.name
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusOnFrames(8, { first.requestFocus() }, { app.streamsetu.tv.ui.components.FocusMemory.focused === first }) }
    TvDialog(onDismissRequest = { c.search.setLastIn(scope, ""); onClose() }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().pageBackground().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
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
    Column(Modifier.fillMaxSize().padding(start = Tokens.safeHorizontal + 4.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Label("Search", Tokens.display, Tokens.text, FontWeight.ExtraBold)
        SearchContent(c, setOf(ContentKind.CHANNEL, ContentKind.MOVIE, ContentKind.SERIES), Modifier.fillMaxSize(), entry = entry,
            onChannel = { ch -> app.streamsetu.tv.play(c, nav, ChannelPlayable(ch)) },
            onMovie = { m -> nav.open(app.streamsetu.tv.nav.Overlay.MovieDetail(m)) },
            onSeries = { s -> nav.open(app.streamsetu.tv.nav.Overlay.SeriesDetail(s)) },
            onEpisode = { e, s -> app.streamsetu.tv.play(c, nav, EpisodePlayable(e, s)) },
            onFolder = { k, id -> nav.openFolderTab(k, id) },
            onCollection = { id, k -> nav.openCollection(k, id) },
            onProgramme = { ch, start -> nav.openGuideAt(app.streamsetu.tv.sports.discovery.GuideTarget(ch.id, start + c.ui.epgOffsetMinutes.value * 60_000L)) },
            onSports = if (app.streamsetu.tv.sports.SportsFeature.enabled) ({ t -> nav.openSports(t) }) else null,
            session = nav.search, sessionKey = "${c.library.activeId.value}|${c.profiles.activeId.value}|${nav.searchScope.name}",
            initialType = when (nav.searchScope) { app.streamsetu.core.data.repo.SearchTab.LIVE -> ContentKind.CHANNEL; app.streamsetu.core.data.repo.SearchTab.MOVIES -> ContentKind.MOVIE; app.streamsetu.core.data.repo.SearchTab.SERIES -> ContentKind.SERIES; else -> null },
            above = { typed, first -> rememberSearchActions(c, nav, typed, nav.search, first) })
    }
}

/** How many more rows one press of "Show more" adds to a group. */
internal const val SHOW_MORE_STEP = 24


/** A film or series with no picture asks for its own cover, as a poster does; the tile shows it the next time the results are drawn. */
@androidx.compose.runtime.Composable
private fun SearchArtworkFill(x: SearchItem) {
    val filler = LocalArtworkFiller.current
    if (x.artworkUrl.isNullOrBlank() && (x.kind == SearchKind.MOVIE || x.kind == SearchKind.SERIES)) androidx.compose.runtime.LaunchedEffect(x.id) { filler?.invoke(x.id, false) }
}
