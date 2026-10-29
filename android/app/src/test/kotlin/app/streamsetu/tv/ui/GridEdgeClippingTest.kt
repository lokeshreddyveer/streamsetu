package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items as rowItems
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.dp
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.bleedStart
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** A 154 x 230 poster that grows to 1.06 on focus must never be cut off at the edge of a grid or a row: first and last column, first and last row, rails, folders open or closed. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class GridEdgeClippingTest {
    @get:Rule val rule = createComposeRule()

    private fun px(dp: androidx.compose.ui.unit.Dp) = with(rule.density) { dp.toPx() }
    private fun bounds(tag: String) = rule.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
    private fun settle() { rule.waitForIdle(); rule.mainClock.advanceTimeBy(700); rule.waitForIdle() }
    private fun focus(tag: String) { rule.onNodeWithTag(tag).requestFocus(); settle() }

    @Composable private fun Poster(tag: String) {
        Focusable({}, Modifier.testTag(tag).size(154.dp, 230.dp), scaleOnFocus = Motion.POSTER_FOCUS_SCALE, ringWidth = 2.5.dp) { _ -> Label(tag) }
    }

    @Composable private fun Grid(count: Int, modifier: Modifier = Modifier) {
        LazyVerticalGrid(GridCells.Fixed(6), modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 14.dp, bottom = 40.dp),
            horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(Tokens.gutter)) {
            items((0 until count).toList(), key = { it }) { Poster("p$it") }
        }
    }

    @Test fun theFocusedPosterGrowsToOnePointZeroSixWithoutChangingItsTile() {
        rule.setContent { Grid(30) }
        rule.waitForIdle()
        val node = rule.onNodeWithTag("p0").fetchSemanticsNode()
        assertTrue("a poster in the grid shares the row: ${node.layoutInfo.width}", node.layoutInfo.width >= px(154.dp)); assertEquals(px(230.dp), node.layoutInfo.height.toFloat(), 1f)
        val rest = bounds("p0"); focus("p0"); val grown = bounds("p0")
        assertEquals(1.06f, grown.width / rest.width, 0.01f)                                                                                // and grows to 1.06 when focused
        assertEquals(node.layoutInfo.width.toFloat(), rule.onNodeWithTag("p0").fetchSemanticsNode().layoutInfo.width.toFloat(), 1f)          // without changing its layout size
    }

    @Test fun firstRowAndFirstColumnAreNotCutOffAtTheTopAndLeft() {
        rule.setContent { Grid(30) }; rule.waitForIdle(); focus("p0")
        val b = bounds("p0"); assertTrue("top ${b.top}", b.top >= 0f); assertTrue("left ${b.left}", b.left >= 0f)
    }

    @Test fun lastColumnIsNotCutOffAtTheRight() {
        rule.setContent { Grid(30) }; rule.waitForIdle()
        val columns = ((1280f - 124f + 18f) / (154f + 18f)).toInt()               // 6 across at full width
        focus("p${columns - 1}"); val b = bounds("p${columns - 1}")
        assertTrue("right ${b.right} of ${px(1280.dp)}", b.right <= px(1280.dp))
    }

    @Test fun lastRowIsNotCutOffAtTheBottom() {
        rule.setContent { Grid(30) }; rule.waitForIdle()
        rule.onNodeWithTag("p0").requestFocus()
        repeat(12) { rule.onNode(isFocused()).performKeyInput { pressKey(Key.DirectionDown) } }
        settle()
        val b = rule.onNode(isFocused()).fetchSemanticsNode().boundsInRoot
        assertTrue("bottom ${b.bottom} of ${px(720.dp)}", b.bottom <= px(720.dp)); assertTrue(b.top >= 0f)
    }

    @Test fun withTheFoldersOpenTheFirstColumnIsNotCutOffByThePanelEdge() {
        rule.setContent { Row(Modifier.fillMaxSize()) { Box(Modifier.width(256.dp).fillMaxSize().testTag("panel")); Box(Modifier.fillMaxSize().testTag("page")) { Grid(30) } } }
        rule.waitForIdle(); focus("p0")
        val page = bounds("page"); val b = bounds("p0")
        assertTrue("left ${b.left} vs page ${page.left}", b.left >= page.left); assertTrue(b.top >= page.top)
    }

    @Test fun aRailInsideTheGridKeepsItsFirstCardWhereItWasAndDoesNotCutItOff() {
        rule.setContent {
            LazyVerticalGrid(GridCells.Adaptive(154.dp), Modifier.fillMaxSize(), contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 14.dp, bottom = 40.dp)) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "rail") {
                    LazyRow(Modifier.bleedStart(14.dp).testTag("rail"), horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = PaddingValues(start = 14.dp, end = 24.dp, top = 8.dp, bottom = 8.dp)) {
                        rowItems((0 until 12).toList(), key = { it }) { Poster("r$it") }
                    }
                }
            }
        }
        rule.waitForIdle()
        val resting = bounds("r0")
        assertEquals("the first card stays at the page margin", px(Tokens.safeHorizontal), resting.left, 1.5f)
        focus("r0"); val grown = bounds("r0"); val rail = bounds("rail")
        assertTrue("card left ${grown.left} vs rail left ${rail.left}", grown.left >= rail.left)
    }

    @Test fun aHomeRailWithSideMarginsAndRoomAboveAndBelowDoesNotCutOffItsCards() {
        rule.setContent {
            LazyRow(Modifier.testTag("rail"), horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = PaddingValues(horizontal = Tokens.safeHorizontal, vertical = 14.dp)) {
                rowItems((0 until 12).toList(), key = { it }) { Poster("h$it") }
            }
        }
        rule.waitForIdle(); focus("h0")
        val b = bounds("h0"); val rail = bounds("rail")
        assertTrue(b.left >= rail.left); assertTrue("top ${b.top} vs ${rail.top}", b.top >= rail.top); assertTrue(b.bottom <= rail.bottom)
    }

    @Test fun rapidMovementThroughTheGridNeverLeavesTheFocusedPosterCutOff() {
        rule.setContent { Grid(60) }; rule.waitForIdle(); rule.onNodeWithTag("p0").requestFocus()
        val root = px(1280.dp) to px(720.dp)
        val moves = listOf(Key.DirectionRight, Key.DirectionDown, Key.DirectionDown, Key.DirectionLeft, Key.DirectionUp, Key.DirectionRight, Key.DirectionRight, Key.DirectionDown)
        repeat(6) { for (k in moves) rule.onNode(isFocused()).performKeyInput { pressKey(k) } }
        settle()
        val b = rule.onNode(isFocused()).fetchSemanticsNode().boundsInRoot
        assertTrue("inside the screen: $b", b.left >= 0f && b.top >= 0f && b.right <= root.first && b.bottom <= root.second)
    }
}
