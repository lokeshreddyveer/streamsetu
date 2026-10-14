package app.streamsetu.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
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
import kotlinx.coroutines.launch
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.TopBar
import app.streamsetu.tv.ui.screens.*
import app.streamsetu.tv.ui.theme.Tokens

class MainActivity : ComponentActivity() {
    private val nav = Navigator()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as StreamSetuApp).container
        setContent { StreamSetuTV(container, nav, onExit = { finish() }) }
        handle(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); handle(intent) }

    /** `streamsetu://play?kind=channel|movie|series&q=name[&engine=auto|exoplayer|mpv]`: starts something by name (used for testing and voice shortcuts). */
    private fun handle(intent: android.content.Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "streamsetu" || uri.host != "play") return
        val c = (application as StreamSetuApp).container
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
        (application as StreamSetuApp).container.playback.saveProgress()
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
    val topFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    val sidebarEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val contentFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    var anyFocus by remember { mutableStateOf(false) }
    var topBarFocused by remember { mutableStateOf(false) }
    // The window may not be ready the first moment, so asking once is not enough: ask until something holds focus.
    LaunchedEffect(nav.top == null) {
        var tries = 0
        while (!anyFocus && tries < 40 && nav.top == null) { runCatching { topFocus.requestFocus() }; kotlinx.coroutines.delay(150); tries++ }
    }
    val playbackState by c.playback.state.collectAsState()
    val hasSources by c.sources.sources.collectAsState(initial = null)

    // The player covers everything while something is playing.
    val playing = playbackState != PlaybackState.Idle && nav.top == Overlay.Player
    BackHandler(enabled = true) {
        if (nav.top == Overlay.Player) { c.playback.stop(); nav.close() }
        // Back from inside a page goes up to the top bar first; from the top bar it goes Home, then out of the app.
        else if (nav.top == null && !topBarFocused && runCatching { topFocus.requestFocus() }.isSuccess) { }
        else if (!nav.back()) onExit()
    }

    Box(
        Modifier.fillMaxSize().background(Tokens.background)
            .onFocusChanged { anyFocus = it.hasFocus }
            // If a key arrives while nothing is focused (it happens after the window regains focus), the first arrow press picks a place to start.
            .onPreviewKeyEvent { e ->
                val dpad = e.nativeKeyEvent.keyCode in listOf(android.view.KeyEvent.KEYCODE_DPAD_DOWN, android.view.KeyEvent.KEYCODE_DPAD_UP, android.view.KeyEvent.KEYCODE_DPAD_LEFT, android.view.KeyEvent.KEYCODE_DPAD_RIGHT, android.view.KeyEvent.KEYCODE_DPAD_CENTER)
                if (!anyFocus && dpad && nav.top == null) { runCatching { topFocus.requestFocus() }; true } else false
            },
    ) {
        // The page underneath stays alive while a full-screen page is open (so scroll and focus come back as they were); it just cannot take focus.
        val baseFocus = remember { androidx.compose.ui.focus.FocusRequester() }
        LaunchedEffect(nav.top == null) { if (nav.top == null && nav.lastClosedAt > 0) { // Focus may be taken by something else for a moment after a page closes, so the remembered item is asked for until it holds focus.
            repeat(10) {
                kotlinx.coroutines.delay(150)
                val back = app.streamsetu.tv.ui.components.FocusMemory.last
                if (back == null) { runCatching { contentFocus.requestFocus() }; return@repeat }
                val ok = runCatching { back.requestFocus() }
                android.util.Log.i("FocusMem", "restore #$it ${ok.exceptionOrNull()?.javaClass?.simpleName ?: "ok"}")
            } } }
        androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalFocusEnabled provides (nav.top == null), app.streamsetu.tv.ui.components.LocalSidebarEntry provides sidebarEntry) {
        // The page fills the screen; the top bar floats over it (transparent on Home, where the hero picture runs underneath).
        Box(Modifier.fillMaxSize()) {
            val onHome = nav.tab == Tab.HOME && hasSources?.isNotEmpty() == true
            Box(Modifier.fillMaxSize().padding(top = if (onHome) androidx.compose.ui.unit.Dp(0f) else app.streamsetu.tv.ui.theme.Tokens.headerHeight).focusRequester(contentFocus)) {
                when {
                    hasSources == null -> {}
                    hasSources!!.isEmpty() && nav.tab != Tab.SETTINGS -> FirstRun(onAdd = { nav.open(Overlay.AddPlaylist) })
                    else -> when (nav.tab) {
                        Tab.HOME -> HomeScreen(vm { HomeViewModel(c) }, c, nav)
                        Tab.LIVE -> LiveScreen(vm { LiveViewModel(c) }, c, nav)
                        Tab.GUIDE -> GuideScreen(vm { GuideViewModel(c) }, c, nav)
                        Tab.MOVIES -> MoviesScreen(vm { MoviesViewModel(c) }, c, nav)
                        Tab.SERIES -> SeriesScreen(vm { SeriesViewModel(c) }, nav)
                        Tab.SEARCH -> SearchScreen(vm { SearchViewModel(c) }, c, nav)
                        Tab.SETTINGS -> SettingsScreen(vm { SettingsViewModel(c) }, c, nav)
                    }
                }
            }
            TopBar(nav.tab, topFocus, transparent = onHome, onHasFocus = { topBarFocused = it }, canAutoSelect = { nav.canAutoSelect() }, onSelect = { nav.tab = it })
        }
        }
        androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.components.LocalInOverlay provides true) {
        when (val o = nav.top) {
            is Overlay.AddPlaylist -> AddPlaylistScreen(vm { AddPlaylistViewModel(c) }, onClose = { nav.close() })
            is Overlay.MovieDetail -> MovieDetailScreen(o.movie, c, nav)
            is Overlay.SeriesDetail -> SeriesDetailScreen(vm(key = o.series.id) { SeriesDetailViewModel(c, o.series) }, c, nav)
            is Overlay.Player -> PlayerScreen(c, onClose = { c.playback.stop(); nav.close() })
            null -> {}
        }
        }
    }
}

/** Plays something and shows the player on top. */
fun play(c: AppContainer, nav: Navigator, item: app.streamsetu.core.model.Playable, queue: List<app.streamsetu.core.model.Playable> = listOf(item)) {
    c.play(item, queue)
    if (nav.top != Overlay.Player) nav.open(Overlay.Player)
}
