package app.streamsetu.tv.ui.phone

import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.activity.compose.BackHandler
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
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import app.streamsetu.core.data.repo.GlobalResults
import app.streamsetu.core.data.repo.SearchItem
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchTab
import app.streamsetu.core.data.repo.SearchTarget
import app.streamsetu.core.model.EpisodePlayable
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.ChannelLogo
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.PosterPlaceholder
import app.streamsetu.tv.ui.screens.guide.GuideScreen
import app.streamsetu.tv.ui.screens.settings.SettingsScreen
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.saveable.rememberSaveable
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.tv.ui.screens.guide.GuideViewModel
import app.streamsetu.tv.ui.screens.settings.Category
import app.streamsetu.tv.ui.screens.settings.SettingsPanel
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.delay

/** The guide as a list that suits a phone held upright: each channel with what is on now, how far through it is, and what comes next. Tap a channel to watch; tap a programme for its details. */
@Composable
fun PhoneGuide(c: AppContainer, nav: Navigator, vm: GuideViewModel = hiltViewModel()) {
    val rows by vm.rows.collectAsState()
    val favOnly by vm.favouritesOnly.collectAsState()
    val hasGuide by vm.hasGuide.collectAsState()
    var detail by remember { mutableStateOf<Pair<Channel, EpgProgram>?>(null) }
    val now = remember { System.currentTimeMillis() }
    val time = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    Column(Modifier.fillMaxSize()) {
        PhoneTopBar("TV Guide", leading = { RoundTap(Icons.Filled.ArrowBack, "Back") { nav.tab = Tab.LIVE } })
        Row(Modifier.padding(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("All channels", !favOnly, { vm.favouritesOnly.value = false })
            Chip("Favourites", favOnly, { vm.favouritesOnly.value = true }, icon = Icons.Filled.Favorite)
            Chip("Now", false, { vm.now() }, icon = Icons.Filled.Schedule)
        }
        Spacer(Modifier.height(8.dp))
        val list = rows
        when {
            list == null -> app.streamsetu.tv.ui.components.Loading(Modifier.weight(1f))
            list.isEmpty() -> Box(Modifier.weight(1f).fillMaxWidth()) { Empty(if (hasGuide == false) "No guide from this provider" else "No channels with a guide", if (hasGuide == false) "Your provider has no programme guide. Channels still play from Live TV." else "Try All channels, or check the guide time in Settings, Live TV.") }
            else -> LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 12.dp)) {
                items(list, key = { it.channel.id }) { row ->
                    val cur = row.programmes.firstOrNull { it.isLive(now) }
                    val next = row.programmes.firstOrNull { it.startMs >= (cur?.endMs ?: now) }
                    Column(Modifier.fillMaxWidth().padding(horizontal = Ph.gutter, vertical = 6.dp).clip(RoundedCornerShape(14.dp)).background(Tokens.card).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(Modifier.clickable { play(c, nav, ChannelPlayable(row.channel), list.map { ChannelPlayable(it.channel) }) }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            ChannelLogo(row.channel.logoUrl, row.channel.name, 44.dp)
                            Column(Modifier.weight(1f)) {
                                Label((row.channel.number?.let { "$it  " } ?: "") + row.channel.name, Ph.body, Tokens.text, FontWeight.SemiBold)
                                Label(cur?.title ?: "No programme information", Ph.small, if (cur != null) Tokens.text else Tokens.textTertiary)
                            }
                            Icon(Icons.Filled.PlayArrow, Tokens.accent, 22.dp)
                        }
                        if (cur != null) {
                            val frac = ((now - cur.startMs).toFloat() / (cur.endMs - cur.startMs).coerceAtLeast(1)).coerceIn(0f, 1f)
                            Box(Modifier.fillMaxWidth().height(3.dp).background(Tokens.elevated, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(frac).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
                            Label("${time.format(Date(cur.startMs))} – ${time.format(Date(cur.endMs))}", Ph.caption, Tokens.textTertiary)
                        }
                        if (next != null) Row(Modifier.fillMaxWidth().clickable { detail = row.channel to next }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Label("Next  ${time.format(Date(next.startMs))}", Ph.caption, Tokens.textTertiary)
                            Label(next.title, Ph.caption, Tokens.textSecondary, modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
    detail?.let { (ch, p) ->
        Sheet(p.title, listOf(SheetItem("Watch ${ch.name}", Icons.Filled.PlayArrow) { play(c, nav, ChannelPlayable(ch)) }),
            onClose = { detail = null }, subtitle = "${time.format(Date(p.startMs))} – ${time.format(Date(p.endMs))}" + (p.description?.takeIf { it.isNotBlank() }?.let { "\n$it" } ?: ""))
    }
}

/** Settings on a phone: the categories as a list; a tap opens that category as a page of its own, and Back returns to the list. */
@Composable
private fun PhoneSettings(c: AppContainer, nav: Navigator, onBack: () -> Unit) {
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    BackHandler(enabled = true) { if (open != null) open = null else onBack() }
    val cat = open?.let { runCatching { Category.valueOf(it) }.getOrNull() }
    Column(Modifier.fillMaxSize()) {
        PhoneTopBar(cat?.title ?: "Settings", leading = { RoundTap(Icons.Filled.ArrowBack, "Back") { if (open != null) open = null else onBack() } })
        if (cat == null) LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 12.dp)) {
            items(Category.entries) { k ->
                Row(Modifier.fillMaxWidth().clickable { open = k.name }.padding(horizontal = Ph.gutter, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Box(Modifier.size(42.dp).clip(RoundedCornerShape(12.dp)).background(Tokens.elevated), Alignment.Center) { Icon(k.icon, Tokens.accent, 22.dp) }
                    Column(Modifier.weight(1f)) { Label(k.title, Ph.body, Tokens.text, FontWeight.SemiBold); Label(k.subtitle, Ph.caption, Tokens.textSecondary, maxLines = 2) }
                    Icon(Icons.Filled.ChevronRight, Tokens.textTertiary, 20.dp)
                }
            }
        } else Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Ph.gutter, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Label(cat.subtitle, Ph.small, Tokens.textSecondary)
            SettingsPanel(cat, c, nav)
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
fun PhoneMore(c: AppContainer, nav: Navigator) {
    var settings by remember { mutableStateOf(nav.settingsFromChooser) }
    if (settings) { PhoneSettings(c, nav) { settings = false; if (nav.settingsFromChooser) { nav.settingsFromChooser = false; nav.toChooser() } }; return }
    Column(Modifier.fillMaxSize()) {
        PhoneTopBar("More")
        Entry(Icons.Filled.Search, "Search", "Channels, movies, series and episodes") { nav.openSearch() }
        Entry(Icons.Filled.CalendarMonth, "TV Guide", "What is on, and what is next") { nav.tab = Tab.GUIDE }
        Entry(Icons.Filled.Layers, "Libraries", "Switch or manage connections") { c.library.close(); nav.toChooser() }
        Entry(Icons.Filled.Settings, "Settings", "Playback, appearance, sounds and more") { settings = true }
    }
}

@Composable
private fun Entry(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Ph.gutter, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(Tokens.elevated), Alignment.Center) { Icon(icon, Tokens.accent, 22.dp) }
        Column(Modifier.weight(1f)) { Label(title, Ph.body, Tokens.text, FontWeight.SemiBold); Label(subtitle, Ph.caption, Tokens.textSecondary) }
        Icon(Icons.Filled.ChevronRight, Tokens.textTertiary, 20.dp)
    }
}

/**
 * Search, laid out like the iPhone app. From Home it is one list with a group for each kind of result (Live TV, Movies, Series, Episodes, TV Guide, Folders,
 * Collections). From Movies, Series or Live TV it covers only that kind and shows the results as tiles. "hindi movies 2024" works, a misspelt word is fixed
 * when nothing matches (and the screen says what it searched for), and recent searches are kept for each screen.
 */
@Composable
fun PhoneSearch(c: AppContainer, nav: Navigator) {
    val tab = nav.searchScope
    val scopeKey = tab.name
    var q by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(GlobalResults()) }
    var searching by remember { mutableStateOf(false) }
    var recents by remember { mutableStateOf(c.search.recentIn(scopeKey)) }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) { delay(150); runCatching { focus.requestFocus() } }
    LaunchedEffect(Unit) { c.globalSearch.warmUp() }
    LaunchedEffect(q, tab) {
        if (q.trim().isEmpty()) { results = GlobalResults(); searching = false; return@LaunchedEffect }
        searching = true
        delay(200)                                  // type-ahead: wait for a pause
        results = runCatching { c.globalSearch.search(q, tab) }.getOrDefault(GlobalResults()); searching = false
    }
    fun remember() { c.search.rememberIn(scopeKey, q); recents = c.search.recentIn(scopeKey) }
    fun open(r: SearchItem) {
        remember(); keyboard?.hide()
        when (val t = r.target) {
            is SearchTarget.PlayChannel -> play(c, nav, ChannelPlayable(t.channel))
            is SearchTarget.PlayProgramme -> play(c, nav, ChannelPlayable(t.channel))
            is SearchTarget.OpenMovie -> nav.open(Overlay.MovieDetail(t.movie))
            is SearchTarget.OpenSeries -> nav.open(Overlay.SeriesDetail(t.series))
            is SearchTarget.PlayEpisode -> play(c, nav, EpisodePlayable(t.episode, t.series))
            is SearchTarget.OpenFolder -> nav.openFolderTab(t.kind, t.folderId)
            is SearchTarget.OpenCollection -> nav.openCollection(t.kind, t.id)
        }
    }
    val prompt = if (tab == SearchTab.ALL) "Channels, movies, series" else "Search ${tab.label.lowercase()}"
    val blank = q.isBlank()
    val found = results.flat(tab)

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(start = 4.dp, end = Ph.gutter, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(Icons.Filled.ArrowBack, "Back", { nav.tab = nav.searchFrom })
            Row(Modifier.weight(1f).height(46.dp).clip(RoundedCornerShape(23.dp)).background(Tokens.elevated).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Filled.Search, Tokens.textTertiary, 20.dp)
                Box(Modifier.weight(1f)) {
                    if (q.isEmpty()) Label(prompt, Ph.body, Tokens.textTertiary)
                    BasicTextField(q, { q = it }, Modifier.fillMaxWidth().focusRequester(focus), singleLine = true, textStyle = TextStyle(color = Tokens.text, fontSize = Ph.body), cursorBrush = SolidColor(Tokens.accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { remember(); keyboard?.hide() }))
                }
                if (q.isNotEmpty()) Icon(Icons.Filled.Close, Tokens.textSecondary, 18.dp, Modifier.clickable { q = "" })
            }
        }
        when {
            blank -> Column(Modifier.weight(1f)) {
                if (recents.isNotEmpty()) {
                    SectionHeader("Recent searches", Modifier.padding(top = 8.dp), action = "Clear", onAction = { c.search.clearIn(scopeKey); recents = emptyList() })
                    LazyColumn { items(recents) { r -> Row(Modifier.fillMaxWidth().clickable { q = r }.padding(horizontal = Ph.gutter, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Icon(Icons.Filled.History, Tokens.textTertiary, 18.dp); Label(r, Ph.body, Tokens.text) } } }
                } else Empty(if (tab == SearchTab.ALL) "Search your library" else "Search ${tab.label.lowercase()}", if (tab == SearchTab.ALL) "Channels, movies, series and episodes from every playlist." else "Try a title, or something like \u201chindi movies 2024\u201d.")
            }
            tab == SearchTab.ALL -> LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 16.dp)) {
                if (found.isEmpty() && searching) item { app.streamsetu.tv.ui.components.Loading(Modifier.height(120.dp)) }
                if (found.isEmpty() && !searching) item { Empty("No results", "Try fewer letters or another spelling.") }
                results.correctedTo?.let { fixed -> item { CorrectedNote(q, fixed) } }
                SearchKind.entries.filter { !results.byKind[it].isNullOrEmpty() }.forEach { kind ->
                    item(key = "h-${kind.name}") { SectionHeader(kind.title, Modifier.padding(top = 10.dp)) }
                    items(results.byKind[kind].orEmpty(), key = { it.id }) { r -> Result(r) { open(r) } }
                }
            }
            else -> {
                val channels = tab == SearchTab.LIVE
                LazyVerticalGrid(GridCells.Fixed(3), Modifier.weight(1f), contentPadding = PaddingValues(start = Ph.gutter, end = Ph.gutter, top = 8.dp, bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (found.isEmpty() && searching) item(span = { GridItemSpan(maxLineSpan) }) { app.streamsetu.tv.ui.components.Loading(Modifier.height(120.dp)) }
                    if (found.isEmpty() && !searching) item(span = { GridItemSpan(maxLineSpan) }) { Empty("No results", "Try fewer letters or another spelling.") }
                    results.correctedTo?.let { fixed -> item(span = { GridItemSpan(maxLineSpan) }) { CorrectedNote(q, fixed) } }
                    gridItems(found, key = { it.id }) { r ->
                        if (channels) Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Tokens.card).clickable { open(r) }.padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            ChannelLogo(r.artworkUrl, r.title, 56.dp); Label(r.title, Ph.caption, Tokens.text, FontWeight.Medium, maxLines = 2)
                        } else PhonePoster(r.title, r.artworkUrl, { open(r) }, subtitle = r.subtitle.substringBefore(" · ").ifBlank { null })
                    }
                }
            }
        }
    }
}

/** "Showing results for X", with the original search a tap away. */
@Composable
private fun CorrectedNote(original: String, corrected: String) {
    Label("Showing results for \u201c$corrected\u201d instead of \u201c$original\u201d.", Ph.small, Tokens.textSecondary, maxLines = 2, modifier = Modifier.padding(horizontal = Ph.gutter, vertical = 8.dp))
}

@Composable
private fun Result(r: SearchItem, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Ph.gutter, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        when (r.kind) {
            SearchKind.CHANNEL, SearchKind.PROGRAMME -> ChannelLogo(r.artworkUrl, r.title, 44.dp)
            SearchKind.FOLDER, SearchKind.COLLECTION -> Box(Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)).background(Tokens.elevated), Alignment.Center) { Icon(if (r.kind == SearchKind.FOLDER) Icons.Filled.Folder else Icons.Filled.Layers, Tokens.accent, 22.dp) }
            else -> Box(Modifier.width(44.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(6.dp)).background(Tokens.card)) {
                if (r.artworkUrl.isNullOrBlank()) PosterPlaceholder(r.title, Modifier.fillMaxSize()) else AsyncImage(r.artworkUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        Column(Modifier.weight(1f)) {
            Label(r.title, Ph.body, Tokens.text, FontWeight.Medium, maxLines = 2)
            if (r.subtitle.isNotBlank()) Label(r.subtitle, Ph.caption, Tokens.textSecondary)
        }
    }
}
