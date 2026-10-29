package app.streamsetu.tv.ui.phone

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
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
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/**
 * Search the whole catalog from inside the player. A drop-down narrows it to All, Movies, Series or Live TV (All to start with). A channel, movie or episode starts at
 * once in the player; a series opens its page.
 */
@Composable
fun PhonePlayerSearch(c: AppContainer, initialTab: SearchTab = SearchTab.ALL, onPlay: (Playable) -> Unit, onSeries: (Series) -> Unit, onClose: () -> Unit) {
    var q by remember { mutableStateOf("") }
    var tab by remember { mutableStateOf(initialTab) }
    var menu by remember { mutableStateOf(false) }
    var results by remember { mutableStateOf(GlobalResults()) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var retry by remember { mutableIntStateOf(0) }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) { delay(150); runCatching { focus.requestFocus() } }
    LaunchedEffect(Unit) { c.globalSearch.warmUp() }
    LaunchedEffect(q, tab, retry) {
        if (q.trim().isEmpty()) { results = GlobalResults(); busy = false; failed = false; return@LaunchedEffect }
        busy = true; failed = false; delay(200)
        try { results = c.globalSearch.search(q, tab, if (tab == SearchTab.ALL) 12 else 60) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { failed = true }
        busy = false
    }
    fun open(r: SearchItem) {
        c.search.rememberIn(tab.name, q); keyboard?.hide()
        when (val t = r.target) {
            is SearchTarget.PlayChannel -> onPlay(ChannelPlayable(t.channel))
            is SearchTarget.PlayProgramme -> onPlay(ChannelPlayable(t.channel))
            is SearchTarget.OpenMovie -> onPlay(MoviePlayable(t.movie))
            is SearchTarget.OpenSeries -> onSeries(t.series)
            is SearchTarget.PlayEpisode -> onPlay(EpisodePlayable(t.episode, t.series))
            else -> {}
        }
    }
    val tabs = listOf(SearchTab.ALL to "All", SearchTab.MOVIES to "Movies", SearchTab.SERIES to "Series", SearchTab.LIVE to "Live TV")
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(Tokens.background).windowInsetsPadding(WindowInsets.systemBars)) {
            Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = Ph.gutter, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                IconTap(Icons.Filled.ArrowBack, "Close search", onClose)
                Row(Modifier.weight(1f).height(46.dp).clip(RoundedCornerShape(23.dp)).background(Tokens.elevated).padding(start = 16.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Search, Tokens.textTertiary, 20.dp)
                    Box(Modifier.weight(1f)) {
                        if (q.isEmpty()) Label("Search the catalog", Ph.body, Tokens.textTertiary)
                        BasicTextField(q, { q = it }, Modifier.fillMaxWidth().focusRequester(focus), singleLine = true, textStyle = TextStyle(color = Tokens.text, fontSize = Ph.body), cursorBrush = SolidColor(Tokens.accent),
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }))
                    }
                    Box {
                        Row(Modifier.clip(RoundedCornerShape(18.dp)).background(Tokens.card).clickable { menu = true }.padding(start = 12.dp, end = 6.dp, top = 7.dp, bottom = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                            Label(tabs.first { it.first == tab }.second, Ph.small, Tokens.accent, FontWeight.SemiBold)
                            Icon(Icons.Filled.ArrowDropDown, Tokens.textSecondary, 18.dp)
                        }
                        if (menu) Popup(alignment = Alignment.TopEnd, offset = androidx.compose.ui.unit.IntOffset(0, 120), onDismissRequest = { menu = false }, properties = PopupProperties(focusable = true)) {
                            Column(Modifier.width(160.dp).clip(RoundedCornerShape(14.dp)).background(Tokens.elevated).padding(vertical = 6.dp)) {
                                tabs.forEach { (t, name) -> Label(name + if (t == tab) "   ✓" else "", Ph.body, if (t == tab) Tokens.accent else Tokens.text, FontWeight.Medium, modifier = Modifier.fillMaxWidth().clickable { tab = t; menu = false }.padding(horizontal = 16.dp, vertical = 12.dp)) }
                            }
                        }
                    }
                }
            }
            val found = results.flat(tab)
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 16.dp)) {
                if (q.isBlank()) item { Label("Type a title, a channel or something like “hindi movies 2024”.", Ph.body, Tokens.textSecondary, modifier = Modifier.padding(Ph.gutter)) }
                else if (failed) item { Label("Search could not be completed. Tap to try again.", Ph.body, Tokens.accent, modifier = Modifier.fillMaxWidth().clickable { retry++ }.padding(Ph.gutter)) }
                else if (found.isEmpty()) item { Label(if (busy) "Searching…" else "No results. Try fewer letters or another spelling.", Ph.body, Tokens.textSecondary, modifier = Modifier.padding(Ph.gutter)) }
                items(found, key = { it.id }) { r ->
                    Row(Modifier.fillMaxWidth().clickable { open(r) }.padding(horizontal = Ph.gutter, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(when (r.kind) { SearchKind.CHANNEL, SearchKind.PROGRAMME -> Icons.Filled.LiveTv; SearchKind.MOVIE -> Icons.Filled.Movie; SearchKind.SERIES -> Icons.Filled.VideoLibrary; else -> Icons.Filled.PlayCircle }, Tokens.accent, 20.dp)
                        Column(Modifier.weight(1f)) {
                            Label(r.title, Ph.body, Tokens.text, FontWeight.Medium, maxLines = 1)
                            if (r.subtitle.isNotBlank()) Label(r.subtitle, Ph.caption, Tokens.textSecondary, maxLines = 1)
                        }
                    }
                }
            }
        }
    }
}


/** Asks for a time ("1:23:45", "83:45" or seconds) and jumps there. */
@Composable
fun PhoneGoToDialog(onGo: (Long) -> Unit, onClose: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(150); runCatching { focus.requestFocus() } }
    Dialog(onDismissRequest = onClose) {
        Column(Modifier.clip(RoundedCornerShape(20.dp)).background(Tokens.card).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("Go to time", Ph.heading, Tokens.text, FontWeight.Bold)
            Label("Hours:minutes:seconds, for example 1:23:45.", Ph.small, Tokens.textSecondary)
            Row(Modifier.fillMaxWidth().height(46.dp).clip(RoundedCornerShape(12.dp)).background(Tokens.elevated).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                BasicTextField(text, { text = it }, Modifier.fillMaxWidth().focusRequester(focus), singleLine = true, textStyle = TextStyle(color = Tokens.text, fontSize = Ph.body), cursorBrush = SolidColor(Tokens.accent),
                    keyboardOptions = KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { app.streamsetu.tv.ui.components.PlayerMenus.parseTime(text)?.let { onGo(it) } }))
            }
            PillButton("Go", { app.streamsetu.tv.ui.components.PlayerMenus.parseTime(text)?.let { onGo(it) } }, primary = true)
        }
    }
}
