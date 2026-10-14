package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import app.streamsetu.tv.ui.components.ContextMenu
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.MenuAction
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * A card that opens a context menu (as holding OK does) and the menu itself. The menu is a window of its own, so the key events of the press that opened it arrive in it:
 * these tests send them the way a remote does and check the menu is still there afterwards.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@androidx.compose.ui.test.ExperimentalTestApi
class ContextMenuTest {
    @get:Rule val rule = createComposeRule()
    private var open by mutableStateOf(false)
    private var chosen by mutableIntStateOf(0)
    private var cardClicks by mutableIntStateOf(0)

    /** The menu moves focus to its first action a moment after it opens; the test clock is advanced past that moment. */
    private fun openMenu() { open = true; rule.waitForIdle(); rule.mainClock.advanceTimeBy(500); rule.waitForIdle() }

    private fun show() {
        rule.setContent {
            Column {
                Focusable({ cardClicks++ }, Modifier.testTag("card"), onLongClick = { open = true }) { Label("A movie") }
                if (open) ContextMenu("A movie", null, listOf(MenuAction("First action", Icons.Filled.Check) { chosen = 1 }, MenuAction("Second action", Icons.Filled.Check) { chosen = 2 }), onClose = { open = false })
            }
        }
    }

    @Test fun theMenuStaysOpenWhenTheKeyThatOpenedItIsReleased() {
        show(); openMenu()
        rule.onNodeWithText("First action").assertIsDisplayed()
        // What the remote still sends for the press that opened the menu: repeats while held, then the release.
        rule.onNodeWithText("First action").performKeyInput { keyDown(Key.DirectionCenter); advanceEventTime(1200); keyUp(Key.DirectionCenter) }     // held: the key repeats, then is released
        rule.waitForIdle()
        rule.onNodeWithText("First action").assertIsDisplayed()
        assertEquals("the release did not choose anything", 0, chosen)
    }

    @Test fun afterwardsOkChoosesTheFocusedActionAndTheMenuCloses() {
        show(); openMenu()
        rule.onNodeWithText("First action").performKeyInput { keyDown(Key.DirectionCenter); keyUp(Key.DirectionCenter) }    // the opening press
        rule.onNodeWithText("First action").performKeyInput { pressKey(Key.DirectionCenter) }                                // a new press
        rule.waitForIdle()
        assertEquals(1, chosen)
        rule.onNodeWithText("First action").assertDoesNotExist()
    }

    @Test fun upAndDownMoveBetweenTheActionsWhileTheMenuIsOpen() {
        show(); openMenu()
        rule.onNodeWithText("First action").performKeyInput { keyDown(Key.DirectionCenter); keyUp(Key.DirectionCenter) }
        rule.onNodeWithText("First action").performKeyInput { pressKey(Key.DirectionDown) }; rule.waitForIdle()
        rule.onNodeWithText("Second action").performKeyInput { pressKey(Key.DirectionCenter) }; rule.waitForIdle()
        assertEquals(2, chosen)
    }

    @Test fun aShortPressOnTheCardIsAClickAndOpensNoMenu() {
        show(); rule.onNodeWithTag("card").requestFocus()
        rule.onNodeWithTag("card").performKeyInput { pressKey(Key.DirectionCenter) }; rule.waitForIdle()
        assertEquals(1, cardClicks)
        rule.onNodeWithText("First action").assertDoesNotExist()
    }

    @Test fun theCardGetsTheRemoteBackWhenTheMenuCloses() {
        show(); rule.onNodeWithTag("card").requestFocus(); rule.waitForIdle()
        openMenu()
        rule.onNodeWithText("First action").performKeyInput { keyDown(Key.DirectionCenter); keyUp(Key.DirectionCenter) }
        rule.onNodeWithText("First action").performKeyInput { pressKey(Key.DirectionCenter) }; rule.waitForIdle()     // chooses and closes
        rule.onNodeWithTag("card").requestFocus(); rule.waitForIdle()                                                    // the card is still there to take focus
        rule.onNodeWithTag("card").assertIsFocused()
    }
}
