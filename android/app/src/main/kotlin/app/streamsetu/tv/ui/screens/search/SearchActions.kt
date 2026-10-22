package app.streamsetu.tv.ui.screens.search

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.CommandTarget
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

/** Rows above the search results: what the typed words can do besides search, and (when an AI is set up) a way to ask it. */
@Composable
fun SearchActions(c: AppContainer, nav: Navigator, typed: String) {
    val scope = rememberCoroutineScope()
    var message by remember(typed) { mutableStateOf<String?>(null) }
    val commands = remember(typed) { SearchCommands.parse(typed) }
    val kids = c.profiles.profiles.collectAsState().value.firstOrNull { it.id == c.profiles.activeId.value }?.kids == true
    val aiReady = !kids && c.ai.load().isReady
    val looksLikeARequest = typed.trim().split(Regex("\\s+")).size >= 4 || (typed.trim().split(Regex("\\s+")).size >= 3 && app.streamsetu.core.data.repo.MoodVocabulary.understands(typed))
    var busy by remember(typed) { mutableStateOf(false) }
    var error by remember(typed) { mutableStateOf<String?>(null) }
    var note by remember(typed) { mutableStateOf<String?>(null) }
    var found by remember(typed) { mutableStateOf<List<FoundTitle>>(emptyList()) }
    var asked by remember(typed) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        commands.forEach { cmd ->
            Focusable({ scope.launch { message = runSearchCommand(cmd, c, nav) } }, Modifier.widthIn(max = 620.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(icon(cmd), null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.accent)); Label(cmd.title, Tokens.row, Tokens.text, FontWeight.Medium, maxLines = 1)
                }
            }
        }
        if (aiReady && looksLikeARequest && commands.isEmpty()) {
            Focusable({
                if (busy) return@Focusable
                busy = true; asked = true; error = null
                scope.launch {
                    try { val r = c.askWhatToWatch(typed); note = r.first.note.ifBlank { null }; found = r.second } catch (e: Exception) { error = e.message }
                    busy = false
                }
            }, Modifier.widthIn(max = 620.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(Icons.Filled.AutoAwesome, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.accent))
                    Column(Modifier.weight(1f)) {
                        Label(if (busy) "Thinking…" else "Ask ${c.ai.provider.title}", Tokens.row, Tokens.text, FontWeight.Medium, maxLines = 1)
                        Label("Finds matches in your own library. Only what you typed is sent.", Tokens.caption, Tokens.textSecondary, maxLines = 1)
                    }
                }
            }
        }
        message?.let { Label(it, Tokens.small, Tokens.textSecondary, maxLines = 2) }
        error?.let { Label(it, Tokens.small, Tokens.textSecondary, maxLines = 3) }
        note?.let { Label(it, Tokens.small, Tokens.accent, maxLines = 3) }
        found.forEach { f ->
            Focusable({ f.open(nav) }, Modifier.widthIn(max = 620.dp).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(if (f.isSeries) Icons.Filled.VideoLibrary else Icons.Filled.Movie, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.accent))
                    Label(listOfNotNull(f.title, f.year?.toString()).joinToString("  ·  "), Tokens.row, Tokens.text, FontWeight.Medium, maxLines = 1)
                }
            }
        }
        if (asked && !busy && error == null && found.isEmpty()) Label("None of the suggestions are in your library.", Tokens.small, Tokens.textSecondary)
    }
}
