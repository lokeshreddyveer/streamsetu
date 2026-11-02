package app.streamsetu.tv.ui.screens.settings

import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.*
import androidx.compose.ui.draw.clip
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.components.scrollThumb
import app.streamsetu.tv.ui.components.sidebarRowFill
import app.streamsetu.tv.ui.theme.Tokens
import androidx.compose.ui.platform.testTag
import app.streamsetu.tv.ui.theme.ui
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The categories, most used first; the technical ones are at the bottom. */
enum class Category(val title: String, val subtitle: String, val icon: ImageVector, val tint: Color, val section: Int) {
    PLAYBACK("Playback", "Engine, buffering, resume and recovery", Icons.Filled.PlayArrow, Mac.blue, 0),
    VIDEO("Video & Display", "Picture size, decoding and screen", Icons.Filled.Tv, Mac.indigo, 0),
    AUDIO("Audio", "Language, surround and track memory", Icons.Filled.VolumeUp, Mac.pink, 0),
    SUBTITLES("Subtitles & Accessibility", "Subtitle style, motion and contrast", Icons.Filled.Subtitles, Mac.gray, 0),
    LIVE("Live TV", "Channel keys, numbers and guide time", Icons.Filled.LiveTv, Mac.red, 1),
    CHANNELS("Channel Manager", "Hide, rename and check channels", Icons.Filled.Tune, Mac.orange, 1),
    DEVICE("On Your Device", "Videos and pictures stored here", Icons.Filled.PhoneAndroid, Mac.teal, 1),
    STATISTICS("Statistics", "What you have watched", Icons.Filled.BarChart, Mac.green, 1),
    LIBRARIES("Libraries & Folders", "Connections, combined libraries, folders", Icons.Filled.Layers, Mac.blue, 2),
    SEARCH("Search & Catalog", "Sorting, search history and the index", Icons.Filled.Search, Mac.gray, 2),
    FAVOURITES("Favorites & History", "Lists, history and Home rows", Icons.Filled.Favorite, Mac.pink, 2),
    APPEARANCE("Appearance & Sounds", "Posters, banner, animation, interface sounds", Icons.Filled.Palette, Mac.purple, 2),
    PRIVACY("Privacy & Security", "Folder PIN, relock, clearing data", Icons.Filled.Lock, Mac.blue, 3),
    PODCASTS("Podcasts", "Follow shows and play episodes", Icons.Filled.Mic, Mac.orange, 3),
    INTEGRATIONS("AI, Trakt and Debrid", "Ask for what to watch, watch tracking and link unlocking, with your own keys", Icons.Filled.Link, Mac.indigo, 3),
    PROFILES("Profiles", "Who is watching, kids profiles and PINs", Icons.Filled.People, Mac.green, 3),
    SYNC("Sync on this network", "Share favourites and progress over Wi-Fi", Icons.Filled.Sync, Mac.teal, 3),
    ADDONS("Add-ons", "Extra connections described by a small file", Icons.Filled.Extension, Mac.indigo, 3),
    STORAGE("Storage & Backup", "Cache, backup and reset", Icons.Filled.Storage, Mac.gray, 4),
    DIAGNOSTICS("Diagnostics", "Playback facts and a safe report", Icons.Filled.Troubleshoot, Mac.orange, 4),
    ABOUT("About StreamSetu", "Version, licenses and support", Icons.Filled.Info, Mac.gray, 4),
}

/**
 * Settings: Settings Home (this list) → a category → its controls. The list takes about a third of the width and the controls the rest.
 * OK or Right on a category moves into its controls; Back returns to the list on the same category. Everything saves the moment it changes.
 */
@Composable
fun SettingsScreen(c: AppContainer, nav: Navigator) {
    var selected by remember { mutableStateOf(nav.settings.category ?: Category.PLAYBACK.name) }
    LaunchedEffect(selected) { nav.settings.category = selected }
    // Something elsewhere asked for one category (the Sports Hub's "Open Guide Settings"): open on it once.
    LaunchedEffect(nav.pendingSettings) { nav.pendingSettings?.let { name -> categoryFromRequest(name)?.let { selected = it.name }; nav.pendingSettings = null } }
    val current = Category.valueOf(selected)
    val advanced by c.ui.advancedSettings.collectAsState()
    // Settings search: what was typed, whether the technical settings are included, whether the open page was reached from a result, and the control the remote should land on.
    var searching by remember { mutableStateOf(nav.settings.searching) }
    var query by remember { mutableStateOf(nav.settings.query) }
    var includeAdvanced by remember { mutableStateOf(nav.settings.includeAdvanced) }
    var fromSearch by remember { mutableStateOf(false) }
    var lastResult by remember { mutableStateOf(nav.settings.lastResult) }
    LaunchedEffect(searching, query, includeAdvanced, lastResult) { nav.settings.searching = searching; nav.settings.query = query; nav.settings.includeAdvanced = includeAdvanced; nav.settings.lastResult = lastResult }
    var restoreId by remember { mutableStateOf<String?>(null) }          // set when Back returns to the results: the result to put the remote on again
    var focusTitle by remember { mutableStateOf<String?>(null) }
    val searchRow = remember { FocusRequester() }
    val fieldFocus = remember { FocusRequester() }
    val listEntry = LocalContentEntry.current ?: remember { FocusRequester() }
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    // The panel is a focus group: asking it for focus goes to its first control, so Right and OK never pick whichever control is nearest.
    val panelEntry = remember { FocusRequester() }
    var inPanel by remember { mutableStateOf(false) }
    val rows = remember { Category.entries.associateWith { FocusRequester() } }
    // A short status beside a category where there is one to give: who is watching, whether sync is on, how many libraries.
    val profileList by c.profiles.profiles.collectAsStateWithLifecycle(); val activeProfile by c.profiles.activeId.collectAsStateWithLifecycle()
    val lanOn by c.lan.enabled.collectAsStateWithLifecycle(); val libraryEntries by c.library.entries.collectAsState(initial = emptyList())
    // Essential never hides a page that is in use or that a current problem needs: sync while it is on, Add-ons while one is installed, Diagnostics while a connection has failed.
    val allSources by c.sources.sources.collectAsState(initial = emptyList())
    val inUse = remember(lanOn, allSources) {
        buildSet {
            if (lanOn) add(Category.SYNC)
            if (allSources.any { it.type == app.streamsetu.core.model.SourceType.ADDON }) add(Category.ADDONS)
            if (allSources.any { it.status == app.streamsetu.core.model.SyncStatus.FAILED }) add(Category.DIAGNOSTICS)
        }
    }
    val shown = remember(advanced, current, inUse) { Category.entries.filter { advanced || it !in SettingsRegistry.advancedCategories || it == current || it in inUse } }
    fun statusOf(cat: Category): String? = when (cat) {
        Category.PROFILES -> profileList.firstOrNull { it.id == activeProfile }?.name
        Category.SYNC -> if (lanOn) "On" else "Off"
        Category.LIBRARIES -> libraryEntries.count { it.usable }.takeIf { it > 0 }?.toString()
        else -> null
    }

    // The categories are a lazy list, so one that is scrolled out of view is not on screen to take the remote. Anything that sends the remote to a category scrolls it into view first.
    val categoryState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    suspend fun reveal(index: Int) {
        val info = categoryState.layoutInfo
        val v = info.visibleItemsInfo.firstOrNull { it.index == index }
        when {
            v == null -> categoryState.scrollToItem(index)
            v.offset < info.viewportStartOffset -> categoryState.scrollBy((v.offset - info.viewportStartOffset).toFloat())
            v.offset + v.size > info.viewportEndOffset -> categoryState.scrollBy((v.offset + v.size - info.viewportEndOffset).toFloat())
        }
    }
    // The chosen category is always on screen, so Left from the controls (and Back) can find it.
    LaunchedEffect(selected) { reveal(shown.indexOf(current)) }

    BackHandler(enabled = inPanel) {
        scope.launch {
            reveal(shown.indexOf(current))          // into view first,
            androidx.compose.runtime.withFrameNanos { }        // then wait for the layout it caused,
            runCatching { rows[current]?.requestFocus() }      // then the remote goes there
        }
    }
    // Back from a page that a search result opened returns to the results (the words typed and the result chosen are still there); Back from the results returns to the list on the search entry.
    BackHandler(enabled = inPanel && fromSearch && !searching) { restoreId = lastResult; fromSearch = false; searching = true }
    BackHandler(enabled = inPanel && searching) { searching = false; restoreId = null; scope.launch { androidx.compose.runtime.withFrameNanos { }; runCatching { searchRow.requestFocus() } } }
    // Choosing a category by hand ends the search; a category opened by a result keeps it.
    var lastSelected by remember { mutableStateOf(selected) }
    LaunchedEffect(selected) { if (selected != lastSelected) { lastSelected = selected; if (focusTitle == null) { fromSearch = false; searching = false } } }          // not on the first composition: that would undo the search state that was just restored
    // A result whose control is not on the page (a collapsed group) must not leave the remote nowhere: after a moment it goes to the page.
    LaunchedEffect(focusTitle) { if (focusTitle != null) { kotlinx.coroutines.delay(1500); if (focusTitle != null) { focusTitle = null; runCatching { panelEntry.requestFocus() } } } }

    Row(Modifier.fillMaxSize()) {
        // Left: the categories, each with an icon tile and a line saying what is inside.
        Column(Modifier.weight(0.25f).fillMaxHeight().railOnLeft().sidebarSurface().padding(horizontal = 12.dp, vertical = Tokens.safeVertical)) {
            Label("Settings", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(start = 10.dp, bottom = 8.dp))
            // The first entry of the list searches every setting.
            Focusable({ searching = true; scope.launch { androidx.compose.runtime.withFrameNanos { }; runCatching { panelEntry.requestFocus() } } },
                Modifier.focusRequester(searchRow).fillMaxWidth().testTag("settings-search-row").focusProperties { up = FocusRequester.Cancel; left = FocusRequester.Cancel; down = shown.firstOrNull()?.let { rows.getValue(it) } ?: FocusRequester.Cancel }
                    .onPreviewKeyEvent { e -> if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) { searching = true; scope.launch { androidx.compose.runtime.withFrameNanos { }; runCatching { panelEntry.requestFocus() } }; true } else false },
                shape = RoundedCornerShape(Tokens.radius), container = Color.Transparent, focusedContainer = Color.Transparent, scaleOnFocus = 1.0f, showRing = false, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE) { f ->
                Row(Modifier.fillMaxWidth().sidebarRowFill(f, searching).heightIn(min = 44.ui), verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.width(5.dp))
                    Box(Modifier.width(34.ui), Alignment.Center) { androidx.compose.foundation.Image(Icons.Filled.Search, null, Modifier.size(22.ui), colorFilter = ColorFilter.tint(if (f || searching) Color.White else Tokens.textSecondary)) }
                    Label("Search settings", Tokens.row, if (f || searching) Color.White else Tokens.textSecondary, if (searching) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.weight(1f).padding(start = 8.dp))
                }
            }
            Spacer(Modifier.height(6.dp))
            LazyColumn(Modifier.weight(1f).fillMaxWidth().scrollThumb(categoryState), state = categoryState, verticalArrangement = Arrangement.spacedBy(0.dp)) {
                itemsIndexed(shown, key = { _, cat -> cat.name }) { index, cat ->
                    val isSel = cat == current
                    var dwell by remember { mutableStateOf(false) }
                    LaunchedEffect(dwell) { if (dwell) { delay(350); selected = cat.name } }          // the page on the right follows the remote once it rests on a category: moving down the list does not build every page it passes
                    Column {
                        if (index > 0 && shown[index - 1].section != cat.section) Spacer(Modifier.height(10.dp))
                                        Focusable({ selected = cat.name; runCatching { panelEntry.requestFocus() }.isSuccess },
                        (if (isSel) Modifier.focusRequester(listEntry) else Modifier).then(Modifier.focusRequester(rows.getValue(cat))).fillMaxWidth()
                            // Up and Down go to the neighbouring category by name, never by where it happens to be on screen; at either end the remote stays put, and it never leaves sideways but through Right.
                            .focusProperties {
                                up = shown.getOrNull(index - 1)?.let { rows.getValue(it) } ?: (if (index == 0) searchRow else FocusRequester.Cancel)
                                down = shown.getOrNull(index + 1)?.let { rows.getValue(it) } ?: FocusRequester.Cancel
                                left = FocusRequester.Cancel
                            }
                            .onPreviewKeyEvent { e -> if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) { selected = cat.name; runCatching { panelEntry.requestFocus() }.isSuccess } else false },
                        shape = RoundedCornerShape(Tokens.radius), container = Color.Transparent, focusedContainer = Color.Transparent, scaleOnFocus = 1.0f, showRing = false, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE, onFocus = { dwell = it; if (it) scope.launch { reveal(index) } }) { f ->
                        // The same entry as the main menu: a soft fill for the open one, the icon, then the name; the line saying what is inside stays on the page's own header.
                        Row(Modifier.fillMaxWidth().sidebarRowFill(f, isSel).heightIn(min = 44.ui), verticalAlignment = Alignment.CenterVertically) {
                            Spacer(Modifier.width(5.dp))
                            Box(Modifier.width(34.ui), Alignment.Center) {
                                androidx.compose.foundation.Image(cat.icon, null, Modifier.size(22.ui), colorFilter = ColorFilter.tint(if (f || isSel) Color.White else Tokens.textSecondary))
                            }
                            Label(cat.title, Tokens.row, if (f || isSel) Color.White else Tokens.textSecondary, if (isSel) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.weight(1f).padding(start = 8.dp), maxLines = 1)
                            statusOf(cat)?.let { st -> Label(st, Mac.rowDetail, if (isSel) Color(0xCCFFFFFF) else Tokens.textTertiary, FontWeight.Medium, modifier = Modifier.widthIn(max = 90.dp).padding(end = 6.dp)) }
                        }
                    }
                    }
                }
            }
            // The person who is watching sits at the bottom, out of the way: their initial in a blue circle, their name and the app's version.
            Row(Modifier.padding(start = 6.dp, end = 6.dp, top = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val who = profileList.firstOrNull { it.id == activeProfile }?.name ?: "StreamSetu"
                Box(Modifier.size(32.dp).clip(androidx.compose.foundation.shape.CircleShape).background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Mac.blue, Mac.indigo))), Alignment.Center) {
                    Label(who.take(1).uppercase(), 14.sp, Color.White, FontWeight.SemiBold)
                }
                Column { Label(who, Mac.rowTitle, Tokens.text, FontWeight.SemiBold); Label("Version " + app.streamsetu.tv.BuildConfig.VERSION_NAME.substringBefore("-"), Mac.rowDetail, Tokens.textTertiary) }
            }
        }
        // Right: a header for the category, then its groups. Statistics is a lazy list (only the groups near the screen are built); the other pages are still one column.
        val panelMod = Modifier.weight(0.75f).fillMaxHeight().focusRequester(panelEntry).leftGoesTo(rows.getValue(current)).onFocusChanged { inPanel = it.hasFocus }
        val header: @Composable () -> Unit = { Column(Modifier.padding(start = 12.dp, bottom = 2.dp)) { Label(current.title, Mac.pageTitle, Tokens.text, FontWeight.Bold); Label(current.subtitle, Mac.rowDetail, Tokens.textSecondary) } }
        if (searching) {
            SettingsSearchPanel(query, { query = it }, advanced, includeAdvanced, { includeAdvanced = it }, fieldFocus, restoreId, { d ->
                lastResult = d.id; fromSearch = true; restoreId = null; focusTitle = d.focusTargetId; selected = d.category.name; searching = false
            }, panelMod)
            LaunchedEffect(Unit) { if (restoreId == null) { androidx.compose.runtime.withFrameNanos { }; runCatching { fieldFocus.requestFocus() } } }
        } else if (current == Category.STATISTICS) {
            val statsUi = rememberStatsUi(c)
            val statsState = androidx.compose.foundation.lazy.rememberLazyListState()
            val statsTarget = remember(focusTitle) { focusTitle?.let { t -> SettingFocusTarget(t, FocusRequester()) { focusTitle = null } } }
            SweepToSettingTarget(statsState, statsTarget) { focusTitle = null; runCatching { panelEntry.requestFocus() } }          // the control is not on the page: the remote goes to the page
            androidx.compose.runtime.CompositionLocalProvider(LocalSettingFocus provides statsTarget) {
            androidx.compose.foundation.lazy.LazyColumn(panelMod, state = statsState, contentPadding = PaddingValues(start = 26.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                item(key = "header", contentType = "header") { header() }
                statisticsItems(statsUi)
            }
            }
        } else Column(panelMod.verticalScroll(rememberScrollState()).padding(start = 26.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            header()
            val target = remember(focusTitle) { focusTitle?.let { t -> SettingFocusTarget(t, FocusRequester()) { focusTitle = null } } }
            androidx.compose.runtime.CompositionLocalProvider(LocalSettingFocus provides target) { SettingsPanel(current, c, nav) }
        }
    }
}


/** The controls of one category. Shared by the remote layout (beside the list) and the phone layout (a page of its own). */
@Composable
fun SettingsPanel(current: Category, c: AppContainer, nav: Navigator) {
    when (current) {
        Category.PLAYBACK -> PlaybackSettings(c)
        Category.VIDEO -> VideoSettings(c)
        Category.AUDIO -> AudioSettings(c)
        Category.SUBTITLES -> SubtitleSettings(c)
        Category.LIVE -> { LiveSettings(c); RemindersSettings(c); GuideAlertsSettings(c); ScheduledRecordingsSettings(c) }
        Category.CHANNELS -> ChannelManagerSettings(c)
        Category.DEVICE -> DeviceSettings(c, nav)
        Category.STATISTICS -> { WeeklyDigestSettings(c, nav); StatisticsSettings(c) }
        Category.LIBRARIES -> LibrarySettings(c, nav)
        Category.SEARCH -> SearchSettings(c)
        Category.FAVOURITES -> FavouriteSettings(c)
        Category.APPEARANCE -> AppearanceSettings(c)
        Category.PRIVACY -> { PrivacySettings(c); PrivacyReportSettings(c) }
        Category.PODCASTS -> PodcastSettings(c, nav)
        Category.INTEGRATIONS -> IntegrationsSettings(c, nav)
        Category.PROFILES -> ProfileSettings(c)
        Category.SYNC -> SyncSettings(c)
        Category.ADDONS -> AddonsSettings(c)
        Category.STORAGE -> StorageSettings(c)
        Category.DIAGNOSTICS -> DiagnosticsSettings(c)
        Category.ABOUT -> AboutSettings(c)
    }
}

// ---------------------------------------------------------------------------------------------------------------------------------------------

private val languages = listOf("" to "Any", "en" to "English", "hi" to "Hindi", "te" to "Telugu", "ta" to "Tamil", "kn" to "Kannada", "ml" to "Malayalam", "ur" to "Urdu", "ar" to "Arabic", "es" to "Spanish", "fr" to "French", "de" to "German", "pt" to "Portuguese")

@Composable
private fun connections(c: AppContainer): List<Source> = c.sources.sources.collectAsState(initial = emptyList()).value.filter { !it.draft }

/** A group of settings that only the Advanced view lists. What it holds keeps its value and keeps working while it is not listed. */
@Composable
internal fun AdvancedGroup(c: AppContainer, title: String, footer: String? = null, danger: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    val advanced by c.ui.advancedSettings.collectAsState()
    if (advanced) SettingGroup(title, footer, danger, content)
}

@Composable
private fun AdvancedToggle(content: @Composable ColumnScope.() -> Unit) {
    var open by remember { mutableStateOf(false) }
    SettingGroup("Advanced") {
        SettingRow(if (open) "Hide advanced settings" else "Show advanced settings", "Technical options. The defaults suit almost everyone.", if (open) "Shown" else "Hidden") { open = !open }
        if (open) content()
    }
}

@Composable
fun PlaybackSettings(c: AppContainer) {
    val s = c.settings
    val engine by s.enginePreference.collectAsStateWithLifecycle()
    val liveBuf by s.liveBuffering.collectAsStateWithLifecycle(); val vodBuf by s.vodBuffering.collectAsStateWithLifecycle()
    val resume by s.resumeAutomatically.collectAsStateWithLifecycle(); val seek by s.seekSeconds.collectAsStateWithLifecycle(); val next by s.playNextAutomatically.collectAsStateWithLifecycle(); val remember by s.rememberPosition.collectAsStateWithLifecycle()
    val retry by s.automaticRetry.collectAsStateWithLifecycle(); val patience by s.stallPatience.collectAsStateWithLifecycle()
    val mpv = EngineKind.MPV in c.playback.available
    val conns = connections(c)
    var tick by remember { mutableIntStateOf(0) }; tick.let { }

    AdvancedGroup(c, "Player engine", "Automatic chooses the best player for each stream.") {
        ChoiceRow("Default engine", options = listOf(EnginePreference.AUTOMATIC to "Automatic", EnginePreference.EXOPLAYER to "Media3 ExoPlayer", EnginePreference.MPV to if (mpv) "MPV" else "MPV (not available)"), value = engine) { if (it != EnginePreference.MPV || mpv) s.setEngine(it) }
        if (!mpv) InfoRow("MPV", "Not available", "MPV needs Android 8 or later.")
        listOf("LIVE" to "Live TV", "MOVIES" to "Movies and series", "CATCHUP" to "Past programmes").forEach { (kind, label) ->
            val chosen = s.engineForKind(kind)
            ChoiceRow("Engine for $label", if (kind == "LIVE") "Overrides the default for this content type." else null, listOf<Pair<EnginePreference?, String>>(null to "Use the default", EnginePreference.AUTOMATIC to "Automatic", EnginePreference.EXOPLAYER to "Media3 ExoPlayer", EnginePreference.MPV to if (mpv) "MPV" else "MPV (not available)"), chosen) { s.setEngineForKind(kind, it); tick++ }
        }
        if (conns.size > 1 || (conns.isNotEmpty() && s.engineFor(conns.first().id) != null)) conns.forEach { src ->
            val over = s.engineFor(src.id)
            ChoiceRow("Engine for ${src.name}", "Uses this player for this connection.", listOf<Pair<EnginePreference?, String>>(null to "Use global default", EnginePreference.AUTOMATIC to "Automatic", EnginePreference.EXOPLAYER to "Media3 ExoPlayer") + (if (mpv) listOf(EnginePreference.MPV to "MPV") else emptyList()), over) { s.setEngineFor(src.id, it); tick++ }
        }
    }
    SettingGroup("Picture") {
        val matchFps by s.matchFrameRate.collectAsStateWithLifecycle()
        ToggleRow("Match the TV's frame rate", "Matches the TV to the video for smoother motion. The screen may briefly go dark.", matchFps) { s.setMatchFrameRate(it) }
    }
    SettingGroup("Buffering", "A larger buffer handles unstable streams but changes channels more slowly.") {
        ChoiceRow("Live TV buffer", options = listOf(BufferingMode.LOW_LATENCY to "Low latency", BufferingMode.AUTOMATIC to "Balanced", BufferingMode.LARGE to "Stable"), value = liveBuf) { s.setLiveBuffering(it) }
        ChoiceRow("Movies and series buffer", options = listOf(BufferingMode.AUTOMATIC to "Balanced", BufferingMode.LARGE to "Stable"), value = vodBuf) { s.setVodBuffering(it) }
        conns.forEach { src ->
            if (conns.size > 1) ChoiceRow("Live buffer for ${src.name}", "Overrides the global Live TV buffer for this connection.", listOf<Pair<BufferingMode?, String>>(null to "Use global default", BufferingMode.LOW_LATENCY to "Low latency", BufferingMode.AUTOMATIC to "Balanced", BufferingMode.LARGE to "Stable"), s.liveBufferFor(src.id)) { s.setLiveBufferFor(src.id, it); tick++ }
        }
    }
    val dnsAdvanced by c.ui.advancedSettings.collectAsState()
    if (dnsAdvanced) AppDnsGroup(s)          // App DNS is a technical setting: Essential does not list it (it stays on and keeps working)
    AdvancedGroup(c, "Network proxy", "Sends internet streams and playlists through your proxy. Local devices connect directly.") {
        val pk by s.proxyKind.collectAsStateWithLifecycle(); val ph by s.proxyHost.collectAsStateWithLifecycle(); val pp by s.proxyPort.collectAsStateWithLifecycle()
        ChoiceRow("Proxy", options = listOf("NONE" to "None", "HTTP" to "HTTP", "SOCKS" to "SOCKS"), value = pk) { s.setProxyKind(it) }
        if (pk != "NONE") {
            app.streamsetu.tv.ui.components.TvTextField(ph, { s.setProxyHost(it) }, "Proxy host (name or address)", Modifier.fillMaxWidth())
            app.streamsetu.tv.ui.components.TvTextField(if (pp > 0) pp.toString() else "", { s.setProxyPort(it.filter { c -> c.isDigit() }.take(5).toIntOrNull() ?: 0) }, "Proxy port", Modifier.fillMaxWidth())
        }
    }
    SettingGroup("Movies and series") {
        ToggleRow("Remember playback position", "Saves where you stop so Continue Watching works.", remember) { s.setRememberPosition(it) }
        ToggleRow("Resume automatically", "Continue a partly watched title where it stopped.", resume && remember, enabled = remember, reason = "Turn on Remember playback position first.") { s.setResumeAutomatically(it) }
        val bestFirst by s.bestVersionFirst.collectAsStateWithLifecycle()
        ToggleRow("Play the best version first", "Starts the highest-quality copy. If it fails, tries the next best.", bestFirst) { s.setBestVersionFirst(it) }
        ChoiceRow("Skip interval", "How far Left and Right jump while watching.", listOf(5 to "5 seconds", 10 to "10 seconds", 15 to "15 seconds", 30 to "30 seconds"), seek) { s.setSeekSeconds(it) }
        val confirmLeave by s.confirmLeavingPlayer.collectAsStateWithLifecycle()
        ToggleRow("Ask before leaving the player", "Back shows Continue watching or Exit instead of leaving at once.", confirmLeave) { s.setConfirmLeavingPlayer(it) }
        val bgAudio by s.backgroundAudio.collectAsStateWithLifecycle()
        ToggleRow("Keep playing when I leave the app", "Keeps audio playing in the background with system controls.", bgAudio) { s.setBackgroundAudio(it) }
        ToggleRow("Play the next episode automatically", "Only continues to the very next episode; it never plays across a missing one.", next) { s.setPlayNext(it) }
    }
    SettingGroup("Recovery", "Retries the same stream. Another provider stream is never selected automatically.") {
        ToggleRow("Retry a failing stream automatically", "Retries automatically after playback fails.", retry) { s.setAutomaticRetry(it) }
        ChoiceRow("How long to wait for a stream to load", "Past this, loading counts as a failure.", listOf("SHORT" to "Short (10 s live)", "NORMAL" to "Normal (18 s live)", "LONG" to "Long (30 s live)"), patience) { s.setStallPatience(it) }
    }
    val dec by s.decoderFallback.collectAsStateWithLifecycle()
    val showAdvanced by c.ui.advancedSettings.collectAsState()
    if (showAdvanced) AdvancedToggle {
        ToggleRow("Decoder fallback", "Tries another decoder when the first cannot play the stream.", dec) { s.setDecoderFallback(it) }
        ActionRow("Reset player settings", "Puts every setting on the Playback, Audio and Subtitles pages back to its default.", "Reset", danger = true) { s.resetPlayerPreferences() }
    }
}

@Composable
fun VideoSettings(c: AppContainer) {
    val s = c.settings
    val aspect by s.defaultAspect.collectAsStateWithLifecycle(); val info by s.showStreamInfo.collectAsStateWithLifecycle()
    val context = androidx.compose.ui.platform.LocalContext.current
    val display = remember { runCatching { (context.getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager).getDisplay(0) }.getOrNull() }
    val mode = display?.mode
    val hdr = remember { runCatching { display?.hdrCapabilities?.supportedHdrTypes?.map { when (it) { 1 -> "Dolby Vision"; 2 -> "HDR10"; 3 -> "HLG"; 4 -> "HDR10+"; else -> "HDR" } } }.getOrNull().orEmpty() }
    SettingGroup("Picture") {
        ChoiceRow("Default picture size", "Fit shows the full picture. Fill and Zoom crop the edges.", listOf("FIT" to "Fit", "FILL" to "Fill", "ZOOM" to "Zoom"), aspect) { s.setDefaultAspect(it) }
        ToggleRow("Show stream information while playing", "Shows the player, resolution and codecs during playback.", info) { s.setShowStreamInfo(it) }
        SettingRow("Quality", "Streams from IPTV providers have one quality each; adaptive streams (HLS with several levels) are chosen automatically.", "Automatic")
    }
    SettingGroup("This screen") {
        InfoRow("Resolution", mode?.let { "${it.physicalWidth}×${it.physicalHeight} at ${"%.0f".format(it.refreshRate)} Hz" } ?: "unknown")
        InfoRow("HDR formats the TV accepts", hdr.joinToString(", ").ifBlank { "none reported" }, "Played only when the TV, the decoder and the stream all support it.")
    }
    AdvancedGroup(c, "Decoders on this device", "Hardware decoding is used whenever the device has it.") {
        InfoRow("Hardware video decoders", c.maintenance.hardwareDecoders().joinToString(", ").ifBlank { "none found" })
    }
}

@Composable
fun AudioSettings(c: AppContainer) {
    val s = c.settings
    val lang by s.audioLanguage.collectAsStateWithLifecycle(); val remember by s.rememberAudioChoice.collectAsStateWithLifecycle(); val pass by s.surroundPassthrough.collectAsStateWithLifecycle()
    SettingGroup("Language") {
        ChoiceRow("Preferred audio language", "Chosen automatically when a stream has several audio tracks. You can still switch while watching.", languages, lang) { s.setAudioLanguage(it) }
        ToggleRow("Remember the track I choose", "The language you pick while watching becomes the preferred language.", remember) { s.setRememberAudioChoice(it) }
    }
    SettingGroup("Sound output", "Takes effect on the next stream.") {
        ToggleRow("Surround sound passthrough", "On: surround is sent to the TV or receiver as it is, when they support it. Off: this device decodes to stereo (a stereo downmix).", pass) { s.setSurroundPassthrough(it) }
        SettingRow("Audio sync offset", "Shifts the sound earlier or later against the picture.", "Not available", enabled = false, reason = "The Media3 player used for most streams has no sound-delay control.")
    }
}

@Composable
fun SubtitleSettings(c: AppContainer) {
    val s = c.settings; val ui = c.ui
    val mode by s.subtitleMode.collectAsStateWithLifecycle(); val lang by s.subtitleLanguage.collectAsStateWithLifecycle(); val size by s.subtitleSize.collectAsStateWithLifecycle(); val bg by s.subtitleBackground.collectAsStateWithLifecycle(); val outline by s.subtitleOutline.collectAsStateWithLifecycle()
    val anim by ui.animation.collectAsStateWithLifecycle(); val contrast by ui.highContrastFocus.collectAsStateWithLifecycle()
    SettingGroup("Subtitles", "Style applies to the next stream.") {
        ChoiceRow("Subtitles", "Auto turns them on when the sound is not in your preferred audio language.", listOf("OFF" to "Off", "AUTO" to "Auto", "ON" to "On when available"), mode) { s.setSubtitleMode(it) }
        ChoiceRow("Subtitle language", options = languages, value = lang) { s.setSubtitleLanguage(it) }
        ChoiceRow("Size", options = listOf("SMALL" to "Small", "MEDIUM" to "Medium", "LARGE" to "Large", "XLARGE" to "Extra large"), value = size) { s.setSubtitleSize(it) }
        ChoiceRow("Background", options = listOf("NONE" to "None", "DARK" to "Dark box"), value = bg) { s.setSubtitleBackground(it) }
        ToggleRow("Outline", "A dark edge around the letters.", outline) { s.setSubtitleOutline(it) }
        SettingRow("Subtitle delay", "Shifts subtitles earlier or later. Open More, then Sync audio & subtitles while watching (MPV player).", "In the player")
    }
    SettingGroup("Find subtitles online", "From OpenSubtitles, using your own free account and API key (opensubtitles.com, Consumers). They stay on this device and are sent only to OpenSubtitles when you ask for subtitles in the player.") {
        val auto by s.autoSubtitles.collectAsStateWithLifecycle()
        ToggleRow("Fetch automatically", "When a film or episode has no subtitles in your language, loads the most downloaded one a few seconds in. Needs the account below.", auto) { s.setAutoSubtitles(it) }
        var key by remember { mutableStateOf(c.credentials.load("os.key").orEmpty()) }
        var user by remember { mutableStateOf(c.credentials.load("os.user").orEmpty()) }
        var pass by remember { mutableStateOf(c.credentials.load("os.pass").orEmpty()) }
        fun save(name: String, v: String) { if (v.isBlank()) c.credentials.delete(name) else c.credentials.save(name, v.trim()) }
        TvTextField(key, { key = it.trim(); save("os.key", key) }, "OpenSubtitles API key", Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), secret = true)
        TvTextField(user, { user = it.trim(); save("os.user", user) }, "OpenSubtitles account name", Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp))
        TvTextField(pass, { pass = it; save("os.pass", pass) }, "OpenSubtitles password", Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), secret = true)
    }
    SettingGroup("Accessibility") {
        ChoiceRow("Animation", "Reduced and Off remove sliding and fading. Android's own \"remove animations\" setting is also respected.", listOf(app.streamsetu.core.settings.AnimationLevel.FULL to "Full", app.streamsetu.core.settings.AnimationLevel.REDUCED to "Reduced", app.streamsetu.core.settings.AnimationLevel.OFF to "Off"), anim) { ui.setAnimation(it) }
        ToggleRow("High-contrast focus", "Uses a thicker white frame around the focused item.", contrast) { ui.setHighContrastFocus(it) }
        val scale by s.textScalePercent.collectAsStateWithLifecycle()
        ChoiceRow("Text size", "Scales every label in the app.", listOf(100 to "Standard", 115 to "Large", 130 to "Extra large"), scale) { s.setTextScalePercent(it) }
    }
}

@Composable
fun LiveSettings(c: AppContainer) {
    val s = c.settings; val ui = c.ui
    val inv by s.invertChannelKeys.collectAsStateWithLifecycle(); val nums by s.showChannelNumbers.collectAsStateWithLifecycle(); val resumeLast by s.resumeLastChannel.collectAsStateWithLifecycle(); val off by ui.epgOffsetMinutes.collectAsStateWithLifecycle()
    SettingGroup("Watching live TV") {
        ToggleRow("Swap the channel keys", "Off: Up is the next channel and Down the previous one. On: the other way round.", inv) { s.setInvertChannelKeys(it) }
        ToggleRow("Show channel numbers", "The number the provider gives each channel, in lists and when typing a number.", nums) { s.setShowChannelNumbers(it) }
        val group by ui.groupDuplicates.collectAsStateWithLifecycle()
        ToggleRow("Fold the same channel into one row", "A channel that comes in HD, FHD and SD, or from two connections, is one row. Hold OK on it to pick a version.", group) { ui.setGroupDuplicates(it) }
        ToggleRow("Open Live TV on the last channel", "Starts the last channel you watched when Live TV opens. Off: nothing plays until you choose a channel.", resumeLast) { s.setResumeLastChannel(it) }
    }
    val scope = rememberCoroutineScope()
    var guideMsg by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<app.streamsetu.core.model.Source?>(null) }
    val sources by c.sources.sources.collectAsState(initial = emptyList())
    val openIds by c.library.sourceIds.collectAsStateWithLifecycle()
    val zone by s.catchupZone.collectAsStateWithLifecycle()
    val connections = sources.filter { it.id in openIds && !it.draft }.map { GuideConnection(it.id, it.name, it.epgUrl) }
    GuideSettingsContent(
        GuideSettingsModel(connections, off, zone, java.util.TimeZone.getDefault().id, guideMsg),
        GuideSettingsActions(
            refresh = { c.ensureGuide(force = true); guideMsg = "Reading the guide in the background. New programmes and sports events appear when it is done." },
            changeAddress = { id -> editing = sources.firstOrNull { it.id == id } },
            setOffset = { ui.setEpgOffsetMinutes(it) },
            setCatchupZone = { s.setCatchupZone(it) },
        ),
    )
    editing?.let { src ->
        GuideAddressDialog(src, src.epgUrl.orEmpty(), onClose = { editing = null }, onSave = { text -> editing = null; guideMsg = "Reading the guide…"; scope.launch { guideMsg = saveGuideAddress(c, src, text) } })
    }
}

/** The one page that holds the guide's own settings: refresh now, each connection's guide address, the guide time shift and the catch-up time zone. The Sports Hub's "Open Guide Settings" opens it. */
/** The category a "show me this settings page" request names, or null for a name that is not one. */
fun categoryFromRequest(name: String?): Category? = name?.let { n -> Category.values().firstOrNull { it.name == n } }

object GuideSettingsPage { val category = Category.LIVE; val request: String get() = category.name }

@androidx.compose.runtime.Immutable data class GuideConnection(val id: String, val name: String, val address: String?)
@androidx.compose.runtime.Immutable data class GuideSettingsModel(val connections: List<GuideConnection>, val offsetMinutes: Int, val catchupZone: String, val timeZoneId: String, val message: String?)
class GuideSettingsActions(val refresh: () -> Unit, val changeAddress: (String) -> Unit, val setOffset: (Int) -> Unit, val setCatchupZone: (String) -> Unit)

/** The Guide group, as a function of what it shows and what its rows do (so it can be checked without the rest of the app). */
@Composable
fun GuideSettingsContent(m: GuideSettingsModel, a: GuideSettingsActions) {
    SettingGroup("Guide") {
        ActionRow("Refresh guide now", "Reads the programme guide again from your provider.", "Refresh", confirm = false) { a.refresh() }
        m.connections.forEach { cn ->
            ActionRow(if (m.connections.size > 1) "Guide (EPG) address: ${cn.name}" else "Guide (EPG) address", if (cn.address.isNullOrBlank()) "The provider's own guide is used. Paste an XMLTV link here to use another one." else cn.address, "Change", confirm = false) { a.changeAddress(cn.id) }
        }
        ChoiceRow("Guide time shift", "For a provider whose guide is early or late: every programme time moves by this much.", listOf(-120, -90, -60, -30, 0, 30, 60, 90, 120).map { it to if (it == 0) "None" else (if (it > 0) "+" else "−") + "${kotlin.math.abs(it)} min" }, m.offsetMinutes) { a.setOffset(it) }
        ChoiceRow("Catch-up start time", "Providers read the start of a catch-up programme in their own time zone. If a catch-up plays the wrong programme, switch this.", listOf("UTC" to "UTC", "DEVICE" to "This device's time zone"), m.catchupZone) { a.setCatchupZone(it) }
        InfoRow("Time zone", m.timeZoneId, "Guide times are shown in this device's time zone.")
    }
    ResultLine(m.message)
}

internal fun fmtBytes(b: Long): String = when { b >= 1L shl 30 -> "%.1f GB".format(b / (1L shl 30).toDouble()); b >= 1L shl 20 -> "%.1f MB".format(b / (1L shl 20).toDouble()); b >= 1L shl 10 -> "%.0f KB".format(b / 1024.0); else -> "$b B" }


/** Encrypted DNS for StreamSetu's own traffic only. Not a VPN: nothing outside the app changes. */
@Composable
private fun AppDnsGroup(s: app.streamsetu.core.settings.AppSettings) {
    val on by s.appDnsEnabled.collectAsStateWithLifecycle(); val prov by s.appDnsProvider.collectAsStateWithLifecycle()
    val name by s.appDnsName.collectAsStateWithLifecycle(); val url by s.appDnsUrl.collectAsStateWithLifecycle(); val boot by s.appDnsBootstrap.collectAsStateWithLifecycle()
    val local by s.appDnsLocalUsesSystem.collectAsStateWithLifecycle()
    val provider = app.streamsetu.core.net.AppDns.Provider.of(prov)
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var result by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<app.streamsetu.core.net.AppDns.TestResult?>(null) }
    var testing by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    val cfg = app.streamsetu.core.net.AppDns.Config(on, provider, name, url, boot.split(',', ';', ' ').map { it.trim() }.filter { it.isNotEmpty() }, local)
    val problem = if (provider == app.streamsetu.core.net.AppDns.Provider.CUSTOM && url.isNotEmpty()) app.streamsetu.core.net.AppDns.validate(url).exceptionOrNull()?.message else null
    val status = when { !on -> "Not active"; cfg.resolver == null -> "Custom resolver is not valid"; else -> "Requested through ${cfg.resolver!!.name} for library, guide and playback" }
    SettingGroup("App DNS", app.streamsetu.core.net.AppDns.PRIVACY_NOTICE + " It can fix DNS blocking; it cannot get past IP blocking, routing problems or geographic limits.") {
        ToggleRow("Use App DNS", status, on) { s.setAppDnsEnabled(it) }
        ChoiceRow("DNS provider", provider.summary, app.streamsetu.core.net.AppDns.Provider.entries.map { it.name to it.label }, prov) { s.setAppDnsProvider(it) }
        if (provider == app.streamsetu.core.net.AppDns.Provider.CUSTOM) {
            app.streamsetu.tv.ui.components.TvTextField(name, { s.setAppDnsName(it) }, "Name", Modifier.fillMaxWidth())
            app.streamsetu.tv.ui.components.TvTextField(url, { s.setAppDnsUrl(it) }, "https://example.com/dns-query", Modifier.fillMaxWidth())
            app.streamsetu.tv.ui.components.TvTextField(boot, { s.setAppDnsBootstrap(it) }, "Bootstrap IP addresses (optional)", Modifier.fillMaxWidth())
            if (problem != null) InfoRow("Address", problem)
        }
        ToggleRow("Use system DNS for local devices", ".local names, single-label names and local addresses.", local) { s.setAppDnsLocalUsesSystem(it) }
        ActionRow("Test App DNS", result?.let { it.resolverName + (if (it.reachable) " is working · ${it.milliseconds} ms" else " is unavailable") } ?: "Checks your playlist server as well as a public name.", if (testing) "Testing…" else "Test", enabled = !testing) {
            testing = true
            scope.launch(kotlinx.coroutines.Dispatchers.IO) {
                val r = app.streamsetu.core.net.AppDns.test(cfg, emptyList())
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { result = r; testing = false }
            }
        }
        result?.rows?.forEach { InfoRow(it.label, it.detail, it.host) }
        result?.comparison?.let { InfoRow("Compared with device DNS", "", it) }
        ActionRow("Clear DNS cache", null, "Clear") { app.streamsetu.core.net.AppDns.clearCache(); app.streamsetu.core.net.Http.client.connectionPool.evictAll() }
    }
}
