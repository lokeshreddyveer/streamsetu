package app.streamsetu.tv.ui.screens.library

import androidx.compose.ui.draw.drawWithContent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.focusable
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.animation.core.animateFloat
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.testTag
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
    val emptyAdd = remember { FocusRequester() }          // the one button of the empty screen
    LaunchedEffect(list?.isEmpty()) { if (list != null && list.isEmpty()) { app.streamsetu.tv.ui.components.requestFocusSoon(emptyAdd, 8) } }
    var focused by remember { mutableStateOf(false) }
    var addMenu by remember { mutableStateOf(false) }
    LaunchedEffect(initial) { if (initial != null && !focused) { app.streamsetu.tv.ui.components.requestFocusSoon(initialFocus, 40) } }
    LaunchedEffect(initial) { if (previewId == null) previewId = initial }
    val ordered = list.orEmpty().let { l -> l.filter { it.kind == LibraryEntry.Kind.COMBINED } + l.filter { it.kind == LibraryEntry.Kind.CONNECTION } + l.filter { it.kind == LibraryEntry.Kind.UNFINISHED } }

    // One row of large cards, one per library, with Add Connection as the last card. Settings and the actions for the library under the remote sit below.
    Column(Modifier.fillMaxSize().pageBackground().ambientGlow(preview?.id).padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(38.dp).clip(RoundedCornerShape(10.dp)))
            Column(Modifier.weight(1f)) {
                Label("Choose a library", Tokens.pageTitle, Tokens.text, FontWeight.Bold)
                Label("Pick where to watch from.", Tokens.small, Tokens.textSecondary)
            }
            Clock()
        }
        if (list != null && list.isEmpty()) Column(Modifier.fillMaxWidth().weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Label("Welcome", Tokens.hero, Tokens.text, FontWeight.Bold)
            Label("Add a connection to get started.", Tokens.body, Tokens.textSecondary, modifier = Modifier.padding(top = 6.dp))
            TvButton("Add Connection", { addMenu = true }, Modifier.padding(top = 24.dp).focusRequester(emptyAdd), icon = Icons.Filled.Add, primary = true)
        } else {
            Box(Modifier.fillMaxWidth().weight(1f), Alignment.CenterStart) {
                // A few cards, so a plain scrolling row: the first one starts at the page margin, in line with the header and the buttons below.
                if (list == null) Loading(Modifier.height(120.dp)) else Row(Modifier.fillMaxWidth().bleedStart(14.dp).fillMaxWidth().horizontalScroll(androidx.compose.foundation.rememberScrollState()).padding(horizontal = 14.dp, vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    ordered.forEach { e -> androidx.compose.runtime.key(e.id) { LibraryCard(e, e.id == initial, initialFocus, nav, vm, onPreview = { previewId = e.id; focused = true }) } }
                    AddCard { addMenu = true }
                }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                // OK on a card opens it, so there is no separate button for that; this line says so, and where the rest is.
                Label("OK opens the library  ·  hold OK for actions", Tokens.small, Tokens.textTertiary, modifier = Modifier.weight(1f))
                if (preview != null) {
                    if (preview.kind != LibraryEntry.Kind.UNFINISHED) TvButton("Edit", { if (preview.kind == LibraryEntry.Kind.COMBINED) nav.base = Base.Combined(preview) else nav.base = Base.Setup(typeOf(preview), preview.sourceIds.first()) }, icon = Icons.Filled.Edit)
                    TvButton("Actions", { nav.open(Overlay.ManageLibrary(preview)) }, icon = Icons.Filled.Tune)
                }
                TvButton("Settings", { nav.openSettingsFromChooser() }, icon = Icons.Filled.Settings)
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

/** One saved library as a card: its kind and name, how it is doing, and what it holds. OK enters it; holding OK opens its actions. */
@Composable
private fun LibraryCard(e: LibraryEntry, isInitial: Boolean, initialFocus: FocusRequester, nav: Navigator, vm: LibraryViewModel, onPreview: () -> Unit) {
    Focusable(
        onClick = { if (e.kind == LibraryEntry.Kind.UNFINISHED) nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) else vm.open(e) { nav.enterLibrary() } },
        modifier = (if (isInitial) Modifier.focusRequester(initialFocus) else Modifier).width(224.dp).height(232.dp).testTag("library-${e.id}"),
        shape = RoundedCornerShape(Tokens.radiusLarge), container = Color(0x14FFFFFF), focusedContainer = Color(0x2EFFFFFF), scaleOnFocus = 1.05f, hairline = true,
        onFocus = { if (it) onPreview() }, onLongClick = { nav.open(Overlay.ManageLibrary(e)) },
    ) { f ->
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusOrb(e, f)
                Spacer(Modifier.weight(1f))
                if (e.id == vm.lastUsedId) Label("Last used", Tokens.caption, Tokens.accent, FontWeight.SemiBold)
            }
            Spacer(Modifier.height(4.dp))
            Label(e.name, Tokens.row, Tokens.text, FontWeight.Bold, maxLines = 2)
            Label(if (e.kind == LibraryEntry.Kind.COMBINED) "Combined library" else if (e.kind == LibraryEntry.Kind.UNFINISHED) "Setup not finished" else e.typeLabel, Tokens.caption, Tokens.textSecondary)
            // The read time appears once the connection has been verified, not before.
            if (e.kind == LibraryEntry.Kind.CONNECTION && e.lastSyncAt > 0) {
                var shown by remember { mutableStateOf(false) }
                LaunchedEffect(Unit) { delay(350); shown = true }
                val a by androidx.compose.animation.core.animateFloatAsState(if (shown) 1f else 0f, androidx.compose.animation.core.tween(600), label = "readAt")
                Label("Last read  ·  " + java.text.SimpleDateFormat("MMM d, h:mm a", java.util.Locale.getDefault()).format(java.util.Date(e.lastSyncAt)), Tokens.caption, Tokens.textTertiary, modifier = Modifier.graphicsLayer { alpha = a })
            }
            Spacer(Modifier.weight(1f))
            if (e.kind == LibraryEntry.Kind.UNFINISHED) Label("Press OK to continue", Tokens.small, Tokens.textSecondary)
            else Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // One large number and two smaller tiles: what the library is mostly made of.
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label("%,d".format(e.channelCount), Tokens.title, Tokens.text, FontWeight.Bold)
                    Label("live", Tokens.caption, Tokens.textSecondary, modifier = Modifier.padding(bottom = 3.dp))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CardCount("Movies", e.movieCount, Modifier.weight(1f)); CardCount("Series", e.seriesCount, Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun CardCount(title: String, n: Int, modifier: Modifier) {
    Column(modifier.background(Color(0x1AFFFFFF), RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 6.dp)) { Label("%,d".format(n), Tokens.small, Tokens.text, FontWeight.Bold); Label(title, Tokens.caption, Tokens.textSecondary) }
}

/** The library's icon inside a soft ring in the health colour. Still: nothing on this screen animates while the remote rests. */
@Composable
private fun StatusOrb(e: LibraryEntry, focused: Boolean) {
    val ring = healthColor(e)
    Box(Modifier.size(40.dp).drawBehind {
        val w = 3.dp.toPx()
        drawCircle(ring.copy(alpha = 0.22f), radius = size.minDimension / 2)
        drawCircle(ring.copy(alpha = 0.9f), radius = size.minDimension / 2 - w / 2, style = androidx.compose.ui.graphics.drawscope.Stroke(w))
    }, Alignment.Center) {
        Image(typeIcon(e), null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(if (focused) Tokens.text else Tokens.textSecondary))
    }
}

/** Two soft colour glows behind the page, from the library under the remote. Still, so the page costs nothing to keep on screen; the colour eases from one library to the next. */
@Composable
private fun Modifier.ambientGlow(key: String?): Modifier {
    val hue = ((key?.hashCode() ?: 0).toLong().and(0x7fffffff) % 360).toFloat()
    val c1 by androidx.compose.animation.animateColorAsState(Color.hsv(hue, 0.55f, 0.85f), androidx.compose.animation.core.tween(500), label = "glow1")
    val c2 by androidx.compose.animation.animateColorAsState(Color.hsv((hue + 70f) % 360f, 0.5f, 0.8f), androidx.compose.animation.core.tween(500), label = "glow2")
    return this.drawBehind {
        val r = size.maxDimension * 0.55f
        val a = androidx.compose.ui.geometry.Offset(size.width * 0.25f, size.height * 0.30f)
        val b = androidx.compose.ui.geometry.Offset(size.width * 0.78f, size.height * 0.72f)
        drawCircle(androidx.compose.ui.graphics.Brush.radialGradient(listOf(c1.copy(alpha = 0.13f), Color.Transparent), center = a, radius = r), radius = r, center = a)
        drawCircle(androidx.compose.ui.graphics.Brush.radialGradient(listOf(c2.copy(alpha = 0.10f), Color.Transparent), center = b, radius = r), radius = r, center = b)
    }
}

/** The last card of the row: add another connection. */
@Composable
private fun AddCard(onClick: () -> Unit) {
    Focusable(onClick, Modifier.width(224.dp).height(232.dp), shape = RoundedCornerShape(Tokens.radiusLarge), container = Color(0x0AFFFFFF), focusedContainer = Color(0x2EFFFFFF), scaleOnFocus = 1.05f, hairline = true) { f ->
        Column(Modifier.fillMaxSize().padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Box(Modifier.size(46.dp).clip(CircleShape).background(Tokens.elevated), Alignment.Center) { Image(Icons.Filled.Add, null, Modifier.size(24.dp), colorFilter = ColorFilter.tint(if (f) Tokens.text else Tokens.textSecondary)) }
            Label("Add Connection", Tokens.row, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 10.dp))
            Label("Xtream, M3U and more", Tokens.caption, Tokens.textSecondary, modifier = Modifier.padding(top = 2.dp))
        }
    }
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
private fun StatTile(icon: ImageVector, title: String, n: Int, modifier: Modifier = Modifier) {
    Column(modifier.background(Color(0x990A1018), RoundedCornerShape(18.dp)).border(1.dp, Color(0x26FFFFFF), RoundedCornerShape(18.dp)).padding(horizontal = 14.dp, vertical = 18.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Image(icon, null, Modifier.size(24.dp), colorFilter = ColorFilter.tint(Tokens.accent))
        Label("%,d".format(n), Tokens.display, Tokens.text, FontWeight.Bold)
        Label(title, Tokens.row, Tokens.textSecondary)
    }
}

/** The main action: a wide white pill that glows gold when the remote is on it. */
@Composable
private fun BigPill(text: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = Color(0xFFDDE3EA), focusedContainer = Color.White, ring = Gold, scaleOnFocus = 1.03f) { _ ->
        Row(Modifier.fillMaxWidth().padding(vertical = 13.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Image(icon, null, Modifier.size(22.dp), colorFilter = ColorFilter.tint(Tokens.onBright)); Spacer(Modifier.width(10.dp)); Label(text, Tokens.title, Tokens.onBright, FontWeight.Bold)
        }
    }
}

@Composable
private fun GhostPill(text: String, icon: ImageVector, onClick: () -> Unit) {
    Focusable(onClick, Modifier, shape = RoundedCornerShape(50), container = Tokens.pick(Color(0x66101011), Tokens.card), focusedContainer = Tokens.pick(Color(0xFF222224), Tokens.focusedSurface), ring = Gold, hairline = true, scaleOnFocus = 1.04f) { f ->
        Row(Modifier.padding(horizontal = 18.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Image(icon, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(if (f) Gold else Tokens.text)); Label(text, Tokens.row, Tokens.text, FontWeight.Medium)
        }
    }
}

@Composable
private fun QuickTile(title: String, sub: String, icon: ImageVector, bg: Color, tint: Color, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(14.dp), container = Tokens.pick(Color(0xFF121213), Tokens.card), focusedContainer = Tokens.pick(Tokens.focusedSurface, Tokens.focusedSurface), ring = Gold, hairline = true, scaleOnFocus = 1.03f) { _ ->
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
        scaleOnFocus = 1.06f, container = Tokens.pick(Color(0xFF0E1218), Tokens.card), focusedContainer = Tokens.pick(Color(0xFF1A1F27), Tokens.focusedSurface), ring = Gold, shape = RoundedCornerShape(22.dp), hairline = true,
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
    LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
    // The page takes the wordmark art's own backdrop colour, so the logo sits on it without an edge.
    Column(Modifier.fillMaxSize().background(Tokens.pick(Color(0xFF070808), Tokens.background)).padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Label("Everything you watch, in one place", Tokens.display, Tokens.text, FontWeight.Bold)
        AnimatedWordmark(Modifier.height(150.dp), app.streamsetu.core.ui.motion.LocalReducedMotion.current, repeatEvery = 7000L)
        Label("Add your own playlist or login to get started.", Tokens.body, Tokens.textSecondary)
        Spacer(Modifier.height(24.dp))
        Row(Modifier.widthIn(max = 800.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            SetupCard("Xtream Codes", "Server, user name and password", Icons.Filled.Dns, Modifier.weight(1f).focusRequester(first)) { nav.base = Base.Setup(SourceType.XTREAM) }
            SetupCard("M3U URL", "A playlist link", Icons.Filled.Link, Modifier.weight(1f)) { nav.base = Base.Setup(SourceType.M3U) }
            SetupCard("Local M3U File", "A playlist file on this device", Icons.Filled.Folder, Modifier.weight(1f)) { nav.base = Base.Setup(SourceType.LOCAL_FILE) }
            SetupCard("Stalker Portal", "Portal address and MAC", Icons.Filled.Router, Modifier.weight(1f)) { nav.base = Base.Setup(SourceType.STALKER) }
        }
        Spacer(Modifier.height(24.dp))
        Label("1. Add your playlist or login   ·   2. Let it load, big lists take a minute   ·   3. Search, add favorites, press play", Tokens.small, Tokens.textSecondary)
        Spacer(Modifier.height(6.dp))
        Label("Arrow keys move  ·  OK chooses  ·  hold OK for options  ·  Back goes back", Tokens.small, Tokens.textTertiary)
        Spacer(Modifier.height(14.dp))
        Label("StreamSetu does not include any channels, movies or subscriptions. You bring your own provider.", Tokens.caption, Tokens.textTertiary)
        if (drafts.isNotEmpty()) {
            Spacer(Modifier.height(22.dp))
            TvButton("Continue Previous Setup", { val d = drafts.first(); nav.base = Base.Setup(typeOf(d), d.sourceIds.first()) }, icon = Icons.Filled.Edit)
        }
    }
}

@Composable
private fun SetupCard(title: String, subtitle: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier.height(140.dp), container = Tokens.card, scaleOnFocus = 1.04f, shape = RoundedCornerShape(Tokens.radiusLarge)) { _ ->
        // Icon, name and description sit at the same height on every card, whatever the description's length.
        Column(Modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Image(icon, null, Modifier.size(30.dp), colorFilter = ColorFilter.tint(Tokens.accent))
            Spacer(Modifier.height(10.dp))
            Label(title, Tokens.row, Tokens.text, FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Label(subtitle, Tokens.small, Tokens.textSecondary, maxLines = 2, modifier = Modifier.fillMaxWidth(), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
    }
}

/** The wordmark art carries its own backdrop and a pale spotlight behind the mark. Alpha follows brightness, so the backdrop turns transparent and only the mark remains. */
private val WordmarkKnockout = androidx.compose.ui.graphics.ColorMatrix(floatArrayOf(
    1f, 0f, 0f, 0f, 0f,
    0f, 1f, 0f, 0f, 0f,
    0f, 0f, 1f, 0f, 0f,
    1.3f, 1.3f, 1.3f, 0f, -190f,
))

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
        app.streamsetu.tv.ui.components.requestFocusSoon(first, 8)
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
        LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusSoon(open, 8) }
        Column(Modifier.fillMaxSize().screenPadding(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically)) {
            Box(Modifier.size(64.dp).background(Color(0xFF33B866), CircleShape), Alignment.Center) { Image(Icons.Filled.Check, null, Modifier.size(38.dp), colorFilter = ColorFilter.tint(Color.White)) }
            Label("Connection verified", Tokens.display, Tokens.text, FontWeight.Bold)
            Label(passed.name, Tokens.heading, Tokens.accent, FontWeight.SemiBold)
            Row(Modifier.widthIn(max = 780.dp).fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                StatTile(Icons.Filled.LiveTv, "Live TV", passed.channels, Modifier.weight(1f)); StatTile(Icons.Filled.Movie, "Movies", passed.movies, Modifier.weight(1f)); StatTile(Icons.Filled.VideoLibrary, "Series", passed.series, Modifier.weight(1f))
            }
            Label("Saved on this device. Your login is kept in the Android Keystore and is never shown or logged.", Tokens.small, Tokens.textTertiary, maxLines = 2)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
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
        Column(Modifier.weight(0.34f).fillMaxHeight().padding(top = 48.dp), verticalArrangement = Arrangement.Top) {
            Label(title, Tokens.display, Tokens.text, FontWeight.Bold, maxLines = 2)
            Label(when (type) {
                SourceType.XTREAM -> "The server address, user name and password your provider gave you."
                SourceType.M3U -> "The playlist link your provider gave you."
                SourceType.LOCAL_FILE -> "Pick an M3U playlist file stored on this device."
                SourceType.LOCAL_FOLDER -> "Pick a folder of videos stored on this device."
                SourceType.STALKER -> "Your portal address and the MAC address it expects."
                else -> "Connect to ${type.label}."
            }, Tokens.body, Tokens.textSecondary, maxLines = 3, modifier = Modifier.padding(top = 8.dp, bottom = 24.dp))
            listOf("Details" to true, "Test the connection" to (test is LibraryViewModel.Test.Running), "Enter the library" to false).forEachIndexed { i, (step, now) ->
                Row(Modifier.padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(Modifier.size(26.dp).background(if (now || (i == 0 && test !is LibraryViewModel.Test.Running)) Color.White else Tokens.elevated, CircleShape), Alignment.Center) { Label("${i + 1}", Tokens.small, if (now || (i == 0 && test !is LibraryViewModel.Test.Running)) Tokens.onBright else Tokens.textSecondary, FontWeight.Bold) }
                    Label(step, Tokens.row, if (now || (i == 0 && test !is LibraryViewModel.Test.Running)) Tokens.text else Tokens.textSecondary, FontWeight.Medium)
                }
            }
            Label(when (type) {
                SourceType.LOCAL_FILE, SourceType.LOCAL_FOLDER -> "Nothing is uploaded. The file is read on this device."
                SourceType.M3U, SourceType.STALKER, SourceType.HDHOMERUN -> "Your details are kept in the Android Keystore and are never shown or logged."
                else -> "Your login is kept in the Android Keystore and is never shown or logged."
            }, Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.padding(top = 24.dp))
        }
        // Right: the fields and the actions.
        Column(Modifier.weight(0.66f).fillMaxHeight().verticalScroll(androidx.compose.foundation.rememberScrollState()).padding(top = 48.dp), verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.Top)) {
        TvTextField(form.name, { form = form.copy(name = it) }, "Name (optional)", Modifier.widthIn(max = 640.dp).fillMaxWidth().focusRequester(first))
        when (type) {
            SourceType.HDHOMERUN -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Tuner address (192.168.1.50 or hdhomerun.local)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                Label("Channels are read from the tuner on your network. Run a channel scan in the tuner's own setup first.", Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
            }
            SourceType.TVHEADEND -> LoginFields(form, "Server (http://host:9981)", "User name", "Password", reveal) { form = it }
            SourceType.ENIGMA2 -> {
                LoginFields(form, "Receiver address (http://192.168.1.60)", "User name (only if the receiver asks)", "Password", reveal) { form = it }
                Label("Needs OpenWebif on the receiver. Streams play from its own stream port (8001).", Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
            }
            SourceType.JELLYFIN, SourceType.EMBY -> {
                LoginFields(form, "Server (http://host:8096)", "User name", "Password", reveal) { form = it }
                Label("Movies and series from the server's libraries. Live TV is not read.", Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
            }
            SourceType.PLEX -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Server (http://host:32400)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.password, { form = form.copy(password = it) }, "Access token (X-Plex-Token)", Modifier.widthIn(max = 640.dp).fillMaxWidth(), secret = !reveal)
                Label("Movies and shows from the server's libraries. Find the token in Plex Web: Get Info, View XML, the address ends in X-Plex-Token=…", Tokens.small, Tokens.textTertiary, maxLines = 3)
            }
            SourceType.WEBDAV -> {
                LoginFields(form, "Share address (https://host/remote.php/dav/files/me/)", "User name (optional)", "Password (optional)", reveal) { form = it }
                Label("Video files in the share and its folders (four levels deep) appear as movies.", Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
            }
            SourceType.LOCAL_FOLDER -> {
                Label(if (form.address.isBlank()) "No folder chosen" else "Chosen: " + Uri.decode(Uri.parse(form.address).lastPathSegment.orEmpty()).substringAfterLast(':'), Tokens.body, Tokens.textSecondary)
                TvButton("Choose Folder…", { folderPicker.launch(null) }, icon = Icons.Filled.Folder)
                Label("Video files in the folder and its sub-folders appear as movies.", Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
            }
            SourceType.XTREAM -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Server address (http://host:port)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.user, { form = form.copy(user = it) }, "User name", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.password, { form = form.copy(password = it) }, "Password", Modifier.widthIn(max = 640.dp).fillMaxWidth(), secret = !reveal)
            }
            SourceType.STALKER -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Portal address (http://host/c/)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.user, { form = form.copy(user = it) }, "MAC address (00:1A:79:xx:xx:xx)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                Label("Live TV is read from the portal. Movies and series from portals are not supported yet.", Tokens.small, Tokens.textTertiary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
            }
            SourceType.ADDON -> Label("An add-on is managed in Settings, Add-ons.", Tokens.body, Tokens.textSecondary, maxLines = 2, modifier = Modifier.widthIn(max = 640.dp))
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
        if (test is LibraryViewModel.Test.Running) {
            // The wait can be a minute on a big list, so it says what is happening, moves, and can be stopped.
            val stop = remember { FocusRequester() }
            LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusSoon(stop, 4) }
            Column(Modifier.fillMaxWidth().widthIn(max = 640.dp).background(Tokens.card, RoundedCornerShape(Tokens.radius)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Label("Testing the connection", Tokens.row, Tokens.text, FontWeight.SemiBold)
                IndeterminateBar()
                Label("Signing in and reading your channels, movies and series. Big lists can take a minute.", Tokens.small, Tokens.textSecondary, maxLines = 3)
            }
            TvButton("Cancel test", { vm.cancelTest() }, Modifier.focusRequester(stop), icon = Icons.Filled.Close)
        } else {
            // The main action first, and on a row with the phone, which is the easier way to type a login; saving a draft and cancelling are a quieter row below it.
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                TvButton("Test Connection", { if (canTest) { message = null; vm.test(type, id, form) } else message = "Fill in the details first." }, icon = Icons.Filled.PlayArrow, primary = canTest)          // lit only when there is enough to test, so it is never mistaken for the focused field
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

/** A bar with a moving segment, for waits of unknown length. Only the draw phase runs while it moves. */
@Composable
private fun IndeterminateBar(modifier: Modifier = Modifier) {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "wait")
    val x by t.animateFloat(0f, 1f, androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(1300, easing = androidx.compose.animation.core.LinearEasing)), label = "x")
    Box(modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(Tokens.elevated).drawBehind {
        val w = size.width * 0.35f; val left = (size.width + w) * x - w
        drawRoundRect(Tokens.accent, androidx.compose.ui.geometry.Offset(left.coerceAtLeast(0f), 0f), androidx.compose.ui.geometry.Size((left + w).coerceAtMost(size.width) - left.coerceAtLeast(0f), size.height), androidx.compose.ui.geometry.CornerRadius(size.height / 2))
    })
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
        app.streamsetu.tv.ui.components.requestFocusSoon(first, 8)
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

private enum class ManageMode { Menu, Rename, Confirm, Info }

/** The actions of a library or connection (hold OK on it, or the Actions button): the app's own side sheet, then a small panel for the few that need a second step. */
@Composable
fun ManageLibraryDialog(entry: LibraryEntry, nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    var mode by remember { mutableStateOf(ManageMode.Menu) }
    var closing by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var newName by remember { mutableStateOf(entry.name) }
    // The sheet reports "closed" before an action runs; the screen goes away only if that action did not open a second step or leave the screen itself.
    LaunchedEffect(closing, mode) { if (closing && mode == ManageMode.Menu) nav.close() }
    when (mode) {
        ManageMode.Menu -> ContextMenu(entry.name, entry.typeLabel, buildList {
            if (entry.kind == LibraryEntry.Kind.UNFINISHED) add(MenuAction("Continue Setup", Icons.Filled.Edit) { nav.close(); nav.base = Base.Setup(typeOf(entry), entry.sourceIds.first()) })
            else add(MenuAction("Open", Icons.Filled.PlayArrow) { nav.close(); vm.open(entry) { nav.enterLibrary() } })
            if (entry.kind != LibraryEntry.Kind.UNFINISHED) add(MenuAction("Refresh Catalog Now", Icons.Filled.Refresh) { status = "Refreshing…"; mode = ManageMode.Info; vm.refresh(entry) { err -> status = err ?: "Catalog refreshed." } })
            if (entry.kind == LibraryEntry.Kind.CONNECTION) add(MenuAction("Edit Connection", Icons.Filled.Edit) { nav.close(); nav.base = Base.Setup(typeOf(entry), entry.sourceIds.first()) })
            if (entry.kind == LibraryEntry.Kind.COMBINED) add(MenuAction("Edit Members", Icons.Filled.Layers) { nav.close(); nav.base = Base.Combined(entry) })
            add(MenuAction("Rename", Icons.Filled.Edit) { mode = ManageMode.Rename })
            if (entry.kind != LibraryEntry.Kind.UNFINISHED) add(MenuAction("Connection Information", Icons.Filled.Info) {
                status = healthText(entry) + (if (entry.kind == LibraryEntry.Kind.CONNECTION) "  ·  last read " + lastSync(entry.lastSyncAt) else "") + "  ·  %,d channels, %,d movies, %,d series".format(entry.channelCount, entry.movieCount, entry.seriesCount)
                mode = ManageMode.Info
            })
            add(MenuAction("Delete", Icons.Filled.Delete, danger = true) { mode = ManageMode.Confirm })
        }, onClose = { closing = true })
        ManageMode.Rename -> ManagePanel("Rename", { nav.close() }) { first ->
            TvTextField(newName, { newName = it }, "Name", Modifier.fillMaxWidth().focusRequester(first))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Save", { vm.rename(entry, newName.ifBlank { entry.name }); nav.close() }, primary = true)
                TvButton("Cancel", { nav.close() })
            }
        }
        ManageMode.Confirm -> ManagePanel("Delete " + entry.name + "?", { nav.close() }) { first ->
            Label("This removes the connection and its saved catalog from this device. It cannot be undone.", Tokens.body, Tokens.textSecondary, maxLines = 4)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Keep it", { nav.close() }, Modifier.focusRequester(first), primary = true)
                TvButton("Delete", { vm.delete(entry) { nav.close() } }, icon = Icons.Filled.Delete)
            }
        }
        ManageMode.Info -> ManagePanel(entry.name, { nav.close() }) { first ->
            Label(status.orEmpty(), Tokens.body, Tokens.textSecondary, maxLines = 5)
            TvButton("Close", { nav.close() }, Modifier.focusRequester(first), primary = true)
        }
    }
}

/** A small centred panel for the second step of an action. The page behind it dims softly together with the panel arriving, with no black layer first. */
@Composable
private fun ManagePanel(title: String, onClose: () -> Unit, content: @Composable ColumnScope.(FocusRequester) -> Unit) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 12) }
    val reduced = app.streamsetu.core.ui.motion.LocalReducedMotion.current
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    val a by androidx.compose.animation.core.animateFloatAsState(if (shown) 1f else 0f, if (reduced) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(160), label = "panelIn")
    app.streamsetu.tv.ui.components.TvDialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().drawBehind { drawRect(Tokens.background.copy(alpha = 0.6f), alpha = a) }, Alignment.Center) {
            Column(Modifier.width(460.dp).graphicsLayer { alpha = a; translationY = (1f - a) * 14.dp.toPx() }.background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Label(title, Tokens.title, Tokens.text, FontWeight.Bold, maxLines = 2)
                content(first)
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
    LaunchedEffect(received) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
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


/** The opening animation: the wordmark rises into place and a soft light crosses it once, then it fades out into the library screen. Any key skips it. */
@Composable
fun LogoReveal(reduced: Boolean, onDone: () -> Unit) {
    val a = remember { androidx.compose.animation.core.Animatable(1f) }
    val root = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        runCatching { root.requestFocus() }
        delay(if (reduced) 400 else 2100)
        a.animateTo(0f, androidx.compose.animation.core.tween(if (reduced) 0 else 280))
        onDone()
    }
    Box(Modifier.fillMaxSize().background(Tokens.pick(Color(0xFF070808), Tokens.background)).focusRequester(root).focusable().onPreviewKeyEvent { if (it.type == androidx.compose.ui.input.key.KeyEventType.KeyDown) { onDone(); true } else false }, Alignment.Center) {
        AnimatedWordmark(Modifier.height(300.dp).graphicsLayer { alpha = a.value }, reduced)
    }
}

/**
 * The wordmark, without its baked-in backdrop. It eases in (fade and a small rise in scale), a band of light crosses the mark once,
 * and with [repeatEvery] set it crosses again at that interval. Only the draw phase runs while the light moves.
 */
@Composable
fun AnimatedWordmark(modifier: Modifier, reduced: Boolean, repeatEvery: Long = 0L) {
    val enter = remember { androidx.compose.animation.core.Animatable(if (reduced) 1f else 0f) }
    val sweep = remember { androidx.compose.animation.core.Animatable(-1f) }
    LaunchedEffect(reduced) {
        if (reduced) return@LaunchedEffect
        enter.animateTo(1f, androidx.compose.animation.core.tween(700, easing = app.streamsetu.core.ui.motion.Motion.Standard))
        do {
            sweep.snapTo(0f); sweep.animateTo(1f, androidx.compose.animation.core.tween(1200, easing = androidx.compose.animation.core.LinearEasing))
            sweep.snapTo(-1f)
            if (repeatEvery > 0) delay(repeatEvery)
        } while (repeatEvery > 0)
    }
    Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.brand_wordmark), null,
        modifier
            .graphicsLayer { alpha = enter.value; val k = 0.9f + 0.1f * enter.value; scaleX = k; scaleY = k; compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                val t = sweep.value
                if (t >= 0f) {
                    val x = size.width * (0.15f + 0.7f * t); val half = size.width * 0.12f
                    drawRect(androidx.compose.ui.graphics.Brush.horizontalGradient(0f to Color.Transparent, 0.5f to Color.White.copy(alpha = 0.6f), 1f to Color.Transparent, startX = x - half, endX = x + half), blendMode = androidx.compose.ui.graphics.BlendMode.SrcAtop)
                }
            },
        colorFilter = ColorFilter.colorMatrix(WordmarkKnockout))
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
