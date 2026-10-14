package app.streamsetu.tv

import app.streamsetu.tv.nav.*
import org.junit.Assert.*
import org.junit.Test

class NavigatorTests {
    private fun inLibrary(tab: Tab = Tab.HOME) = Navigator().apply { enterLibrary(); if (tab != Tab.HOME) go(tab) }

    @Test fun homeShowsTheCollapsedSidebarAndExpandsWhileFocused() {
        val n = inLibrary()
        assertEquals(SidebarMode.COLLAPSED, n.sidebarMode)
        n.sidebarFocusChanged(true); assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
        n.sidebarFocusChanged(false); assertEquals(SidebarMode.COLLAPSED, n.sidebarMode)
    }
    @Test fun everyOtherPageHidesTheSidebar() {
        listOf(Tab.MOVIES, Tab.SERIES, Tab.LIVE, Tab.GUIDE, Tab.SEARCH, Tab.SETTINGS).forEach { assertEquals(SidebarMode.HIDDEN, inLibrary(it).sidebarMode) }
    }
    @Test fun moviesThenBackRevealsTheSidebarAndStaysOnMovies() {
        val n = inLibrary(Tab.MOVIES)
        assertTrue(n.back())
        assertEquals(SidebarMode.EXPANDED, n.sidebarMode); assertEquals(Tab.MOVIES, n.tab)
    }
    @Test fun theSidebarStaysOpenWhileFocusIsLostForAMoment() {
        val n = inLibrary(Tab.SERIES); n.back(); n.sidebarFocusChanged(true)
        n.sidebarFocusChanged(false)                                 // focus is "nowhere" for an instant while it moves between two entries
        assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
    }
    @Test fun theSidebarClosesWhenTheRemoteHasArrivedInThePage() {
        val n = inLibrary(Tab.SERIES); n.back(); n.sidebarFocusChanged(true)
        n.sidebarFocusChanged(false); n.contentFocusChanged(true)
        assertEquals(SidebarMode.HIDDEN, n.sidebarMode)
    }
    @Test fun thePageGainingFocusDoesNotCloseTheSidebarWhileTheRemoteIsOnIt() {
        val n = inLibrary(Tab.LIVE); n.back(); n.sidebarFocusChanged(true)
        n.contentFocusChanged(true)
        assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
    }
    @Test fun backOnTheOpenSidebarClosesItAndLeavesThePageWhereItWas() {
        val n = inLibrary(Tab.LIVE); n.back(); n.sidebarFocusChanged(true)
        val before = n.restoreFocusTick
        assertTrue(n.back())
        assertEquals(Tab.LIVE, n.tab); assertEquals(SidebarMode.HIDDEN, n.sidebarMode); assertFalse(n.sidebarFocused)
        assertEquals(before + 1, n.restoreFocusTick)                  // the page is asked to give the remote back where it was
    }
    @Test fun backFromHomesSidebarGoesToTheChooserAndNeverExitsFromHome() {
        val n = inLibrary(); assertTrue(n.back()); n.sidebarFocusChanged(true)
        assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
        assertTrue(n.back()); assertEquals(Base.ChooseLibrary, n.base)
    }
    @Test fun backTwiceFromAPageOpensThenClosesTheSidebar() {
        val n = inLibrary(Tab.MOVIES)
        n.back(); n.sidebarFocusChanged(true); assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
        n.back(); assertEquals(SidebarMode.HIDDEN, n.sidebarMode); assertEquals(Tab.MOVIES, n.tab)
    }
    @Test fun anOverlayClosesBeforeAnythingElse() {
        val n = inLibrary(Tab.MOVIES); n.open(Overlay.Player)
        assertTrue(n.back()); assertNull(n.top); assertEquals(Tab.MOVIES, n.tab); assertEquals(SidebarMode.HIDDEN, n.sidebarMode)
    }
    @Test fun onePressIsOneTransition() {
        val n = inLibrary(Tab.GUIDE)
        n.back(); assertEquals(Tab.GUIDE, n.tab)            // reveal only
        assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
    }
    @Test fun choosingAPageFromTheSidebarHidesItAndOpensThePage() {
        val n = inLibrary(Tab.MOVIES); n.back(); n.sidebarFocusChanged(true)
        n.go(Tab.SERIES)
        assertEquals(Tab.SERIES, n.tab); assertEquals(SidebarMode.HIDDEN, n.sidebarMode)
    }
    @Test fun rapidSwitchingEndsOnTheLastPage() {
        val n = inLibrary()
        repeat(20) { n.go(listOf(Tab.MOVIES, Tab.SERIES, Tab.LIVE)[it % 3]) }
        assertEquals(Tab.SERIES, n.tab); assertEquals(SidebarMode.HIDDEN, n.sidebarMode)
    }
    @Test fun settingsOpenedFromTheChooserReturnsThere() {
        val n = Navigator(); n.openSettingsFromChooser()
        assertTrue(n.back()); assertEquals(Base.ChooseLibrary, n.base)
    }
    @Test fun theChooserHasNoSidebar() = assertEquals(SidebarMode.HIDDEN, Navigator().sidebarMode)
    @Test fun setupBackReturnsToTheChooser() {
        val n = Navigator(); n.base = Base.Setup(app.streamsetu.core.model.SourceType.XTREAM)
        assertTrue(n.back()); assertEquals(Base.ChooseLibrary, n.base)
    }
}
