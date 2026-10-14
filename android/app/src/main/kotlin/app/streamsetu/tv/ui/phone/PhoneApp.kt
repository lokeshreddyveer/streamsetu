package app.streamsetu.tv.ui.phone

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.hilt.navigation.compose.hiltViewModel
import app.streamsetu.core.model.LibraryEntry
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.closePlayer
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.screens.SeriesDetailViewModel
import app.streamsetu.tv.ui.screens.section.MoviesSectionViewModel
import app.streamsetu.tv.ui.screens.section.SeriesSectionViewModel
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.vm

/**
 * The phone and tablet app. It uses the same libraries, catalog, folders and playback as the TV app (and the same Navigator), with a layout made for touch:
 * a bottom tab bar, scrolling grids and rows, and a player you tap, drag and swipe. The TV layout is not used here and this layout is not used on a TV.
 */
@Composable
fun PhoneApp(c: AppContainer, nav: Navigator, onExit: () -> Unit) {
    val entries by c.library.entries.collectAsState(initial = emptyList())
    val noLibrary = entries.none { it.usable }
    val base = if (nav.base == Base.ChooseLibrary && noLibrary && entries.none { it.kind == LibraryEntry.Kind.CONNECTION }) Base.Welcome else nav.base

    BackHandler(enabled = true) {
        when {
            nav.top == Overlay.Player -> closePlayer(c, nav)
            nav.overlays.isNotEmpty() -> nav.close()
            base is Base.Setup || base is Base.Combined -> nav.base = Base.ChooseLibrary
            base == Base.ChooseLibrary || base == Base.Welcome -> onExit()
            base == Base.Shell && nav.settingsFromChooser && nav.tab == Tab.SETTINGS -> { nav.settingsFromChooser = false; nav.toChooser() }
            base == Base.Shell && nav.tab == Tab.SEARCH -> nav.tab = nav.searchFrom
            base == Base.Shell && nav.tab != Tab.HOME -> nav.tab = Tab.HOME
            else -> onExit()
        }
    }

    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        when (base) {
            Base.ChooseLibrary -> PhoneChooser(c, nav)
            Base.Welcome -> app.streamsetu.tv.ui.screens.library.WelcomeScreen(nav)
            is Base.Setup -> app.streamsetu.tv.ui.screens.library.SetupScreen(base.type, base.draftId, nav)
            is Base.Combined -> app.streamsetu.tv.ui.screens.library.CombinedScreen(base.editing, nav)
            Base.Shell -> PhoneShell(c, nav)
        }
        app.streamsetu.tv.ui.components.PhoneUpdatePrompt(c, suppress = nav.top != null || base != Base.Shell)
        nav.top?.let { top ->
            when (val o = top) {
                is Overlay.MovieDetail -> PhoneMovieDetail(o.movie, c, nav)
                is Overlay.SeriesDetail -> PhoneSeriesDetail(vm(key = o.series.id) { SeriesDetailViewModel(c, o.series) }, c, nav)
                is Overlay.Player -> PhonePlayer(c, onClose = { closePlayer(c, nav) })
                is Overlay.ManageLibrary -> app.streamsetu.tv.ui.screens.library.ManageLibraryDialog(o.entry, nav)
                is Overlay.Collection -> app.streamsetu.tv.ui.screens.home.HomeCollectionScreen(o.id, c, nav)
            }
        }
    }
}

@Composable
private fun PhoneShell(c: AppContainer, nav: Navigator) {
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (nav.tab) {
                Tab.HOME -> PhoneHome(hiltViewModel(), c, nav)
                Tab.LIVE -> PhoneLive(hiltViewModel(), c, nav)
                Tab.MOVIES -> PhoneSection(hiltViewModel<MoviesSectionViewModel>(), "Movies", c, nav)
                Tab.SERIES -> PhoneSection(hiltViewModel<SeriesSectionViewModel>(), "Series", c, nav)
                Tab.SEARCH -> PhoneSearch(c, nav)
                Tab.GUIDE -> PhoneGuide(c, nav)
                else -> PhoneMore(c, nav)
            }
        }
        // The bar is hidden behind the player and detail pages, which cover the window.
        if (nav.overlays.isEmpty()) PhoneTabBar(nav.tab) { nav.tab = it }
    }
}
