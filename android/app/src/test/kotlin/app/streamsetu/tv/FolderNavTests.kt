package app.streamsetu.tv

import app.streamsetu.tv.nav.FolderNav
import app.streamsetu.tv.nav.FolderNav.Next
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The remote's path through a screen with folders: main sidebar, folders, content. */
class FolderNavTests {
    @Test fun backAndLeftFromTheFoldersBothAskForTheMainSidebar() {
        val a = FolderNav(startOpen = true); assertEquals(Next.MAIN_SIDEBAR, a.back()); assertFalse(a.open)
        val b = FolderNav(startOpen = true); assertEquals(Next.MAIN_SIDEBAR, b.left()); assertFalse(b.open)
    }
    @Test fun backAndLeftFromTheContentShowTheFolders() {
        val a = FolderNav(); assertEquals(Next.NOTHING, a.back()); assertTrue(a.open)
        val b = FolderNav(); assertEquals(Next.NOTHING, b.left()); assertTrue(b.open)
    }
    @Test fun theFullRoundTripIsContentFoldersSidebarAndBack() {
        val f = FolderNav()
        assertEquals(Next.NOTHING, f.back()); assertTrue(f.open)                 // content -> folders
        assertEquals(Next.MAIN_SIDEBAR, f.back()); assertFalse(f.open)           // folders -> main sidebar
        f.show(); assertTrue(f.open)                                              // sidebar -> folders (Right / OK on the destination)
        f.hide(); assertFalse(f.open)                                             // folders -> content (Right / OK on a folder)
    }
    @Test fun anEmptyFolderStillAllowsBackAndLeft() {
        val f = FolderNav(); f.hide()                                             // a folder with no titles was chosen: the column is gone
        assertEquals(Next.NOTHING, f.back()); assertTrue(f.open)                  // Back still brings the folders, and
        assertEquals(Next.MAIN_SIDEBAR, f.left()); assertFalse(f.open)            // Left from there still leads to the sidebar
    }
    @Test fun showingTheFoldersTwiceDoesNotToggleOrLoop() {
        val f = FolderNav(); f.show(); val tick = f.focusTick; f.show()
        assertTrue(f.open); assertEquals(tick + 1, f.focusTick)                   // asked again: still open, one more request to focus, nothing chained
        f.hide(); f.hide(); assertFalse(f.open)
    }
    @Test fun rapidPressesEndInOneConsistentState() {
        val f = FolderNav(startOpen = true); var sidebars = 0
        repeat(50) { if (f.left() == Next.MAIN_SIDEBAR) sidebars++; if (f.back() == Next.MAIN_SIDEBAR) sidebars++; f.show(); f.hide() }
        assertTrue(sidebars in 1..100)
        assertFalse(f.open)
    }
    @Test fun changingLibraryClosesTheFolders() { val f = FolderNav(startOpen = true); f.reset(); assertFalse(f.open) }

    @Test fun openingAndClosingADetailPageNeverTouchesTheFolders() {
        val nav = Navigator(); nav.go(Tab.MOVIES)
        val f = FolderNav(); f.hide()
        nav.open(Overlay.Collection("x")); nav.close()
        assertFalse(f.open); assertFalse(nav.foldersRequested); assertFalse(nav.sidebarRevealed)       // the previous card is restored by the shell, not the folder column
    }
    @Test fun choosingTheCurrentDestinationInTheSidebarIsOneRequestNotALoop() {
        val nav = Navigator(); nav.go(Tab.MOVIES); val f = FolderNav()
        nav.foldersRequested = true; if (nav.foldersRequested) { nav.foldersRequested = false; f.show() }        // what the screen does with the request
        nav.go(Tab.MOVIES); nav.foldersRequested = true; if (nav.foldersRequested) { nav.foldersRequested = false; f.show() }
        assertTrue(f.open); assertFalse(nav.foldersRequested)
    }

    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "settings.gradle.kts").exists() }
    private fun source(name: String) = root.walkTopDown().first { it.name == name && "/src/main/" in it.path }.readText()

    @Test fun moviesSeriesAndLiveTvShareOneFolderBehaviour() {
        for (screen in listOf("SectionScreen.kt", "LiveScreen.kt")) {                       // Movies and Series are the one SectionScreen
            val s = source(screen)
            assertTrue("$screen uses FolderNav", "FolderNav(" in s)
            assertTrue("$screen: Left from the folders goes to the main sidebar", "onLeft = { folderNav.left(); nav.revealSidebar() }" in s)
            assertTrue("$screen: choosing or Right hides the folders", "folderNav.hide()" in s)
            assertTrue("$screen: the content follows the folder the remote rests on", "selectOnDwell = true" in s)
        }
    }
}

/** Choosing a destination in the main sidebar claims the folders before the page changes. */
class SidebarSelectionTests {
    @Test fun choosingMoviesSeriesOrLiveClaimsTheFoldersBeforeThePageChanges() {
        for (t in listOf(Tab.MOVIES, Tab.SERIES, Tab.LIVE)) {
            val n = Navigator().apply { enterLibrary() }
            n.choose(t)
            assertEquals(t, n.tab); assertTrue("$t: the request is made", n.foldersRequested); assertTrue("$t: the remote is held for the folders", n.foldersHoldFocus)
        }
    }
    @Test fun otherDestinationsReleaseTheClaimSoTheirContentTakesTheRemote() {
        val n = Navigator().apply { enterLibrary() }
        n.choose(Tab.MOVIES); n.choose(Tab.HOME)
        assertEquals(Tab.HOME, n.tab); assertFalse(n.foldersRequested); assertFalse(n.foldersHoldFocus)
        for (t in listOf(Tab.GUIDE, Tab.SEARCH, Tab.SETTINGS)) { n.choose(Tab.SERIES); n.choose(t); assertFalse(n.foldersHoldFocus) }
    }
    @Test fun switchingBetweenFolderPagesKeepsTheClaim() {
        val n = Navigator().apply { enterLibrary() }
        n.choose(Tab.MOVIES); n.choose(Tab.SERIES); n.choose(Tab.LIVE); n.choose(Tab.MOVIES)
        assertEquals(Tab.MOVIES, n.tab); assertTrue(n.foldersRequested); assertTrue(n.foldersHoldFocus)
    }

    @Test fun contentRestorationIsNotAllowedWhileTheFoldersAreClaimed() {
        val n = Navigator().apply { enterLibrary() }
        assertTrue(n.contentRestoreAllowed)
        for (t in listOf(Tab.MOVIES, Tab.SERIES, Tab.LIVE)) {
            n.choose(t); assertFalse("$t: a pending restore is cancelled", n.contentRestoreAllowed)
            n.foldersRequested = false; assertFalse("$t: still claimed until the folders release it", n.contentRestoreAllowed)
            n.foldersHoldFocus = false; assertTrue(n.contentRestoreAllowed)
        }
        n.choose(Tab.HOME); assertTrue("other destinations may restore their content", n.contentRestoreAllowed)
    }
}
