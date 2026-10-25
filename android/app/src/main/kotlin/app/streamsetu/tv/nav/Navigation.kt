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

/** The sections reached from the sidebar rail. */
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
    /** Several live channels at once, one with sound. */
    data object MultiView : Overlay
    data class SeriesDetail(val series: Series) : Overlay
    data class MovieDetail(val movie: Movie) : Overlay
    data class ManageLibrary(val entry: LibraryEntry) : Overlay
    /** A full list behind a Home shortcut: "favorites", "later", "recent" or "continue". */
    data class Collection(val id: String) : Overlay
}

/**
 * What the remote was on in each primary screen, by the item's stable id (never a list position alone, which changes when content updates), with the position it had as a
 * fallback. Coming back to a screen asks for the same item; if it has gone, the nearest valid one is chosen; if the list is empty there is nothing to focus.
 */
class TabFocusMemory {
    data class Spot(val id: String, val index: Int)
    private val spots = HashMap<Tab, Spot>()
    fun remember(tab: Tab, id: String, index: Int) { spots[tab] = Spot(id, index.coerceAtLeast(0)) }
    fun recall(tab: Tab): Spot? = spots[tab]
    fun forget(tab: Tab) { spots.remove(tab) }
    fun clear() = spots.clear()
    /** The position to put the remote on: the remembered item if it is still there, else the nearest position to where it was, else null (nothing to focus). */
    fun target(tab: Tab, ids: List<String>): Int? {
        val spot = spots[tab] ?: return null
        if (ids.isEmpty()) return null
        ids.indexOf(spot.id).takeIf { it >= 0 }?.let { return it }
        return spot.index.coerceIn(0, ids.lastIndex)
    }
}

/** How the app-wide sidebar is shown. HIDDEN takes no width and cannot take focus. */
enum class SidebarMode { HIDDEN, EXPANDED }

/**
 * The one place that knows where the person is and what Back does. The sidebar's mode is worked out from it, never stored twice:
 *  - HIDDEN on every page, until Left at the page's edge or Back asks for it (EXPANDED); it hides again as soon as the remote is back in the page.
 * Back is dispatched here, once: overlay, then (inside the page: dialogs, search, nested folders, content to folders, handled by the page first), then reveal the sidebar,
 * then Home, then the library chooser.
 */
@Stable
class Navigator {
    var base: Base by mutableStateOf(Base.ChooseLibrary)
    var tab by mutableStateOf(Tab.HOME)
    /** What the open search covers, and the screen it was opened from (Back returns there). */
    var searchScope by mutableStateOf(app.streamsetu.core.data.repo.SearchTab.ALL)
    var searchFrom by mutableStateOf(Tab.HOME)
    fun openSearch(scope: app.streamsetu.core.data.repo.SearchTab = app.streamsetu.core.data.repo.SearchTab.ALL) { searchScope = scope; searchFrom = if (tab == Tab.SEARCH) searchFrom else tab; tab = Tab.SEARCH }
    val overlays = mutableStateListOf<Overlay>()
    /** Set when something elsewhere (a Home tile) wants a section opened on one folder; the section takes it when it appears. */
    var pendingFolder: Pair<app.streamsetu.core.model.ContentKind, String>? by mutableStateOf(null)
    fun openFolder(kind: app.streamsetu.core.model.ContentKind, folderId: String) { pendingFolder = kind to folderId; go(if (kind == app.streamsetu.core.model.ContentKind.MOVIE) Tab.MOVIES else Tab.SERIES) }

    fun openFolderTab(kind: app.streamsetu.core.model.ContentKind, folderId: String) { pendingFolder = kind to folderId; go(when (kind) { app.streamsetu.core.model.ContentKind.MOVIE -> Tab.MOVIES; app.streamsetu.core.model.ContentKind.SERIES -> Tab.SERIES; else -> Tab.LIVE }) }

    /** Set by Home so Movies or Series opens on one of the person's collections. */
    var pendingCollection: Triple<app.streamsetu.core.model.ContentKind, String, Boolean>? by mutableStateOf(null)
    fun openCollection(kind: app.streamsetu.core.model.ContentKind, id: String) { pendingCollection = Triple(kind, id, true); go(if (kind == app.streamsetu.core.model.ContentKind.SERIES) Tab.SERIES else Tab.MOVIES) }

    /** True while a page other than Home has asked for the sidebar (Back from its root). */
    var sidebarRevealed by mutableStateOf(false)
    /** True while the remote is on the sidebar. */
    var sidebarFocused by mutableStateOf(false)
    /** True while the remote is somewhere in the page itself. The sidebar closes when the remote has really gone there, never because focus was lost for a moment. */
    var contentFocused by mutableStateOf(false)
    /** Bumped when the sidebar closes without choosing a page, so the remote goes back to where it was in the page. */
    var restoreFocusTick by mutableStateOf(0)
    /** Bumped to send the remote to the sidebar. */
    var sidebarFocusTick by mutableStateOf(0)
    /** Bumped whenever the page should take the remote (a section was chosen). */
    var contentFocusTick by mutableStateOf(0)

    /** The rail hides itself: it is shown only while the remote is on it or it was asked for (Left at the page's edge, or Back), and goes again when the remote is back in the page. */
    val sidebarMode: SidebarMode get() = when {
        base != Base.Shell -> SidebarMode.HIDDEN
        sidebarFocused || sidebarRevealed -> SidebarMode.EXPANDED
        else -> SidebarMode.HIDDEN
    }

    /** What the remote was on in each screen, so coming back to it (from the rail, a detail page or the player) finds the same item. */
    val memory = TabFocusMemory()

    /** True while the fullscreen player was opened from the Live TV browser: Back then leaves the stream playing in the preview. */
    var liveFullscreen = false

    val top: Overlay? get() = overlays.lastOrNull()
    var lastClosedAt = 0L

    /** What the remote was on when the first page opened over the screen, taken at that moment: the screen shuffles focus while it is covered, so "the last focused" is not reliable later. */
    var returnFocus: androidx.compose.ui.focus.FocusRequester? = null
    fun open(o: Overlay) { if (overlays.isEmpty()) returnFocus = app.streamsetu.tv.ui.components.FocusMemory.last; overlays += o }
    fun close() { if (overlays.isNotEmpty()) { overlays.removeAt(overlays.lastIndex); lastClosedAt = System.currentTimeMillis() } }

    fun go(t: Tab) { tab = t; sidebarRevealed = false; sidebarFocused = false; contentFocusTick++ }

    /**
     * The remote moved onto or off the sidebar. Losing focus does not hide the sidebar by itself (focus is lost for an instant while it moves between two entries,
     * while the page builds, and while a list scrolls); it hides when the remote has actually arrived in the page ([contentFocusChanged]).
     */
    fun sidebarFocusChanged(has: Boolean) { sidebarFocused = has }

    /** The remote moved into or out of the page. Arriving in the page while the sidebar is open (and the remote is not on it) closes the sidebar. */
    fun contentFocusChanged(has: Boolean) {
        contentFocused = has
        if (has && !sidebarFocused) sidebarRevealed = false
    }

    /** Closes the sidebar and sends the remote back to where it was in the page. */
    fun closeSidebar() { sidebarRevealed = false; sidebarFocused = false; restoreFocusTick++ }

    /** True while Settings was opened from the library chooser: Back returns there. */
    var settingsFromChooser = false
    fun openSettingsFromChooser() { settingsFromChooser = true; base = Base.Shell; tab = Tab.SETTINGS; sidebarRevealed = false }

    /** Another library was opened while a page is showing: stay on the page, drop what pointed into the old library (open titles, remembered items). */
    fun switchLibrary() { overlays.clear(); memory.clear(); sidebarRevealed = false; sidebarFocused = false; contentFocusTick++ }

    fun enterLibrary() { overlays.clear(); base = Base.Shell; tab = Tab.HOME; sidebarRevealed = false; sidebarFocused = false }
    fun toChooser() { settingsFromChooser = false; overlays.clear(); base = Base.ChooseLibrary; sidebarRevealed = false; sidebarFocused = false; memory.clear() }

    /** Reveals the sidebar and sends the remote to it (Back from a page's root). */
    fun revealSidebar() { sidebarRevealed = true; sidebarFocusTick++ }

    /** True when back was used up inside the app; false when the app should close. One press, one transition. */
    fun back(): Boolean = when {
        overlays.isNotEmpty() -> { close(); true }
        base is Base.Setup || base is Base.Combined -> { base = Base.ChooseLibrary; true }
        base == Base.Shell && settingsFromChooser && tab == Tab.SETTINGS && !sidebarFocused -> { settingsFromChooser = false; toChooser(); true }
        base == Base.Shell && !sidebarFocused && tab == Tab.SEARCH -> { go(searchFrom.takeIf { it != Tab.SEARCH } ?: Tab.HOME); true }   // Search goes back to the page it was opened from
        base == Base.Shell && !sidebarFocused -> { revealSidebar(); true }                                                            // a page: the rail first
        base == Base.Shell && tab != Tab.HOME -> { go(Tab.HOME); true }                                                              // the rail: on to Home (Right gives the page back instead)
        base == Base.Shell -> { toChooser(); true }                                                                                  // Home: to the library chooser, never out of the app
        else -> false
    }
}
