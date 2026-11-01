package app.streamsetu.tv

import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.SportsFeature
import app.streamsetu.tv.ui.components.Groups
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where each entry of the main menu is. The UI suite reads the same order from the screen and checks it against this. */
class SidebarOrderTests {
    @After fun reset() { SportsFeature.forTest(null) }
    private fun order() = Groups.flatMap { it.second }

    @Test fun searchIsFirstAndHomeIsSecond() {
        SportsFeature.forTest(false)
        assertEquals(listOf(Tab.SEARCH, Tab.HOME, Tab.LIVE, Tab.GUIDE, Tab.MOVIES, Tab.SERIES, Tab.LIBRARIES, Tab.SETTINGS), order())
    }
    @Test fun sportsComesBetweenLiveTvAndTheGuideWhenItIsOn() {
        SportsFeature.forTest(true)
        val o = order(); assertEquals(Tab.SEARCH, o.first()); assertTrue(o.indexOf(Tab.LIVE) < o.indexOf(Tab.SPORTS) && o.indexOf(Tab.SPORTS) < o.indexOf(Tab.GUIDE))
    }
    @Test fun searchHasNoHeadingOfItsOwnAndEveryOtherGroupHasOne() {
        SportsFeature.forTest(false)
        val g = Groups; assertEquals("", g.first().first); assertTrue(g.drop(1).all { it.first.isNotBlank() })
    }
    @Test fun everyDestinationAppearsExactlyOnce() {
        SportsFeature.forTest(false)
        val o = order(); assertEquals(o.size, o.toSet().size)
    }
}
