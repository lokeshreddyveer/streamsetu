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
    HOME("Home"), LIVE("Live TV"), SPORTS("Sports"), MOVIES("Movies"), SERIES("Series"), GUIDE("TV Guide"), SEARCH("Search"), LIBRARIES("Libraries"), SETTINGS("Settings")
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
    /** Two to four Sports feeds at once: the builder, then the tiles. */
    data object SportsMultiview : Overlay
    data class SeriesDetail(val series: Series) : Overlay
    data class MovieDetail(val movie: Movie) : Overlay
    data class ManageLibrary(val entry: LibraryEntry) : Overlay
    /** A full list behind a Home shortcut: "favorites", "later", "recent" or "continue". */
    data class Collection(val id: String, val only: String? = null) : Overlay
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

/**
 * What the Search page held when the person left it (to open a title, or to visit another screen): the words, the type chosen, where the list was scrolled, which result had the
 * remote and what the AI had suggested. Kept for as long as the person stays in the same library, as the same profile and in the same search scope; anything else starts empty.
 */
/**
 * What Settings keeps while another page is open: the page that was chosen, and the Settings search (the words, whether the technical settings are included, the result last opened).
 * It is a plain holder with no connection to any value a setting has, so returning to Settings shows the same page without reading anything again.
 */
class SettingsSession {
    var category: String? = null
    var query = ""; var includeAdvanced = false; var searching = false; var lastResult: String? = null
}

class SearchSession {
    private var key: String? = null
    var query = ""; var type: app.streamsetu.core.model.ContentKind? = null; var typeSet = false
    var scrollIndex = 0; var scrollOffset = 0
    /** Episodes or TV Guide, chosen as the type to search; null for the others (those use [type]). */
    var extraTab: app.streamsetu.core.data.repo.SearchTab? = null
    var focusedId: String? = null
    var aiFor: String? = null; var aiFound: List<app.streamsetu.tv.FoundTitle> = emptyList(); var aiNote: String? = null; var aiAsked = false

    /** The session for [k]; a different key (another library, profile or scope) throws away what was held. */
    fun open(k: String): SearchSession { if (key != k) { clear(); key = k }; return this }
    fun clear() { key = null; query = ""; type = null; typeSet = false; scrollIndex = 0; scrollOffset = 0; focusedId = null; clearAi() }
    /** What the AI suggested is tied to who asked: it goes the moment the profile, library or any restriction changes. */
    fun clearAi() { aiFor = null; aiFound = emptyList(); aiNote = null; aiAsked = false }
    /** Everything this page held that was found under a context that no longer holds: the words, results position and focus too. */
    fun forgetContext() { query = ""; scrollIndex = 0; scrollOffset = 0; focusedId = null; clearAi() }
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
    /** Settings remembers its page and search while the person is on another page. */
    val settings = SettingsSession()
    var base: Base by mutableStateOf(Base.ChooseLibrary)
    var tab by mutableStateOf(Tab.HOME)
    /** What the open search covers, and the screen it was opened from (Back returns there). */
    var searchScope by mutableStateOf(app.streamsetu.core.data.repo.SearchTab.ALL)
    var searchFrom by mutableStateOf(Tab.HOME)
    /** True when Search was opened from another page (its own Search button): Back then returns there. Search chosen in the sidebar is a page of its own and Back opens the sidebar. */
    var searchTemporary by mutableStateOf(false)
    fun openSearch(scope: app.streamsetu.core.data.repo.SearchTab = app.streamsetu.core.data.repo.SearchTab.ALL) { searchScope = scope; searchFrom = if (tab == Tab.SEARCH) searchFrom else tab; if (tab != Tab.SEARCH) searchTemporary = true; tab = Tab.SEARCH }
    val overlays = mutableStateListOf<Overlay>()
    /** Set when something elsewhere (a Home tile) wants a section opened on one folder; the section takes it when it appears. */
    var pendingFolder: Pair<app.streamsetu.core.model.ContentKind, String>? by mutableStateOf(null)

    fun openFolderTab(kind: app.streamsetu.core.model.ContentKind, folderId: String) { pendingFolder = kind to folderId; go(when (kind) { app.streamsetu.core.model.ContentKind.MOVIE -> Tab.MOVIES; app.streamsetu.core.model.ContentKind.SERIES -> Tab.SERIES; else -> Tab.LIVE }) }

    /** A Sports reminder to open (from a notification or the in-app banner), by its id. Sports takes it when it appears; the event is found and checked again before anything opens. */
    var pendingSportsReminder: String? by mutableStateOf(null)

    /** A Sports event, team or competition chosen in Search. Sports takes it when it appears; Back then returns to the Search result it came from (the Sports screen remembers that it was opened from Search). */
    var pendingSportsTarget: app.streamsetu.core.data.repo.SearchTarget.OpenSports? by mutableStateOf(null)
    fun openSports(t: app.streamsetu.core.data.repo.SearchTarget.OpenSports) { if (!app.streamsetu.tv.sports.SportsFeature.enabled) return; pendingSportsTarget = t; go(Tab.SPORTS) }
    /** Back from Sports to the Search page, whose words and result position are still held by [search]. */
    fun returnToSearch() { go(Tab.SEARCH) }

    /** A programme the Guide should open on (set by Sports after it re-checked the channel); the Guide takes it when it appears. */
    var pendingGuideTarget: app.streamsetu.tv.sports.discovery.GuideTarget? by mutableStateOf(null)
    fun openGuideAt(t: app.streamsetu.tv.sports.discovery.GuideTarget) { pendingGuideTarget = t; go(Tab.GUIDE) }

    /** Set when something elsewhere wants Settings opened on one category (by its name); Settings takes it when it appears. */
    var pendingSettings: String? by mutableStateOf(null)

    /** Set by Home so Movies or Series opens on one of the person's collections. */
    var pendingCollection: Triple<app.streamsetu.core.model.ContentKind, String, Boolean>? by mutableStateOf(null)
    fun openCollection(kind: app.streamsetu.core.model.ContentKind, id: String) { pendingCollection = Triple(kind, id, true); go(if (kind == app.streamsetu.core.model.ContentKind.SERIES) Tab.SERIES else Tab.MOVIES) }

    /** Set when Movies or Series was chosen in the sidebar: the page opens its folder panel at once and hides the sidebar; choosing a folder hides the panel and shows the content. */
    var foldersRequested by mutableStateOf(false)
    /** True while a page's folder column is open or about to open: the remote belongs to it, so the shell does not hand it to the page's first item. */
    var foldersHoldFocus by mutableStateOf(false)
    private var foldersOwner: Any? = null
    /** A page keeps (or gives up) the remote for its folder column. Only the page that holds the claim can give it up, so a page that is leaving cannot cancel the claim of the one that is arriving. */
    fun holdFolders(owner: Any, hold: Boolean) { if (hold) { foldersOwner = owner; foldersHoldFocus = true } else if (foldersOwner === owner) { foldersOwner = null; foldersHoldFocus = false } }

    /** False while the remote belongs to a folder column (asked for or showing): nothing may hand it back to the page's content. */
    val contentRestoreAllowed get() = !(foldersHoldFocus || foldersRequested)

    /**
     * A destination was chosen in the main sidebar. For Movies, Series and Live TV the folder column is claimed before the page changes (both flags are set first), so the page opens
     * with the folders showing and the remote on the selected folder, and no first item of the content ever takes the remote, even for a moment.
     */
    fun choose(t: Tab) {
        val hasFolders = t == Tab.MOVIES || t == Tab.SERIES || t == Tab.LIVE
        foldersOwner = null; foldersRequested = hasFolders; foldersHoldFocus = hasFolders
        go(t)
    }

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
    /** The Search page's words, results position and focus, kept while moving between screens (see [SearchSession]). */
    val search = SearchSession()
    /** The season and episode the remote was on, for each series page, so coming back from playing an episode finds them again (the page itself is gone while the player is open). */
    val seriesView = HashMap<String, Pair<Int?, String?>>()

    /** True while the fullscreen player was opened from the Live TV browser: Back then leaves the stream playing in the preview. */
    var liveFullscreen = false

    /** Set when a stream was handed from Sports to Live TV's embedded player: the next time Sports is shown, the remote goes to its remembered (or nearest) event card, and the page clears this. */
    var sportsReturnToCard by mutableStateOf(false)

    /** Where the Live TV preview sits on screen (in the window), published by that screen while it is showing. The one video surface (see PersistentVideo) is placed here. Null when there is no preview. */
    var videoBounds by mutableStateOf<androidx.compose.ui.geometry.Rect?>(null)

    val top: Overlay? get() = overlays.lastOrNull()
    var lastClosedAt = 0L

    /** What the remote was on when the first page opened over the screen, taken at that moment: the screen shuffles focus while it is covered, so "the last focused" is not reliable later. */
    var returnFocus: androidx.compose.ui.focus.FocusRequester? = null
    fun open(o: Overlay) { if (overlays.isEmpty()) returnFocus = app.streamsetu.tv.ui.components.FocusMemory.last; overlays += o }
    fun close() { if (overlays.isNotEmpty()) { overlays.removeAt(overlays.lastIndex); lastClosedAt = System.currentTimeMillis() } }

    /** A section chosen from the rail. Search opened this way searches everything; the Search entry points of Movies, Series and Live TV use [openSearch] with their own scope. */
    fun go(t: Tab) { if (app.streamsetu.tv.KidsLock.on && (t == Tab.SETTINGS || t == Tab.LIBRARIES)) return; if (t == Tab.SPORTS && !app.streamsetu.tv.sports.SportsFeature.enabled) return; if (t == Tab.SEARCH) searchScope = app.streamsetu.core.data.repo.SearchTab.ALL; searchTemporary = false; tab = t; sidebarRevealed = false; sidebarFocused = false; contentFocusTick++ }

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
    fun openSettingsFromChooser() { if (app.streamsetu.tv.KidsLock.on) return; settingsFromChooser = true; base = Base.Shell; tab = Tab.SETTINGS; sidebarRevealed = false }

    /** Another library was opened while a page is showing: stay on the page, drop what pointed into the old library (open titles, remembered items). */
    fun switchLibrary() { overlays.clear(); memory.clear(); search.clear(); seriesView.clear(); sidebarRevealed = false; sidebarFocused = false; contentFocusTick++ }

    fun enterLibrary() { overlays.clear(); base = Base.Shell; tab = Tab.HOME; sidebarRevealed = false; sidebarFocused = false }
    fun toChooser() { settingsFromChooser = false; overlays.clear(); base = Base.ChooseLibrary; sidebarRevealed = false; sidebarFocused = false; memory.clear(); search.clear(); seriesView.clear() }

    /** Reveals the sidebar and sends the remote to it (Back from a page's root). */
    fun revealSidebar() { sidebarRevealed = true; sidebarFocusTick++ }

    /** Set by a page that has a level of its own to go back to before the sidebar (returns true when it used the press up). */
    var backHook: (() -> Boolean)? = null

    /** True when back was used up inside the app; false when the app should close. One press, one transition. */
    fun back(): Boolean = when {
        overlays.isNotEmpty() -> { close(); true }
        base is Base.Setup || base is Base.Combined -> { base = Base.ChooseLibrary; true }
        base == Base.Shell && settingsFromChooser && tab == Tab.SETTINGS && !sidebarFocused -> { settingsFromChooser = false; toChooser(); true }
        base == Base.Shell && !sidebarFocused && tab == Tab.SEARCH && searchTemporary -> { go(searchFrom.takeIf { it != Tab.SEARCH } ?: Tab.HOME); true }   // Search opened from another page goes back to it
        base == Base.Shell && !sidebarFocused && tab == Tab.SEARCH -> { revealSidebar(); true }                                       // Search chosen in the sidebar is a page of its own: Back opens the sidebar
        base == Base.Shell && !sidebarFocused && backHook?.invoke() == true -> true                                                   // the page's own level first (Movies and Series: the folders)
        base == Base.Shell && !sidebarFocused -> { revealSidebar(); true }                                                            // a page: the rail first
        base == Base.Shell -> { closeSidebar(); true }                                                                                // the rail: Back closes it and the remote returns to the page (choosing Home is how to go Home)
        else -> false
    }
}
