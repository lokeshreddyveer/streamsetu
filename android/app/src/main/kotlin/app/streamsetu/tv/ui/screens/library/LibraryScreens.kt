package app.streamsetu.tv.ui.screens.library

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.focusable
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import app.streamsetu.core.model.*
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

private fun typeIcon(e: LibraryEntry): ImageVector = when {
    e.kind == LibraryEntry.Kind.COMBINED -> Icons.Filled.Layers
    e.kind == LibraryEntry.Kind.UNFINISHED -> Icons.Filled.Edit
    else -> Icons.Filled.Dns
}

private fun healthText(e: LibraryEntry) = when (e.health) {
    LibraryEntry.Health.OK -> "Ready"
    LibraryEntry.Health.NEVER_READ -> "Not read yet"
    LibraryEntry.Health.LAST_READ_FAILED -> "Last refresh failed. Cached content is still available."
    LibraryEntry.Health.UNFINISHED -> "Setup not finished"
}

private fun healthColor(e: LibraryEntry) = when (e.health) {
    LibraryEntry.Health.OK -> Tokens.success
    LibraryEntry.Health.UNFINISHED, LibraryEntry.Health.NEVER_READ -> Tokens.warning
    LibraryEntry.Health.LAST_READ_FAILED -> Tokens.warning
}

private fun lastSync(ms: Long) = if (ms <= 0) "Never" else DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(ms))

private val Gold = Color(0xFFF6A72D)
private val Amber = Color(0xFFFFBE62)
private val Night = Color(0xFF05080D)
private val Slate = Color(0xFFA9B6C8)

/**
 * The opening screen of every launch, as a split screen: the saved libraries as a list on the left (about 35 %), and on the right what the one under the remote is (type, state,
 * counts, last read) with the action to enter it. Nothing opens by itself. Up and Down move through the list, Right goes to the details, Left comes back, OK enters, and holding OK
 * (or the Actions button) opens that library's actions.
 */
@Composable
fun ChooseLibraryScreen(nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    val entries by vm.entries.collectAsState()
    val list = entries
    var previewId by remember { mutableStateOf<String?>(null) }
    val preview = list?.firstOrNull { it.id == previewId } ?: list?.firstOrNull()
    val initial = remember(list) { list?.let { l -> l.firstOrNull { it.id == vm.lastUsedId && it.usable } ?: l.firstOrNull { it.usable } ?: l.firstOrNull() }?.id }
    val initialFocus = remember { FocusRequester() }
    val enterButton = remember { FocusRequester() }
    val emptyAdd = remember { FocusRequester() }          // the one button of the empty screen
    LaunchedEffect(list?.isEmpty()) { if (list != null && list.isEmpty()) { delay(150); runCatching { emptyAdd.requestFocus() } } }
    val listFocus = remember { FocusRequester() }       // the library row the remote last stood on: Left from the details goes back to it
    var focused by remember { mutableStateOf(false) }
    var addMenu by remember { mutableStateOf(false) }
    LaunchedEffect(initial) { if (initial != null && !focused) { delay(120); runCatching { initialFocus.requestFocus() } } }
    LaunchedEffect(initial) { if (previewId == null) previewId = initial }
    val ordered = list.orEmpty().let { l -> l.filter { it.kind == LibraryEntry.Kind.COMBINED } + l.filter { it.kind == LibraryEntry.Kind.CONNECTION } + l.filter { it.kind == LibraryEntry.Kind.UNFINISHED } }

    Row(Modifier.fillMaxSize().background(Tokens.background)) {
        // Left: the libraries.
        Column(Modifier.weight(0.38f).fillMaxHeight().background(Tokens.panel).padding(start = Tokens.safeHorizontal, end = 20.dp, top = Tokens.safeVertical, bottom = Tokens.safeVertical)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(34.dp).clip(RoundedCornerShape(8.dp)))
                Label("Choose Library", Tokens.pageTitle, Tokens.text, FontWeight.Bold)
            }
            Spacer(Modifier.height(18.dp))
            if (list == null) Loading(Modifier.height(120.dp)) else androidx.compose.foundation.lazy.LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(ordered, key = { it.id }) { e ->
                    LibraryRow(e, e.id == initial, initialFocus, enterButton, nav, vm, onPreview = { previewId = e.id; focused = true }, current = if (e.id == (preview?.id ?: initial)) listFocus else null)
                }
                // Add Connection is always the last item of the list. Managing a library is on its own details (the Actions button) and on a long press, not a second list entry.
                item(key = "add") { ListAction("Add Connection", Icons.Filled.Add, enterButton) { addMenu = true } }
            }
            // Settings stays at the lower left, apart from the list by a line.
            Box(Modifier.padding(vertical = 8.dp).fillMaxWidth().height(1.dp).background(Tokens.line))
            ListAction("Settings", Icons.Filled.Settings, enterButton) { nav.openSettingsFromChooser() }
        }
        // Right: what the library under the remote is.
        Box(Modifier.weight(0.62f).fillMaxHeight().padding(horizontal = 56.dp, vertical = Tokens.safeVertical)) {
            Box(Modifier.align(Alignment.TopEnd)) { Clock() }
            androidx.compose.animation.Crossfade(preview, Modifier.fillMaxSize(), animationSpec = androidx.compose.animation.core.tween(180), label = "libraryDetails") { e ->
                if (e == null) Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
                    Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(72.dp).clip(RoundedCornerShape(18.dp)))
                    Label("Welcome", Tokens.hero, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(top = 16.dp))
                    Label("Add a connection to get started.", Tokens.body, Tokens.textSecondary, modifier = Modifier.padding(top = 6.dp))
                    TvButton("Add Connection", { addMenu = true }, Modifier.padding(top = 24.dp).focusRequester(emptyAdd), icon = Icons.Filled.Add, primary = true)
                } else LibraryDetails(e, enterButton, listFocus, nav, vm)
            }
        }
    }
    if (addMenu) ContextMenu("Add a connection", null, listOf(
        MenuAction("Xtream Codes", Icons.Filled.Dns) { nav.base = Base.Setup(SourceType.XTREAM) },
        MenuAction("M3U URL", Icons.Filled.Link) { nav.base = Base.Setup(SourceType.M3U) },
        MenuAction("Stalker / Ministra portal", Icons.Filled.Router) { nav.base = Base.Setup(SourceType.STALKER) },
        MenuAction("Import M3U file", Icons.Filled.Description) { nav.base = Base.Setup(SourceType.LOCAL_FILE) },
        MenuAction("Jellyfin", Icons.Filled.Dns) { nav.base = Base.Setup(SourceType.JELLYFIN) },
        MenuAction("Emby", Icons.Filled.Dns) { nav.base = Base.Setup(SourceType.EMBY) },
        MenuAction("Plex", Icons.Filled.Dns) { nav.base = Base.Setup(SourceType.PLEX) },
        MenuAction("HDHomeRun tuner", Icons.Filled.Router) { nav.base = Base.Setup(SourceType.HDHOMERUN) },
        MenuAction("TVHeadend", Icons.Filled.Router) { nav.base = Base.Setup(SourceType.TVHEADEND) },
        MenuAction("Enigma2 receiver", Icons.Filled.Router) { nav.base = Base.Setup(SourceType.ENIGMA2) },
        MenuAction("WebDAV share", Icons.Filled.Folder) { nav.base = Base.Setup(SourceType.WEBDAV) },
        MenuAction("Combine libraries", Icons.Filled.Layers) { nav.base = Base.Combined() },
    ), onClose = { addMenu = false })
}

/** One saved library in the left list: a small icon, the name, its type and state, and a dot when it was the last one used. */
@Composable
private fun LibraryRow(e: LibraryEntry, isInitial: Boolean, initialFocus: FocusRequester, enter: FocusRequester, nav: Navigator, vm: LibraryViewModel, onPreview: () -> Unit, current: FocusRequester?) {
    Focusable(
        onClick = { if (e.kind == LibraryEntry.Kind.UNFINISHED) nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) else vm.open(e) { nav.enterLibrary() } },
        modifier = (if (isInitial) Modifier.focusRequester(initialFocus) else Modifier).then(if (current != null) Modifier.focusRequester(current) else Modifier).fillMaxWidth().focusProperties { right = enter }.testTag("library-${e.id}"),
        shape = RoundedCornerShape(Tokens.radius), container = Color.Transparent, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1.0f,
        onFocus = { if (it) onPreview() }, onLongClick = { nav.open(Overlay.ManageLibrary(e)) },
    ) { f ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(38.dp).clip(RoundedCornerShape(Tokens.radius)).background(Tokens.elevated), Alignment.Center) {
                Image(typeIcon(e), null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(if (f) Tokens.text else Tokens.textSecondary))
            }
            Column(Modifier.weight(1f)) {
                Label(e.name, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 1)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (e.kind != LibraryEntry.Kind.COMBINED) Box(Modifier.size(7.dp).background(healthColor(e), CircleShape))
                    Label(if (e.kind == LibraryEntry.Kind.COMBINED) "Combined library" else if (e.kind == LibraryEntry.Kind.UNFINISHED) "Setup not finished" else e.typeLabel, Tokens.caption, Tokens.textSecondary, maxLines = 1)
                }
            }
            if (e.lastOpenedAt > 0 && e.id == vm.lastUsedId) Label("Last used", Tokens.caption, Tokens.textTertiary)
        }
    }
}

@Composable
private fun ListAction(text: String, icon: ImageVector, enter: FocusRequester, enabled: Boolean = true, onClick: () -> Unit) {
    Focusable(if (enabled) onClick else ({}), Modifier.fillMaxWidth().focusProperties { right = enter }, shape = RoundedCornerShape(Tokens.radius), container = Color.Transparent, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1.0f) { f ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(38.dp), Alignment.Center) { Image(icon, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(if (!enabled) Tokens.textTertiary else if (f) Tokens.text else Tokens.textSecondary)) }
            Label(text, Tokens.row, if (!enabled) Tokens.textTertiary else Tokens.text, FontWeight.Medium)
        }
    }
}

/** The right side: the name large, what kind of connection it is and how it is doing, what it holds, and the actions. */
@Composable
private fun LibraryDetails(e: LibraryEntry, enter: FocusRequester, back: FocusRequester, nav: Navigator, vm: LibraryViewModel) {
    Column(Modifier.fillMaxSize().leftGoesTo(back), verticalArrangement = Arrangement.Center) {
        Label(if (e.kind == LibraryEntry.Kind.COMBINED) "COMBINED LIBRARY" else if (e.kind == LibraryEntry.Kind.UNFINISHED) "SETUP NOT FINISHED" else e.typeLabel.uppercase(), Tokens.caption, Tokens.textTertiary, FontWeight.Bold, letterSpacing = 1.2.sp)
        Label(e.name, Tokens.hero, Tokens.text, FontWeight.Bold, maxLines = 2, modifier = Modifier.padding(top = 4.dp))
        Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(9.dp).background(healthColor(e), CircleShape))
            Label(healthText(e), Tokens.body, Tokens.textSecondary, maxLines = 2)
        }
        if (e.kind != LibraryEntry.Kind.UNFINISHED) Row(Modifier.padding(top = 22.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Stat("Channels", e.channelCount); Stat("Movies", e.movieCount); Stat("Series", e.seriesCount)
        }
        if (e.kind == LibraryEntry.Kind.CONNECTION) Label("Last read  ·  " + lastSync(e.lastSyncAt), Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(top = 16.dp))
        if (e.health == LibraryEntry.Health.LAST_READ_FAILED) Label("Opening uses what is saved on this device.", Tokens.small, Tokens.warning, modifier = Modifier.padding(top = 4.dp))
        // One dominant action, then the management actions in a quieter row of their own.
        val open = { if (e.kind == LibraryEntry.Kind.UNFINISHED) nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) else vm.open(e) { nav.enterLibrary() } }
        TvButton(if (e.kind == LibraryEntry.Kind.UNFINISHED) "Continue Setup" else "Enter Library", { open() }, Modifier.padding(top = 28.dp).widthIn(min = 260.dp).focusRequester(enter).testTag("enter-library"), icon = Icons.Filled.PlayArrow, primary = true)
        Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TvButton("Actions", { nav.open(Overlay.ManageLibrary(e)) }, icon = Icons.Filled.Tune)
            if (e.kind != LibraryEntry.Kind.UNFINISHED) TvButton("Details", { if (e.kind == LibraryEntry.Kind.COMBINED) nav.base = Base.Combined(e) else nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) }, icon = Icons.Filled.Info)
        }
    }
}

@Composable
private fun Stat(title: String, n: Int) {
    Column(Modifier.background(Tokens.card, RoundedCornerShape(Tokens.radius)).padding(horizontal = 18.dp, vertical = 12.dp)) { Label("%,d".format(n), Tokens.heading, Tokens.text, FontWeight.Bold); Label(title, Tokens.caption, Tokens.textSecondary) }
}

@Composable
private fun Clock() {
    val now by produceState(System.currentTimeMillis()) { while (true) { value = System.currentTimeMillis(); delay(15_000) } }
    Column(horizontalAlignment = Alignment.End) {
        Label(java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault()).format(java.util.Date(now)), Tokens.title, Tokens.text, FontWeight.SemiBold)
        Label(java.text.SimpleDateFormat("EEE, MMM d", java.util.Locale.getDefault()).format(java.util.Date(now)), Tokens.small, Tokens.textSecondary)
    }
}

@Composable
private fun IconTile(icon: ImageVector, bg: Color, tint: Color, size: Int = 40) {
    Box(Modifier.size(size.dp).clip(RoundedCornerShape(11.dp)).background(bg), Alignment.Center) { Image(icon, null, Modifier.size((size * 0.55f).dp), colorFilter = ColorFilter.tint(tint)) }
}

@Composable
private fun StatTile(icon: ImageVector, title: String, n: Int) {
    Column(Modifier.width(118.dp).background(Color(0x990A1018), RoundedCornerShape(18.dp)).border(1.dp, Color(0x26FFFFFF), RoundedCornerShape(18.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Image(icon, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.textSecondary))
        Label("%,d".format(n), Tokens.pageTitle, Tokens.text, FontWeight.Bold)
        Label(title, Tokens.small, Tokens.textSecondary)
    }
}

/** The main action: a wide white pill that glows gold when the remote is on it. */
@Composable
private fun BigPill(text: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = Color(0xFFDDE3EA), focusedContainer = Color.White, ring = Gold, scaleOnFocus = 1.03f) { _ ->
        Row(Modifier.fillMaxWidth().padding(vertical = 13.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Image(icon, null, Modifier.size(22.dp), colorFilter = ColorFilter.tint(Color.Black)); Spacer(Modifier.width(10.dp)); Label(text, Tokens.title, Color.Black, FontWeight.Bold)
        }
    }
}

@Composable
private fun GhostPill(text: String, icon: ImageVector, onClick: () -> Unit) {
    Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = Color(0x66101011), focusedContainer = Color(0xFF222224), ring = Gold, hairline = true, scaleOnFocus = 1.04f) { f ->
        Row(Modifier.padding(horizontal = 18.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Image(icon, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(if (f) Gold else Tokens.text)); Label(text, Tokens.row, Tokens.text, FontWeight.Medium)
        }
    }
}

@Composable
private fun QuickTile(title: String, sub: String, icon: ImageVector, bg: Color, tint: Color, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(14.dp), container = Color(0xFF121213), ring = Gold, hairline = true, scaleOnFocus = 1.03f) { _ ->
        Row(Modifier.padding(horizontal = 10.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            IconTile(icon, bg, tint, 38)
            Column { Label(title, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 1); Label(sub, Tokens.caption, Tokens.textSecondary, maxLines = 1) }
        }
    }
}

private fun typeOf(e: LibraryEntry) = SourceType.fromLabel(e.typeLabel)

@Composable
private fun LibraryTile(e: LibraryEntry, isInitial: Boolean, initialFocus: FocusRequester, nav: Navigator, vm: LibraryViewModel, onPreview: () -> Unit, onFocused: () -> Unit) {
    val (tileBg, tileTint) = when {
        e.kind == LibraryEntry.Kind.COMBINED -> Color(0xFF2A2A2C) to Color.White
        e.kind == LibraryEntry.Kind.UNFINISHED -> Color(0xFF4A3A14) to Gold
        e.typeLabel == "M3U URL" -> Color(0xFF3A2A66) to Color(0xFFA48BFF)
        e.typeLabel == "Local M3U file" -> Color(0xFF14463A) to Color(0xFF3DDCA8)
        else -> Color(0xFF1B3A5C) to Color(0xFF4DA3FF)
    }
    Focusable(
        onClick = { if (e.kind == LibraryEntry.Kind.UNFINISHED) nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) else vm.open(e) { nav.enterLibrary() } },
        modifier = (if (isInitial) Modifier.focusRequester(initialFocus) else Modifier).width(240.dp).height(190.dp),
        scaleOnFocus = 1.06f, container = Color(0xFF0E1218), focusedContainer = Color(0xFF1A1F27), ring = Gold, shape = RoundedCornerShape(22.dp), hairline = true,
        onFocus = { if (it) { onPreview(); onFocused() } },
        onLongClick = { nav.open(Overlay.ManageLibrary(e)) },
    ) { _ ->
        Column(Modifier.fillMaxSize().padding(18.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            IconTile(typeIcon(e), tileBg, tileTint, 64)
            Label(e.name, Tokens.title, Tokens.text, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.padding(top = 12.dp))
            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (e.kind != LibraryEntry.Kind.COMBINED) Box(Modifier.size(8.dp).background(healthColor(e), CircleShape))
                Label(if (e.kind == LibraryEntry.Kind.COMBINED) "Combined" else if (e.kind == LibraryEntry.Kind.UNFINISHED) "Unfinished" else e.typeLabel, Tokens.caption, Tokens.textSecondary, maxLines = 1)
            }
        }
    }
}

/** Shown when there is no working library yet. */
@Composable
fun WelcomeScreen(nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    val entries by vm.entries.collectAsState()
    val drafts = entries.orEmpty().filter { it.kind == LibraryEntry.Kind.UNFINISHED }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(150); runCatching { first.requestFocus() } }
    Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.brand_wordmark), null, Modifier.height(220.dp))
        Spacer(Modifier.height(6.dp))
        Label("Welcome to StreamSetu", Tokens.display, Tokens.text, FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Label("A player for your own IPTV connection. Choose how you want to connect.", Tokens.body, Tokens.textSecondary)
        Spacer(Modifier.height(10.dp))
        Label("StreamSetu does not provide channels, movies or subscriptions.", Tokens.small, Tokens.textTertiary)
        Spacer(Modifier.height(4.dp))
        Label("1. Add your playlist or login   2. Let it load, big lists take a minute   3. Search, add favorites, press play", Tokens.small, Tokens.textSecondary)
        Spacer(Modifier.height(4.dp))
        Label("Arrow keys move  ·  OK chooses  ·  hold OK for options  ·  Back goes back", Tokens.small, Tokens.textTertiary)
        Spacer(Modifier.height(26.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            SetupCard("Xtream Codes", "Server, user name and password", Icons.Filled.Dns, Modifier.focusRequester(first)) { nav.base = Base.Setup(SourceType.XTREAM) }
            SetupCard("M3U URL", "A playlist link", Icons.Filled.Link, Modifier) { nav.base = Base.Setup(SourceType.M3U) }
            SetupCard("Local M3U File", "A playlist file on this device", Icons.Filled.Folder, Modifier) { nav.base = Base.Setup(SourceType.LOCAL_FILE) }
            SetupCard("Stalker Portal", "Portal address and MAC", Icons.Filled.Router, Modifier) { nav.base = Base.Setup(SourceType.STALKER) }
        }
        if (drafts.isNotEmpty()) {
            Spacer(Modifier.height(22.dp))
            TvButton("Continue Previous Setup", { val d = drafts.first(); nav.base = Base.Setup(typeOf(d), d.sourceIds.first()) }, icon = Icons.Filled.Edit)
        }
    }
}

@Composable
private fun SetupCard(title: String, subtitle: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier.width(170.dp).height(130.dp), container = Tokens.card, scaleOnFocus = 1.04f, shape = RoundedCornerShape(Tokens.radiusLarge)) { _ ->
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
            Image(icon, null, Modifier.size(30.dp), colorFilter = ColorFilter.tint(Tokens.accent))
            Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold)
            Label(subtitle, Tokens.small, Tokens.textSecondary, maxLines = 2)
        }
    }
}

/** Entering a connection, testing it by hand, and either saving it as a working library or keeping it as a draft. */
@Composable
fun SetupScreen(type: SourceType, draftId: String?, nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    var form by remember { mutableStateOf(LibraryViewModel.Form()) }
    var id by remember { mutableStateOf(draftId) }
    var message by remember { mutableStateOf<String?>(null) }
    val test by vm.test.collectAsState()
    val first = remember { FocusRequester() }
    val context = LocalContext.current
    LaunchedEffect(draftId) {
        vm.resetTest()
        if (draftId != null) vm.draft(draftId)?.let { (s, pw) -> form = LibraryViewModel.Form(s.name, s.address, s.username.orEmpty(), pw.orEmpty(), s.userAgent.orEmpty(), vm.headersFor(draftId), vm.trustsCertificate(draftId)) }
        delay(150); runCatching { first.requestFocus() }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            runCatching { context.contentResolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            form = form.copy(address = uri.toString(), name = form.name.ifBlank { uri.lastPathSegment?.substringAfterLast('/')?.substringBeforeLast('.').orEmpty() })
        }
    }
    var phoneOpen by remember { mutableStateOf(false) }
    var reveal by remember { mutableStateOf(false) }
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
        if (uri != null) {
            runCatching { context.contentResolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            form = form.copy(address = uri.toString(), name = form.name.ifBlank { Uri.decode(uri.lastPathSegment.orEmpty()).substringAfterLast(':').substringAfterLast('/') })
        }
    }
    val canTest = when (type) {
        SourceType.XTREAM, SourceType.TVHEADEND, SourceType.JELLYFIN, SourceType.EMBY -> form.address.isNotBlank() && form.user.isNotBlank() && form.password.isNotBlank()
        SourceType.PLEX -> form.address.isNotBlank() && form.password.isNotBlank()
        SourceType.STALKER -> form.address.isNotBlank() && Regex("""^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$""").matches(form.user.trim())
        else -> form.address.isNotBlank()
    }
    val title = when (type) { SourceType.XTREAM -> "Add Xtream Connection"; SourceType.M3U -> "Add M3U URL"; SourceType.LOCAL_FILE -> "Add Local M3U File"; SourceType.STALKER -> "Add Stalker Portal"; else -> "Add ${type.label}" }

    val passed = test as? LibraryViewModel.Test.Passed
    if (passed != null) {
        val open = remember { FocusRequester() }
        LaunchedEffect(Unit) { delay(150); runCatching { open.requestFocus() } }
        Column(Modifier.fillMaxSize().screenPadding(), verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically)) {
            Label("Connection verified", Tokens.display, Tokens.text, FontWeight.Bold)
            Label(passed.name, Tokens.heading, Tokens.accent, FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { StatTile(Icons.Filled.LiveTv, "Live TV", passed.channels); StatTile(Icons.Filled.Movie, "Movies", passed.movies); StatTile(Icons.Filled.VideoLibrary, "Series", passed.series) }
            Label("Saved on this device. Your login is kept in the Android Keystore and is never shown or logged.", Tokens.body, Tokens.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Enter Home", {
                    vm.entries.value?.firstOrNull { it.id == "src:${passed.sourceId}" }?.let { e -> vm.open(e) { nav.enterLibrary() } }
                }, Modifier.focusRequester(open), icon = Icons.Filled.PlayArrow, primary = true)
                TvButton("Back to Libraries", { vm.resetTest(); nav.base = Base.ChooseLibrary })
            }
        }
        return
    }

    if (phoneOpen) PhoneSetupDialog(onFilled = { t, f -> form = f; vm.resetTest() }, onClose = { phoneOpen = false })
    val hasPassword = type in setOf(SourceType.XTREAM, SourceType.TVHEADEND, SourceType.ENIGMA2, SourceType.JELLYFIN, SourceType.EMBY, SourceType.PLEX, SourceType.WEBDAV)
    Row(Modifier.fillMaxSize().screenPadding(), horizontalArrangement = Arrangement.spacedBy(48.dp)) {
        // Left: what is being added, and where this step sits.
        Column(Modifier.weight(0.34f).fillMaxHeight(), verticalArrangement = Arrangement.Center) {
            Label(title, Tokens.display, Tokens.text, FontWeight.Bold)
            Label(when (type) {
                SourceType.XTREAM -> "Your provider's server address, user name and password."
                SourceType.M3U -> "A playlist link from your provider."
                SourceType.LOCAL_FILE, SourceType.LOCAL_FOLDER -> "Read from this device."
                else -> "Read from ${type.label}."
            }, Tokens.body, Tokens.textSecondary, maxLines = 3, modifier = Modifier.padding(top = 8.dp, bottom = 24.dp))
            listOf("Details" to true, "Test the connection" to (test is LibraryViewModel.Test.Running), "Enter the library" to false).forEachIndexed { i, (step, now) ->
                Row(Modifier.padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(Modifier.size(26.dp).background(if (now || (i == 0 && test !is LibraryViewModel.Test.Running)) Color.White else Tokens.elevated, CircleShape), Alignment.Center) { Label("${i + 1}", Tokens.small, if (now || (i == 0 && test !is LibraryViewModel.Test.Running)) Tokens.onBright else Tokens.textSecondary, FontWeight.Bold) }
                    Label(step, Tokens.row, if (now || (i == 0 && test !is LibraryViewModel.Test.Running)) Tokens.text else Tokens.textSecondary, FontWeight.Medium)
                }
            }
            Label("Your login is kept in the Android Keystore and is never shown or logged.", Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.padding(top = 24.dp))
        }
        // Right: the fields and the actions.
        Column(Modifier.weight(0.66f).fillMaxHeight().verticalScroll(androidx.compose.foundation.rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically)) {
        TvTextField(form.name, { form = form.copy(name = it) }, "Name (optional)", Modifier.widthIn(max = 640.dp).fillMaxWidth().focusRequester(first))
        when (type) {
            SourceType.HDHOMERUN -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Tuner address (192.168.1.50 or hdhomerun.local)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                Label("Channels are read from the tuner on your network. Run a channel scan in the tuner's own setup first.", Tokens.small, Tokens.textTertiary)
            }
            SourceType.TVHEADEND -> LoginFields(form, "Server (http://host:9981)", "User name", "Password", reveal) { form = it }
            SourceType.ENIGMA2 -> {
                LoginFields(form, "Receiver address (http://192.168.1.60)", "User name (only if the receiver asks)", "Password", reveal) { form = it }
                Label("Needs OpenWebif on the receiver. Streams play from its own stream port (8001).", Tokens.small, Tokens.textTertiary)
            }
            SourceType.JELLYFIN, SourceType.EMBY -> {
                LoginFields(form, "Server (http://host:8096)", "User name", "Password", reveal) { form = it }
                Label("Movies and series from the server's libraries. Live TV is not read.", Tokens.small, Tokens.textTertiary)
            }
            SourceType.PLEX -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Server (http://host:32400)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.password, { form = form.copy(password = it) }, "Access token (X-Plex-Token)", Modifier.widthIn(max = 640.dp).fillMaxWidth(), secret = !reveal)
                Label("Movies and shows from the server's libraries. Find the token in Plex Web: Get Info, View XML, the address ends in X-Plex-Token=…", Tokens.small, Tokens.textTertiary, maxLines = 3)
            }
            SourceType.WEBDAV -> {
                LoginFields(form, "Share address (https://host/remote.php/dav/files/me/)", "User name (optional)", "Password (optional)", reveal) { form = it }
                Label("Video files in the share and its folders (four levels deep) appear as movies.", Tokens.small, Tokens.textTertiary)
            }
            SourceType.LOCAL_FOLDER -> {
                Label(if (form.address.isBlank()) "No folder chosen" else "Chosen: " + Uri.decode(Uri.parse(form.address).lastPathSegment.orEmpty()).substringAfterLast(':'), Tokens.body, Tokens.textSecondary)
                TvButton("Choose Folder…", { folderPicker.launch(null) }, icon = Icons.Filled.Folder)
                Label("Video files in the folder and its sub-folders appear as movies.", Tokens.small, Tokens.textTertiary)
            }
            SourceType.XTREAM -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Server address (http://host:port)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.user, { form = form.copy(user = it) }, "User name", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.password, { form = form.copy(password = it) }, "Password", Modifier.widthIn(max = 640.dp).fillMaxWidth(), secret = !reveal)
            }
            SourceType.STALKER -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Portal address (http://host/c/)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.user, { form = form.copy(user = it) }, "MAC address (00:1A:79:xx:xx:xx)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                Label("Live TV is read from the portal. Movies and series from portals are not supported yet.", Tokens.small, Tokens.textTertiary)
            }
            SourceType.M3U -> TvTextField(form.address, { form = form.copy(address = it) }, "Playlist link (http://…/playlist.m3u)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
            SourceType.LOCAL_FILE -> {
                Label(if (form.address.isBlank()) "No file chosen" else "Chosen: ${Uri.parse(form.address).lastPathSegment?.substringAfterLast('/') ?: form.address}", Tokens.body, Tokens.textSecondary)
                TvButton("Choose File…", { picker.launch(arrayOf("*/*")) }, icon = Icons.Filled.Folder)
            }
        }
        // User-Agent, headers and the certificate choice are for the few providers that need them, so they are folded away; the basic form is just the address and the login.
        if (type != SourceType.LOCAL_FILE && type != SourceType.LOCAL_FOLDER) {
            var advanced by remember { mutableStateOf(form.userAgent.isNotBlank() || form.headers.isNotBlank() || form.trustCertificate) }
            TvButton(if (advanced) "Hide advanced options" else "Advanced options", { advanced = !advanced }, icon = if (advanced) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore)
            if (advanced) {
                TvTextField(form.userAgent, { form = form.copy(userAgent = it) }, "User-Agent (optional)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.headers, { form = form.copy(headers = it) }, "Extra headers (optional): Name: value || Name: value", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvButton(if (form.trustCertificate) "Trust this provider's own certificate: on" else "Trust this provider's own certificate: off", { form = form.copy(trustCertificate = !form.trustCertificate) }, icon = if (form.trustCertificate) Icons.Filled.LockOpen else Icons.Filled.Lock)
                Label(if (form.trustCertificate) "Its certificate is not checked, so anyone on the network could pose as it." else "Only if streams stop with a certificate error (MPV only).", Tokens.small, if (form.trustCertificate) Tokens.danger else Tokens.textTertiary, maxLines = 2, modifier = Modifier.widthIn(max = 640.dp))
            }
        }
        if (hasPassword) TvButton(if (reveal) "Hide password" else "Show password", { reveal = !reveal }, icon = if (reveal) Icons.Filled.VisibilityOff else Icons.Filled.Visibility)
        (test as? LibraryViewModel.Test.Failed)?.let { TvStatusState("The connection did not work", Modifier.widthIn(max = 640.dp), detail = it.message, icon = Icons.Filled.ErrorOutline) }
        message?.let { Label(it, Tokens.body, Tokens.textSecondary) }
        if (test is LibraryViewModel.Test.Running) Row(Modifier.fillMaxWidth().widthIn(max = 640.dp).background(Tokens.card, RoundedCornerShape(Tokens.radius)).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Spinner(); Label("Testing the connection and reading the catalog. This can take a minute for big lists…", Tokens.body, Tokens.textSecondary, maxLines = 3)
        } else {
            // The main action first, and on a row with the phone, which is the easier way to type a login; saving a draft and cancelling are a quieter row below it.
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                TvButton("Test Connection", { if (canTest) { message = null; vm.test(type, id, form) } else message = "Fill in the details first." }, icon = Icons.Filled.PlayArrow, primary = true)
                if (type == SourceType.XTREAM || type == SourceType.M3U) TvButton("Use my phone", { phoneOpen = true }, icon = Icons.Filled.PhoneAndroid)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                TvButton("Save as Draft", { vm.saveDraft(type, id, form) { saved -> id = saved; message = "Saved. Finish it any time from Choose Your Library." } })
                TvButton("Cancel", { nav.base = Base.ChooseLibrary })
            }
        }
        }
    }
}

/** Builds a library out of several connections. It copies nothing; it only remembers which connections belong together. */
@Composable
fun CombinedScreen(editing: LibraryEntry?, nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    var name by remember { mutableStateOf(editing?.name.orEmpty()) }
    var chosen by remember { mutableStateOf<Set<String>>(emptySet()) }
    var connections by remember { mutableStateOf<List<Source>?>(null) }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        connections = vm.connections()
        if (editing != null) chosen = vm.memberIds(editing).toSet()
        delay(150); runCatching { first.requestFocus() }
    }
    Column(Modifier.fillMaxSize().screenPadding(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Label(if (editing == null) "Create Combined Library" else "Edit Combined Library", Tokens.display, Tokens.text, FontWeight.Bold)
        Label("Choose the connections to show together. Nothing is copied; each keeps its own catalog.", Tokens.body, Tokens.textSecondary)
        TvTextField(name, { name = it }, "Library name", Modifier.widthIn(max = 640.dp).fillMaxWidth())
        val list = connections
        when {
            list == null -> Loading(Modifier.height(80.dp))
            list.size < 2 && editing == null -> Label("Add at least two connections first. Then combine them here.", Tokens.body, Tokens.warning)
            else -> LazyColumn(Modifier.weight(1f).widthIn(max = 640.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(list, key = { it.id }) { s ->
                    val on = s.id in chosen
                    Focusable({ chosen = if (on) chosen - s.id else chosen + s.id }, (if (s === list.first()) Modifier.focusRequester(first) else Modifier).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Image(if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(if (on) Tokens.accent else Tokens.textTertiary))
                            Column(Modifier.weight(1f)) { Label(s.name, Tokens.title, Tokens.text, FontWeight.SemiBold); Label("%,d live · %,d movies · %,d series".format(s.channelCount, s.movieCount, s.seriesCount), Tokens.small, Tokens.textSecondary) }
                        }
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val ready = chosen.size >= 2 || (editing != null && chosen.isNotEmpty())
            TvButton(if (editing == null) "Create Library" else "Save", {
                if (ready) {
                    if (editing == null) vm.createCombined(name, chosen.toList()) { nav.base = Base.ChooseLibrary }
                    else vm.updateCombined(editing, name.ifBlank { editing.name }, chosen.toList()) { nav.base = Base.ChooseLibrary }
                }
            }, icon = Icons.Filled.Check, primary = true)
            TvButton("Cancel", { nav.base = Base.ChooseLibrary })
        }
    }
}

/** The long-press menu of a library or connection. */
@Composable
fun ManageLibraryDialog(entry: LibraryEntry, nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    var confirmDelete by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf(entry.name) }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(120); runCatching { first.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Color(0xCC000000)), Alignment.Center) {
        Column(Modifier.width(420.dp).background(Tokens.card, RoundedCornerShape(Tokens.radiusPanel)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Label(entry.name, Tokens.title, Tokens.text, FontWeight.Bold)
            Label(entry.typeLabel, Tokens.small, Tokens.textSecondary)
            Spacer(Modifier.height(6.dp))
            if (renaming) {
                TvTextField(newName, { newName = it }, "Name", Modifier.fillMaxWidth().focusRequester(first))
                TvButton("Save Name", { vm.rename(entry, newName.ifBlank { entry.name }); nav.close() }, primary = true)
            } else {
                if (entry.kind != LibraryEntry.Kind.UNFINISHED) MenuRow("Open", Icons.Filled.PlayArrow, Modifier.focusRequester(first)) { nav.close(); vm.open(entry) { nav.enterLibrary() } }
                if (entry.kind == LibraryEntry.Kind.UNFINISHED) MenuRow("Continue Setup", Icons.Filled.Edit, Modifier.focusRequester(first)) { nav.close(); nav.base = Base.Setup(typeOf(entry), entry.sourceIds.first()) }
                if (entry.kind != LibraryEntry.Kind.UNFINISHED) MenuRow(if (busy) "Refreshing…" else "Refresh Catalog Now", Icons.Filled.Refresh) { if (!busy) { busy = true; vm.refresh(entry) { err -> busy = false; status = err ?: "Catalog refreshed." } } }
                if (entry.kind == LibraryEntry.Kind.CONNECTION) MenuRow("Edit Connection", Icons.Filled.Edit) { nav.close(); nav.base = Base.Setup(typeOf(entry), entry.sourceIds.first()) }
                if (entry.kind == LibraryEntry.Kind.COMBINED) MenuRow("Edit Members", Icons.Filled.Layers) { nav.close(); nav.base = Base.Combined(entry) }
                MenuRow("Rename", Icons.Filled.Edit) { renaming = true }
                if (entry.kind != LibraryEntry.Kind.UNFINISHED) MenuRow("Connection Information", Icons.Filled.Info) {
                    status = healthText(entry) + (if (entry.kind == LibraryEntry.Kind.CONNECTION) "  ·  last read " + lastSync(entry.lastSyncAt) else "") + "  ·  %,d channels, %,d movies, %,d series".format(entry.channelCount, entry.movieCount, entry.seriesCount)
                }
                MenuRow(if (confirmDelete) "Press again to delete" else "Delete", Icons.Filled.Delete) {
                    if (!confirmDelete) confirmDelete = true else vm.delete(entry) { nav.close() }
                }
                MenuRow("Cancel", Icons.Filled.Close) { nav.close() }
                status?.let { Label(it, Tokens.small, Tokens.textSecondary, maxLines = 4) }
            }
        }
    }
}

@Composable
private fun MenuRow(title: String, icon: ImageVector, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier.fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Image(icon, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(Tokens.accent))
            Label(title, Tokens.row, Tokens.text)
        }
    }
}

/** Shows a QR code; the phone types the connection; the TV shows what arrived (never the password) and the person approves it. Then the form is filled in, ready to test. */
@Composable
fun PhoneSetupDialog(onFilled: (SourceType, LibraryViewModel.Form) -> Unit, onClose: () -> Unit) {
    var received by remember { mutableStateOf<app.streamsetu.tv.PhoneSetup?>(null) }
    var link by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf(false) }
    var left by remember { mutableIntStateOf(300) }
    val server = remember { app.streamsetu.tv.PhoneSetupServer { received = it } }
    DisposableEffect(Unit) { link = server.start(); failed = link == null; onDispose { server.stop() } }
    LaunchedEffect(Unit) { while (true) { left = server.secondsLeft; delay(1000); if (left == 0) onClose() } }
    val first = remember { FocusRequester() }
    LaunchedEffect(received) { delay(120); runCatching { first.requestFocus() } }
    TvDialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.Center) {
            Column(Modifier.width(420.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(18.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val r = received
                when {
                    r != null -> {
                        Label("Approve this connection?", Tokens.title, Tokens.text, FontWeight.Bold)
                        Label(listOf(if (r.type == "m3u") "M3U link" else "Xtream login", r.name.ifBlank { null }).filterNotNull().joinToString("  ·  "), Tokens.body, Tokens.accent)
                        Label(r.address.let { runCatching { java.net.URI(if ("://" in it) it else "http://$it").host }.getOrNull() ?: "address received" }, Tokens.body, Tokens.textSecondary)
                        if (r.user.isNotBlank()) Label("User: ${r.user}   Password: received", Tokens.small, Tokens.textSecondary)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TvButton("Approve", { onFilled(if (r.type == "m3u") SourceType.M3U else SourceType.XTREAM, LibraryViewModel.Form(r.name, r.address, r.user, r.password)); onClose() }, Modifier.focusRequester(first), primary = true)
                            TvButton("Decline", onClose)
                        }
                    }
                    failed -> { Label("No home network found", Tokens.title, Tokens.text, FontWeight.Bold); Label("Connect the TV to Wi-Fi or Ethernet, or type it with the remote.", Tokens.body, Tokens.textSecondary, maxLines = 3); TvButton("Close", onClose, Modifier.focusRequester(first)) }
                    else -> {
                        Label("Scan with your phone", Tokens.title, Tokens.text, FontWeight.Bold)
                        link?.let { u -> QrCode(u, Modifier.size(170.dp)); Label(u, Tokens.caption, Tokens.textSecondary, maxLines = 2) }
                        Label("Valid for ${left / 60}:%02d. Works on your home network only, and is not encrypted: use it on your own Wi-Fi, not a shared one.".format(left % 60), Tokens.small, Tokens.textTertiary)
                        TvButton("Cancel", onClose, Modifier.focusRequester(first))
                    }
                }
            }
        }
    }
}

@Composable
private fun QrCode(text: String, modifier: Modifier) {
    val matrix = remember(text) { com.google.zxing.qrcode.QRCodeWriter().encode(text, com.google.zxing.BarcodeFormat.QR_CODE, 0, 0, mapOf(com.google.zxing.EncodeHintType.MARGIN to 1)) }
    androidx.compose.foundation.Canvas(modifier.background(Color.White)) {
        val n = matrix.width; val cell = size.width / n
        for (y in 0 until matrix.height) for (x in 0 until n) if (matrix[x, y]) drawRect(Color.Black, androidx.compose.ui.geometry.Offset(x * cell, y * cell), androidx.compose.ui.geometry.Size(cell + 0.5f, cell + 0.5f))
    }
}


@Composable
private fun UtilityButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Focusable(onClick, Modifier, shape = CircleShape, container = Color(0x1AFFFFFF), focusedContainer = Color(0x33FFFFFF), ring = Gold, hairline = true, scaleOnFocus = 1.08f) { f ->
        Image(icon, label, Modifier.padding(13.dp).size(22.dp), colorFilter = ColorFilter.tint(if (f) Amber else Color(0xFFF5F7FA)))
    }
}

/** A dark mountain horizon under a warm sunset, drawn here so it needs no picture file. */
@Composable
private fun HeroArt(modifier: Modifier) {
    androidx.compose.foundation.Canvas(modifier) {
        val w = size.width; val h = size.height
        drawRect(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color(0xFF05080D), Color(0xFF1A1420), Color(0xFF6B3A1E), Color(0xFFF08A2E)), startY = 0f, endY = h * 0.62f))
        drawCircle(androidx.compose.ui.graphics.Brush.radialGradient(listOf(Color(0xCCFFC56B), Color(0x00FFC56B)), center = androidx.compose.ui.geometry.Offset(w * 0.78f, h * 0.55f), radius = h * 0.5f), radius = h * 0.5f, center = androidx.compose.ui.geometry.Offset(w * 0.78f, h * 0.55f))
        fun ridge(color: Color, base: Float, amp: Float, seed: Int) {
            val path = androidx.compose.ui.graphics.Path().apply {
                moveTo(0f, h)
                var x = 0f
                lineTo(0f, h * base)
                while (x < w) { x += w / 14f; val k = ((x / w * 11f + seed) * 1.7f); lineTo(x, h * base - h * amp * (0.5f + 0.5f * kotlin.math.sin(k) * kotlin.math.cos(k * 0.6f))) }
                lineTo(w, h); close()
            }
            drawPath(path, color)
        }
        ridge(Color(0xFF2A1A18), 0.80f, 0.16f, 1); ridge(Color(0xFF140E10), 0.88f, 0.12f, 4); ridge(Color(0xFF07090D), 0.95f, 0.08f, 7)
    }
}


/** The opening animation: the mark fades in and rises, drifts slowly larger for about six seconds, then fades out into the library screen. Any key skips it. */
@Composable
fun LogoReveal(reduced: Boolean, onDone: () -> Unit) {
    val a = remember { androidx.compose.animation.core.Animatable(if (reduced) 1f else 0f) }
    val drift = remember { androidx.compose.animation.core.Animatable(1f) }
    val root = remember { FocusRequester() }
    // A quiet start: the wordmark fades in, holds for a moment and fades out, under two seconds in all. Any key skips it.
    LaunchedEffect(Unit) {
        runCatching { root.requestFocus() }
        if (!reduced) a.animateTo(1f, androidx.compose.animation.core.tween(400, easing = app.streamsetu.core.ui.motion.Motion.Standard))
        delay(if (reduced) 400 else 800)
        a.animateTo(0f, androidx.compose.animation.core.tween(if (reduced) 0 else 260))
        onDone()
    }
    Box(Modifier.fillMaxSize().background(Color.Black).focusRequester(root).focusable().onPreviewKeyEvent { if (it.type == androidx.compose.ui.input.key.KeyEventType.KeyDown) { onDone(); true } else false }, Alignment.Center) {
        Column(Modifier.graphicsLayer { alpha = a.value; translationY = (1f - a.value) * 18.dp.toPx(); scaleX = drift.value; scaleY = drift.value }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.brand_wordmark), null, Modifier.fillMaxSize().graphicsLayer { scaleX = 1.1f; scaleY = 1.1f }, contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        }
    }
}



/** The page margins of a full-screen form: wide on a television, narrow and clear of the status and navigation bars on a phone. */
@Composable
private fun Modifier.screenPadding(): Modifier =
    if (app.streamsetu.tv.ui.phone.isPhoneDevice(LocalContext.current)) this.windowInsetsPadding(WindowInsets.systemBars).padding(horizontal = 20.dp, vertical = 16.dp)
    else this.padding(horizontal = 120.dp, vertical = Tokens.safeVertical)


/** The three fields of a connection that signs in with a server address, a user name and a password. */
@Composable
private fun LoginFields(form: LibraryViewModel.Form, addressHint: String, userHint: String, passwordHint: String, reveal: Boolean = false, onChange: (LibraryViewModel.Form) -> Unit) {
    TvTextField(form.address, { onChange(form.copy(address = it)) }, addressHint, Modifier.widthIn(max = 640.dp).fillMaxWidth())
    TvTextField(form.user, { onChange(form.copy(user = it)) }, userHint, Modifier.widthIn(max = 640.dp).fillMaxWidth())
    TvTextField(form.password, { onChange(form.copy(password = it)) }, passwordHint, Modifier.widthIn(max = 640.dp).fillMaxWidth(), secret = !reveal)
}
