package app.streamsetu.tv.ui.screens.search

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.CommandTarget
import app.streamsetu.core.data.repo.SearchTarget
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchItem
import app.streamsetu.core.data.repo.SearchCommand
import app.streamsetu.core.data.repo.SearchCommands
import app.streamsetu.core.data.repo.SearchScope
import app.streamsetu.core.data.repo.SearchTab
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.FoundTitle
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

/** Carries out a command chosen in the search box. Returns a sentence to show when it could not be done. */
suspend fun runSearchCommand(cmd: SearchCommand, c: AppContainer, nav: Navigator): String? {
    suspend fun findMovie(n: String) = c.search.movieVariants(n).firstOrNull { it.title.equals(n, true) } ?: c.search.movieVariants(n).firstOrNull()
    suspend fun findSeries(n: String) = c.search.seriesVariants(n).firstOrNull { it.title.equals(n, true) } ?: c.search.seriesVariants(n).firstOrNull()
    val missing = { n: String -> "Nothing named “$n” in your library." }
    when (cmd) {
        is SearchCommand.Go -> {
            val libraryTab = when (cmd.target) { CommandTarget.MOVIES -> SearchTab.MOVIES; CommandTarget.SERIES -> SearchTab.SERIES; else -> null }
            if (libraryTab != null && cmd.library != null) c.search.setLastIn(libraryTab.name, cmd.library!!)
            when (cmd.target) {
                CommandTarget.DISCOVER -> nav.go(Tab.HOME)
                CommandTarget.LIVE_TV -> nav.go(Tab.LIVE)
                CommandTarget.MOVIES -> nav.go(Tab.MOVIES)
                CommandTarget.SERIES -> nav.go(Tab.SERIES)
                CommandTarget.GUIDE -> nav.go(Tab.GUIDE)
                CommandTarget.SETTINGS -> nav.go(Tab.SETTINGS)
                CommandTarget.FAVORITES -> nav.open(Overlay.Collection("favorites"))
                CommandTarget.WATCH_LATER -> nav.open(Overlay.Collection("later"))
                CommandTarget.CONTINUE -> nav.open(Overlay.Collection("continue"))
                CommandTarget.HISTORY -> nav.open(Overlay.Collection("recent"))
            }
        }
        is SearchCommand.Resume -> nav.open(Overlay.Collection("continue"))
        is SearchCommand.LastChannel -> { if (c.settings.lastChannelId == null) return "No last channel yet."; c.lastChannel() }
        is SearchCommand.Play -> {
            val m = findMovie(cmd.name)
            if (m != null) { app.streamsetu.tv.play(c, nav, MoviePlayable(m)); return null }
            findSeries(cmd.name)?.let { nav.open(Overlay.SeriesDetail(it)); return null }
            val ch = c.search.search(cmd.name, SearchScope(setOf(ContentKind.CHANNEL)), 5).channels.firstOrNull() ?: return missing(cmd.name)
            app.streamsetu.tv.play(c, nav, ChannelPlayable(ch))
        }
        is SearchCommand.Favourite -> {
            val (id, kind) = findMovie(cmd.name)?.let { it.id to ContentKind.MOVIE } ?: findSeries(cmd.name)?.let { it.id to ContentKind.SERIES } ?: return missing(cmd.name)
            c.user.setFavourite(id, kind, cmd.on, UserRepository.FAVOURITES)
            return if (cmd.on) "Added “${cmd.name}” to Favorites." else "Removed “${cmd.name}” from Favorites."
        }
        is SearchCommand.WatchLater -> {
            val (id, kind) = findMovie(cmd.name)?.let { it.id to ContentKind.MOVIE } ?: findSeries(cmd.name)?.let { it.id to ContentKind.SERIES } ?: return missing(cmd.name)
            c.user.setFavourite(id, kind, cmd.on, UserRepository.WATCH_LATER)
            return if (cmd.on) "Added “${cmd.name}” to Watch Later." else "Removed “${cmd.name}” from Watch Later."
        }
    }
    return null
}

private fun icon(cmd: SearchCommand): ImageVector = when (cmd) {
    is SearchCommand.Go -> Icons.Filled.ArrowForward
    is SearchCommand.Play, SearchCommand.Resume -> Icons.Filled.PlayArrow
    SearchCommand.LastChannel -> Icons.Filled.LiveTv
    is SearchCommand.Favourite -> Icons.Filled.Favorite
    is SearchCommand.WatchLater -> Icons.Filled.Bookmark
}

/**
 * What the typed words can do besides search (commands), a way to ask the AI when one is set up, its answer, and the titles it named that are in the library. Returned as rows to add
 * to the Search screen's one list, in this order, so the AI's rows and the library's results are one list the remote moves through and never push each other off the screen.
 * The AI only names titles; each one is looked up in the library (see askWhatToWatch) and only those found are shown or can be opened.
 */
@Composable
fun rememberSearchActions(c: AppContainer, nav: Navigator, typed: String, session: app.streamsetu.tv.nav.SearchSession? = null, firstAction: androidx.compose.ui.focus.FocusRequester? = null): Pair<LazyListScope.() -> Unit, LazyListScope.() -> Unit> {
    val scope = rememberCoroutineScope()
    var message by remember(typed) { mutableStateOf<String?>(null) }
    val commands = remember(typed) { SearchCommands.parse(typed) }
    val kids = c.profiles.profiles.collectAsState().value.firstOrNull { it.id == c.profiles.activeId.value }?.kids == true
    val aiReady = !kids && c.ai.load().isReady
    val looksLikeARequest = typed.trim().split(Regex("\\s+")).size >= 4 || (typed.trim().split(Regex("\\s+")).size >= 3 && app.streamsetu.core.data.repo.MoodVocabulary.understands(typed))
    var busy by remember(typed) { mutableStateOf(false) }
    var error by remember(typed) { mutableStateOf<String?>(null) }
    // What the AI suggested for these very words is put back when the person returns to the page.
    val kept = session?.takeIf { it.aiFor == typed }
    var note by remember(typed) { mutableStateOf<String?>(kept?.aiNote) }
    var found by remember(typed) { mutableStateOf<List<FoundTitle>>(kept?.aiFound.orEmpty()) }
    var asked by remember(typed) { mutableStateOf(kept?.aiAsked ?: false) }
    LaunchedEffect(typed, found, note, asked) { session?.let { if (asked) { it.aiFor = typed; it.aiFound = found; it.aiNote = note; it.aiAsked = true } } }
    val aiName = c.ai.provider.title
    val showAsk = aiReady && looksLikeARequest && commands.isEmpty()
    fun runAi() {
        if (busy) return
        busy = true; asked = true; error = null
        scope.launch {
            try { val r = c.askWhatToWatch(typed); note = r.first.note.ifBlank { null }; found = r.second } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { error = "failed" }
            busy = false
        }
    }
    val matches = found.distinctBy { listOf(it.title.lowercase(), it.year, it.isSeries) }.take(MAX_AI_MATCHES)
    var showAll by remember(typed) { mutableStateOf(false) }
    val shownMatches = if (showAll) matches else matches.take(INITIAL_AI_MATCHES)           // the first five; the rest on request

    val top: LazyListScope.() -> Unit = {
        itemsIndexed(commands, key = { i, _ -> "command:$i" }) { index, cmd ->
            Focusable({ scope.launch { message = runSearchCommand(cmd, c, nav) } }, Modifier.then(if (index == 0 && firstAction != null) Modifier.focusRequester(firstAction) else Modifier).widthIn(max = 620.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(icon(cmd), null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.accent)); Label(cmd.title, Tokens.row, Tokens.text, FontWeight.Medium, maxLines = 1)
                }
            }
        }
        if (showAsk) item(key = "ask-ai") {
            Focusable({ runAi() }, Modifier.then(if (firstAction != null) Modifier.focusRequester(firstAction) else Modifier).widthIn(max = 620.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(Icons.Filled.AutoAwesome, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.accent))
                    Column(Modifier.weight(1f)) {
                        Label(if (busy) "Thinking…" else "Ask $aiName to suggest titles", Tokens.row, Tokens.text, FontWeight.Medium, maxLines = 1)
                        Label("Only the words you typed are sent.", Tokens.caption, Tokens.textSecondary, maxLines = 1)
                    }
                }
            }
        }
        message?.let { m -> item(key = "search-message") { Label(m, Tokens.small, Tokens.textSecondary, maxLines = 2) } }
        // If the suggestions could not be had, the app's own results stay as they are; only this short note appears, with a way to ask again. Nothing technical is shown.
        if (error != null) item(key = "ai-error") {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Label("Suggestions are unavailable right now.", Tokens.small, Tokens.textSecondary, maxLines = 2)
                TvButton("Try suggestions again", { runAi() }, icon = Icons.Filled.Refresh)
            }
        }
    }
    val bottom: LazyListScope.() -> Unit = {
        // The AI's titles, labelled for what they are, come after what the app itself found; its own words (kept short) after them.
        if (shownMatches.isNotEmpty()) item(key = "ai-heading") { Eyebrow("Suggested titles found in your library", Modifier.padding(top = 4.dp)) }
        itemsIndexed(shownMatches, key = { i, f -> "ai:$i:${f.title}" }) { _, f ->
            // A suggestion that was found in the library is an ordinary result row, with a line saying what it was suggested for.
            val item = f.movie?.let { m -> SearchItem(m.id, SearchKind.MOVIE, m.title, listOfNotNull(f.year?.toString()).joinToString(), m.posterUrl, SearchTarget.OpenMovie(m), 0) }
                ?: f.series?.let { sr -> SearchItem(sr.id, SearchKind.SERIES, sr.title, listOfNotNull(f.year?.toString()).joinToString(), sr.posterUrl, SearchTarget.OpenSeries(sr), 0) }
            if (item != null) SearchResultRow(item, Modifier, {}, "Suggested for “${typed.trim().take(40)}”") { f.open(nav) }
        }
        if (!showAll && matches.size > INITIAL_AI_MATCHES) item(key = "ai-more") {
            Focusable({ showAll = true }, Modifier.widthIn(max = 620.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                Label("Show all ${matches.size} suggestions", Tokens.row, Tokens.accent, FontWeight.Medium, modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
            }
        }
        note?.let { n -> item(key = "ai-note") { Label(n, Tokens.small, Tokens.textSecondary, maxLines = 2) } }
        if (asked && !busy && error == null && found.isEmpty()) item(key = "ai-none") { Label("None of the suggestions are in your library.", Tokens.small, Tokens.textSecondary) }
    }
    return top to bottom
}

private const val MAX_AI_MATCHES = 8
private const val INITIAL_AI_MATCHES = 5
