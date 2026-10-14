package app.streamsetu.tv.ui

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.tv.ui.components.FadeIn
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Posters in a grid, folders in a list, and the page transition, driven by D-pad keys. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class ListNavigationTest {
    @get:Rule val rule = createComposeRule()
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }

    // ---- poster grid ----

    private val posters = mutableStateListOf<Int>().also { it.addAll(0 until 60) }
    private var gridState: androidx.compose.foundation.lazy.grid.LazyGridState? = null

    private fun showGrid() {
        rule.setContent {
            val st = rememberLazyGridState(); gridState = st
            LazyVerticalGrid(GridCells.Fixed(5), Modifier.width(1000.dp).height(600.dp), state = st) {
                gridItems(posters, key = { it }) { i -> Focusable({}, Modifier.testTag("poster-$i").height(200.dp)) { Label("Poster $i") } }
            }
        }
    }

    @Test fun rightAndLeftMoveAlongARowAndDownAndUpMoveBetweenRows() {
        showGrid(); rule.onNodeWithTag("poster-0").requestFocus(); rule.waitForIdle()
        press("poster-0", Key.DirectionRight); rule.onNodeWithTag("poster-1").assertIsFocused()
        press("poster-1", Key.DirectionDown); rule.onNodeWithTag("poster-6").assertIsFocused()
        press("poster-6", Key.DirectionLeft); rule.onNodeWithTag("poster-5").assertIsFocused()
        press("poster-5", Key.DirectionUp); rule.onNodeWithTag("poster-0").assertIsFocused()
    }

    private fun focusedPoster(): Int = rule.onNode(androidx.compose.ui.test.isFocused()).fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.TestTag].removePrefix("poster-").toInt()

    /**
     * Each Down press moves focus exactly one row and the grid scrolls to follow it. Focus never jumps back to the start or skips a row.
     * (Known: when the next row is not composed yet, Compose may put focus on the first poster of that row instead of the same column; see the notes.)
     */
    @Test fun rapidDownPressesWalkDownOneRowAtATimeAndScrollTheGrid() {
        showGrid(); rule.onNodeWithTag("poster-2").requestFocus(); rule.waitForIdle()
        var row = 0
        repeat(8) { press("poster-${focusedPoster()}", Key.DirectionDown); row++; assertEquals("row after press ${it + 1}", row, focusedPoster() / 5) }
        assertTrue("the grid scrolled to follow focus", (gridState?.firstVisibleItemIndex ?: 0) > 0)
    }

    @Test fun theGridKeepsItsPlaceAndFocusWhenMorePostersLoad() {
        showGrid(); rule.onNodeWithTag("poster-12").requestFocus(); rule.waitForIdle()
        posters.addAll(60 until 120); rule.waitForIdle()                    // a page of posters arrives
        rule.onNodeWithTag("poster-12").assertIsFocused()
        press("poster-12", Key.DirectionRight); rule.onNodeWithTag("poster-13").assertIsFocused()
    }

    // ---- folder list ----

    private var selectedFolder by mutableIntStateOf(0)

    private fun showFolders() {
        rule.setContent {
            val st = rememberLazyListState()
            LazyColumn(Modifier.width(300.dp).height(600.dp), state = st) {
                items((0 until 40).toList(), key = { it }) { i -> Focusable({ selectedFolder = i }, Modifier.testTag("folder-$i").height(60.dp)) { Label("Folder $i") } }
            }
        }
    }

    @Test fun movingBetweenFoldersDoesNotOpenThemAndOkDoes() {
        showFolders(); rule.onNodeWithTag("folder-0").requestFocus(); rule.waitForIdle()
        press("folder-0", Key.DirectionDown); press("folder-1", Key.DirectionDown); rule.onNodeWithTag("folder-2").assertIsFocused()
        assertEquals("moving did not open a folder", 0, selectedFolder)
        press("folder-2", Key.DirectionCenter); assertEquals(2, selectedFolder)
    }

    @Test fun theFolderListScrollsWithFocusAndFocusStaysOnTheFolderAfterChoosingIt() {
        showFolders(); rule.onNodeWithTag("folder-0").requestFocus(); rule.waitForIdle()
        var current = 0
        repeat(15) { press("folder-$current", Key.DirectionDown); current++ }
        press("folder-$current", Key.DirectionCenter)
        rule.onNodeWithTag("folder-$current").assertIsFocused(); assertEquals(current, selectedFolder)
    }

    // ---- page transition ----

    private var page by mutableStateOf("home")

    private fun showPages(reduced: Boolean) {
        rule.setContent { androidx.compose.runtime.CompositionLocalProvider(LocalReducedMotion provides reduced) { FadeIn(page) { Label("page $page") } } }
    }

    @Test fun switchingPagesShowsTheNewPageAndRemovesTheOldOne() {
        showPages(reduced = false); rule.onNodeWithText("page home").assertExists()
        page = "movies"; rule.mainClock.advanceTimeBy(500); rule.waitForIdle()
        rule.onNodeWithText("page movies").assertExists(); rule.onNodeWithText("page home").assertDoesNotExist()
    }

    @Test fun switchingPagesAsFastAsTheRemoteCanEndsOnTheLastPage() {
        showPages(reduced = false)
        listOf("movies", "series", "live", "guide", "movies", "series", "live", "home", "series").forEach { page = it; rule.mainClock.advanceTimeBy(40); rule.waitForIdle() }
        rule.mainClock.advanceTimeBy(600); rule.waitForIdle()
        rule.onNodeWithText("page series").assertExists(); rule.onNodeWithText("page live").assertDoesNotExist()
    }

    @Test fun reducedMotionShowsThePageWithoutWaiting() {
        showPages(reduced = true)
        page = "settings"; rule.waitForIdle()                                  // no clock advance at all
        rule.onNodeWithText("page settings").assertExists()
    }
}
