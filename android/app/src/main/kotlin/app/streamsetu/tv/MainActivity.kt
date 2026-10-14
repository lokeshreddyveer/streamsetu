package app.streamsetu.tv

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
        setContent { StreamSetuTV(container, nav, onExit = { finish() }) }
        handle(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); handle(intent) }

    /** `streamsetu://play?kind=channel|movie|series&q=name[&engine=auto|exoplayer|mpv]`: starts something by name (used for testing and voice shortcuts). */
    private fun handle(intent: android.content.Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "streamsetu" || uri.host != "play") return
        val c = container
        uri.getQueryParameter("engine")?.let { e -> c.settings.setEngine(app.streamsetu.core.playback.EnginePreference.entries.firstOrNull { it.name.equals(e, true) || (e == "auto" && it.name == "AUTOMATIC") } ?: app.streamsetu.core.playback.EnginePreference.AUTOMATIC) }
        val q = uri.getQueryParameter("q") ?: return
        c.appScope.launch {
            val r = c.catalog.search(q, 1)
            val item: app.streamsetu.core.model.Playable? = when (uri.getQueryParameter("kind")) {
                "movie" -> r.movies.firstOrNull()?.let { app.streamsetu.core.model.MoviePlayable(it) }
                "series" -> r.series.firstOrNull()?.let { s -> c.sync.loadEpisodes(s); c.catalog.episodesOnce(s.id).firstOrNull()?.let { app.streamsetu.core.model.EpisodePlayable(it, s) } }
                else -> r.channels.firstOrNull()?.let { app.streamsetu.core.model.ChannelPlayable(it) }
            }
            if (item != null) kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { play(c, nav, item) }
        }
    }

    override fun onStop() {
        runCatching { frames.stop() }
        container.playback.onBackground()
        super.onStop()
    }

    // ---- Holding OK ----
    // Seen here, before any screen can take the key: after about half a second the thing the remote is on gets its long press, and the release that follows is swallowed
    // so it does not also count as a click. Works whether the remote repeats the key while held or not.
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var longFired = false
    private val fireLong = Runnable { val h = app.streamsetu.tv.ui.components.LongPress.handler; if (h != null) { longFired = true; h.run() } }

    override fun dispatchKeyEvent(e: android.view.KeyEvent): Boolean {
        val select = e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_CENTER || e.keyCode == android.view.KeyEvent.KEYCODE_ENTER || e.keyCode == android.view.KeyEvent.KEYCODE_NUMPAD_ENTER
        if (!select || nav.top == Overlay.Player) return super.dispatchKeyEvent(e)
        when (e.action) {
            android.view.KeyEvent.ACTION_DOWN -> {
                if (e.repeatCount == 0) { longFired = false; main.removeCallbacks(fireLong); if (app.streamsetu.tv.ui.components.LongPress.handler != null) main.postDelayed(fireLong, 520) }
                if (longFired) return true
            }
            android.view.KeyEvent.ACTION_UP -> { main.removeCallbacks(fireLong); if (longFired) { longFired = false; return true } }
        }
        return super.dispatchKeyEvent(e)
    }

    private val frames by lazy { app.streamsetu.core.ui.motion.FrameMonitor(this) }

    override fun onStart() {
        super.onStart()
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

@Composable
fun StreamSetuTV(c: AppContainer, nav: Navigator, onExit: () -> Unit) {
    var showSplash by remember { mutableStateOf(!splashDone) }
    val systemReduced = app.streamsetu.core.ui.motion.rememberReducedMotion()
    val animation by c.ui.animation.collectAsState()
    val reduced = systemReduced || animation != app.streamsetu.core.settings.AnimationLevel.FULL
    val contrast by c.ui.highContrastFocus.collectAsState()
    val textScale by c.settings.textScalePercent.collectAsState()
    val entries by c.library.entries.collectAsState(initial = emptyList())
    val relock by c.settings.relockPolicy.collectAsState()
    LaunchedEffect(nav.base, relock) { if (nav.base != Base.Shell && relock == "LEAVE") c.folders.lockAgain() }
    val playbackState by c.playback.state.collectAsState()
    val sidebarEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val contentEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val baseFocus = remember { androidx.compose.ui.focus.FocusRequester() }

    // No working library at all: the first-time welcome replaces the chooser.
    val noLibrary = entries.none { it.usable }
    val effectiveBase = if (nav.base == Base.ChooseLibrary && noLibrary && entries.none { it.kind == LibraryEntry.Kind.CONNECTION }) Base.Welcome else nav.base

    BackHandler(enabled = true) {
        when {
            nav.top == Overlay.Player -> closePlayer(c, nav)
            nav.overlays.isNotEmpty() -> nav.close()
            effectiveBase is Base.Setup || effectiveBase is Base.Combined -> nav.base = Base.ChooseLibrary
            effectiveBase == Base.ChooseLibrary || effectiveBase == Base.Welcome -> onExit()
            !nav.back() -> onExit()
        }
    }

    val density = androidx.compose.ui.platform.LocalDensity.current
    // Never leave the screen without a valid focus target: if nothing holds the remote for a moment (a page was still being built, a focused item went away),
    // it goes to the page's entry point, then the sidebar, then the first focusable thing on screen.
    var anyFocus by remember { mutableStateOf(true) }
    val rootFocus = androidx.compose.ui.platform.LocalFocusManager.current
    LaunchedEffect(anyFocus, nav.top, nav.base, nav.tab, nav.sidebarFocused) {
        if (anyFocus || nav.top != null || (nav.top == Overlay.Player)) return@LaunchedEffect
        kotlinx.coroutines.delay(700)
        repeat(6) {
            val ok = (nav.base == Base.Shell && (runCatching { contentEntry.requestFocus() }.isSuccess || runCatching { sidebarEntry.requestFocus() }.isSuccess)) ||
                runCatching { rootFocus.moveFocus(androidx.compose.ui.focus.FocusDirection.Enter) }.getOrDefault(false)
            if (ok) { android.util.Log.i("Nav", "focus recovered on ${nav.base} ${nav.tab}"); return@LaunchedEffect }
            kotlinx.coroutines.delay(250)
        }
    }
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
        if (showSplash) app.streamsetu.tv.ui.screens.library.LogoReveal(reduced) { showSplash = false; splashDone = true }
        androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalInOverlay provides true) {
            nav.top?.let { top -> app.streamsetu.tv.ui.components.FadeIn(top) {
                when (val o = top) {
                    is Overlay.MovieDetail -> app.streamsetu.tv.ui.screens.detail.MovieDetailScreen(o.movie, c, nav)
                    is Overlay.SeriesDetail -> app.streamsetu.tv.ui.screens.detail.SeriesDetailScreen(vm(key = o.series.id) { SeriesDetailViewModel(c, o.series) }, c, nav)
                    is Overlay.Player -> PlayerScreen(c, onClose = { closePlayer(c, nav) })
                    is Overlay.ManageLibrary -> app.streamsetu.tv.ui.screens.library.ManageLibraryDialog(o.entry, nav)
                    is Overlay.Collection -> app.streamsetu.tv.ui.screens.home.HomeCollectionScreen(o.id, c, nav)
                }
            } }
        }
    }
    }
}

/** An open library: the sidebar and the sections. Movies, Series and Live TV hide the sidebar and bring their own folder panel. */
@Composable
private fun Shell(c: AppContainer, nav: Navigator, sidebarEntry: androidx.compose.ui.focus.FocusRequester, contentEntry: androidx.compose.ui.focus.FocusRequester) {
    val reduced = app.streamsetu.core.ui.motion.LocalReducedMotion.current
    val mode = nav.sidebarMode
    // A chosen section gives the remote to the page's entry point, once per choice (not on every recomposition).
    LaunchedEffect(nav.tab, nav.contentFocusTick) {
        kotlinx.coroutines.delay(220)
        repeat(8) { if (runCatching { contentEntry.requestFocus() }.isSuccess) return@LaunchedEffect; kotlinx.coroutines.delay(120) }
    }
    // When a detail page, the player or a menu closes, the card that was under the remote gets it back.
    val overlayOpen = nav.top != null
    LaunchedEffect(overlayOpen) {
        if (overlayOpen || nav.lastClosedAt == 0L) return@LaunchedEffect
        val back = app.streamsetu.tv.ui.components.FocusMemory.last ?: return@LaunchedEffect
        repeat(10) { kotlinx.coroutines.delay(120); if (runCatching { back.requestFocus() }.isSuccess) return@LaunchedEffect }
    }
    // Back from a page's root (or Back on Home) sends the remote to the sidebar, once per request.
    LaunchedEffect(nav.sidebarFocusTick) {
        if (nav.sidebarFocusTick == 0) return@LaunchedEffect
        kotlinx.coroutines.delay(60)
        repeat(8) { if (runCatching { sidebarEntry.requestFocus() }.isSuccess) return@LaunchedEffect; kotlinx.coroutines.delay(80) }
    }
    // One instance of the sidebar, in the layout beside the page. When it is HIDDEN it takes no width and is not composed, so it cannot take focus or keys.
    androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalFocusRing provides if (nav.tab == Tab.HOME) app.streamsetu.tv.ui.theme.Tokens.gold else androidx.compose.ui.graphics.Color.Unspecified) {
    Row(Modifier.fillMaxSize()) {
        androidx.compose.animation.AnimatedVisibility(
            mode != app.streamsetu.tv.nav.SidebarMode.HIDDEN,
            enter = androidx.compose.animation.expandHorizontally(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SIDEBAR, easing = app.streamsetu.core.ui.motion.Motion.Standard)) + androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SIDEBAR)),
            exit = androidx.compose.animation.shrinkHorizontally(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SIDEBAR, easing = app.streamsetu.core.ui.motion.Motion.Exit)) + androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SHORT)),
        ) {
            app.streamsetu.tv.ui.components.Sidebar(nav.tab, onSelect = { t ->
                if (t == Tab.LIBRARIES) { c.library.close(); nav.toChooser() } else nav.go(t)
            }, entry = sidebarEntry, expanded = mode == app.streamsetu.tv.nav.SidebarMode.EXPANDED, onFocusChange = nav::sidebarFocusChanged)
        }
        Box(Modifier.weight(1f).fillMaxHeight()) {
            app.streamsetu.tv.ui.components.FadeIn(nav.tab) {
                when (nav.tab) {
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
}

/** Closes the fullscreen player. From the Live TV browser the channel keeps playing in the preview; anywhere else the stream stops. */
fun closePlayer(c: AppContainer, nav: Navigator) {
    if (nav.liveFullscreen && nav.tab == Tab.LIVE) nav.liveFullscreen = false else { c.playback.stop(); nav.liveFullscreen = false }
    nav.close()
}

/** Plays something and shows the player on top. */
fun play(c: AppContainer, nav: Navigator, item: app.streamsetu.core.model.Playable, queue: List<app.streamsetu.core.model.Playable> = listOf(item)) {
    c.play(item, queue)
    if (nav.top != Overlay.Player) nav.open(Overlay.Player)
}
