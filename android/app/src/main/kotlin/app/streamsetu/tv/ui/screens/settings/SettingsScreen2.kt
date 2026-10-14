package app.streamsetu.tv.ui.screens.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.core.settings.AnimationLevel
import app.streamsetu.core.settings.PosterSize
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.home.HomeViewModel
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.update.UpdateState
import kotlinx.coroutines.launch
import java.io.File
import java.text.DateFormat
import java.util.Date

private fun readText(context: android.content.Context, uri: android.net.Uri): String = context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } ?: error("That file could not be opened.")

@Composable
fun LibrarySettings(c: AppContainer, nav: Navigator) {
    val scope = rememberCoroutineScope()
    val all by c.sources.sources.collectAsState(initial = emptyList())
    val libs by c.library.entries.collectAsState(initial = emptyList())
    var result by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf<String?>(null) }
    SettingGroup("Connections", "A connection that is turned off is left out of combined libraries. It still opens on its own.") {
        if (all.isEmpty()) InfoRow("No connections yet", "")
        all.forEach { s ->
            InfoRow(s.name + if (s.draft) "  (unfinished)" else "", when { s.draft -> "Not tested"; s.status == SyncStatus.FAILED -> "Last read failed"; s.status == SyncStatus.OK -> "Healthy"; else -> "Not read yet" },
                "%,d live · %,d movies · %,d series  ·  last read %s".format(s.channelCount, s.movieCount, s.seriesCount, if (s.lastSyncAt > 0) DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(s.lastSyncAt)) else "never") + (s.lastError?.let { "\n" + app.streamsetu.core.data.repo.MaintenanceService.redact(it) } ?: ""))
            if (!s.draft) { val cap by produceState<SourceCapabilities?>(null, s.id, s.lastSyncAt) { value = c.maintenance.capabilities(s) }; cap?.let { k ->
                InfoRow("What ${s.name} offers", listOfNotNull(if (k.live) "Live" else null, if (k.movies) "Movies" else null, if (k.series) "Series" else null, if (k.guide) "Guide" else null, if (k.catchUp) "Catch-up" else null).joinToString(" · ").ifBlank { "nothing yet" }, if (!k.guide && k.live) "No guide data was delivered, so the TV Guide is empty for this connection." else if (k.catchUp) "Catch-up is offered on %,d channels: choose a past programme in the TV Guide.".format(k.catchUpChannels) else null) } }
            if (!s.draft) ToggleRow("Include ${s.name} in combined libraries", on = s.enabled) { v -> scope.launch { c.sources.setEnabled(s.id, v) } }
            if (!s.draft) ActionRow("Refresh ${s.name} now", "Reads the catalog again. Your favorites, folders and progress stay.", if (busy == s.id) "Reading…" else "Refresh", enabled = busy == null, reason = "Another refresh is running.", confirm = false) {
                busy = s.id; scope.launch { result = runCatching { c.syncWithGuide(s.id); "${s.name} refreshed." }.getOrElse { "${s.name}: " + (it.message ?: "could not be read") + " The previous catalog is still in use." }; busy = null }
            }
            ActionRow("Edit ${s.name}", "Change the address or login, and test again.", "Edit", confirm = false) { nav.base = Base.Setup(s.type, s.id) }
            ActionRow("Remove ${s.name}", "Deletes this connection and its catalog from this device. Favorites and history of other connections stay.", "Remove", danger = true) { scope.launch { c.sources.remove(s.id); result = "${s.name} removed." } }
        }
        ActionRow("Add a connection", "Xtream, M3U link or a local M3U file.", "Add", confirm = false) { c.library.close(); nav.toChooser() }
    }
    ResultLine(result)
    val hours by c.settings.backgroundSyncHours.collectAsState()
    val ctx = LocalContext.current
    SettingGroup("Catalog refresh", "A refresh also looks for new episodes of series you have started. It never runs while something is playing, and a failed read keeps the last good catalog.") {
        val onStart by c.settings.refreshOnStart.collectAsState()
        ToggleRow("Refresh when the app opens", "Reads every connection and its guide a few seconds after launch, one at a time, and never while something is playing.", onStart) { c.settings.setRefreshOnStart(it) }
        ChoiceRow("Refresh catalogs in the background", options = listOf(0 to "Only when I ask", 12 to "Every 12 hours", 24 to "Every day"), value = hours) { c.settings.setBackgroundSyncHours(it); app.streamsetu.tv.CatalogSyncWorker.schedule(ctx, it) }
    }
    SettingGroup("Libraries") {
        InfoRow("Libraries", libs.size.toString(), libs.joinToString(", ") { it.name }.ifBlank { "none" })
        ActionRow("Manage combined libraries", "Opens Choose Your Library: hold OK on a library to edit its members.", "Open", confirm = false) { c.library.close(); nav.toChooser() }
    }
    FolderResets(c)
}

@Composable
private fun FolderResets(c: AppContainer) {
    val scope = rememberCoroutineScope()
    var msg by remember { mutableStateOf<String?>(null) }
    SettingGroup("Folders", "Folder arrangements are only stored on this device. The provider's own folders are never changed.") {
        listOf(ContentKind.MOVIE to "Movies", ContentKind.SERIES to "Series", ContentKind.CHANNEL to "Live TV").forEach { (k, n) ->
            ActionRow("$n: show hidden folders again", null, "Unhide all", confirm = false) { scope.launch { c.folders.unhideAll(k); msg = "$n folders unhidden." } }
            ActionRow("$n: restore the provider's order", "Keeps favorites, hidden, locked and renamed folders; only the order changes.", "Restore", confirm = false) { scope.launch { c.folders.restoreDefaultOrder(k); msg = "$n folders are in the provider's order." } }
            ActionRow("$n: reset all folder arrangements", "Clears order, pins, favorites, hidden, locks and renamed labels for $n.", "Reset", danger = true) { scope.launch { c.maintenance.resetFolderPrefs(k); msg = "$n folder arrangements reset." } }
        }
    }
    ResultLine(msg)
}

@Composable
fun SearchSettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    var availability by remember { mutableStateOf(SortAvailability(false, false, false, false)) }
    LaunchedEffect(Unit) { availability = runCatching { c.browse.availability() }.getOrDefault(availability) }
    var indexRows by remember { mutableStateOf<Int?>(null) }; var catalogRows by remember { mutableStateOf<Int?>(null) }
    var msg by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(msg) { indexRows = c.maintenance.indexRows(); catalogRows = c.maintenance.catalogRows() }
    val recent by c.search.recent.collectAsState()
    SettingGroup("Default sorting", "Everything starts with the most recently added first. Every other order stays available; each section remembers its own choice. A folder can also have its own (use Sort inside the folder). Choices appear only when the catalog really has that information.") {
        listOf(ContentKind.MOVIE to "Movies", ContentKind.SERIES to "Series", ContentKind.CHANNEL to "Live TV").forEach { (k, n) ->
            val spec by c.browse.sort(k, null).collectAsState()
            val fields = availability.offers(k)
            ChoiceRow("$n: order by", options = fields.map { it to it.label }, value = spec.field) { c.browse.setSort(k, null, spec.copy(field = it)) }
            ToggleRow("$n: reverse the order", on = !spec.ascending) { c.browse.setSort(k, null, spec.copy(ascending = !it)) }
            ToggleRow("$n: favorites first", on = spec.favoritesFirst) { c.browse.setSort(k, null, spec.copy(favoritesFirst = it)) }
            if (k != ContentKind.CHANNEL) ToggleRow("$n: unwatched first", on = spec.unwatchedFirst) { c.browse.setSort(k, null, spec.copy(unwatchedFirst = it)) }
        }
    }
    SettingGroup("Search") {
        InfoRow("Recent searches", recent.size.toString(), "Kept on this device only.")
        ActionRow("Clear recent searches", null, "Clear", danger = true) { c.search.clearHistory(); msg = "Recent searches cleared." }
        InfoRow("Search index", if (indexRows == null) "…" else "%,d entries".format(indexRows), if (indexRows != null && catalogRows != null) (if (indexRows == catalogRows) "Matches the catalog (%,d entries). Healthy.".format(catalogRows) else "The catalog has %,d entries. Rebuilding is recommended.".format(catalogRows)) else null)
        ActionRow("Rebuild the search index", "Safe: favorites, folders, progress and connections are not touched.", "Rebuild", confirm = false) { scope.launch { msg = "Search index rebuilt: %,d entries.".format(c.maintenance.rebuildSearchIndex()) } }
    }
    ResultLine(msg)
}

@Composable
fun FavouriteSettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    val favs by c.user.favouriteIds(app.streamsetu.core.data.repo.UserRepository.FAVOURITES).collectAsState(initial = emptySet())
    val later by c.user.favouriteIds(app.streamsetu.core.data.repo.UserRepository.WATCH_LATER).collectAsState(initial = emptySet())
    val history by c.user.history(500).collectAsState(initial = emptyList())
    var order by remember { mutableStateOf(c.ui.homeOrder(HomeViewModel.DEFAULT_ORDER)) }
    var msg by remember { mutableStateOf<String?>(null) }
    val names = mapOf("continue" to "Continue Watching", "live" to "Recently Watched Live TV", "favorites" to "Favorites", "later" to "Watch Later", "movies" to "Recently Added Movies", "series" to "Recently Added Series", "categories" to "Browse by Category")
    SettingGroup("Lists") {
        InfoRow("Favorites", favs.size.toString(), "Channels, movies and series. Hold OK on any of them to add or remove.")
        InfoRow("Watch Later", later.size.toString())
        InfoRow("Watch history", history.size.toString(), "Kept on this device only.")
        ActionRow("Clear Favorites", null, "Clear", danger = true) { scope.launch { c.user.clearList(app.streamsetu.core.data.repo.UserRepository.FAVOURITES); msg = "Favorites cleared." } }
        ActionRow("Clear Watch Later", null, "Clear", danger = true) { scope.launch { c.user.clearList(app.streamsetu.core.data.repo.UserRepository.WATCH_LATER); msg = "Watch Later cleared." } }
        ActionRow("Clear watch history", "Removes Recently Watched. Resume positions and favorites stay.", "Clear", danger = true) { scope.launch { c.user.clearHistory(); msg = "Watch history cleared." } }
        ActionRow("Forget all resume positions", "Continue Watching empties; watched marks are removed too. Favorites and history stay.", "Forget", danger = true) { scope.launch { c.user.clearAllProgress(); msg = "Resume positions cleared." } }
    }
    val hiddenRows by c.ui.homeHidden.collectAsState()
    SettingGroup("Home rows", "Choose where each row sits on Home, and which rows to show. A row with nothing in it is never shown.") {
        order.forEach { id -> ToggleRow("Show: ${names[id] ?: id}", on = id !in hiddenRows) { c.ui.setHomeRowHidden(id, !it) } }
        order.forEachIndexed { i, id ->
            ChoiceRow(names[id] ?: id, options = (1..order.size).map { it to "Position $it" }, value = i + 1) { pos ->
                val l = order.toMutableList(); l.removeAt(i); l.add(pos - 1, id); order = l; c.ui.setHomeOrder(l)
            }
        }
        ActionRow("Restore the default order", null, "Restore", confirm = false) { order = HomeViewModel.DEFAULT_ORDER; c.ui.setHomeOrder(order) }
    }
    SettingGroup("Shortcuts in Movies and Series", "Hold OK on a shortcut under the banner to move it.") {
        ActionRow("Restore the default shortcut order", null, "Restore", confirm = false) { listOf("MOVIE", "SERIES").forEach { c.ui.setShortcutOrder(it, listOf("favorites", "later", "recent", "continue")) }; msg = "Shortcut order restored." }
    }
    ResultLine(msg)
}

@Composable
fun AppearanceSettings(c: AppContainer) {
    val ui = c.ui; val s = c.settings
    val poster by ui.posterSize.collectAsState(); val meta by ui.showPosterMeta.collectAsState(); val banner by ui.bannerEnabled.collectAsState(); val secs by ui.bannerSeconds.collectAsState()
    val shortcuts by ui.showShortcuts.collectAsState(); val anim by ui.animation.collectAsState(); val dwell by s.foldersOpenOnFocus.collectAsState(); val contrast by ui.highContrastFocus.collectAsState()
    SettingGroup("Look") {
        InfoRow("Theme", "Dark", "The only theme; it suits a TV in a dim room.")
        ChoiceRow("Poster size", options = PosterSize.entries.map { it to it.label }, value = poster) { ui.setPosterSize(it) }
        ToggleRow("Show the year under posters", on = meta) { ui.setShowPosterMeta(it) }
        ToggleRow("High-contrast focus", "A thicker white frame around whatever the remote is on.", contrast) { ui.setHighContrastFocus(it) }
        ChoiceRow("Animation", options = AnimationLevel.entries.map { it to it.label }, value = anim) { ui.setAnimation(it) }
    }
    SettingGroup("Banner and shortcuts") {
        ToggleRow("Featured banner slideshow", "The large picture at the top of Home, Movies and Series. Off: no banner.", banner) { ui.setBannerEnabled(it) }
        ChoiceRow("Slide duration", "The banner never changes while the remote is on one of its buttons.", listOf(6 to "6 seconds", 9 to "9 seconds", 12 to "12 seconds"), secs, enabled = banner, reason = "Turn on the banner first.") { ui.setBannerSeconds(it) }
        ToggleRow("Shortcut chips under the banner", "Favorites, Watch Later, Recently Watched, Continue Watching.", shortcuts) { ui.setShowShortcuts(it) }
    }
    val soundsOn by ui.soundsEnabled.collectAsState(); val theme by ui.soundTheme.collectAsState(); val vol by ui.soundVolume.collectAsState()
    val navT by ui.navTones.collectAsState(); val selT by ui.selectionTones.collectAsState(); val confT by ui.confirmationTones.collectAsState(); val errT by ui.errorTones.collectAsState(); val dur by ui.soundsDuringPlayback.collectAsState()
    SettingGroup("Interface sounds", "Short, soft tones for moving, choosing and confirming. They never change the TV's volume, never take audio focus, and do not play for the banner slideshow or background updates.") {
        ToggleRow("Interface sounds", "One switch for every interface tone.", soundsOn) { ui.setSoundsEnabled(it) }
        ChoiceRow("Sound theme", "Signature has every tone, Minimal keeps only choosing, going back, confirmations and errors.", listOf("SIGNATURE" to "StreamSetu Signature", "MINIMAL" to "Minimal", "SILENT" to "Silent"), theme, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSoundTheme(it); app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.SELECT) }
        ChoiceRow("Sound volume", "Relative to a deliberately low base level.", listOf(10, 25, 50, 75, 100).map { it to "$it%" }, vol, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSoundVolume(it); app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.SELECT) }
        ToggleRow("Navigation tones", "Moving between items and opening or closing menus.", navT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setNavTones(it) }
        ToggleRow("Selection tones", "Choosing an item and starting playback.", selT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSelectionTones(it) }
        ToggleRow("Confirmation tones", "Favorites, Watch Later, folder changes and successful connections.", confT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setConfirmationTones(it) }
        ToggleRow("Error tones", "When something cannot be done.", errT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setErrorTones(it) }
        ChoiceRow("Sounds during playback", "What happens to these tones while a video is playing.", listOf("OFF" to "Off", "REDUCED" to "Reduced", "ON" to "On"), dur, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSoundsDuringPlayback(it) }
    }
    SettingGroup("Folders") {
        ToggleRow("Open a folder when the remote rests on it", "Off: a folder opens only when OK is pressed.", dwell) { s.setFoldersOpenOnFocus(it) }
    }
}

@Composable
fun PrivacySettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    val s = c.settings
    val relock by s.relockPolicy.collectAsState()
    var locked by remember { mutableIntStateOf(0) }
    var pinDialog by remember { mutableStateOf<String?>(null) }   // "create" | "verify-remove" | "verify-reset"
    var hasPin by remember { mutableStateOf(c.parental.hasPin) }
    var msg by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(msg) { locked = c.folders.lockedCount(); hasPin = c.parental.hasPin }
    val hideAdult by c.parental.hideAdult.collectAsState()
    SettingGroup("Folder lock", "A locked folder's titles are also left out of search, banners and Home until it is unlocked. If you forget the PIN, remove it here after clearing all locks, or erase local data in Storage & Backup; there is no back door.") {
        InfoRow("Locked folders", locked.toString())
        ActionRow(if (hasPin) "Change PIN" else "Create a PIN", "Four digits. Only a scrambled form is stored on this device.", if (hasPin) "Change" else "Create", confirm = false) { pinDialog = if (hasPin) "verify-change" else "create" }
        if (hasPin) ActionRow("Remove the PIN", "Asks for the current PIN. Locked folders then ask you to create a new one.", "Remove", confirm = false) { pinDialog = "verify-remove" }
        ChoiceRow("Lock folders again", options = listOf("LEAVE" to "When I leave the library", "TEN" to "After 10 minutes", "SESSION" to "Only when the app closes"), value = relock) { s.setRelockPolicy(it) }
        ToggleRow("Hide adult folders", "Folders named XXX, Adult, 18+ and similar are left out everywhere.", hideAdult) { c.parental.setHideAdult(it) }
    }
    SettingGroup("Your data stays here", "Connections, favorites, history and progress are stored on this device only. Logins are kept in the Android Keystore and are never shown, logged or exported.") {
        ActionRow("Clear recent searches", null, "Clear", danger = true) { c.search.clearHistory(); msg = "Recent searches cleared." }
        ActionRow("Clear playback history", null, "Clear", danger = true) { scope.launch { c.user.clearHistory(); msg = "Playback history cleared." } }
        ActionRow("Reset privacy preferences", "Removes the PIN and every folder lock. Needs the current PIN.", "Reset", enabled = hasPin || locked > 0, reason = "There is nothing to reset: no PIN and no locked folders.", confirm = false) { if (hasPin) pinDialog = "verify-reset" else scope.launch { c.folders.clearAllLocks(); msg = "Folder locks removed." } }
    }
    ResultLine(msg)
    when (pinDialog) {
        "create" -> PinDialog(true, { true }, { c.parental.setPin(it); pinDialog = null; msg = "PIN saved." }, { pinDialog = null })
        "verify-change" -> PinDialog(false, c.parental::checkPin, { pinDialog = "create" }, { pinDialog = null })
        "verify-remove" -> PinDialog(false, c.parental::checkPin, { c.parental.clearPin(); pinDialog = null; msg = "PIN removed." }, { pinDialog = null })
        "verify-reset" -> PinDialog(false, c.parental::checkPin, { pinDialog = null; c.parental.clearPin(); scope.launch { c.folders.clearAllLocks(); s.setRelockPolicy("LEAVE"); msg = "PIN and folder locks removed." } }, { pinDialog = null })
    }
}

@Composable
fun StorageSettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var db by remember { mutableLongStateOf(c.maintenance.databaseBytes()) }; var img by remember { mutableLongStateOf(c.maintenance.imageCacheBytes()) }
    var msg by remember { mutableStateOf<String?>(null) }
    val dir = remember { File(context.getExternalFilesDir(null) ?: context.filesDir, "backups").also { it.mkdirs() } }
    var files by remember { mutableStateOf(dir.listFiles { f -> f.extension == "json" }?.sortedByDescending { it.lastModified() }.orEmpty()) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch { msg = runCatching { val r = c.maintenance.restoreBackup(readText(context, uri)); "Restored ${r.favourites} favorites, ${r.folders} folder settings, ${r.progress} positions, ${r.history} history entries" + if (r.skipped > 0) ". ${r.skipped} items belonged to connections that are not on this device and were skipped." else "." }.getOrElse { it.message ?: "The backup could not be restored." } }
    }
    SettingGroup("Storage") {
        InfoRow("Catalog database", fmtBytes(db)); InfoRow("Artwork cache", fmtBytes(img))
        ActionRow("Clear the artwork cache", "Safe. Pictures download again when needed. Favorites, connections and progress are not touched.", "Clear", confirm = false) { c.maintenance.clearImageCache(); img = c.maintenance.imageCacheBytes(); msg = "Artwork cache cleared." }
        ActionRow("Rebuild the search index", "Safe.", "Rebuild", confirm = false) { scope.launch { msg = "Search index rebuilt: %,d entries.".format(c.maintenance.rebuildSearchIndex()) } }
        ActionRow("Remove obsolete catalog data", "Removes episodes of series that no longer exist, then compacts the database. Safe.", "Clean", confirm = false) { scope.launch { val n = c.maintenance.cleanObsolete(); db = c.maintenance.databaseBytes(); msg = "Removed $n obsolete entries." } }
    }
    SettingGroup("Backup", "A backup holds favorites, Watch Later, folder arrangements, resume positions, history and settings. It never holds logins, playlist links or stream addresses.") {
        val auto by c.settings.automaticBackups.collectAsState()
        ToggleRow("Back up automatically", "About once a week, keeping the last five. They are saved in the same place and can be restored the same way.", auto) { c.settings.setAutomaticBackups(it); app.streamsetu.tv.AutoBackupWorker.schedule(context, it) }
        ActionRow("Create a backup", "Saved in ${dir.absolutePath.substringAfter("Android/")}.", "Back up", confirm = false) { scope.launch {
            val f = File(dir, "streamsetu-" + java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US).format(Date()) + ".json")
            runCatching { f.writeText(c.maintenance.exportBackup()) }.onSuccess { files = dir.listFiles { x -> x.extension == "json" }?.sortedByDescending { it.lastModified() }.orEmpty(); msg = "Backup saved: ${f.name}" }.onFailure { msg = "The backup could not be saved: ${it.message}" }
        } }
        files.take(5).forEach { f ->
            ActionRow("Restore ${f.name}", "Newer positions on this device are kept. Connections are matched by name.", "Restore", danger = true) { scope.launch { msg = runCatching { val r = c.maintenance.restoreBackup(f.readText()); "Restored ${r.favourites} favorites, ${r.folders} folder settings, ${r.progress} positions." + if (r.skipped > 0) " ${r.skipped} skipped." else "" }.getOrElse { it.message ?: "Restore failed." } } }
        }
        ActionRow("Restore from a file…", "Choose a backup file from this device or a USB drive.", "Choose", confirm = false) { picker.launch(arrayOf("*/*")) }
    }
    SettingGroup("Reset", "Resetting settings never erases connections, favorites or progress.") {
        ActionRow("Reset all settings", "Every setting goes back to its default.", "Reset", danger = true) { c.maintenance.resetSettings(); msg = "Settings reset. Some changes show after the app restarts." }
        ActionRow("Erase all local data", "Deletes every connection, login, catalog, favorite, folder arrangement, progress and setting on this device. Cannot be undone.", "Erase", danger = true) { scope.launch { c.maintenance.deleteAllLocalData(); msg = "Everything was erased."; db = c.maintenance.databaseBytes() } }
    }
    ResultLine(msg)
}

@Composable
fun DiagnosticsSettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var facts by remember { mutableStateOf(c.playback.diagnostics()) }
    var errors by remember { mutableStateOf(c.playback.recentErrors()) }
    LaunchedEffect(Unit) { while (true) { facts = c.playback.diagnostics(); errors = c.playback.recentErrors(); kotlinx.coroutines.delay(2000) } }
    val sources by c.sources.sources.collectAsState(initial = emptyList())
    var indexRows by remember { mutableStateOf(0) }; var catalogRows by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { indexRows = c.maintenance.indexRows(); catalogRows = c.maintenance.catalogRows() }
    var msg by remember { mutableStateOf<String?>(null) }
    val version = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "?" }
    SettingGroup("Playing now") {
        if (c.playback.current.value == null) InfoRow("Nothing is playing", "", "Start a channel or movie, then come back to see its details.")
        facts.forEach { (k, v) -> InfoRow(k, v) }
    }
    SettingGroup("Recent player errors", "Newest first. Addresses and logins are never shown.") {
        if (errors.isEmpty()) InfoRow("No errors", "") else errors.take(8).forEach { InfoRow(it, "") }
    }
    SettingGroup("Connections and catalog") {
        sources.forEach { s -> InfoRow(s.name, if (s.draft) "Unfinished" else s.status.name.lowercase(), s.lastError?.let { app.streamsetu.core.data.repo.MaintenanceService.redact(it) }) }
        InfoRow("Search index", if (indexRows == catalogRows) "Healthy" else "Out of date", "%,d indexed of %,d catalog entries".format(indexRows, catalogRows))
    }
    SettingGroup("Report", "A report has the stream format, error kinds, app version and device facts. Provider addresses, user names, passwords and tokens are removed.") {
        ActionRow("Export a diagnostic report", "Saved as a text file you can share.", "Export", confirm = false) { scope.launch {
            val text = c.maintenance.diagnosticsReport(c.playback.diagnostics(), c.playback.recentErrors(), "StreamSetu $version")
            val dir = File(context.getExternalFilesDir(null) ?: context.filesDir, "reports").also { it.mkdirs() }
            val f = File(dir, "diagnostics-" + java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US).format(Date()) + ".txt"); f.writeText(text)
            msg = "Saved: ${f.absolutePath.substringAfter("Android/")}"
        } }
        ActionRow("Reset player settings", "Playback, audio and subtitle settings go back to their defaults.", "Reset", danger = true) { c.settings.resetPlayerPreferences(); msg = "Player settings reset." }
    }
    ResultLine(msg)
}

@Composable
fun AboutSettings(c: AppContainer) {
    val context = LocalContext.current
    val pkg = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull() }
    SettingGroup("StreamSetu") {
        InfoRow("Version", (pkg?.versionName ?: "?") + "  (build " + (pkg?.let { if (android.os.Build.VERSION.SDK_INT >= 28) it.longVersionCode else @Suppress("DEPRECATION") it.versionCode.toLong() } ?: 0) + ")")
        InfoRow("What it is", "A player for your own IPTV connections", "StreamSetu does not provide channels, movies, subscriptions or accounts.")
    }
    UpdateSettings(c)
    SettingGroup("This device") {
        InfoRow("Device", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
        InfoRow("Android", "${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})", if (context.packageManager.hasSystemFeature("amazon.hardware.fire_tv")) "Amazon Fire TV" else null)
        InfoRow("Playback engines", c.playback.available.joinToString(", ") { it.label })
        InfoRow("Needs", "Android 5.1 or later", "MPV needs Android 8.")
    }
    SettingGroup("Privacy", "No account, no advertising, no analytics. Nothing leaves this device except the requests your own provider needs to stream and list content.") {
        InfoRow("Stored on this device", "Connections, favorites, history, progress", "Logins are encrypted with the Android Keystore.")
        InfoRow("Crash and usage reports", "Off", "None are collected or sent.")
    }
    SettingGroup("Open-source software") {
        listOf("AndroidX Media3 (ExoPlayer)" to "Apache 2.0", "mpv and libmpv for Android" to "LGPL 2.1 or later", "OkHttp and Retrofit" to "Apache 2.0", "Coil" to "Apache 2.0", "Room, Compose, WorkManager" to "Apache 2.0", "Hilt and Dagger" to "Apache 2.0", "Kotlin and kotlinx" to "Apache 2.0").forEach { (n, l) -> InfoRow(n, l) }
    }
    SettingGroup("Support") {
        InfoRow("Something wrong?", "Export a diagnostic report", "Settings, Diagnostics. It contains no logins or provider addresses, so it is safe to share.")
    }
}


/** Settings, About: check for a newer release, download it and open the installer. Nothing installs without the person confirming in the system installer. */
@Composable
fun UpdateSettings(c: AppContainer) {
    val u = c.updates
    if (!u.enabled) {
        SettingGroup("Updates") { InfoRow("Updates", "Through your device\'s app store", "This build does not update itself.") }
        return
    }
    val st by u.state.collectAsState()
    val auto by c.settings.autoUpdateCheck.collectAsState()
    val last = c.settings.lastUpdateCheckAt
    SettingGroup("Updates", "Updates come from the StreamSetu releases on GitHub. A file is used only if its checksum matches the release notes and it is signed with the same key as this app. The system installer always asks you to confirm.") {
        InfoRow("Installed version", u.installedVersion())
        ToggleRow("Check for updates when the app opens", "Once a day, and never while something is playing. Only the release list is requested; nothing about you is sent.", auto) { c.settings.setAutoUpdateCheck(it) }
        when (val s = st) {
            is UpdateState.Checking -> InfoRow("Checking…", "")
            is UpdateState.Downloading -> InfoRow("Downloading the update", "${s.percent}%", "Keep the app open until it finishes.")
            is UpdateState.Available -> {
                InfoRow("Version ${s.release.version} is available", "", s.asset.name + "  ·  " + "%.1f MB".format(s.asset.size / 1_048_576.0))
                ActionRow("Download and install", "Downloads the file, checks it, then opens the installer.", "Download", confirm = false) { u.downloadAndInstall() }
            }
            is UpdateState.Ready -> ActionRow("Install version ${s.version}", "The update is downloaded and checked.", "Install", confirm = false) { u.install() }
            is UpdateState.NeedsPermission -> {
                InfoRow("One setting to allow", "", "Allow StreamSetu to install apps in the screen that opened, then come back and press Install.")
                ActionRow("Install version ${s.version}", null, "Install", confirm = false) { u.install() }
            }
            is UpdateState.UpToDate -> { InfoRow("You are up to date", ""); ActionRow("Check again", null, "Check", confirm = false) { u.check(manual = true) } }
            is UpdateState.Failed -> { ResultLine(s.message); ActionRow("Check for updates", null, "Check", confirm = false) { u.check(manual = true) } }
            UpdateState.Idle -> ActionRow("Check for updates", if (last > 0) "Last checked " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(last)) else null, "Check", confirm = false) { u.check(manual = true) }
        }
    }
}
