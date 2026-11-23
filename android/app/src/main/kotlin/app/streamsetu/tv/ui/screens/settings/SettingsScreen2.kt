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
    val startup by c.ui.startup.collectAsState()
    SettingGroup("When the app opens", "Home and the other choices go straight into the library you used last. The chooser is the default, so nothing opens by itself.") {
        ChoiceRow("Start on", null, listOf("CHOOSER" to "Library chooser", "HOME" to "Home", "LAST_SCREEN" to "Last screen", "LAST_CHANNEL" to "Last playing channel", "LIVE" to "Live TV", "GUIDE" to "TV Guide"), startup) { c.ui.setStartup(it) }
    }
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
    SettingGroup("Catalog refresh", "Updates connections and checks followed series for new episodes.") {
        val onStart by c.settings.refreshOnStart.collectAsState()
        ToggleRow("Refresh when the app opens", "Updates connections shortly after launch when nothing is playing.", onStart) { c.settings.setRefreshOnStart(it) }
        ChoiceRow("Refresh catalogs in the background", options = listOf(0 to "Only when I ask", 12 to "Every 12 hours", 24 to "Every day"), value = hours) { c.settings.setBackgroundSyncHours(it); app.streamsetu.tv.CatalogSyncWorker.schedule(ctx, it) }
    }
    SettingGroup("Recordings", "Live TV recordings stored on this device. Start recording from the player or Guide.") {
        var files by remember { mutableStateOf(emptyList<app.streamsetu.core.data.repo.RecordingFiles.Item>()) }
        PollWhileShown(5_000) { files = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { app.streamsetu.core.data.repo.RecordingFiles.list(c.recordingsFolder) } }
        if (files.isEmpty()) InfoRow("Nothing is recorded yet", "")
        files.forEach { r ->
            InfoRow(r.title, app.streamsetu.core.data.repo.SavedTitles.size(r.bytes), DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(java.util.Date(r.startedAt)))
            ActionRow("Play ${r.title}", null, "Play", confirm = false) {
                val movie = app.streamsetu.core.model.Movie(app.streamsetu.core.data.repo.RecordingFiles.playId(r.file.name), "recordings", null, r.title + " (recorded)", null, null, null, null, "", 0)
                app.streamsetu.tv.play(c, nav, app.streamsetu.core.model.MoviePlayable(movie))
            }
            ActionRow("Remove ${r.title}", "Deletes the recording from this device.", "Remove", danger = true) { r.file.delete() }
        }
    }
    SettingGroup("Subscriptions", "When each connection's subscription ends, as the provider reports it. It is read each time the connection is refreshed. You are warned from a week before one ends.") {
        val list = c.sources.sources.collectAsState(initial = emptyList()).value.filter { !it.draft }
        val any = list.mapNotNull { s -> c.resolver.accountStatus(s.id)?.let { s to it } }
        if (any.isEmpty()) InfoRow("Nothing reported yet", "Refresh a connection that signs in with a user name (Xtream) to see its end date.")
        any.forEach { (src, st) ->
            InfoRow(src.name, st.summary(), if (st.level() == app.streamsetu.core.data.repo.AccountStatus.Level.FINE) null else "Renew it with your provider before it stops working.")
        }
    }
    SettingGroup("Downloads", "Movies and episodes saved on this device for offline playback.") {
        val saved by c.downloads.items.collectAsState()
        val wifi = remember { mutableStateOf(c.downloads.wifiOnly) }
        if (saved.isEmpty()) InfoRow("Nothing is saved yet", "")
        saved.forEach { t ->
            val status = when (t.state) {
                app.streamsetu.core.data.repo.SaveState.DONE -> "Saved  ·  " + app.streamsetu.core.data.repo.SavedTitles.size(t.bytesTotal)
                app.streamsetu.core.data.repo.SaveState.DOWNLOADING -> "${(t.fraction * 100).toInt()} %"
                app.streamsetu.core.data.repo.SaveState.QUEUED -> "Waiting"
                app.streamsetu.core.data.repo.SaveState.PAUSED -> "Paused"
                app.streamsetu.core.data.repo.SaveState.FAILED -> "Failed"
            }
            InfoRow(t.title, status, listOfNotNull(t.subtitle, t.error).joinToString("  ·  ").ifBlank { null })
            when (t.state) {
                app.streamsetu.core.data.repo.SaveState.DONE -> ActionRow("Play ${t.title}", null, "Play", confirm = false) { app.streamsetu.tv.playSaved(c, nav, t) }
                app.streamsetu.core.data.repo.SaveState.DOWNLOADING, app.streamsetu.core.data.repo.SaveState.QUEUED -> ActionRow("Pause ${t.title}", null, "Pause", confirm = false) { c.downloads.pause(t.itemId) }
                else -> ActionRow("Resume ${t.title}", null, "Resume", confirm = false) { c.downloads.resume(t.itemId) }
            }
            ActionRow("Remove ${t.title}", "Deletes the saved copy from this device.", "Remove", danger = true) { c.downloads.remove(t.itemId) }
        }
        if (saved.isNotEmpty()) InfoRow("Space used", app.streamsetu.core.data.repo.SavedTitles.size(c.downloads.totalBytes))
        ToggleRow("Only on Wi-Fi", "Off lets downloads use mobile data too.", wifi.value) { c.downloads.wifiOnly = it; wifi.value = it }
        val deleteAfter = remember { mutableStateOf(c.downloads.deleteWhenWatched) }
        ToggleRow("Delete after watching", "Removes a completed download to free storage.", deleteAfter.value) { c.downloads.deleteWhenWatched = it; deleteAfter.value = it }
    }
    SettingGroup("Cast and directors", "Searching for an actor or director uses a cast index. It is read only when you ask, or (if switched on) when the TV has been idle for a while. What is already there stays.") {
        var progress by remember { mutableStateOf(c.people.progress()) }
        PollWhileShown(5_000) { progress = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { c.people.progress() } }
        InfoRow("Movies read", "%,d of %,d".format(progress.first, progress.second))
        ActionRow("Update cast search index", "Reads the cast of new titles. It stops when you start watching and carries on next time.", "Update", confirm = false, enabled = progress.first < progress.second, reason = "Everything has been read") { c.people.start() }
        val auto = remember { mutableStateOf(c.settings.autoCastIndex.value) }
        ToggleRow("Update when idle", "After 5 minutes without using the remote. Stops as soon as you press a key. Off by default on low-memory TVs.", auto.value) { c.settings.setAutoCastIndex(it); auto.value = it }
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
    SettingGroup("Default sorting", "Sets the initial order. Each screen can remember a different choice.") {
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
    val names = mapOf("continue" to "Continue Watching", "live" to "Recently Watched Live TV", "favorites" to "Favorites", "later" to "Watch Later", "foryou" to "For You", "movies" to "Recently Added Movies", "series" to "Recently Added Series", "categories" to "Browse by Category")
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
    SettingGroup("Home rows", "Choose which Home rows appear and their order. Empty rows stay hidden.") {
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
    SettingGroup("Settings") {
        val advancedOn by ui.advancedSettings.collectAsState()
        ChoiceRow("Settings pages", "Essential lists the everyday pages. Advanced adds channel management, statistics, sync, add-ons, storage, diagnostics and the rest. Nothing is turned off or reset by switching, and a page that is in use or that a problem needs stays listed.", listOf(false to "Essential", true to "Advanced"), advancedOn) { ui.setAdvancedSettings(it) }
    }
    SettingGroup("Look") {
        val themeName by ui.theme.collectAsState(); val accentName by ui.accent.collectAsState()
        val languageName by ui.language.collectAsState()
        ChoiceRow("Language", "The language of the app's own text. Titles and descriptions come from your provider and stay as they are. Some text is still in English.", app.streamsetu.tv.ui.i18n.I18n.languages, languageName) { ui.setLanguage(it) }
        ChoiceRow("Theme", "The colour of pages and cards.", app.streamsetu.tv.ui.theme.Theme.entries.map { it.name to it.label }, themeName) { ui.setTheme(it) }
        val projectorOn by ui.projectorMode.collectAsState()
        ToggleRow("Projector mode", "Makes pages, cards, text and focus controls easier to see on projectors. It does not change video brightness or HDR.", projectorOn) { ui.setProjectorMode(it) }
        ChoiceRow("Accent colour", "Highlights, selected items and primary buttons.", app.streamsetu.tv.ui.theme.Accent.entries.map { it.name to it.label }, accentName) { ui.setAccent(it) }
        ChoiceRow("Poster size", options = PosterSize.entries.map { it to it.label }, value = poster) { ui.setPosterSize(it) }
        ToggleRow("Show the year under posters", on = meta) { ui.setShowPosterMeta(it) }
        ToggleRow("High-contrast focus", "Uses a thicker white frame around the focused item.", contrast) { ui.setHighContrastFocus(it) }
        ChoiceRow("Animation", options = AnimationLevel.entries.map { it to it.label }, value = anim) { ui.setAnimation(it) }
        // The opening at launch: automatic (the full story on the first ever launch, a short cut on every other) or off. It cannot be skipped, so it can be turned off here.
        val context = androidx.compose.ui.platform.LocalContext.current
        var opening by remember { mutableStateOf(app.streamsetu.tv.opening.startup.StartupCoordinator.mode(context)) }
        ChoiceRow("Opening", "The short film when the app starts. Reduced motion always shows a still instead.",
            app.streamsetu.tv.opening.startup.OpeningMode.entries.map { it to it.label }, opening) { opening = it; app.streamsetu.tv.opening.startup.StartupCoordinator.setMode(context, it) }
        var replayAsked by remember { mutableStateOf(false) }
        ActionRow("Replay the full story", if (replayAsked) "It plays the next time the app starts." else "Plays the full opening once more, the next time the app starts.", "Replay", confirm = false) {
            app.streamsetu.tv.opening.startup.StartupCoordinator.replayFullNextLaunch(context); replayAsked = true
        }
    }
    SettingGroup("Artwork from TMDB", "Pictures, summaries and cast come from TMDB. It works without a key: the app has its own. Your own free key is optional and is used instead.") {
        var tmdbKey by remember { mutableStateOf(c.credentials.load("tmdb.key").orEmpty()) }
        var testing by remember { mutableStateOf(false) }; var testResult by remember { mutableStateOf<String?>(null) }
        val scope = rememberCoroutineScope()
        val auth = c.tmdbAuth; val tmdbCtx = androidx.compose.ui.platform.LocalContext.current
        val trendingOn by c.ui.tmdbTrending.collectAsState()
        val matchOn by c.ui.artworkMatching.collectAsState()
        val cellularOn by c.ui.artworkMatchingCellular.collectAsState()
        val progress by c.artworkEngine.progress.collectAsState()
        val using = when (if (tmdbKey.isNotBlank()) (if (app.streamsetu.core.data.repo.TmdbAuth.isToken(tmdbKey)) app.streamsetu.core.data.repo.TmdbAuth.Source.OWN_TOKEN else app.streamsetu.core.data.repo.TmdbAuth.Source.OWN_KEY) else auth.source) {
            app.streamsetu.core.data.repo.TmdbAuth.Source.OWN_KEY, app.streamsetu.core.data.repo.TmdbAuth.Source.OWN_TOKEN -> "Your own key"
            app.streamsetu.core.data.repo.TmdbAuth.Source.BUILT_IN -> "The built-in key"
            null -> if (auth.builtInRefused) "None: the built-in key is not working; add your own free key to keep artwork" else "None"
        }
        InfoRow("Key in use", using)
        TvTextField(tmdbKey, { tmdbKey = it.trim(); testResult = null
            if (tmdbKey.isEmpty()) { c.credentials.delete("tmdb.key"); if (!auth.available) c.clearTmdbData() } else c.credentials.save("tmdb.key", tmdbKey)
            c.artworkEngine.kick() }, "Your own TMDB key (optional)", Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), secret = true)
        if (tmdbKey.isNotBlank()) ActionRow("Remove key", "Goes back to the built-in key when this build has one.", "Remove", confirm = false) {
            tmdbKey = ""; testResult = null; c.credentials.delete("tmdb.key"); if (!auth.available) c.clearTmdbData(); c.artworkEngine.kick()
        }
        ActionRow("Test key", testResult ?: "Asks TMDB whether the key in use is accepted.", if (testing) "Testing…" else "Test", confirm = false, enabled = !testing && auth.available, reason = "There is no key to test.") {
            testing = true; testResult = "Testing…"
            scope.launch { testResult = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { c.tmdbService.test() }.getOrDefault("That did not work.") }; testing = false }
        }
        ToggleRow("Match artwork in the background", "Finds missing pictures and summaries for your whole library by itself, a little at a time, and carries on where it stopped. Sends a title's name and year to TMDB; never a title in a locked, hidden or adult folder.", matchOn, enabled = auth.available || matchOn, reason = "Add your own free TMDB key first.") {
            c.ui.setArtworkMatching(it); if (!it) c.clearTmdbData(files = false); app.streamsetu.tv.TmdbMatchWorker.schedule(tmdbCtx, it, cellularOn); c.artworkEngine.kick()
        }
        ToggleRow("Use mobile data", "On: matching also runs on mobile data. Off: it waits for Wi-Fi or another network that is not metered.", cellularOn, enabled = matchOn) { c.ui.setArtworkMatchingCellular(it); app.streamsetu.tv.TmdbMatchWorker.schedule(tmdbCtx, matchOn, it); c.artworkEngine.kick() }
        InfoRow("Artwork matching", "", progress.line(auth.builtInRefused && !auth.available))
        ActionRow("Match now", "Starts or resumes the run at once, even on mobile data. You never have to press it.", "Match now", confirm = false, enabled = matchOn && auth.available, reason = "Turn on background matching first.") { c.artworkEngine.matchAnyway() }
        ToggleRow("Weekly trending (Top This Week)", "Uses TMDB's public weekly list to order Top This Week, matched on this device. Nothing about you is sent. Turn it off and the saved list is deleted.", trendingOn && auth.available, enabled = auth.available, reason = "No TMDB key is available.") {
            c.ui.setTmdbTrending(it); if (!it) c.appScope.launch(kotlinx.coroutines.Dispatchers.IO) { app.streamsetu.core.data.repo.TmdbFiles.clear(c.tmdbDir) }; c.smartMix.invalidate()
        }
        TmdbNotice()
    }
    HubSourcesGroup(c)
    SettingGroup("Browsing") {
        val rev by ui.folderViewRev.collectAsState()
        val profile = c.profiles.activeId.value
        ToggleRow("Folders view for Movies", "One row per folder, with a See all and a More tile. Off shows the plain poster grid. Kept for each profile on this device.", remember(rev, profile) { ui.foldersView("MOVIE", profile) }) { ui.setFoldersView("MOVIE", profile, it) }
        ToggleRow("Folders view for Series", "One row per folder, with a See all and a More tile. Off shows the plain poster grid. Kept for each profile on this device.", remember(rev, profile) { ui.foldersView("SERIES", profile) }) { ui.setFoldersView("SERIES", profile, it) }
        ToggleRow("Folders view for Live TV", "One row of channels per folder. Off shows the channel list with the preview. Kept for each profile on this device.", remember(rev, profile) { ui.foldersView("CHANNEL", profile) }) { ui.setFoldersView("CHANNEL", profile, it) }
    }
    SettingGroup("Banner and shortcuts") {
        ToggleRow("Featured banner slideshow", "Shows featured titles at the top of Home, Movies and Series.", banner) { ui.setBannerEnabled(it) }
        ChoiceRow("Slide duration", "The banner never changes while the remote is on one of its buttons.", listOf(6 to "6 seconds", 9 to "9 seconds", 12 to "12 seconds"), secs, enabled = banner, reason = "Turn on the banner first.") { ui.setBannerSeconds(it) }
        ToggleRow("Shortcut chips under the banner", "Favorites, Watch Later, Recently Watched, Continue Watching.", shortcuts) { ui.setShowShortcuts(it) }
    }
    val soundsOn by ui.soundsEnabled.collectAsState(); val theme by ui.soundTheme.collectAsState(); val vol by ui.soundVolume.collectAsState()
    val navT by ui.navTones.collectAsState(); val selT by ui.selectionTones.collectAsState(); val confT by ui.confirmationTones.collectAsState(); val errT by ui.errorTones.collectAsState(); val dur by ui.soundsDuringPlayback.collectAsState()
    SettingGroup("Interface sounds", "Quiet tones for navigation, selections and results.") {
        ToggleRow("Interface sounds", "Plays quiet tones for navigation, selections and results.", soundsOn) { ui.setSoundsEnabled(it) }
        ChoiceRow("Sound theme", "Pick a set of tones: Signature, Wood, Crystal, Soft or Arcade. Minimal keeps only choosing, going back, confirmations and errors.", listOf("SIGNATURE" to "StreamSetu Signature", "WOOD" to "Wood", "CRYSTAL" to "Crystal", "SOFT" to "Soft", "ARCADE" to "Arcade", "MINIMAL" to "Minimal", "SILENT" to "Silent"), theme, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSoundTheme(it); app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.SELECT) }
        ChoiceRow("Sound volume", "Relative to a deliberately low base level.", listOf(10, 25, 50, 75, 100).map { it to "$it%" }, vol, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSoundVolume(it); app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.SELECT) }
        ToggleRow("Navigation tones", "Moving between items and opening or closing menus.", navT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setNavTones(it) }
        ToggleRow("Selection tones", "Choosing an item and starting playback.", selT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSelectionTones(it) }
        ToggleRow("Confirmation tones", "Favorites, Watch Later, folder changes and successful connections.", confT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setConfirmationTones(it) }
        ToggleRow("Error tones", "When something cannot be done.", errT, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setErrorTones(it) }
        ChoiceRow("Sounds during playback", "What happens to these tones while a video is playing.", listOf("OFF" to "Off", "REDUCED" to "Reduced", "ON" to "On"), dur, enabled = soundsOn, reason = "Interface sounds are off.") { ui.setSoundsDuringPlayback(it) }
    }
    SettingGroup("Folders") {
        ToggleRow("Open a folder when the remote rests on it", "Opens a folder when focused. Turn off to require OK.", dwell) { s.setFoldersOpenOnFocus(it) }
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
    SettingGroup("Folder lock", "Hides locked titles from browsing, Home, banners and search.") {
        InfoRow("Locked folders", locked.toString())
        ActionRow(if (hasPin) "Change PIN" else "Create a PIN", "Four digits. Only a scrambled form is stored on this device.", if (hasPin) "Change" else "Create", confirm = false) { pinDialog = if (hasPin) "verify-change" else "create" }
        if (hasPin) ActionRow("Remove the PIN", "Asks for the current PIN. Locked folders then ask you to create a new one.", "Remove", confirm = false) { pinDialog = "verify-remove" }
        ChoiceRow("Lock folders again", options = listOf("LEAVE" to "When I leave the library", "TEN" to "After 10 minutes", "SESSION" to "Only when the app closes"), value = relock) { s.setRelockPolicy(it) }
        ToggleRow("Hide adult folders", "Hides folders whose names indicate adult content.", hideAdult) { c.parental.setHideAdult(it) }
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
        if (uri != null) scope.launch { msg = runCatching { val r = c.maintenance.restoreBackup(readText(context, uri)); "Restored ${r.favourites} favorites, ${r.folders} folder settings, ${r.progress} positions, ${r.history} history entries" + (if (r.skipped > 0) ". ${r.skipped} items belonged to connections that are not on this device and were skipped." else ".") + " The app is starting again so the settings apply." }.onSuccess { scope.launch { kotlinx.coroutines.delay(2000); restartApp(context) } }.getOrElse { it.message ?: "The backup could not be restored." } }
    }
    SettingGroup("Storage") {
        InfoRow("Catalog database", fmtBytes(db)); InfoRow("Artwork cache", fmtBytes(img))
        ActionRow("Clear the artwork cache", "Safe. Pictures download again when needed. Favorites, connections and progress are not touched.", "Clear", confirm = false) { c.maintenance.clearImageCache(); img = c.maintenance.imageCacheBytes(); msg = "Artwork cache cleared." }
        ActionRow("Rebuild the search index", "Safe.", "Rebuild", confirm = false) { scope.launch { msg = "Search index rebuilt: %,d entries.".format(c.maintenance.rebuildSearchIndex()) } }
        ActionRow("Remove obsolete catalog data", "Removes episodes of series that no longer exist, then compacts the database. Safe.", "Clean", confirm = false) { scope.launch { val n = c.maintenance.cleanObsolete(); db = c.maintenance.databaseBytes(); msg = "Removed $n obsolete entries." } }
    }
    SettingGroup("Backup", "Saves settings and library activity without logins or provider addresses.") {
        val auto by c.settings.automaticBackups.collectAsState()
        ToggleRow("Back up automatically", "Creates a weekly backup and keeps the five newest copies.", auto) { c.settings.setAutomaticBackups(it); app.streamsetu.tv.AutoBackupWorker.schedule(context, it) }
        ActionRow("Create a backup", "Saved in ${dir.absolutePath.substringAfter("Android/")}.", "Back up", confirm = false) { scope.launch {
            val f = File(dir, "streamsetu-" + java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US).format(Date()) + ".json")
            runCatching { f.writeText(c.maintenance.exportBackup()) }.onSuccess { files = dir.listFiles { x -> x.extension == "json" }?.sortedByDescending { it.lastModified() }.orEmpty(); msg = "Backup saved: ${f.name}" }.onFailure { msg = "The backup could not be saved: ${it.message}" }
        } }
        files.take(5).forEach { f ->
            ActionRow("Restore ${f.name}", "Newer positions on this device are kept. Connections are matched by name.", "Restore", danger = true) { scope.launch { msg = runCatching { val r = c.maintenance.restoreBackup(f.readText()); "Restored ${r.favourites} favorites, ${r.folders} folder settings, ${r.progress} positions." + (if (r.skipped > 0) " ${r.skipped} skipped." else "") + " The app is starting again so the settings apply." }.onSuccess { scope.launch { kotlinx.coroutines.delay(2000); restartApp(context) } }.getOrElse { it.message ?: "Restore failed." } } }
        }
        ActionRow("Restore from a file…", "Choose a backup file from this device or a USB drive.", "Choose", confirm = false) { picker.launch(arrayOf("*/*")) }
    }
    SettingGroup("Danger zone", "Resetting settings never erases connections, favorites or progress. Erasing everything cannot be undone.", danger = true) {
        ActionRow("Reset all settings", "Every setting goes back to its default.", "Reset", danger = true) { c.maintenance.resetSettings(); msg = "Settings reset. The app is starting again so they apply."; scope.launch { kotlinx.coroutines.delay(2000); restartApp(context) } }
        ActionRow("Erase all local data", "Deletes every connection, login, catalog, favorite, folder arrangement, progress and setting on this device. Cannot be undone.", "Erase", danger = true) { scope.launch {
            val left = runCatching { c.eraseEverything() }.getOrElse { listOf("it failed: ${it.message}") }
            if (left.isEmpty()) { msg = "Everything was erased. The app is starting again."; kotlinx.coroutines.delay(1500); restartApp(context) }
            else { msg = "Not everything could be erased (${left.size} left: ${left.take(3).joinToString(", ")}). Nothing was reported as done."; db = c.maintenance.databaseBytes() }
        } }
    }
    ResultLine(msg)
}

@Composable
fun DiagnosticsSettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var facts by remember { mutableStateOf(c.playback.diagnostics()) }
    var errors by remember { mutableStateOf(c.playback.recentErrors()) }
    // With nothing playing there is nothing new to read: the facts are read again only while a stream is open.
    PollWhileShown(3_000) { if (c.playback.current.value != null) { facts = c.playback.diagnostics(); errors = c.playback.recentErrors() } }
    val sources by c.sources.sources.collectAsState(initial = emptyList())
    var indexRows by remember { mutableStateOf(0) }; var catalogRows by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { indexRows = c.maintenance.indexRows(); catalogRows = c.maintenance.catalogRows() }
    var msg by remember { mutableStateOf<String?>(null) }
    val version = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "?" }
    SettingGroup("Playing now") {
        if (c.playback.current.collectAsState().value == null) InfoRow("Nothing is playing", "", "Start a channel or movie, then come back to see its details.")
        facts.forEach { (k, v) -> InfoRow(k, v) }
    }
    SettingGroup("Recent player errors", "Newest first. Addresses and logins are never shown.") {
        if (errors.isEmpty()) InfoRow("No errors", "") else errors.take(8).forEach { InfoRow(it, "") }
    }
    SettingGroup("Connections and catalog") {
        sources.forEach { s -> InfoRow(s.name, if (s.draft) "Unfinished" else s.status.name.lowercase(), s.lastError?.let { app.streamsetu.core.data.repo.MaintenanceService.redact(it) }) }
        InfoRow("Search index", if (indexRows == catalogRows) "Healthy" else "Out of date", "%,d indexed of %,d catalog entries".format(indexRows, catalogRows))
    }
    PlaybackCapabilitiesGroup(c)
    SettingGroup("Report", "A report has the stream format, error kinds, app version and device facts. Provider addresses, user names, passwords and tokens are removed.") {
        ActionRow("Export a diagnostic report", "Includes app, device and playback details without logins or provider addresses.", "Export", confirm = false) { scope.launch {
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
    ServiceCredits()
    SettingGroup("Open-source software") {
        listOf("AndroidX Media3 (ExoPlayer)" to "Apache 2.0", "mpv and libmpv for Android" to "LGPL 2.1 or later", "FFmpeg, libplacebo (with mpv)" to "LGPL 2.1 or later", "libass (with mpv)" to "ISC", "dav1d (with mpv)" to "BSD 2-clause", "OkHttp" to "Apache 2.0", "Coil" to "Apache 2.0", "Room, Compose, WorkManager" to "Apache 2.0", "Hilt and Dagger" to "Apache 2.0", "Kotlin and kotlinx" to "Apache 2.0").forEach { (n, l) -> InfoRow(n, l) }
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
        ToggleRow("Check for updates when the app opens", "Checks once daily when nothing is playing. No personal data is sent.", auto) { c.settings.setAutoUpdateCheck(it) }
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

/** Starts the app again in a fresh process, so nothing the erase removed is still held in memory. */
private fun restartApp(context: android.content.Context) {
    val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK) ?: return
    context.startActivity(launch)
    Runtime.getRuntime().exit(0)
}

/** The TMDB logo, the notice TMDB requires, and what is and is not sent to TMDB (shown in About and beside the TMDB settings). */
@Composable
fun TmdbNotice() {
    androidx.compose.foundation.layout.Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp), verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
        androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(app.streamsetu.tv.R.drawable.tmdb_logo), "TMDB logo", Modifier.height(14.dp), contentScale = androidx.compose.ui.layout.ContentScale.Fit, alignment = androidx.compose.ui.Alignment.CenterStart)
        Label(TMDB_NOTICE, app.streamsetu.tv.ui.theme.Tokens.small, app.streamsetu.tv.ui.theme.Tokens.textSecondary, maxLines = 4)
        Label(TMDB_PRIVACY, app.streamsetu.tv.ui.theme.Tokens.small, app.streamsetu.tv.ui.theme.Tokens.textTertiary, maxLines = 14)
    }
}

const val TMDB_NOTICE = "This product uses the TMDB API but is not endorsed or certified by TMDB."
const val TMDB_PRIVACY = "TMDB is used with your own free key when you add one, and otherwise with a key built into the app. Matching artwork, opening a title's cast or trailer, and the weekly list send TMDB a title's name and year, nothing else about you; a title in a locked, hidden or adult folder, or with a copy in one, is never sent. You can switch matching and trending off in Settings. Looking up a person by name (Ask) sends that name and nothing else. Weekly trending requests TMDB's public list: nothing about you, your history, your profile or this device is sent, and the list is matched here on this device. Saved lists and details, and the posters, summaries and ratings TMDB filled in, are kept for at most 180 days and then removed; anything your playlist provided itself is never touched. Turn the trending switch off and the saved list is deleted."
