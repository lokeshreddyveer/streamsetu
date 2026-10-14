package app.streamsetu.tv.ui.screens.library

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
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

/** The opening screen of every launch (the person picks which library to open; nothing opens by itself). */
@Composable
fun ChooseLibraryScreen(nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    val entries by vm.entries.collectAsState()
    val list = entries
    var previewId by remember { mutableStateOf<String?>(null) }
    val preview = list?.firstOrNull { it.id == previewId } ?: list?.firstOrNull()
    val initial = remember(list) {
        list?.let { l -> l.firstOrNull { it.id == vm.lastUsedId && it.usable } ?: l.firstOrNull { it.usable } ?: l.firstOrNull() }?.id
    }
    val initialFocus = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(initial) { if (initial != null && !focused) { delay(120); runCatching { initialFocus.requestFocus() } } }
    LaunchedEffect(initial) { if (previewId == null) previewId = initial }

    Row(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
        // Left 40 %: logo, heading and the libraries.
        Column(Modifier.weight(0.4f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            LogoRow()
            Label("Choose Your Library", Tokens.display, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(top = 10.dp, bottom = 6.dp))
            if (list == null) Loading(Modifier.weight(1f)) else LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
                val combined = list.filter { it.kind == LibraryEntry.Kind.COMBINED }
                val single = list.filter { it.kind == LibraryEntry.Kind.CONNECTION }
                val drafts = list.filter { it.kind == LibraryEntry.Kind.UNFINISHED }
                if (combined.isNotEmpty()) { item { Eyebrow("Combined Libraries", Modifier.padding(top = 6.dp)) }; items(combined, key = { it.id }) { LibraryRow(it, it.id == initial, initialFocus, nav, vm, { previewId = it.id }) { focused = true } } }
                if (single.isNotEmpty()) { item { Eyebrow("Individual Connections", Modifier.padding(top = 10.dp)) }; items(single, key = { it.id }) { LibraryRow(it, it.id == initial, initialFocus, nav, vm, { previewId = it.id }) { focused = true } } }
                if (drafts.isNotEmpty()) { item { Eyebrow("Unfinished Connections", Modifier.padding(top = 10.dp)) }; items(drafts, key = { it.id }) { LibraryRow(it, it.id == initial, initialFocus, nav, vm, { previewId = it.id }) { focused = true } } }
            }
        }
        // Right 60 %: the preview from cached details, then the always-visible add controls.
        Column(Modifier.weight(0.6f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(Modifier.weight(1f).fillMaxWidth().background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(22.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (preview == null) { Label("No libraries yet", Tokens.title, Tokens.text, FontWeight.SemiBold); Label("Add a connection below to get started.", Tokens.body, Tokens.textSecondary) }
                else {
                    Eyebrow(preview.typeLabel, color = Tokens.accent)
                    Label(preview.name, Tokens.display, Tokens.text, FontWeight.Bold)
                    if (preview.kind != LibraryEntry.Kind.UNFINISHED) Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Stat("Live TV", preview.channelCount); Stat("Movies", preview.movieCount); Stat("Series", preview.seriesCount)
                    }
                    if (preview.kind == LibraryEntry.Kind.COMBINED) Label("${preview.sourceIds.size} connected source${if (preview.sourceIds.size == 1) "" else "s"}", Tokens.body, Tokens.textSecondary)
                    Label("Last catalog refresh: ${lastSync(preview.lastSyncAt)}", Tokens.body, Tokens.textSecondary)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.size(9.dp).background(healthColor(preview), RoundedCornerShape(50)))
                        Label(healthText(preview), Tokens.body, healthColor(preview))
                    }
                    Spacer(Modifier.weight(1f))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (preview.kind == LibraryEntry.Kind.UNFINISHED) TvButton("Continue Setup", { nav.base = Base.Setup(typeOf(preview), preview.sourceIds.first()) }, icon = Icons.Filled.Edit, primary = true)
                        else TvButton("Enter Home", { vm.open(preview) { nav.enterLibrary() } }, icon = Icons.Filled.PlayArrow, primary = true)
                        TvButton("Manage Library", { nav.open(Overlay.ManageLibrary(preview)) }, icon = Icons.Filled.Settings)
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Eyebrow("Add a connection")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AddTile("Xtream Connection", Icons.Filled.Dns, Modifier.weight(1f)) { nav.base = Base.Setup(SourceType.XTREAM) }
                    AddTile("M3U URL", Icons.Filled.Link, Modifier.weight(1f)) { nav.base = Base.Setup(SourceType.M3U) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AddTile("Local M3U File", Icons.Filled.Folder, Modifier.weight(1f)) { nav.base = Base.Setup(SourceType.LOCAL_FILE) }
                    AddTile("Create Combined Library", Icons.Filled.Layers, Modifier.weight(1f)) { nav.base = Base.Combined() }
                }
            }
        }
    }
}

private fun typeOf(e: LibraryEntry) = when (e.typeLabel) { "M3U URL" -> SourceType.M3U; "Local M3U file" -> SourceType.LOCAL_FILE; else -> SourceType.XTREAM }

@Composable
private fun LogoRow() = Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
    Box(Modifier.size(28.dp).background(Tokens.accent, RoundedCornerShape(8.dp)), Alignment.Center) { Image(Icons.Filled.PlayArrow, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Color(0xFF04141A))) }
    Label("StreamSetu", Tokens.title, Tokens.text, FontWeight.Bold)
}

@Composable
private fun Stat(title: String, n: Int) = Column(Modifier.background(Tokens.card, RoundedCornerShape(Tokens.radius)).padding(horizontal = 16.dp, vertical = 10.dp)) {
    Label("%,d".format(n), Tokens.pageTitle, Tokens.text, FontWeight.Bold); Label(title, Tokens.small, Tokens.textSecondary)
}

@Composable
private fun AddTile(title: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, container = Tokens.card, scaleOnFocus = 1.02f) { _ ->
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Image(icon, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.accent))
            Label(title, Tokens.row, Tokens.text, FontWeight.Medium)
        }
    }
}

@Composable
private fun LibraryRow(e: LibraryEntry, isInitial: Boolean, initialFocus: FocusRequester, nav: Navigator, vm: LibraryViewModel, onPreview: () -> Unit, onFocused: () -> Unit) {
    Focusable(
        onClick = {
            when {
                e.kind == LibraryEntry.Kind.UNFINISHED -> nav.base = Base.Setup(typeOf(e), e.sourceIds.first())
                else -> vm.open(e) { nav.enterLibrary() }
            }
        },
        modifier = (if (isInitial) Modifier.focusRequester(initialFocus) else Modifier).fillMaxWidth(),
        scaleOnFocus = 1.0f, container = Tokens.card,
        onFocus = { if (it) { onPreview(); onFocused() } },
        onLongClick = { nav.open(Overlay.ManageLibrary(e)) },
    ) { _ ->
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Image(typeIcon(e), null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(if (e.usable) Tokens.accent else Tokens.warning))
            Column(Modifier.weight(1f)) {
                Label(e.name, Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label(if (e.kind == LibraryEntry.Kind.UNFINISHED) "Resume setup" else e.typeLabel, Tokens.small, Tokens.textSecondary)
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
        Box(Modifier.size(54.dp).background(Tokens.accent, RoundedCornerShape(14.dp)), Alignment.Center) { Image(Icons.Filled.PlayArrow, null, Modifier.size(32.dp), colorFilter = ColorFilter.tint(Color(0xFF04141A))) }
        Spacer(Modifier.height(14.dp))
        Label("Welcome to StreamSetu", Tokens.display, Tokens.text, FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Label("A player for your own IPTV connection. Choose how you want to connect.", Tokens.body, Tokens.textSecondary)
        Spacer(Modifier.height(10.dp))
        Label("StreamSetu does not provide channels, movies or subscriptions.", Tokens.small, Tokens.textTertiary)
        Spacer(Modifier.height(26.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            SetupCard("Xtream Codes", "Server, user name and password", Icons.Filled.Dns, Modifier.focusRequester(first)) { nav.base = Base.Setup(SourceType.XTREAM) }
            SetupCard("M3U URL", "A playlist link", Icons.Filled.Link, Modifier) { nav.base = Base.Setup(SourceType.M3U) }
            SetupCard("Local M3U File", "A playlist file on this device", Icons.Filled.Folder, Modifier) { nav.base = Base.Setup(SourceType.LOCAL_FILE) }
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
        if (draftId != null) vm.draft(draftId)?.let { (s, pw) -> form = LibraryViewModel.Form(s.name, s.address, s.username.orEmpty(), pw.orEmpty()) }
        delay(150); runCatching { first.requestFocus() }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            runCatching { context.contentResolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            form = form.copy(address = uri.toString(), name = form.name.ifBlank { uri.lastPathSegment?.substringAfterLast('/')?.substringBeforeLast('.').orEmpty() })
        }
    }
    val canTest = when (type) {
        SourceType.XTREAM -> form.address.isNotBlank() && form.user.isNotBlank() && form.password.isNotBlank()
        else -> form.address.isNotBlank()
    }
    val title = when (type) { SourceType.XTREAM -> "Add Xtream Connection"; SourceType.M3U -> "Add M3U URL"; SourceType.LOCAL_FILE -> "Add Local M3U File" }

    val passed = test as? LibraryViewModel.Test.Passed
    if (passed != null) {
        val open = remember { FocusRequester() }
        LaunchedEffect(Unit) { delay(150); runCatching { open.requestFocus() } }
        Column(Modifier.fillMaxSize().padding(horizontal = 120.dp, vertical = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically)) {
            Label("Connection verified", Tokens.display, Tokens.text, FontWeight.Bold)
            Label(passed.name, Tokens.heading, Tokens.accent, FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { Stat("Live TV", passed.channels); Stat("Movies", passed.movies); Stat("Series", passed.series) }
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

    Column(Modifier.fillMaxSize().padding(horizontal = 120.dp, vertical = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Label(title, Tokens.display, Tokens.text, FontWeight.Bold)
        TvTextField(form.name, { form = form.copy(name = it) }, "Name (optional)", Modifier.widthIn(max = 640.dp).fillMaxWidth().focusRequester(first))
        when (type) {
            SourceType.XTREAM -> {
                TvTextField(form.address, { form = form.copy(address = it) }, "Server address (http://host:port)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.user, { form = form.copy(user = it) }, "User name", Modifier.widthIn(max = 640.dp).fillMaxWidth())
                TvTextField(form.password, { form = form.copy(password = it) }, "Password", Modifier.widthIn(max = 640.dp).fillMaxWidth(), secret = true)
            }
            SourceType.M3U -> TvTextField(form.address, { form = form.copy(address = it) }, "Playlist link (http://…/playlist.m3u)", Modifier.widthIn(max = 640.dp).fillMaxWidth())
            SourceType.LOCAL_FILE -> {
                Label(if (form.address.isBlank()) "No file chosen" else "Chosen: ${Uri.parse(form.address).lastPathSegment?.substringAfterLast('/') ?: form.address}", Tokens.body, Tokens.textSecondary)
                TvButton("Choose File…", { picker.launch(arrayOf("*/*")) }, icon = Icons.Filled.Folder)
            }
        }
        (test as? LibraryViewModel.Test.Failed)?.let { Label(it.message, Tokens.body, Tokens.danger, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp)) }
        message?.let { Label(it, Tokens.body, Tokens.textSecondary) }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            if (test is LibraryViewModel.Test.Running) { Spinner(); Label("Testing the connection and reading the catalog. This can take a minute for big lists…", Tokens.body, Tokens.textSecondary) }
            else {
                TvButton("Test Connection", { if (canTest) { message = null; vm.test(type, id, form) } else message = "Fill in the details first." }, icon = Icons.Filled.PlayArrow, primary = true)
                TvButton("Save as Draft", { vm.saveDraft(type, id, form) { saved -> id = saved; message = "Saved. Finish it any time from Choose Your Library." } })
                TvButton("Cancel", { nav.base = Base.ChooseLibrary })
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
    Column(Modifier.fillMaxSize().padding(horizontal = 120.dp, vertical = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(10.dp)) {
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
        Column(Modifier.width(380.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
                MenuRow(if (confirmDelete) "Press again to delete" else "Delete", Icons.Filled.Delete) {
                    if (!confirmDelete) confirmDelete = true else vm.delete(entry) { nav.close() }
                }
                status?.let { Label(it, Tokens.small, Tokens.textSecondary, maxLines = 2) }
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
