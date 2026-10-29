package app.streamsetu.tv

import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.tv.ui.components.railOnLeft
import kotlinx.coroutines.flow.first
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import android.os.Bundle
import androidx.activity.ComponentActivity
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.animation.togetherWith
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.foundation.focusGroup
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Base
import app.streamsetu.core.model.LibraryEntry
import kotlinx.coroutines.launch
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.screens.*
import app.streamsetu.tv.ui.theme.Tokens

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var container: AppContainer
    private val nav = Navigator()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A television keeps the remote layout, sideways. A phone or tablet gets the touch layout and turns with the person.
        val phone = app.streamsetu.tv.ui.phone.isPhoneDevice(this)
        if (phone) androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)
        else requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        setContent {
            val watched by container.watchedTitles.collectAsStateWithLifecycle()
            val partial by container.partialTitles.collectAsStateWithLifecycle()
            val saved by container.downloads.items.collectAsStateWithLifecycle()
            val downloadStatus = androidx.compose.runtime.remember(saved) {
                val order = listOf(app.streamsetu.core.data.repo.SaveState.DOWNLOADING, app.streamsetu.core.data.repo.SaveState.QUEUED, app.streamsetu.core.data.repo.SaveState.PAUSED, app.streamsetu.core.data.repo.SaveState.FAILED, app.streamsetu.core.data.repo.SaveState.DONE)
                saved.groupBy { it.seriesId ?: it.itemId }.mapValues { (_, list) -> list.minBy { order.indexOf(it.state) }.let { it.state to it.fraction } }
            }
            androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalWatched provides watched, app.streamsetu.tv.ui.components.LocalDownloadStatus provides downloadStatus, app.streamsetu.tv.ui.components.LocalPartialProgress provides partial) {
                if (phone) androidx.compose.foundation.layout.Box {
                    app.streamsetu.tv.ui.phone.PhoneApp(container, nav, onExit = { finish() })
                    app.streamsetu.tv.ui.screens.settings.ViewingBlockOverlay(container)
                    var picked by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(profileChosen) }
                    val many by container.profiles.profiles.collectAsStateWithLifecycle()
                    if (!picked && many.size > 1) app.streamsetu.tv.ui.screens.settings.ProfilePickerOverlay(container) { picked = true; profileChosen = true }
                } else androidx.compose.foundation.layout.Box {
                    StreamSetuTV(container, nav, onExit = { finish() })
                    app.streamsetu.tv.ui.screens.settings.ViewingBlockOverlay(container)
                }
            }
        }
        handle(intent)
        // A little after the first screens are up, start reading who is in the movies (see PeopleIndexer).
        android.os.Handler(mainLooper).postDelayed({ container.people.start(); app.streamsetu.tv.ui.screens.settings.refreshInsightAlarms(container) }, 20_000)
    }

    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); handle(intent) }

    /** `streamsetu://play?kind=channel|movie|series&q=name[&engine=auto|exoplayer|mpv]`: starts something by name (used for testing and voice shortcuts). */
    private fun handle(intent: android.content.Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "streamsetu" || (uri.host != "play" && uri.host != "watch")) return
        val c = container
        // A link from the home screen's Continue watching row (or a reminder) names the exact item.
        uri.getQueryParameter("id")?.let { id ->
            c.appScope.launch {
                val item: app.streamsetu.core.model.Playable? = c.catalog.movie(id)?.let { app.streamsetu.core.model.MoviePlayable(it) }
                    ?: c.catalog.episode(id)?.let { ep -> c.catalog.series(ep.seriesId)?.let { s -> app.streamsetu.core.model.EpisodePlayable(ep, s) } }
                    ?: c.catalog.channel(id)?.let { app.streamsetu.core.model.ChannelPlayable(it) }
                if (item != null) kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { play(c, nav, item) }
            }
            return
        }
        uri.getQueryParameter("engine")?.let { e -> c.settings.setEngine(app.streamsetu.core.playback.EnginePreference.entries.firstOrNull { it.name.equals(e, true) || (e == "auto" && it.name == "AUTOMATIC") } ?: app.streamsetu.core.playback.EnginePreference.AUTOMATIC) }
        // Links shared from the Apple apps and from the share button: ?channel=, ?movie= or ?series= with the name.
        val named = listOf("channel", "movie", "series").firstOrNull { uri.getQueryParameter(it) != null }
        val q = uri.getQueryParameter("q") ?: named?.let { uri.getQueryParameter(it) } ?: return
        val kind = uri.getQueryParameter("kind") ?: named
        c.appScope.launch {
            val r = c.catalog.search(q, 1)
            val item: app.streamsetu.core.model.Playable? = when (kind) {
                "movie" -> r.movies.firstOrNull()?.let { app.streamsetu.core.model.MoviePlayable(it) }
                "series" -> r.series.firstOrNull()?.let { s -> c.sync.loadEpisodes(s); c.catalog.episodesOnce(s.id).firstOrNull()?.let { app.streamsetu.core.model.EpisodePlayable(it, s) } }
                else -> r.channels.firstOrNull()?.let { app.streamsetu.core.model.ChannelPlayable(it) }
            }
            if (item != null) kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { play(c, nav, item) }
        }
    }

    override fun onStop() {
        app.streamsetu.tv.UISound.pause()
        runCatching { frames.stop() }
        container.playback.onBackground()
        ContinueWidget.refresh(this)
        super.onStop()
    }

    // ---- Holding OK ----
    // Seen here, before any screen can take the key: after about half a second the thing the remote is on gets its long press, and the release that follows is swallowed
    // so it does not also count as a click. Works whether the remote repeats the key while held or not.
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var pendingHold: Runnable? = null
    private val hold = HoldToSelect(
        hasHandler = { app.streamsetu.tv.ui.components.LongPress.handler != null },
        schedule = { ms, run -> val r = Runnable { run() }; pendingHold = r; main.postDelayed(r, ms) },
        cancel = { pendingHold?.let { main.removeCallbacks(it) }; pendingHold = null },
        fire = { app.streamsetu.tv.ui.components.LongPress.handler?.run?.invoke() },
    )

    private val directions = app.streamsetu.tv.nav.DirectionThrottle()

    override fun dispatchKeyEvent(e: android.view.KeyEvent): Boolean {
        if (e.action == android.view.KeyEvent.ACTION_DOWN) app.streamsetu.tv.trace.SSTrace.v { "key ${e.keyCode} ev=${e.eventTime} now=${android.os.SystemClock.uptimeMillis()}" }
        // A held direction is thinned to what the screen can draw, and presses that waited in the queue behind a slow frame are dropped, so the cursor stops when the button is released.
        if (e.action == android.view.KeyEvent.ACTION_DOWN && e.keyCode in android.view.KeyEvent.KEYCODE_DPAD_UP..android.view.KeyEvent.KEYCODE_DPAD_RIGHT && nav.top != Overlay.Player &&
            !directions.accept(e.keyCode, e.eventTime, android.os.SystemClock.uptimeMillis())) return true
        if (e.action == android.view.KeyEvent.ACTION_DOWN && e.keyCode in android.view.KeyEvent.KEYCODE_DPAD_UP..android.view.KeyEvent.KEYCODE_DPAD_RIGHT) app.streamsetu.tv.UISound.noteDpad()
        // While the player is minimized (the sound keeps playing under the browsing screens): Play/Pause pauses it, Menu or Info brings the picture back.
        if (e.action == android.view.KeyEvent.ACTION_DOWN && nav.top != Overlay.Player && container.playback.audioOnly.value && container.playback.current.value != null) {
            when (e.keyCode) {
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, android.view.KeyEvent.KEYCODE_MEDIA_PLAY, android.view.KeyEvent.KEYCODE_MEDIA_PAUSE -> { container.playback.togglePause(); return true }
                android.view.KeyEvent.KEYCODE_MENU, android.view.KeyEvent.KEYCODE_INFO -> { container.playback.setMinimized(false); nav.open(Overlay.Player); return true }
            }
        }
        // Menu (where the remote has the key) opens the same menu as holding OK, so no action is reachable only by a long press.
        if (e.action == android.view.KeyEvent.ACTION_DOWN && e.repeatCount == 0 && e.keyCode == android.view.KeyEvent.KEYCODE_MENU && nav.top == null) {
            app.streamsetu.tv.ui.components.LongPress.handler?.run?.let { it(); return true }
        }
        val select = e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_CENTER || e.keyCode == android.view.KeyEvent.KEYCODE_ENTER || e.keyCode == android.view.KeyEvent.KEYCODE_NUMPAD_ENTER
        if (!select || nav.top == Overlay.Player) return super.dispatchKeyEvent(e)
        if (hold.onSelect(e.action == android.view.KeyEvent.ACTION_DOWN, e.repeatCount, e.downTime)) return true
        return super.dispatchKeyEvent(e)
    }

    private val frames by lazy { app.streamsetu.core.ui.motion.FrameMonitor(this) }

    override fun onResume() { super.onResume(); app.streamsetu.tv.trace.SSTrace.refresh(); container.updates.resumeAfterPermission() }

    override fun onStart() {
        super.onStart()
        app.streamsetu.tv.UISound.resume()
        container.playback.onForeground()
        // In a test build, frame timing is written to the log (adb logcat -s Motion) so smoothness can be measured, not guessed.
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) frames.start()
    }
}

/** A tiny factory so each screen gets its own ViewModel built from the container. */
@Composable
inline fun <reified T : ViewModel> vm(key: String? = null, crossinline create: () -> T): T =
    viewModel(key = key, factory = object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST") override fun <V : ViewModel> create(modelClass: Class<V>): V = create() as V
    })

/** The opening animation plays once per launch of the app, not every time the person returns to the chooser. */
private var splashDone = false
/** The start-up choice (Settings, Libraries) is applied once per process, when the splash and the profile picker are done. */
private var startupApplied = false
/** Who is watching is asked once per launch of the app. */
private var profileChosen = false

@Composable
fun StreamSetuTV(c: AppContainer, nav: Navigator, onExit: () -> Unit) {
    var showSplash by remember { mutableStateOf(!splashDone) }
    var profilePicked by remember { mutableStateOf(profileChosen) }
    val sharedDevice by c.profiles.profiles.collectAsStateWithLifecycle()
    val systemReduced = app.streamsetu.core.ui.motion.rememberReducedMotion()
    val animation by c.ui.animation.collectAsStateWithLifecycle()
    val reduced = systemReduced || animation != app.streamsetu.core.settings.AnimationLevel.FULL
    val contrast by c.ui.highContrastFocus.collectAsStateWithLifecycle()
    val textScale by c.settings.textScalePercent.collectAsStateWithLifecycle()
    val entries by c.library.entries.collectAsState(initial = emptyList())
    val relock by c.settings.relockPolicy.collectAsStateWithLifecycle()
    LaunchedEffect(nav.base, relock) { if (nav.base != Base.Shell && relock == "LEAVE") c.folders.lockAgain() }
    val playbackState by c.playback.state.collectAsStateWithLifecycle()
    val sidebarEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val contentEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val baseFocus = remember { androidx.compose.ui.focus.FocusRequester() }

    // No working library at all: the first-time welcome replaces the chooser.
    val noLibrary = entries.none { it.usable }
    val effectiveBase = if (nav.base == Base.ChooseLibrary && noLibrary && entries.none { it.kind == LibraryEntry.Kind.CONNECTION }) Base.Welcome else nav.base

    BackHandler(enabled = true) {
        app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.NAVIGATE_BACK)
        when {
            nav.top == Overlay.Player -> closePlayer(c, nav, embeddedLive = true)
            nav.overlays.isNotEmpty() -> nav.close()
            effectiveBase is Base.Setup || effectiveBase is Base.Combined -> nav.base = Base.ChooseLibrary
            effectiveBase == Base.ChooseLibrary || effectiveBase == Base.Welcome -> onExit()
            !nav.back() -> onExit()
        }
    }

    // The page the person is on is remembered for the "last screen" start.
    LaunchedEffect(nav.tab, nav.base) { if (nav.base == Base.Shell && nav.tab != Tab.LIBRARIES) c.ui.setLastTab(nav.tab.name) }
    // Start-up: straight into the last library, and from there to Home, the last page, Live TV, the Guide, or playing the last channel. Not done when the app was opened by a link, which has its own destination.
    val activity = androidx.compose.ui.platform.LocalContext.current as? android.app.Activity
    LaunchedEffect(showSplash, profilePicked) {
        if (showSplash || !profilePicked || startupApplied) return@LaunchedEffect
        startupApplied = true
        val mode = c.ui.startup.value
        if (mode == "CHOOSER" || nav.base != Base.ChooseLibrary || activity?.intent?.data != null) return@LaunchedEffect
        val entry = kotlinx.coroutines.withTimeoutOrNull(4_000) { c.library.entries.first { l -> l.any { it.usable } } }?.let { l -> l.firstOrNull { it.id == c.library.lastUsedId && it.usable } ?: l.firstOrNull { it.usable } } ?: return@LaunchedEffect
        c.library.open(entry); nav.enterLibrary()
        when (mode) {
            "LAST_SCREEN" -> c.ui.lastTab()?.let { n -> runCatching { Tab.valueOf(n) }.getOrNull() }?.takeIf { it != Tab.LIBRARIES && it != Tab.SEARCH }?.let { nav.go(it) }
            "LIVE" -> nav.go(Tab.LIVE)
            "GUIDE" -> nav.go(Tab.GUIDE)
            "LAST_CHANNEL" -> {
                nav.go(Tab.LIVE)
                c.settings.lastChannelId?.let { id -> c.catalog.channel(id) }?.let { ch -> play(c, nav, app.streamsetu.core.model.ChannelPlayable(ch)) }
            }
        }
    }

    val density = androidx.compose.ui.platform.LocalDensity.current
    // Never leave the screen without a valid focus target: if nothing holds the remote for a moment (a page was still being built, a focused item went away),
    // it goes to the page's entry point, then the sidebar, then the first focusable thing on screen.
    var anyFocus by remember { mutableStateOf(true) }
    val rootFocus = androidx.compose.ui.platform.LocalFocusManager.current
    LaunchedEffect(anyFocus, nav.top, nav.base, nav.tab, nav.sidebarFocused) {
        if (anyFocus || nav.top != null || nav.sidebarRevealed) return@LaunchedEffect
        kotlinx.coroutines.delay(700)
        repeat(6) {
            val ok = (nav.base == Base.Shell && (runCatching { contentEntry.requestFocus() }.isSuccess || runCatching { sidebarEntry.requestFocus() }.isSuccess)) ||
                runCatching { rootFocus.moveFocus(androidx.compose.ui.focus.FocusDirection.Enter) }.getOrDefault(false)
            if (ok) { android.util.Log.i("Nav", "focus recovered on ${nav.base} ${nav.tab}"); return@LaunchedEffect }
            kotlinx.coroutines.delay(250)
        }
    }
    // The real size of the screen, published before anything below reads a size (the layout is scaled by it; nothing is drawn through a scaled canvas).
    androidx.compose.ui.platform.LocalConfiguration.current.let { cfg -> remember(cfg.screenWidthDp, cfg.screenHeightDp) { app.streamsetu.tv.ui.theme.UiScale.apply(cfg.screenWidthDp.toFloat(), cfg.screenHeightDp.toFloat()); true } }
    androidx.compose.runtime.CompositionLocalProvider(
        app.streamsetu.core.ui.motion.LocalReducedMotion provides reduced,
        app.streamsetu.tv.ui.components.LocalHighContrast provides contrast,
        androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(density.density, density.fontScale * textScale / 100f),
    ) {
    Box(Modifier.fillMaxSize().background(Tokens.background).onFocusChanged { anyFocus = it.hasFocus }) {
        androidx.compose.runtime.CompositionLocalProvider(
            app.streamsetu.tv.ui.components.LocalFocusEnabled provides (nav.top == null),
            app.streamsetu.tv.ui.components.LocalContentEntry provides contentEntry,
        ) {
            androidx.compose.animation.AnimatedContent(
                effectiveBase, Modifier.fillMaxSize(),
                transitionSpec = { androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SCREEN)) togetherWith androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(if (reduced) 0 else 120)) },
                label = "base",
            ) { base ->
                when (base) {
                    Base.ChooseLibrary -> app.streamsetu.tv.ui.screens.library.ChooseLibraryScreen(nav)
                    Base.Welcome -> app.streamsetu.tv.ui.screens.library.WelcomeScreen(nav)
                    is Base.Setup -> app.streamsetu.tv.ui.screens.library.SetupScreen(base.type, base.draftId, nav)
                    is Base.Combined -> app.streamsetu.tv.ui.screens.library.CombinedScreen(base.editing, nav)
                    Base.Shell -> Shell(c, nav, sidebarEntry, contentEntry)
                }
            }
        }
        if (!profilePicked && sharedDevice.size > 1) app.streamsetu.tv.ui.screens.settings.ProfilePickerOverlay(c) { profilePicked = true; profileChosen = true }
        if (showSplash) app.streamsetu.tv.ui.screens.library.LogoReveal(reduced) { showSplash = false; splashDone = true }
        app.streamsetu.tv.ui.components.TvUpdatePrompt(c, suppress = nav.top != null || nav.base != Base.Shell)
        if (nav.top != Overlay.Player) app.streamsetu.tv.ui.components.TvMiniPlayer(c)
        // The one video surface: above the screens, below the player's controls.
        app.streamsetu.tv.ui.components.PersistentVideo(c, nav)
        androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalInOverlay provides true) {
            // A page opens with a quick fade and a slight settle, and closes with a fade. The one that is leaving cannot take the remote while it fades.
            androidx.compose.animation.AnimatedContent(
                nav.top, Modifier.fillMaxSize(),
                transitionSpec = {
                    // The video view moves between the Live TV preview and the fullscreen player. Fading or scaling a hierarchy that holds a video surface makes the Fire TV redraw it
                    // every frame, so opening and closing the player is a cut: nothing around the picture animates.
                    if (initialState == Overlay.Player || targetState == Overlay.Player) androidx.compose.animation.EnterTransition.None togetherWith androidx.compose.animation.ExitTransition.None
                    else (androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SCREEN, easing = app.streamsetu.core.ui.motion.Motion.Standard)) +
                        androidx.compose.animation.scaleIn(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SCREEN, easing = app.streamsetu.core.ui.motion.Motion.Standard), 0.98f)) togetherWith
                        androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(if (reduced) 0 else 160, easing = app.streamsetu.core.ui.motion.Motion.Exit))
                },
                label = "overlay",
            ) { top ->
              if (top != null) androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalFocusEnabled provides (top == nav.top)) {
                when (val o: Overlay = top) {
                    is Overlay.MovieDetail -> app.streamsetu.tv.ui.screens.detail.MovieDetailScreen(o.movie, c, nav)
                    is Overlay.SeriesDetail -> app.streamsetu.tv.ui.screens.detail.SeriesDetailScreen(vm(key = o.series.id) { SeriesDetailViewModel(c, o.series) }, c, nav)
                    is Overlay.Player -> PlayerScreen(c, onClose = { closePlayer(c, nav, embeddedLive = true) }, onMultiView = { openMultiView(c, nav) }, onOpenSeries = { sr -> closePlayer(c, nav); nav.open(Overlay.SeriesDetail(sr)) }, onMinimize = { nav.liveFullscreen = false; nav.close() }, onOpenGuide = { nav.liveFullscreen = false; nav.close(); nav.go(Tab.GUIDE) })
                    is Overlay.MultiView -> app.streamsetu.tv.ui.screens.MultiViewScreen(c, onClose = { nav.close() }, onFullScreen = { ch -> nav.close(); play(c, nav, app.streamsetu.core.model.ChannelPlayable(ch), c.queue.ifEmpty { listOf(app.streamsetu.core.model.ChannelPlayable(ch)) }) })
                    is Overlay.ManageLibrary -> app.streamsetu.tv.ui.screens.library.ManageLibraryDialog(o.entry, nav)
                    is Overlay.Collection -> app.streamsetu.tv.ui.screens.home.HomeCollectionScreen(o.id, c, nav)
                }
              }
            }
        }
    }
    }
}

/** An open library: the sidebar and the sections. Movies, Series and Live TV hide the sidebar and bring their own folder panel. */
@Composable
private fun Shell(c: AppContainer, nav: Navigator, sidebarEntry: androidx.compose.ui.focus.FocusRequester, contentEntry: androidx.compose.ui.focus.FocusRequester) {
    val reduced = app.streamsetu.core.ui.motion.LocalReducedMotion.current
    val mode = nav.sidebarMode
    // For the automated tests: the navigation flags are written to the log whenever one of them changes (nothing runs unless the test switch is on).
    LaunchedEffect(Unit) {
        if (!app.streamsetu.tv.trace.SSTrace.on) return@LaunchedEffect
        androidx.compose.runtime.snapshotFlow { listOf(nav.tab.name, nav.sidebarFocused, nav.sidebarRevealed, nav.foldersRequested, nav.foldersHoldFocus, nav.top?.let { it::class.simpleName } ?: "none") }.collect { st ->
            app.streamsetu.tv.trace.SSTrace.v { "state tab=${st[0]} sidebarFocused=${st[1]} revealed=${st[2]} foldersRequested=${st[3]} foldersHold=${st[4]} overlay=${st[5]} now=${android.os.SystemClock.uptimeMillis()}" }
        }
    }
    // A chosen section gives the remote to the page's entry point, once per choice (not on every recomposition).
    LaunchedEffect(nav.tab, nav.contentFocusTick) {
        if (nav.foldersHoldFocus) return@LaunchedEffect          // the page's folder column has the remote (Movies, Series, Live TV opened from the sidebar)
        app.streamsetu.tv.ui.components.requestFocusOnFrames(5, { contentEntry.requestFocus() }, { nav.contentFocused || nav.foldersHoldFocus })
    }
    // When a detail page, the player or a menu closes, the card that was under the remote gets it back.
    val overlayOpen = nav.top != null
    LaunchedEffect(overlayOpen) {
        if (overlayOpen || nav.lastClosedAt == 0L) return@LaunchedEffect
        val back = nav.returnFocus ?: app.streamsetu.tv.ui.components.FocusMemory.last ?: return@LaunchedEffect
        // Asking is not getting: the page only accepts focus once the page above it has gone, and the system may hand the remote to some other card meanwhile. Ask again until it is on this one.
        app.streamsetu.tv.ui.components.requestFocusOnFrames(8, { back.requestFocus() }, { !nav.contentRestoreAllowed || app.streamsetu.tv.ui.components.FocusMemory.focused === back })
    }
    // Back from a page's root (or Back on Home) sends the remote to the sidebar, once per request.
    LaunchedEffect(nav.sidebarFocusTick) {
        if (nav.sidebarFocusTick == 0) return@LaunchedEffect
        app.streamsetu.tv.ui.components.requestFocusOnFrames(5, { sidebarEntry.requestFocus() }, { nav.sidebarFocused })
    }
    // Closing the sidebar with Back sends the remote back to where it was in the page.
    LaunchedEffect(nav.restoreFocusTick) {
        if (nav.restoreFocusTick == 0) return@LaunchedEffect
        if (!nav.contentRestoreAllowed) return@LaunchedEffect          // the folders were chosen meanwhile: the remote stays with them
        var tries = 0
        app.streamsetu.tv.ui.components.requestFocusOnFrames(5, { ((if (tries++ < 3) app.streamsetu.tv.ui.components.FocusMemory.content else null) ?: contentEntry).requestFocus() }, { nav.contentFocused || !nav.contentRestoreAllowed })
    }
    // One instance of the sidebar. The page is laid out once: on Home it keeps a strip as wide as the collapsed sidebar, elsewhere it uses the whole width. The sidebar is drawn over the
    // page and widens over it, so opening and closing it never makes the page measure itself again (which cost most of a frame on a Fire TV Stick). When it is HIDDEN it is not composed.
    androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalFocusRing provides androidx.compose.ui.graphics.Color.Unspecified, app.streamsetu.tv.ui.components.LocalRailReveal provides remember(nav) { { if (nav.tab == Tab.MOVIES || nav.tab == Tab.SERIES || nav.tab == Tab.LIVE) nav.foldersRequested = true else nav.revealSidebar() } }) {
    Box(Modifier.fillMaxSize()) {
    Row(Modifier.fillMaxSize()) {
                // Left, with nothing further left inside the page, goes to the rail (see leftGoesTo): the page never has the remote jump to some card to the left.
        Box(Modifier.weight(1f).fillMaxHeight().onFocusChanged { nav.contentFocusChanged(it.hasFocus) }.railOnLeft()) {
            // Moving between pages crossfades them. The page that is leaving cannot take the remote while it fades.
            val pageFocusOk = app.streamsetu.tv.ui.components.LocalFocusEnabled.current
            androidx.compose.animation.Crossfade(nav.tab, Modifier.fillMaxSize(), animationSpec = androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SHORT, easing = app.streamsetu.core.ui.motion.Motion.Standard), label = "page") { page ->
              androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalFocusEnabled provides (pageFocusOk && page == nav.tab)) {
                when (page) {
                    Tab.HOME -> app.streamsetu.tv.ui.screens.home.HomeScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.LIVE -> app.streamsetu.tv.ui.screens.live.LiveScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.GUIDE -> app.streamsetu.tv.ui.screens.guide.GuideScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.MOVIES -> app.streamsetu.tv.ui.screens.section.SectionScreen(androidx.hilt.navigation.compose.hiltViewModel<app.streamsetu.tv.ui.screens.section.MoviesSectionViewModel>(), c, nav) { card -> card.movie?.let { nav.open(Overlay.MovieDetail(it)) } }
                    Tab.SERIES -> app.streamsetu.tv.ui.screens.section.SectionScreen(androidx.hilt.navigation.compose.hiltViewModel<app.streamsetu.tv.ui.screens.section.SeriesSectionViewModel>(), c, nav) { card -> card.series?.let { nav.open(Overlay.SeriesDetail(it)) } }
                    Tab.SEARCH -> app.streamsetu.tv.ui.screens.search.SearchScreen(c, nav)
                    Tab.SETTINGS -> app.streamsetu.tv.ui.screens.settings.SettingsScreen(c, nav)
                    Tab.LIBRARIES -> {}
                }
              }
            }
        }
    }
    // The sidebar hides itself: it slides in over a soft shade when asked for (Left at a page's edge, or Back) and slides away when the remote is back in the page.
    androidx.compose.animation.AnimatedVisibility(
        mode != app.streamsetu.tv.nav.SidebarMode.HIDDEN,
        enter = androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(if (reduced) 0 else 220)),
        exit = androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(if (reduced) 0 else 200, delayMillis = if (reduced) 0 else 40)),
    ) {
        // The main sidebar floats over the page: a 45 % scrim behind it, and the page never moves.
        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color(0x73000000)))
    }
    androidx.compose.animation.AnimatedVisibility(
        mode != app.streamsetu.tv.nav.SidebarMode.HIDDEN, Modifier.align(androidx.compose.ui.Alignment.TopStart),
        enter = androidx.compose.animation.slideInHorizontally(androidx.compose.animation.core.tween(if (reduced) 0 else 180, easing = app.streamsetu.core.ui.motion.Motion.Standard)) { -it } + androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(if (reduced) 0 else 180)),
        exit = androidx.compose.animation.slideOutHorizontally(androidx.compose.animation.core.tween(if (reduced) 0 else 140, easing = app.streamsetu.core.ui.motion.Motion.Exit)) { -it } + androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(if (reduced) 0 else 180)),
    ) {
        app.streamsetu.tv.ui.components.Sidebar(nav.tab, onSelect = { t ->
            if (t == Tab.LIBRARIES) { c.library.close(); nav.toChooser() } else nav.choose(t)
        }, entry = sidebarEntry, expanded = true, onFocusChange = nav::sidebarFocusChanged, onReturn = nav::closeSidebar, livePlaying = c.playback.current.collectAsStateWithLifecycle().value?.isLive == true)
    }
    }
    }
}

/**
 * Closes the fullscreen player. On a TV ([embeddedLive]) a live channel keeps playing and Back lands on Live TV with that channel in the picture beside the list, wherever it was opened
 * from (Home, Search, the Guide...), so opening the same channel again is instant. Anything else (a movie or episode, a catch-up programme, a phone) stops. Stopping on purpose
 * ("Close player") calls `playback.stop()` itself first.
 */
fun closePlayer(c: AppContainer, nav: Navigator, embeddedLive: Boolean = false) {
    val item = c.playback.current.value
    val keepLive = embeddedLive && item?.isLive == true && item !is app.streamsetu.core.model.CatchUpPlayable
    if (!keepLive) c.playback.stop()
    nav.liveFullscreen = false
    nav.close()
    if (keepLive && nav.tab != Tab.LIVE) nav.go(Tab.LIVE)
}

/** Hands the channel playing now over to Multi-View: the player closes and its stream stops (so a one-connection provider is free for the tiles). */
fun openMultiView(c: AppContainer, nav: Navigator) {
    c.multiViewStart = listOfNotNull((c.playback.current.value as? app.streamsetu.core.model.ChannelPlayable)?.channel)
    nav.close()
    c.playback.stop()
    nav.open(Overlay.MultiView)
}

/** Plays something and shows the player on top. */
fun play(c: AppContainer, nav: Navigator, item: app.streamsetu.core.model.Playable, queue: List<app.streamsetu.core.model.Playable> = listOf(item), privately: Boolean = false) {
    c.play(item, queue, privately = privately)
    if (nav.top != Overlay.Player) nav.open(Overlay.Player)
}
