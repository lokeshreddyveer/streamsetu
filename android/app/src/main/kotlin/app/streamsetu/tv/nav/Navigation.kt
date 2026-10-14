package app.streamsetu.tv.nav

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.streamsetu.core.model.Movie
import app.streamsetu.core.model.Series

/** The sections of the top bar, in the Mac app's order. Search and Settings are the two icons on the right. */
enum class Tab(val title: String) { HOME("Home"), LIVE("Live TV"), MOVIES("Movies"), SERIES("Series"), GUIDE("TV Guide"), SEARCH("Search"), SETTINGS("Settings") }

/** A fixed shortcut at the top of a section's sidebar (the Mac's `Shortcut`). */
enum class Pin(val id: String, val title: String) {
    DISCOVER("discover", "Discover"), CONTINUE("continue", "Continue Watching"), RECENT("recent", "Recently Watched"), HISTORY("history", "Watch History"),
    FAVOURITES("favorites", "Favorites"), WATCH_LATER("later", "Watch Later"), FEATURED("featured", "Featured"), ALL_MOVIES("all", "All Movies"),
    RECENTLY_ADDED("added", "Recently Added"), LIBRARY("all", "Library"), ALL_CHANNELS("all", "All Channels");

    companion object {
        fun forTab(tab: Tab): List<Pin> = when (tab) {
            Tab.HOME -> listOf(DISCOVER, CONTINUE, RECENT, HISTORY, FAVOURITES, WATCH_LATER)
            Tab.MOVIES -> listOf(FEATURED, ALL_MOVIES, RECENTLY_ADDED, CONTINUE, FAVOURITES, WATCH_LATER)
            Tab.SERIES -> listOf(LIBRARY, RECENTLY_ADDED, CONTINUE, FAVOURITES, WATCH_LATER)
            Tab.LIVE -> listOf(ALL_CHANNELS, RECENT, FAVOURITES)
            Tab.GUIDE -> listOf(ALL_CHANNELS, FAVOURITES)
            else -> emptyList()
        }
    }
}

/** Screens that cover the whole window. */
sealed interface Overlay {
    data object Player : Overlay
    data object AddPlaylist : Overlay
    data class SeriesDetail(val series: Series) : Overlay
    data class MovieDetail(val movie: Movie) : Overlay
}

/** What is on screen. Back closes the top overlay, then returns to Home, then leaves the app. */
@Stable
class Navigator {
    var tab by mutableStateOf(Tab.HOME)
    val overlays = mutableStateListOf<Overlay>()

    val top: Overlay? get() = overlays.lastOrNull()

    var lastClosedAt = 0L
    fun open(o: Overlay) { overlays += o }
    fun close() { if (overlays.isNotEmpty()) { overlays.removeAt(overlays.lastIndex); lastClosedAt = System.currentTimeMillis() } }
    /** True when the top bar may switch sections by itself (not right after a page was closed and focus came back). */
    fun canAutoSelect() = System.currentTimeMillis() - lastClosedAt > 1200

    /** True when back was used up inside the app; false when the app should close. */
    fun back(): Boolean = when {
        overlays.isNotEmpty() -> { close(); true }
        tab != Tab.HOME -> { tab = Tab.HOME; true }
        else -> false
    }
}
