package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.Browse
import app.streamsetu.core.model.Folder
import app.streamsetu.tv.ui.components.FolderActions
import app.streamsetu.tv.ui.components.FolderPanel
import app.streamsetu.tv.ui.components.Shortcut
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The folder column: Up and Down move exactly one row, merely landing on a folder never opens it (OK does), Right goes to the content and Left to the main sidebar, and the section
 * heading is never a stop for the remote.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class FolderNavigationTest {
    @get:Rule val rule = createComposeRule()

    private val noActions = object : FolderActions {
        override fun toggleFavorite(f: Folder) {}; override fun togglePinned(f: Folder) {}; override fun toggleHidden(f: Folder) {}; override fun toggleLocked(f: Folder) {}
        override fun rename(f: Folder, alias: String?) {}; override fun move(f: Folder, to: app.streamsetu.core.data.repo.MoveTo) {}; override fun restoreOrder() {}
        override fun resetPosition(f: Folder) {}; override fun resetFolder(f: Folder) {}; override fun createFolder(name: String) {}
        override fun isUnlocked(folderId: String) = true; override val hasPin = false; override fun checkPin(pin: String) = true; override fun setPin(pin: String) {}; override fun unlock(folderId: String) {}
    }
    private val selections = ArrayList<Browse>(); private var rights = 0; private var lefts = 0; private var confirms = 0
    private val folders = (1..14).map { Folder("f$it", "s", "Folder $it", it * 10) }

    private fun show(selected: Browse = Browse.All) {
        selections.clear(); rights = 0; lefts = 0; confirms = 0
        rule.setContent {
            FolderPanel("Movies", listOf(Shortcut(Browse.All, "All Movies", Icons.Filled.GridView)), folders, selected, { selections += it }, noActions, Modifier.width(256.dp).fillMaxHeight(),
                entry = FocusRequester(), onRight = { rights++; true }, onLeft = { lefts++ }, onConfirm = { confirms++ }, selectOnDwell = false)
        }
    }
    private fun row(name: String) = rule.onNodeWithTag("panel-row-$name")
    private fun press(on: String, k: Key) { row(on).performKeyInput { pressKey(k) }; rule.waitForIdle(); rule.mainClock.advanceTimeBy(400) }

    @Test fun downMovesExactlyOneRowAndNeverOpensAFolder() {
        show(); row("All Movies").requestFocus(); rule.waitForIdle()
        press("All Movies", Key.DirectionDown); row("Folder 1").assertIsFocused()
        press("Folder 1", Key.DirectionDown); row("Folder 2").assertIsFocused()
        press("Folder 2", Key.DirectionDown); row("Folder 3").assertIsFocused()
        assertTrue("moving over folders opened one: $selections", selections.isEmpty())
    }
    @Test fun upMovesBackOneRowAtATime() {
        show(); row("Folder 4").requestFocus(); rule.waitForIdle()
        press("Folder 4", Key.DirectionUp); row("Folder 3").assertIsFocused()
        press("Folder 3", Key.DirectionUp); row("Folder 2").assertIsFocused()
        assertTrue(selections.isEmpty())
    }
    @Test fun theSectionHeadingIsNotAStop() {
        show(); row("All Movies").requestFocus(); rule.waitForIdle()
        press("All Movies", Key.DirectionDown)                // the "FOLDERS" heading lies between: the remote lands on the first folder
        row("Folder 1").assertIsFocused()
    }
    @Test fun downOnTheLastFolderStaysOnIt() {
        showList((1..4).map { Folder("f$it", "s", "Folder $it", it) })
        row("Folder 4").requestFocus(); rule.waitForIdle()
        press("Folder 4", Key.DirectionDown); row("Folder 4").assertIsFocused()
    }
    @Test fun okOpensTheFolderAndTellsTheScreenItWasChosen() {
        show(); row("Folder 2").requestFocus(); rule.waitForIdle()
        press("Folder 2", Key.DirectionCenter)
        assertEquals(listOf<Browse>(Browse.Folder("f2")), selections); assertEquals(1, confirms)
    }
    @Test fun rightLeavesForTheContentWithoutChangingTheFolder() {
        show(); row("Folder 3").requestFocus(); rule.waitForIdle()
        press("Folder 3", Key.DirectionRight)
        assertEquals(1, rights); assertTrue(selections.isEmpty())
    }
    @Test fun leftOpensTheMainSidebar() {
        show(); row("Folder 3").requestFocus(); rule.waitForIdle()
        press("Folder 3", Key.DirectionLeft)
        assertEquals(1, lefts); assertTrue(selections.isEmpty())
    }
    @Test fun aBurstOfDownPressesNeverSkipsOrJumpsPastTheList() {
        showList((1..4).map { Folder("f$it", "s", "Folder $it", it) })
        row("All Movies").requestFocus(); rule.waitForIdle()
        repeat(40) { rule.onNode(androidx.compose.ui.test.isFocused()).performKeyInput { pressKey(Key.DirectionDown) } }
        rule.waitForIdle(); rule.mainClock.advanceTimeBy(1000)
        row("Folder 4").assertIsFocused()                                       // it ran to the end of the list and stopped there, with the remote still on a folder
        assertTrue(selections.isEmpty())
    }

    private fun showList(list: List<Folder>, selected: Browse = Browse.All, entry: FocusRequester = FocusRequester()) {
        selections.clear(); rights = 0; lefts = 0; confirms = 0
        rule.setContent {
            FolderPanel("Movies", listOf(Shortcut(Browse.All, "All Movies", Icons.Filled.GridView)), list, selected, { selections += it }, noActions, Modifier.width(256.dp).fillMaxHeight(),
                entry = entry, onRight = { rights++; true }, onLeft = { lefts++ }, onConfirm = { confirms++ }, selectOnDwell = false)
        }
    }

    @Test fun aSingleFolderListWorks() {
        showList(listOf(Folder("only", "s", "Only folder", 5)))
        row("All Movies").requestFocus(); rule.waitForIdle()
        press("All Movies", Key.DirectionDown); row("Only folder").assertIsFocused()
        press("Only folder", Key.DirectionDown); row("Only folder").assertIsFocused()          // nothing below: it stays
        press("Only folder", Key.DirectionUp); row("All Movies").assertIsFocused()
    }
    @Test fun anEmptyFolderListStillLetsLeftAndRightThrough() {
        showList(emptyList())
        row("All Movies").requestFocus(); rule.waitForIdle()
        press("All Movies", Key.DirectionLeft); assertEquals(1, lefts)
        press("All Movies", Key.DirectionRight); assertEquals(1, rights)
        row("All Movies").assertIsFocused()                                                      // focus was never lost
    }
    @Test fun theSelectedFolderTakesFocusEvenWhenItStartsOffscreen() {
        val many = (1..60).map { Folder("f$it", "s", "Folder $it", it) }
        val entry = FocusRequester()
        showList(many, selected = Browse.Folder("f50"), entry = entry)
        // The screen asks again and again until the column has the remote (the row has to be brought into view first).
        repeat(40) { runCatching { entry.requestFocus() }; rule.waitForIdle(); rule.mainClock.advanceTimeBy(40) }
        row("Folder 50").assertIsFocused()
    }
    @Test fun rapidLeftAndRightPressesDoNotLoseFocusOrMultiplyTransitions() {
        show(); row("Folder 3").requestFocus(); rule.waitForIdle()
        repeat(10) { row("Folder 3").performKeyInput { pressKey(Key.DirectionRight) } }
        rule.waitForIdle()
        assertEquals(10, rights); assertTrue(selections.isEmpty())                               // one call per press, and the panel never opened a folder by itself
        row("Folder 3").assertIsFocused()
    }
}
