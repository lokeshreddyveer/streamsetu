package app.streamsetu.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.SideRail
import app.streamsetu.tv.ui.screens.*
import app.streamsetu.tv.ui.theme.Tokens

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as StreamSetuApp).container
        setContent { StreamSetuTV(container, onExit = { finish() }) }
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
fun StreamSetuTV(c: AppContainer, onExit: () -> Unit) {
    val nav = remember { Navigator() }
    val playbackState by c.playback.state.collectAsState()
    val hasSources by c.sources.sources.collectAsState(initial = null)

    // The player covers everything while something is playing.
    val playing = playbackState != PlaybackState.Idle && nav.top == Overlay.Player
    BackHandler(enabled = true) {
        if (nav.top == Overlay.Player) { c.playback.stop(); nav.close() }
        else if (!nav.back()) onExit()
    }

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        Row(Modifier.fillMaxSize()) {
            SideRail(nav.tab, onSelect = { nav.tab = it })
            Box(Modifier.weight(1f).fillMaxHeight()) {
                when {
                    hasSources == null -> {}
                    hasSources!!.isEmpty() && nav.tab != Tab.SETTINGS -> FirstRun(onAdd = { nav.open(Overlay.AddPlaylist) })
                    else -> when (nav.tab) {
                        Tab.HOME -> HomeScreen(vm { HomeViewModel(c) }, c, nav)
                        Tab.LIVE -> LiveScreen(vm { LiveViewModel(c) }, c, nav)
                        Tab.FAVOURITES -> FavouritesScreen(vm { FavouritesViewModel(c) }, c, nav)
                        Tab.MOVIES -> MoviesScreen(vm { MoviesViewModel(c) }, c, nav)
                        Tab.SERIES -> SeriesScreen(vm { SeriesViewModel(c) }, nav)
                        Tab.SEARCH -> SearchScreen(vm { SearchViewModel(c) }, c, nav)
                        Tab.SETTINGS -> SettingsScreen(vm { SettingsViewModel(c) }, nav)
                    }
                }
            }
        }
        when (val o = nav.top) {
            is Overlay.AddPlaylist -> AddPlaylistScreen(vm { AddPlaylistViewModel(c) }, onClose = { nav.close() })
            is Overlay.SeriesDetail -> SeriesDetailScreen(vm(key = o.series.id) { SeriesDetailViewModel(c, o.series) }, c, nav)
            is Overlay.Player -> PlayerScreen(c, onClose = { c.playback.stop(); nav.close() })
            null -> {}
        }
    }
}

/** Plays something and shows the player on top. */
fun play(c: AppContainer, nav: Navigator, item: app.streamsetu.core.model.Playable, queue: List<app.streamsetu.core.model.Playable> = listOf(item)) {
    c.play(item, queue)
    if (nav.top != Overlay.Player) nav.open(Overlay.Player)
}
