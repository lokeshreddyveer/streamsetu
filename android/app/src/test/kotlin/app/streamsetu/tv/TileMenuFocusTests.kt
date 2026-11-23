package app.streamsetu.tv

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import app.streamsetu.tv.ui.components.ContextMenu
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.MenuAction
import app.streamsetu.tv.ui.phone.PhonePoster
import app.streamsetu.tv.ui.phone.Sheet
import app.streamsetu.tv.ui.phone.SheetItem
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The television's menu: holding OK opens it, Back dismisses it, and after it closes (by Back or by a choice) the remote is on the tile it came from. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@ExperimentalTestApi
class TvTileMenuFocusTests {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    @get:Rule val patient = app.streamsetu.tv.ui.PatientIdle()
    @Before fun freezeGuardClock() { app.streamsetu.tv.ui.components.SelectKeyGuard.clock = { 0L } }
    @After fun restoreGuardClock() { app.streamsetu.tv.ui.components.SelectKeyGuard.clock = { System.currentTimeMillis() } }
    private var open by mutableStateOf(false)
    private var chosen = 0

    private fun show() {
        rule.setContent {
            Column {
                Focusable({}, Modifier.testTag("card"), onLongClick = { open = true }) { Label("A movie") }
                if (open) ContextMenu("A movie", null, listOf(MenuAction("First action", Icons.Filled.Check) { chosen = 1 }, MenuAction("Second action", Icons.Filled.Check) { chosen = 2 }), onClose = { open = false })
            }
        }
        rule.onNodeWithTag("card").requestFocus(); rule.waitForIdle()
        open = true; rule.waitForIdle(); rule.mainClock.advanceTimeBy(500); rule.waitForIdle()
    }

    @Test fun backDismissesTheMenuAndTheRemoteIsBackOnTheTile() {
        show()
        rule.onNodeWithText("First action").assertIsDisplayed()
        // Back goes to the menu's own window, as the remote's Back key does.
        rule.runOnUiThread { (org.robolectric.shadows.ShadowDialog.getLatestDialog() as androidx.activity.ComponentDialog).onBackPressedDispatcher.onBackPressed() }
        rule.waitForIdle()
        assertFalse("Back closed the menu", open); rule.onNodeWithText("First action").assertDoesNotExist()
        assertEquals("Back chose nothing", 0, chosen)
        rule.onNodeWithTag("card").assertIsFocused()
    }

    @Test fun choosingAnActionClosesTheMenuAndTheRemoteIsBackOnTheTile() {
        show()
        rule.onNodeWithText("First action").performKeyInput { keyDown(Key.DirectionCenter); keyUp(Key.DirectionCenter) }          // the opening press
        rule.onNodeWithText("First action").performKeyInput { pressKey(Key.DirectionCenter) }
        rule.waitForIdle()
        assertEquals(1, chosen); assertFalse(open)
        rule.onNodeWithTag("card").assertIsFocused()
    }
}

/** The phone's menu: touch and hold opens the shared sheet, Back (or a tap outside) dismisses it. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PhoneTileMenuTests {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    @get:Rule val patient = app.streamsetu.tv.ui.PatientIdle()
    private var open by mutableStateOf(false)
    private var longPresses = 0
    private fun show() = rule.setContent {
        Column {
            PhonePoster("Open Film", null, {}, onLong = { longPresses++; open = true })
            if (open) Sheet("Open Film", listOf(SheetItem("Details", Icons.Filled.Check) {}), onClose = { open = false })
        }
    }

    @Test fun touchAndHoldOpensTheSheetAndBackDismissesIt() {
        show()
        rule.onAllNodesWithText("Open Film")[0].performTouchInput { longClick() }
        rule.waitForIdle()
        assertEquals(1, longPresses); rule.onNodeWithText("Details").assertExists()
        rule.runOnUiThread { rule.activity.onBackPressedDispatcher.onBackPressed() }
        rule.waitForIdle(); rule.mainClock.advanceTimeBy(600)
        assertFalse(open); rule.onNodeWithText("Details").assertDoesNotExist()
    }
}
