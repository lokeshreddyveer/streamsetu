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
import app.streamsetu.tv.ui.components.TopBar
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
        container.playback.saveProgress()
        super.onStop()
    }
}

/** A tiny factory so each screen gets its own ViewModel built from the container. */
@Composable
inline fun <reified T : ViewModel> vm(key: String? = null, crossinline create: () -> T): T =
    viewModel(key = key, factory = object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST") override fun <V : ViewModel> create(modelClass: Class<V>): V = create() as V
    })

@Composable
fun StreamSetuTV(c: AppContainer, nav: Navigator, onExit: () -> Unit) {
    val reduced = app.streamsetu.core.ui.motion.rememberReducedMotion()
    val entries by c.library.entries.collectAsState(initial = emptyList())
    val playbackState by c.playback.state.collectAsState()
    val sidebarEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val contentEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val baseFocus = remember { androidx.compose.ui.focus.FocusRequester() }

    // No working library at all: the first-time welcome replaces the chooser.
    val noLibrary = entries.none { it.usable }
    val effectiveBase = if (nav.base == Base.ChooseLibrary && noLibrary && entries.none { it.kind == LibraryEntry.Kind.CONNECTION }) Base.Welcome else nav.base

    BackHandler(enabled = true) {
        when {
            nav.top == Overlay.Player -> { c.playback.stop(); nav.close() }
            nav.overlays.isNotEmpty() -> nav.close()
            effectiveBase is Base.Setup || effectiveBase is Base.Combined -> nav.base = Base.ChooseLibrary
            effectiveBase == Base.ChooseLibrary || effectiveBase == Base.Welcome -> onExit()
            !nav.back() -> onExit()
        }
    }

    androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.core.ui.motion.LocalReducedMotion provides reduced) {
    Box(Modifier.fillMaxSize().background(Tokens.background)) {
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
        androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalInOverlay provides true) {
            nav.top?.let { top -> app.streamsetu.tv.ui.components.FadeIn(top) {
                when (val o = top) {
                    is Overlay.MovieDetail -> app.streamsetu.tv.ui.screens.detail.MovieDetailScreen(o.movie, c, nav)
                    is Overlay.SeriesDetail -> app.streamsetu.tv.ui.screens.detail.SeriesDetailScreen(vm(key = o.series.id) { SeriesDetailViewModel(c, o.series) }, c, nav)
                    is Overlay.Player -> PlayerScreen(c, onClose = { c.playback.stop(); nav.close() })
                    is Overlay.ManageLibrary -> app.streamsetu.tv.ui.screens.library.ManageLibraryDialog(o.entry, nav)
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
    val sidebarVisible = !nav.tab.fullScreenSection || nav.sidebarRevealed
    // After a section opens, the remote goes to its entry point; after the sidebar is revealed, to the sidebar.
    LaunchedEffect(nav.tab, nav.sidebarRevealed) {
        kotlinx.coroutines.delay(if (nav.sidebarRevealed) 120 else 220)
        repeat(8) {
            val ok = runCatching { if (nav.sidebarRevealed) sidebarEntry.requestFocus() else contentEntry.requestFocus() }.isSuccess
            if (ok) return@LaunchedEffect
            kotlinx.coroutines.delay(120)
        }
    }
    Row(Modifier.fillMaxSize()) {
        androidx.compose.animation.AnimatedVisibility(
            sidebarVisible,
            enter = androidx.compose.animation.expandHorizontally(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SIDEBAR, easing = app.streamsetu.core.ui.motion.Motion.Standard)) + androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SIDEBAR)),
            exit = androidx.compose.animation.shrinkHorizontally(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SIDEBAR, easing = app.streamsetu.core.ui.motion.Motion.Exit)) + androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(if (reduced) 0 else app.streamsetu.core.ui.motion.Motion.SHORT)),
        ) {
            app.streamsetu.tv.ui.components.Sidebar(nav.tab, onSelect = { t ->
                if (t == Tab.LIBRARIES) { c.library.close(); nav.toChooser() } else nav.go(t)
            }, entry = sidebarEntry)
        }
        Box(Modifier.weight(1f).fillMaxHeight()) {
            app.streamsetu.tv.ui.components.FadeIn(nav.tab) {
                when (nav.tab) {
                    Tab.HOME -> app.streamsetu.tv.ui.screens.home.HomeScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.LIVE -> LiveScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.GUIDE -> GuideScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.MOVIES -> app.streamsetu.tv.ui.screens.section.SectionScreen(androidx.hilt.navigation.compose.hiltViewModel<app.streamsetu.tv.ui.screens.section.MoviesSectionViewModel>(), c, nav) { card -> card.movie?.let { nav.open(Overlay.MovieDetail(it)) } }
                    Tab.SERIES -> app.streamsetu.tv.ui.screens.section.SectionScreen(androidx.hilt.navigation.compose.hiltViewModel<app.streamsetu.tv.ui.screens.section.SeriesSectionViewModel>(), c, nav) { card -> card.series?.let { nav.open(Overlay.SeriesDetail(it)) } }
                    Tab.SEARCH -> SearchScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.SETTINGS -> SettingsScreen(androidx.hilt.navigation.compose.hiltViewModel(), c, nav)
                    Tab.LIBRARIES -> {}
                }
            }
        }
    }
}

/** Plays something and shows the player on top. */
fun play(c: AppContainer, nav: Navigator, item: app.streamsetu.core.model.Playable, queue: List<app.streamsetu.core.model.Playable> = listOf(item)) {
    c.play(item, queue)
    if (nav.top != Overlay.Player) nav.open(Overlay.Player)
}
