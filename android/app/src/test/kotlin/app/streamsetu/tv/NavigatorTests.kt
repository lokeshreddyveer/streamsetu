package app.streamsetu.tv

import app.streamsetu.tv.nav.*
import org.junit.Assert.*
import org.junit.Test

class NavigatorTests {
    private fun inLibrary(tab: Tab = Tab.HOME) = Navigator().apply { enterLibrary(); if (tab != Tab.HOME) go(tab) }

    @Test fun theRailIsHiddenOnEveryPageUntilItIsAskedFor() {
        listOf(Tab.HOME, Tab.MOVIES, Tab.SERIES, Tab.LIVE, Tab.GUIDE, Tab.SEARCH, Tab.SETTINGS).forEach { t -> assertEquals("$t", SidebarMode.HIDDEN, inLibrary(t).sidebarMode) }
    }
    @Test fun theRailIsShownWhileTheRemoteIsOnItAndHidesWhenItLeaves() {
        val n = inLibrary(Tab.MOVIES)
        n.sidebarFocusChanged(true); assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
        n.sidebarFocusChanged(false); assertEquals(SidebarMode.HIDDEN, n.sidebarMode)
    }
    @Test fun theChooserAndSetupNeverShowTheRail() { assertEquals(SidebarMode.HIDDEN, Navigator().sidebarMode) }
    @Test fun moviesThenBackRevealsTheSidebarAndStaysOnMovies() {
        val n = inLibrary(Tab.MOVIES)
        assertTrue(n.back())
        assertEquals(SidebarMode.EXPANDED, n.sidebarMode); assertEquals(Tab.MOVIES, n.tab)
    }
    @Test fun backFromAnyPageRevealsTheRailBeforeAnythingElse() {
        listOf(Tab.HOME, Tab.LIVE, Tab.SERIES, Tab.GUIDE, Tab.SETTINGS).forEach { t -> val n = inLibrary(t); n.back(); assertEquals(SidebarMode.EXPANDED, n.sidebarMode); assertEquals(t, n.tab) }
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
    @Test fun backOnTheOpenRailGoesOnToHome() {
        val n = inLibrary(Tab.LIVE); n.back(); n.sidebarFocusChanged(true)
        assertTrue(n.back())
        assertEquals(Tab.HOME, n.tab); assertEquals(SidebarMode.HIDDEN, n.sidebarMode); assertFalse(n.sidebarFocused)
    }
    @Test fun rightOnTheRailGivesThePageBackWithoutLeavingIt() {
        val n = inLibrary(Tab.LIVE); n.back(); n.sidebarFocusChanged(true)
        val before = n.restoreFocusTick
        n.closeSidebar()                                              // what Right does
        assertEquals(Tab.LIVE, n.tab); assertEquals(SidebarMode.HIDDEN, n.sidebarMode); assertEquals(before + 1, n.restoreFocusTick)
    }
    @Test fun backFromHomesSidebarGoesToTheChooserAndNeverExitsFromHome() {
        val n = inLibrary(); assertTrue(n.back()); n.sidebarFocusChanged(true)
        assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
        assertTrue(n.back()); assertEquals(Base.ChooseLibrary, n.base)
    }
    @Test fun backTwiceFromAPageOpensTheRailThenGoesHome() {
        val n = inLibrary(Tab.MOVIES)
        n.back(); n.sidebarFocusChanged(true); assertEquals(SidebarMode.EXPANDED, n.sidebarMode)
        n.back(); assertEquals(Tab.HOME, n.tab); assertEquals(SidebarMode.HIDDEN, n.sidebarMode)
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

    // ---- what the remote was on, per screen ----
    @Test fun theRemembersTheItemByIdNotByPosition() {
        val m = TabFocusMemory(); m.remember(Tab.MOVIES, "m42", 7)
        assertEquals(3, m.target(Tab.MOVIES, listOf("a", "b", "c", "m42", "d")))          // the list changed: the same title is found where it is now
    }
    @Test fun aRemovedItemFallsBackToTheNearestValidPosition() {
        val m = TabFocusMemory(); m.remember(Tab.SERIES, "gone", 5)
        assertEquals(2, m.target(Tab.SERIES, listOf("a", "b", "c")))                      // clamped to the last item, never past the end
        m.remember(Tab.SERIES, "gone", 1); assertEquals(1, m.target(Tab.SERIES, listOf("a", "b", "c")))
    }
    @Test fun anEmptyListHasNothingToFocus() { val m = TabFocusMemory(); m.remember(Tab.LIVE, "x", 0); assertNull(m.target(Tab.LIVE, emptyList())) }
    @Test fun aScreenNeverVisitedHasNoMemory() = assertNull(TabFocusMemory().target(Tab.GUIDE, listOf("a")))
    @Test fun eachScreenKeepsItsOwnSpot() {
        val m = TabFocusMemory(); m.remember(Tab.MOVIES, "m1", 0); m.remember(Tab.LIVE, "c9", 4)
        assertEquals("m1", m.recall(Tab.MOVIES)?.id); assertEquals("c9", m.recall(Tab.LIVE)?.id); assertNull(m.recall(Tab.SERIES))
    }
    @Test fun theNavigatorKeepsTheMemoryAcrossPagesAndClearsItWhenTheLibraryIsLeft() {
        val n = inLibrary(Tab.MOVIES); n.memory.remember(Tab.MOVIES, "m1", 2)
        n.go(Tab.LIVE); n.go(Tab.MOVIES); assertEquals("m1", n.memory.recall(Tab.MOVIES)?.id)
        n.toChooser(); assertNull(n.memory.recall(Tab.MOVIES))                              // another library has other titles
    }
    @Test fun aNegativePositionIsKeptAsZero() { val m = TabFocusMemory(); m.remember(Tab.HOME, "h", -3); assertEquals(0, m.recall(Tab.HOME)?.index) }

    // ---- the journeys: out through details and the player, and back to the exact place ----
    @Test fun movieJourneyBackOutRestoresThePageAndThePosterIsStillRemembered() {
        val n = inLibrary(); n.go(Tab.MOVIES); n.memory.remember(Tab.MOVIES, "mv42", 17)
        n.open(Overlay.Collection("favorites")); n.open(Overlay.Player)                  // details, then the player
        assertTrue(n.back()); assertEquals(Overlay.Collection("favorites"), n.top)         // Back from the player: the details
        assertTrue(n.back()); assertNull(n.top); assertEquals(Tab.MOVIES, n.tab)           // Back from the details: the page
        assertEquals("mv42", n.memory.recall(Tab.MOVIES)?.id)                              // and the poster the remote was on
    }
    @Test fun liveJourneyKeepsTheChannelAndTheCategoryWhileFullscreenOpensAndCloses() {
        val n = inLibrary(Tab.LIVE); n.memory.remember(Tab.LIVE, "ch77", 40)
        n.open(Overlay.Player); n.liveFullscreen = true
        assertTrue(n.back()); assertEquals(Tab.LIVE, n.tab); assertEquals("ch77", n.memory.recall(Tab.LIVE)?.id)
    }
    @Test fun guideJourneyReturnsToTheGuideAfterTheProgramAndThePlayer() {
        val n = inLibrary(Tab.GUIDE); n.memory.remember(Tab.GUIDE, "chA", 3)
        n.open(Overlay.Player); n.back(); assertEquals(Tab.GUIDE, n.tab); assertEquals("chA", n.memory.recall(Tab.GUIDE)?.id)
    }
    @Test fun searchJourneyGoesBackToSearchThenToTheOriginatingPage() {
        val n = inLibrary(Tab.MOVIES); n.openSearch(); n.open(Overlay.Collection("later"))
        assertTrue(n.back()); assertEquals(Tab.SEARCH, n.tab)                                // out of the details: the results
        assertTrue(n.back()); assertEquals(Tab.MOVIES, n.tab)                                // out of Search: the page it was opened from
    }
    @Test fun switchingLibraryKeepsThePageButDropsWhatPointedIntoTheOldOne() {
        val n = inLibrary(Tab.MOVIES); n.memory.remember(Tab.MOVIES, "oldMovie", 5); n.open(Overlay.Collection("favorites"))
        val tick = n.contentFocusTick
        n.switchLibrary()
        assertEquals(Tab.MOVIES, n.tab); assertEquals(Base.Shell, n.base)                    // still on Movies
        assertNull(n.top); assertNull(n.memory.recall(Tab.MOVIES))                           // nothing left that names the old library
        assertEquals(tick + 1, n.contentFocusTick)                                           // the page takes the remote again
    }
    @Test fun backNeverLeavesTheAppFromInsideALibraryEvenAfterManySwitches() {
        val n = inLibrary(Tab.SERIES); repeat(5) { n.switchLibrary() }
        n.back(); n.sidebarFocusChanged(true)                         // the rail opens and takes the remote
        n.back(); assertEquals(Tab.HOME, n.tab)                       // on to Home
        n.back(); n.sidebarFocusChanged(true)                         // Home: the rail again
        assertTrue(n.back()); assertEquals(Base.ChooseLibrary, n.base) // and then the chooser: never "close the app" from inside a library
    }
    @Test fun theFirstPageThatOpensRemembersWhereTheRemoteWas_andPagesOnTopOfItDoNot() {
        val poster = androidx.compose.ui.focus.FocusRequester(); val other = androidx.compose.ui.focus.FocusRequester()
        val n = inLibrary(Tab.MOVIES)
        app.streamsetu.tv.ui.components.FocusMemory.last = poster
        n.open(Overlay.Collection("a")); assertSame(poster, n.returnFocus)
        app.streamsetu.tv.ui.components.FocusMemory.last = other                  // the covered screen shuffles focus: that must not change where Back returns to
        n.open(Overlay.Collection("b")); assertSame(poster, n.returnFocus)
        app.streamsetu.tv.ui.components.FocusMemory.last = null
    }
}
