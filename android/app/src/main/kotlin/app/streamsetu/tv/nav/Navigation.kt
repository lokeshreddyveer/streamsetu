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
enum class Tab(val title: String) {
    HOME("Home"), LIVE("Live TV"), MOVIES("Movies"), SERIES("Series"), GUIDE("TV Guide"), SEARCH("Search"), LIBRARIES("Libraries"), SETTINGS("Settings")
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

/** How the app-wide sidebar is shown. HIDDEN takes no width and cannot take focus. */
enum class SidebarMode { HIDDEN, COLLAPSED, EXPANDED }

/**
 * The one place that knows where the person is and what Back does. The sidebar's mode is worked out from it, never stored twice:
 *  - Home: COLLAPSED (EXPANDED while the remote is on it).
 *  - Every other page: HIDDEN, until Back from the page's root asks for it (EXPANDED); it hides again as soon as the remote leaves it.
 * Back is dispatched here, once: overlay, then (inside the page: dialogs, search, nested folders, content to folders, handled by the page first), then reveal the sidebar,
 * then Home, then the library chooser.
 */
@Stable
class Navigator {
    var base: Base by mutableStateOf(Base.ChooseLibrary)
    var tab by mutableStateOf(Tab.HOME)
    val overlays = mutableStateListOf<Overlay>()
    /** Set when something elsewhere (a Home tile) wants a section opened on one folder; the section takes it when it appears. */
    var pendingFolder: Pair<app.streamsetu.core.model.ContentKind, String>? = null
    fun openFolder(kind: app.streamsetu.core.model.ContentKind, folderId: String) { pendingFolder = kind to folderId; go(if (kind == app.streamsetu.core.model.ContentKind.MOVIE) Tab.MOVIES else Tab.SERIES) }

    /** True while a page other than Home has asked for the sidebar (Back from its root). */
    var sidebarRevealed by mutableStateOf(false)
    /** True while the remote is on the sidebar. */
    var sidebarFocused by mutableStateOf(false)
    /** Bumped to send the remote to the sidebar. */
    var sidebarFocusTick by mutableStateOf(0)
    /** Bumped whenever the page should take the remote (a section was chosen). */
    var contentFocusTick by mutableStateOf(0)

    val sidebarMode: SidebarMode get() = when {
        base != Base.Shell -> SidebarMode.HIDDEN
        tab == Tab.HOME -> if (sidebarFocused) SidebarMode.EXPANDED else SidebarMode.COLLAPSED
        sidebarRevealed -> SidebarMode.EXPANDED
        else -> SidebarMode.HIDDEN
    }

    /** True while the fullscreen player was opened from the Live TV browser: Back then leaves the stream playing in the preview. */
    var liveFullscreen = false

    val top: Overlay? get() = overlays.lastOrNull()
    var lastClosedAt = 0L

    fun open(o: Overlay) { overlays += o }
    fun close() { if (overlays.isNotEmpty()) { overlays.removeAt(overlays.lastIndex); lastClosedAt = System.currentTimeMillis() } }

    fun go(t: Tab) { tab = t; sidebarRevealed = false; sidebarFocused = false; contentFocusTick++ }

    /** The remote left the sidebar: on a page other than Home it hides again. */
    fun sidebarFocusChanged(has: Boolean) { sidebarFocused = has; if (!has && tab != Tab.HOME) sidebarRevealed = false }

    /** True while Settings was opened from the library chooser: Back returns there. */
    var settingsFromChooser = false
    fun openSettingsFromChooser() { settingsFromChooser = true; base = Base.Shell; tab = Tab.SETTINGS; sidebarRevealed = false }

    fun enterLibrary() { overlays.clear(); base = Base.Shell; tab = Tab.HOME; sidebarRevealed = false; sidebarFocused = false }
    fun toChooser() { settingsFromChooser = false; overlays.clear(); base = Base.ChooseLibrary; sidebarRevealed = false; sidebarFocused = false }

    /** Reveals the sidebar and sends the remote to it (Back from a page's root). */
    fun revealSidebar() { if (tab != Tab.HOME) sidebarRevealed = true; sidebarFocusTick++ }

    /** True when back was used up inside the app; false when the app should close. One press, one transition. */
    fun back(): Boolean = when {
        overlays.isNotEmpty() -> { close(); true }
        base is Base.Setup || base is Base.Combined -> { base = Base.ChooseLibrary; true }
        base == Base.Shell && settingsFromChooser && tab == Tab.SETTINGS && !sidebarFocused -> { settingsFromChooser = false; toChooser(); true }
        base == Base.Shell && !sidebarFocused -> { revealSidebar(); true }
        base == Base.Shell && tab != Tab.HOME -> { go(Tab.HOME); true }
        base == Base.Shell -> { toChooser(); true }
        else -> false
    }
}
