package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items as rowItems
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.dp
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.nav.TabFocusMemory
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.OptionSheet
import app.streamsetu.tv.ui.components.Sidebar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The remote on the pages' real building blocks: the rail's Right key, rows of posters above a grid, remembered focus, and the side picker. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class ScreenNavigationTest {
    @get:Rule val rule = createComposeRule()
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }

    // ---- the rail ----
    @Test fun rightOnTheRailReturnsTheRemoteToThePage() {
        var returned = 0
        rule.setContent { Row { Sidebar(Tab.GUIDE, onSelect = {}, entry = FocusRequester(), expanded = true, onReturn = { returned++ }); Focusable({}, Modifier.testTag("page")) { Label("Page") } } }
        rule.onNodeWithTag("sidebar-GUIDE").requestFocus()
        press("sidebar-GUIDE", Key.DirectionRight)
        assertEquals(1, returned)
    }
    @Test fun upAndDownOnTheRailNeverReturnWhileMovingBetweenEntries() {
        var returned = 0
        rule.setContent { Row { Sidebar(Tab.MOVIES, onSelect = {}, entry = FocusRequester(), expanded = true, onReturn = { returned++ }) } }
        rule.onNodeWithTag("sidebar-MOVIES").requestFocus()
        press("sidebar-MOVIES", Key.DirectionDown); press("sidebar-SERIES", Key.DirectionUp)
        assertEquals(0, returned); rule.onNodeWithTag("sidebar-MOVIES").assertIsFocused()
    }

    // ---- rows above a grid, as on Movies and Series ----
    private val rail = (0 until 12).toList()
    private val grid = (100 until 160).toList()
    private fun showRailAndGrid() {
        rule.setContent {
            LazyVerticalGrid(GridCells.Fixed(6), Modifier.width(1400.dp).height(700.dp)) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "rail") {
                    LazyRow { rowItems(rail, key = { it }) { i -> Focusable({}, Modifier.testTag("rail-$i").width(180.dp).height(200.dp)) { Label("R$i") } } }
                }
                gridItems(grid, key = { it }) { i -> Focusable({}, Modifier.testTag("grid-$i").height(200.dp)) { Label("G$i") } }
            }
        }
    }
    @Test fun downFromTheRowEntersTheGridAndUpComesBack() {
        showRailAndGrid()
        rule.onNodeWithTag("rail-0").requestFocus()
        press("rail-0", Key.DirectionDown); rule.onNodeWithTag("grid-100").assertIsFocused()
        press("grid-100", Key.DirectionUp); rule.onNodeWithTag("rail-0").assertIsFocused()
    }
    @Test fun movingRightAlongTheRowThenDownKeepsTheApproximateColumn() {
        showRailAndGrid()
        rule.onNodeWithTag("rail-0").requestFocus()
        repeat(3) { i -> press("rail-$i", Key.DirectionRight) }
        press("rail-3", Key.DirectionDown)
        // the poster under the fourth card of the row: the same column, not the first poster of the grid
        val col = (0 until 6).map { 100 + it }.first { runCatching { rule.onNodeWithTag("grid-$it").assertIsFocused() }.isSuccess } - 100
        assertTrue("column $col", col in 2..4)
    }
    @Test fun rapidKeyRepeatsNeverLoseTheFocus() {
        showRailAndGrid()
        rule.onNodeWithTag("rail-0").requestFocus()
        repeat(40) { rule.onRoot().performKeyInput { pressKey(Key.DirectionRight) } }; rule.waitForIdle()
        assertTrue((0 until 12).any { runCatching { rule.onNodeWithTag("rail-$it").assertIsFocused() }.isSuccess })
    }

    // ---- remembered focus on a grid ----
    @Test fun returningToTheGridPutsTheRemoteOnTheRememberedTitleEvenAfterTheListChanged() {
        val memory = TabFocusMemory(); memory.remember(Tab.MOVIES, "m130", 30)
        val ids = mutableStateListOf<String>().also { it.addAll((100 until 160).map { n -> "m$n" }) }
        val restore = FocusRequester()
        rule.setContent {
            val state = rememberLazyGridState()
            androidx.compose.runtime.LaunchedEffect(Unit) {
                val at = memory.target(Tab.MOVIES, ids.toList()) ?: return@LaunchedEffect
                state.scrollToItem(at); kotlinx.coroutines.delay(50); runCatching { restore.requestFocus() }
            }
            LazyVerticalGrid(GridCells.Fixed(6), Modifier.width(1400.dp).height(700.dp), state = state) {
                gridItems(ids, key = { it }) { id -> Focusable({}, (if (id == memory.recall(Tab.MOVIES)?.id) Modifier.focusRequester(restore) else Modifier).testTag(id).height(200.dp)) { Label(id) } }
            }
        }
        rule.waitForIdle(); rule.mainClock.advanceTimeBy(500)
        rule.onNodeWithTag("m130").assertIsFocused()
    }

    // ---- the side picker ----
    @Test fun thePickerStartsOnTheCurrentChoiceAndOkPicksAndCloses() {
        var picked: String? = null; var open by mutableStateOf(true)
        rule.setContent {
            CompositionLocalProviderReduced {
                if (open) OptionSheet("Category", listOf("all" to "All", "a" to "News", "b" to "Sports"), "b", onPick = { picked = it }, onClose = { open = false })
            }
        }
        rule.mainClock.advanceTimeBy(600); rule.waitForIdle()
        rule.onNode(androidx.compose.ui.test.hasText("Sports")).assertIsFocused()
        rule.onNode(androidx.compose.ui.test.hasText("Sports")).performKeyInput { pressKey(Key.DirectionCenter) }
        rule.waitForIdle()
        assertEquals("b", picked); assertEquals(false, open)
    }

    @androidx.compose.runtime.Composable
    private fun CompositionLocalProviderReduced(content: @androidx.compose.runtime.Composable () -> Unit) =
        androidx.compose.runtime.CompositionLocalProvider(LocalReducedMotion provides true, content = content)
}
