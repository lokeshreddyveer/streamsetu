package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.runtime.*
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

@Composable
fun SearchScreen(vm: SearchViewModel, c: AppContainer, nav: Navigator) {
    val query by vm.query.collectAsState()
    val results by vm.results.collectAsState()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = Tokens.screenPadding, top = 18.dp, end = Tokens.screenPadding, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Label("Search", Tokens.title, Tokens.text, FontWeight.Bold)
                TvTextField(query, vm::setQuery, "Type a channel, movie or series", (LocalContentEntry.current?.let { Modifier.focusRequester(it) } ?: Modifier).widthIn(max = 700.dp).fillMaxWidth())
            }
        }
        if (results.channels.isNotEmpty()) item {
            Column { SectionTitle("Channels")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(results.channels, key = { it.id }) { ch ->
                        Focusable({ play(c, nav, ChannelPlayable(ch), results.channels.map { ChannelPlayable(it) }) }, Modifier.width(150.dp)) {
                            Column(Modifier.padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                ChannelLogo(ch.logoUrl, ch.name, 72.dp); Label(ch.name, Tokens.small)
                            }
                        }
                    }
                } }
        }
        if (results.movies.isNotEmpty()) item {
            Column { SectionTitle("Movies")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp)) { items(results.movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { play(c, nav, MoviePlayable(m)) }) } } }
        }
        if (results.series.isNotEmpty()) item {
            Column { SectionTitle("Series")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp)) { items(results.series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }) } } }
        }
        if (query.trim().length >= 2 && results.isEmpty) item { Label("Nothing found for “${query.trim()}”.", color = Tokens.muted) }
    }
}

@Composable
fun FirstRun(onAdd: () -> Unit) {
    EmptyState("Welcome to StreamSetu", "Add your playlist (an M3U link or an Xtream login) to start watching.") {
        TvButton("Add a Playlist", onAdd, (LocalContentEntry.current?.let { Modifier.focusRequester(it) } ?: Modifier), icon = Icons.Filled.Add, primary = true)
    }
}

@Composable
fun AddPlaylistScreen(vm: AddPlaylistViewModel, onClose: () -> Unit) {
    val busy by vm.busy.collectAsState()
    val message by vm.message.collectAsState()
    val summary by vm.summary.collectAsState()
    var type by remember { mutableStateOf(SourceType.XTREAM) }
    var name by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    val first = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    val ready = address.isNotBlank() && (type == SourceType.M3U || (user.isNotBlank() && pass.isNotBlank()))

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        summary?.let { sm ->
            val open = remember { androidx.compose.ui.focus.FocusRequester() }
            LaunchedEffect(Unit) { delay(150); runCatching { open.requestFocus() } }
            Column(Modifier.fillMaxSize().padding(horizontal = 120.dp, vertical = 48.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Label("Connection verified", Tokens.title, Tokens.text, FontWeight.Bold)
                Label(sm.name, Tokens.heading, Tokens.accent, FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    listOf("Live channels" to sm.channels, "Movies" to sm.movies, "Series" to sm.series).forEach { (t, n) ->
                        Column(Modifier.background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(horizontal = 22.dp, vertical = 14.dp)) {
                            Label("%,d".format(n), Tokens.display, Tokens.text, FontWeight.Bold); Label(t, Tokens.small, Tokens.textSecondary)
                        }
                    }
                }
                Label("Saved on this device. Your login is kept in the Android Keystore and is never shown or logged.", Tokens.small, Tokens.textSecondary)
                TvButton("Open Home", onClose, Modifier.focusRequester(open), primary = true)
            }
            return@Box
        }
        Column(Modifier.fillMaxSize().padding(horizontal = 120.dp, vertical = 48.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Label("Add a Playlist", Tokens.title, Tokens.text, FontWeight.Bold)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TvButton("Xtream login", { type = SourceType.XTREAM }, Modifier.focusRequester(first), primary = type == SourceType.XTREAM)
                TvButton("M3U link", { type = SourceType.M3U }, primary = type == SourceType.M3U)
            }
            TvTextField(name, { name = it }, "Name (optional)", Modifier.widthIn(max = 700.dp).fillMaxWidth())
            TvTextField(address, { address = it }, if (type == SourceType.XTREAM) "Server address (http://host:port)" else "Playlist link (http://…/playlist.m3u)", Modifier.widthIn(max = 700.dp).fillMaxWidth())
            if (type == SourceType.XTREAM) {
                TvTextField(user, { user = it }, "User name", Modifier.widthIn(max = 700.dp).fillMaxWidth())
                TvTextField(pass, { pass = it }, "Password", Modifier.widthIn(max = 700.dp).fillMaxWidth(), secret = true)
            }
            message?.let { Label(it, color = Tokens.danger, maxLines = 3) }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                if (busy) { Spinner(); Label("Testing the connection and reading the catalog. This can take a minute for big lists…", color = Tokens.muted) }
                else {
                    TvButton("Test and Save", { if (ready) vm.test(type, name, address, user, pass) }, primary = true)
                    TvButton("Cancel", onClose)
                }
            }
        }
    }
}
