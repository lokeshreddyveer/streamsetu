package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.Sidebar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The global sidebar with a page beside it that has focusable things in the same rows (a folder list), as on the real screens. Keys are sent the way a remote sends them.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
class SidebarFocusTest {
    @get:Rule val rule = createComposeRule()
    private val chosen = mutableStateListOf<Tab>()
    private val folderClicks = mutableStateListOf<Int>()
    private var returns = 0

    private val order = listOf(Tab.HOME, Tab.LIVE, Tab.GUIDE, Tab.MOVIES, Tab.SERIES, Tab.SEARCH, Tab.LIBRARIES, Tab.SETTINGS)

    private fun show(selected: Tab = Tab.MOVIES) {
        rule.setContent {
            Row {
                Sidebar(selected, onSelect = { chosen += it }, entry = FocusRequester(), expanded = true, onReturn = { returns++ })
                // A folder list beside the sidebar, taller than it, so there are focusable things below the last sidebar entry.
                Column(Modifier.width(300.dp)) { androidx.compose.foundation.layout.Spacer(Modifier.height(900.dp)); repeat(10) { i -> Focusable({ folderClicks += i }, Modifier.testTag("folder-$i")) { Label("Folder $i") } } }
            }
        }
    }

    private fun key(k: Key) = rule.onNodeWithTag("sidebar-${Tab.MOVIES.name}").performKeyInput { pressKey(k) }
    private fun focusOn(t: Tab) = rule.onNodeWithTag("sidebar-${t.name}").requestFocus()

    @Test fun downGoesFromMoviesToSeriesAndThenToSearch() {
        show(); focusOn(Tab.MOVIES)
        key(Key.DirectionDown); rule.waitForIdle(); rule.onNodeWithTag("sidebar-SERIES").assertIsFocused()
        rule.onNodeWithTag("sidebar-SERIES").performKeyInput { pressKey(Key.DirectionDown) }; rule.waitForIdle()
        rule.onNodeWithTag("sidebar-SEARCH").assertIsFocused()
    }

    @Test fun upGoesBackTheSameWay() {
        show(); focusOn(Tab.SERIES)
        rule.onNodeWithTag("sidebar-SERIES").performKeyInput { pressKey(Key.DirectionUp) }; rule.waitForIdle()
        rule.onNodeWithTag("sidebar-MOVIES").assertIsFocused()
    }

    @Test fun downFromTheLastEntryStaysInTheSidebar() {
        show(); focusOn(Tab.SETTINGS)
        rule.onNodeWithTag("sidebar-SETTINGS").performKeyInput { pressKey(Key.DirectionDown) }; rule.waitForIdle()
        rule.onNodeWithTag("sidebar-SETTINGS").assertIsFocused()                   // not the folder list beside it
        assertTrue(folderClicks.isEmpty())
    }

    @Test fun upFromTheFirstEntryStaysInTheSidebar() {
        show(Tab.HOME); focusOn(Tab.HOME)
        rule.onNodeWithTag("sidebar-HOME").performKeyInput { pressKey(Key.DirectionUp) }; rule.waitForIdle()
        rule.onNodeWithTag("sidebar-HOME").assertIsFocused()
    }

    @Test fun leftNeverLeavesTheSidebar() {
        show(); focusOn(Tab.MOVIES)
        key(Key.DirectionLeft); rule.waitForIdle(); rule.onNodeWithTag("sidebar-MOVIES").assertIsFocused()
    }

    @Test fun rapidDownPressesWalkTheWholeListAndStopAtTheEnd() {
        show(Tab.HOME); focusOn(Tab.HOME)
        repeat(30) { rule.onNodeWithTag("sidebar-HOME").performKeyInput { pressKey(Key.DirectionDown) } }
        rule.waitForIdle(); rule.onNodeWithTag("sidebar-SETTINGS").assertIsFocused()
        assertTrue("moving focus chose nothing", chosen.isEmpty())
    }

    @Test fun rapidUpAndDownLandOnTheRightEntry() {
        show(Tab.HOME); focusOn(Tab.LIVE)
        listOf(Key.DirectionDown, Key.DirectionDown, Key.DirectionDown, Key.DirectionUp).forEach { k -> rule.onNodeWithTag("sidebar-LIVE").performKeyInput { pressKey(k) } }
        rule.waitForIdle(); rule.onNodeWithTag("sidebar-MOVIES").assertIsFocused()      // Live, +3 = Series (Guide, Movies, Series), -1 = Movies
    }

    @Test fun movingFocusNeverChoosesADestinationAndOkDoes() {
        show(); focusOn(Tab.MOVIES)
        key(Key.DirectionDown); key(Key.DirectionDown); rule.waitForIdle()
        assertTrue(chosen.isEmpty())
        rule.onNodeWithTag("sidebar-SEARCH").performKeyInput { pressKey(Key.DirectionCenter) }; rule.waitForIdle()
        assertEquals(listOf(Tab.SEARCH), chosen.toList())
    }

    @Test fun everyEntryCanBeReachedInOrder() {
        show(Tab.HOME); focusOn(Tab.HOME)
        var current = Tab.HOME
        order.drop(1).forEach { next ->
            rule.onNodeWithTag("sidebar-${current.name}").performKeyInput { pressKey(Key.DirectionDown) }; rule.waitForIdle()
            rule.onNodeWithTag("sidebar-${next.name}").assertIsFocused(); current = next
        }
    }

    @Test fun rightOnMoviesSeriesOrLiveTvOpensThatScreensFoldersLikeOkAndDoesNotReturnToTheContent() {
        for (t in listOf(Tab.MOVIES, Tab.SERIES, Tab.LIVE)) {
            chosen.clear(); returns = 0
            if (t == Tab.MOVIES) show(Tab.HOME)
            focusOn(t); rule.waitForIdle()
            rule.onNodeWithTag("sidebar-${t.name}").performKeyInput { pressKey(Key.DirectionRight) }; rule.waitForIdle()
            assertEquals("$t: Right opens its folders (the same call as OK)", listOf(t), chosen.toList())
            assertEquals("$t: Right does not hand the remote back to the content", 0, returns)
        }
    }

    @Test fun rightOnAnyOtherEntryStillReturnsToThePage() {
        show(Tab.HOME)
        for (t in listOf(Tab.HOME, Tab.GUIDE, Tab.SEARCH, Tab.SETTINGS)) {
            chosen.clear(); returns = 0
            focusOn(t); rule.waitForIdle()
            rule.onNodeWithTag("sidebar-${t.name}").performKeyInput { pressKey(Key.DirectionRight) }; rule.waitForIdle()
            assertEquals("$t: Right returns to the page", 1, returns); assertTrue("$t: and selects nothing", chosen.isEmpty())
        }
    }
}
