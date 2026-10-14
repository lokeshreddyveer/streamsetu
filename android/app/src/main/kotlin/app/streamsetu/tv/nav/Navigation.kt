package app.streamsetu.tv.nav

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.streamsetu.core.model.LibraryEntry
import app.streamsetu.core.model.Movie
import app.streamsetu.core.model.Series
import app.streamsetu.core.model.SourceType

/** The sections reached from the sidebar. On Home, Live TV, Movies and Series the sidebar floats over the page (opened with Left at the page's edge, or Back); on the others it is a narrow strip beside the page. */
enum class Tab(val title: String, val floatingSidebar: Boolean = false) {
    HOME("Home", true), LIVE("Live TV", true), MOVIES("Movies", true), SERIES("Series", true), GUIDE("TV Guide"), SEARCH("Search"), LIBRARIES("Libraries"), SETTINGS("Settings")
}

/** What fills the screen under any overlay. */
sealed interface Base {
    /** Every launch starts here (or on Welcome when nothing is set up). */
    data object ChooseLibrary : Base
    data object Welcome : Base
    /** Adding or finishing a connection. [draftId] resumes an unfinished one. */
    data class Setup(val type: SourceType, val draftId: String? = null) : Base
    data class Combined(val editing: LibraryEntry? = null) : Base
    /** An open library: the sidebar and the sections. */
    data object Shell : Base
}

/** Screens that cover the whole window. */
sealed interface Overlay {
    data object Player : Overlay
    data class SeriesDetail(val series: Series) : Overlay
    data class MovieDetail(val movie: Movie) : Overlay
    data class ManageLibrary(val entry: LibraryEntry) : Overlay
}

/**
 * Where the person is. Back follows the hierarchy: an overlay closes; inside a section the section handles it (content → folders → sidebar);
 * the sidebar goes Home; Home goes to the library chooser; the chooser is the root and leaves the app.
 */
@Stable
class Navigator {
    var base: Base by mutableStateOf(Base.ChooseLibrary)
    var tab by mutableStateOf(Tab.HOME)
    val overlays = mutableStateListOf<Overlay>()
    /** Set when something elsewhere (a Home tile) wants a section opened on one folder; the section takes it when it appears. */
    var pendingFolder: Pair<app.streamsetu.core.model.ContentKind, String>? = null
    fun openFolder(kind: app.streamsetu.core.model.ContentKind, folderId: String) { pendingFolder = kind to folderId; go(if (kind == app.streamsetu.core.model.ContentKind.MOVIE) Tab.MOVIES else Tab.SERIES) }
    /** True while the sidebar is shown on a full-screen section (revealed with Back from its folders). */
    var sidebarRevealed by mutableStateOf(false)

    /** True while the fullscreen player was opened from the Live TV browser: Back then leaves the stream playing in the preview. */
    var liveFullscreen = false

    val top: Overlay? get() = overlays.lastOrNull()
    var lastClosedAt = 0L

    fun open(o: Overlay) { overlays += o }
    fun close() { if (overlays.isNotEmpty()) { overlays.removeAt(overlays.lastIndex); lastClosedAt = System.currentTimeMillis() } }

    /** Bumped whenever the page should take the remote (a section was chosen, or the sidebar closed on a choice). */
    var contentFocusTick by mutableStateOf(0)
    fun go(t: Tab) { tab = t; sidebarRevealed = false; contentFocusTick++ }

    /** True while Settings was opened from the library chooser: Back returns there. */
    var settingsFromChooser = false
    fun openSettingsFromChooser() { settingsFromChooser = true; base = Base.Shell; tab = Tab.SETTINGS; sidebarRevealed = false }

    fun enterLibrary() { overlays.clear(); base = Base.Shell; tab = Tab.HOME; sidebarRevealed = false }
    fun toChooser() { settingsFromChooser = false; overlays.clear(); base = Base.ChooseLibrary; sidebarRevealed = false }

    /** True when back was used up inside the app; false when the app should close. */
    fun back(): Boolean = when {
        overlays.isNotEmpty() -> { close(); true }
        base is Base.Setup || base is Base.Combined || base is Base.Welcome && false -> { base = Base.ChooseLibrary; true }
        base == Base.Shell && settingsFromChooser && tab == Tab.SETTINGS -> { settingsFromChooser = false; toChooser(); true }
        base == Base.Shell && sidebarRevealed -> { sidebarRevealed = false; contentFocusTick++; true }     // Back closes the floating sidebar first
        base == Base.Shell && tab != Tab.HOME -> { go(Tab.HOME); true }
        base == Base.Shell -> { toChooser(); true }
        else -> false
    }
}
