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
import app.streamsetu.core.data.repo.SearchResults
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
import kotlinx.coroutines.delay

/** Screens built for a remote (the guide grid and the settings panels) are shown sideways on a phone, where they have room. */
@Composable
private fun LockLandscape() {
    val activity = LocalContext.current as? Activity
    DisposableEffect(Unit) {
        val before = activity?.requestedOrientation
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        onDispose { activity?.requestedOrientation = before ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
    }
}

@Composable
fun PhoneGuide(c: AppContainer, nav: Navigator) {
    LockLandscape()
    GuideScreen(hiltViewModel(), c, nav)
}

@Composable
fun PhoneMore(c: AppContainer, nav: Navigator) {
    var settings by remember { mutableStateOf(nav.settingsFromChooser) }
    if (settings) {
        LockLandscape()
        BackHandler(enabled = true) { settings = false }
        Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars)) { SettingsScreen(c, nav) }
        return
    }
    Column(Modifier.fillMaxSize()) {
        PhoneTopBar("More")
        Entry(Icons.Filled.Search, "Search", "Channels, movies and series") { nav.tab = Tab.SEARCH }
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

/** Search across channels, movies and series, from the text index on this phone. */
@Composable
fun PhoneSearch(c: AppContainer, nav: Navigator) {
    var q by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(SearchResults()) }
    var searched by remember { mutableStateOf(false) }
    val recent by c.search.recent.collectAsState()
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) { delay(150); runCatching { focus.requestFocus() } }
    LaunchedEffect(q) {
        if (q.trim().length < 2) { results = SearchResults(); searched = false; return@LaunchedEffect }
        delay(250)
        results = runCatching { c.search.search(q) }.getOrDefault(SearchResults()); searched = true
    }
    fun done(block: () -> Unit) { c.search.remember(q); keyboard?.hide(); block() }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(start = 4.dp, end = Ph.gutter, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(Icons.Filled.ArrowBack, "Back", { nav.tab = Tab.HOME })
            Row(Modifier.weight(1f).height(46.dp).clip(RoundedCornerShape(23.dp)).background(Tokens.elevated).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Filled.Search, Tokens.textTertiary, 20.dp)
                Box(Modifier.weight(1f)) {
                    if (q.isEmpty()) Label("Search channels, movies, series", Ph.body, Tokens.textTertiary)
                    BasicTextField(q, { q = it }, Modifier.fillMaxWidth().focusRequester(focus), singleLine = true, textStyle = TextStyle(color = Tokens.text, fontSize = Ph.body), cursorBrush = SolidColor(Tokens.accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }))
                }
                if (q.isNotEmpty()) Icon(Icons.Filled.Close, Tokens.textSecondary, 18.dp, Modifier.clickable { q = "" })
            }
        }
        val any = results.channels.isNotEmpty() || results.movies.isNotEmpty() || results.series.isNotEmpty()
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 16.dp)) {
            if (q.isBlank() && recent.isNotEmpty()) {
                item { SectionHeader("Recent searches", Modifier.padding(top = 8.dp), action = "Clear", onAction = { c.search.clearHistory() }) }
                items(recent) { r -> Row(Modifier.fillMaxWidth().clickable { q = r }.padding(horizontal = Ph.gutter, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Icon(Icons.Filled.History, Tokens.textTertiary, 18.dp); Label(r, Ph.body, Tokens.text) } }
            }
            if (searched && !any) item { Empty("No results", "Nothing matches \"$q\" in this library.") }
            if (results.channels.isNotEmpty()) {
                item { SectionHeader("Channels", Modifier.padding(top = 8.dp)) }
                items(results.channels, key = { "c" + it.id }) { ch ->
                    Row(Modifier.fillMaxWidth().clickable { done { play(c, nav, ChannelPlayable(ch), results.channels.map { ChannelPlayable(it) }) } }.padding(horizontal = Ph.gutter, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        ChannelLogo(ch.logoUrl, ch.name, 44.dp); Label(ch.name, Ph.body, Tokens.text, FontWeight.Medium)
                    }
                }
            }
            if (results.movies.isNotEmpty()) {
                item { SectionHeader("Movies", Modifier.padding(top = 8.dp)) }
                items(results.movies, key = { "m" + it.id }) { m -> Result(m.title, listOfNotNull(m.year?.toString(), "Movie").joinToString("  ·  "), m.posterUrl) { done { nav.open(Overlay.MovieDetail(m)) } } }
            }
            if (results.series.isNotEmpty()) {
                item { SectionHeader("Series", Modifier.padding(top = 8.dp)) }
                items(results.series, key = { "s" + it.id }) { s -> Result(s.title, listOfNotNull(s.year?.toString(), "Series").joinToString("  ·  "), s.posterUrl) { done { nav.open(Overlay.SeriesDetail(s)) } } }
            }
        }
    }
}

@Composable
private fun Result(title: String, subtitle: String, image: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Ph.gutter, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.width(48.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(6.dp)).background(Tokens.card)) {
            if (image.isNullOrBlank()) PosterPlaceholder(title, Modifier.fillMaxSize()) else AsyncImage(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
        Column(Modifier.weight(1f)) { Label(title, Ph.body, Tokens.text, FontWeight.Medium, maxLines = 2); Label(subtitle, Ph.caption, Tokens.textSecondary) }
    }
}
