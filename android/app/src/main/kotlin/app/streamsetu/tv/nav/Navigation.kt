package app.streamsetu.tv.nav

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.streamsetu.core.model.Series

/** The top-level places in the side rail. */
enum class Tab(val title: String) { HOME("Home"), LIVE("Live TV"), GUIDE("Guide"), FAVOURITES("Favourites"), MOVIES("Movies"), SERIES("Series"), SEARCH("Search"), SETTINGS("Settings") }

/** Screens that cover the whole window. */
sealed interface Overlay {
    data object Player : Overlay
    data object AddPlaylist : Overlay
    data class SeriesDetail(val series: Series) : Overlay
}

/** What is on screen. Back closes the top overlay, then returns to Home, then leaves the app. */
@Stable
class Navigator {
    var tab by mutableStateOf(Tab.HOME)
    val overlays = mutableStateListOf<Overlay>()

    val top: Overlay? get() = overlays.lastOrNull()

    fun open(o: Overlay) { overlays += o }
    fun close() { if (overlays.isNotEmpty()) overlays.removeAt(overlays.lastIndex) }

    /** True when back was used up inside the app; false when the app should close. */
    fun back(): Boolean = when {
        overlays.isNotEmpty() -> { close(); true }
        tab != Tab.HOME -> { tab = Tab.HOME; true }
        else -> false
    }
}
