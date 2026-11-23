package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.smartmix.ShelfView
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.UiScale
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

private fun desc(s: String) = SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription, listOf(s))

/** The two chips of a ranking shelf: choice, labels, the 44 dp touch target, and the remote (left and right between the chips, down back to the shelf). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class ShelfHeaderTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = PatientIdle()
    @Before fun setup() { UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focused(tag: String) = rule.onNode(isFocused() and (hasTestTag(tag) or hasAnyAncestor(hasTestTag(tag))), useUnmergedTree = true).assertExists()

    @Test fun exactlyOneChipIsOnAndTappingSwitchesAndTheLabelsAreSpoken() {
        var view by mutableStateOf(ShelfView.WEEKLY)
        rule.setContent { ShelfHeader("Top Thriller", shelfSubtitle(view, true), view, false, { view = it }, {}) }
        rule.onNodeWithTag("chip-weekly").assert(desc("Trending this week")).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Selected, true))
        rule.onNodeWithTag("chip-all-time").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Selected, false))
        rule.onNodeWithTag("chip-all-time").performClick(); rule.waitForIdle()
        assertEquals(ShelfView.ALL_TIME, view)
        rule.onNodeWithTag("chip-all-time").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Selected, true))
        rule.onNodeWithText("Top Thriller").assertExists(); rule.onNodeWithTag("see-all").assertExists()
        rule.onNodeWithContentDescription("Ranking for Top Thriller").assertExists()
    }

    @Test fun chipsHaveA44dpTouchTargetAndTheHeaderKeepsItsHeightInBothViews() {
        var view by mutableStateOf(ShelfView.WEEKLY)
        rule.setContent { ShelfHeader("Trending in Your Library", shelfSubtitle(view, false), view, false, { view = it }, null, Modifier.testTag("hdr")) }
        val h = rule.onNodeWithTag("hdr").fetchSemanticsNode().size.height
        val chip = rule.onNodeWithTag("chip-weekly").fetchSemanticsNode().size
        val dp = rule.density.run { 44.dp.roundToPx() }
        assertTrue("touch target ${chip.height} < $dp", chip.height >= dp)
        view = ShelfView.ALL_TIME; rule.waitForIdle()
        assertEquals("nothing moves when the view changes", h, rule.onNodeWithTag("hdr").fetchSemanticsNode().size.height)
        rule.onNodeWithTag("see-all").assertDoesNotExist()
    }

    @Test fun subtitlesAreShortAndTheSwitchStacksAtALargeFont() {
        for (v in ShelfView.values()) for (o in listOf(true, false)) assertTrue(shelfSubtitle(v, o).length <= 20)
        rule.setContent { androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(androidx.compose.ui.platform.LocalDensity.current.density, 2f)) { Box(Modifier.width(360.dp)) { ShelfHeader("Top Thriller", "Best of all time", ShelfView.ALL_TIME, false, {}, {}) } } }
        val sub = rule.onNodeWithTag("shelf-subtitle").fetchSemanticsNode().boundsInRoot; val sw = rule.onNodeWithTag("chip-weekly").fetchSemanticsNode().boundsInRoot
        assertTrue("the switch is under the subtitle", sw.top >= sub.bottom - 1f)
    }

    @Test fun onATelevisionLeftAndRightMoveBetweenTheChipsOkSelectsAndDownGoesToTheFirstTile() {
        var view by mutableStateOf(ShelfView.WEEKLY)
        val row = FocusRequester()
        rule.setContent {
            Column {
                ShelfHeader("Top Thriller", "Popular here", view, true, { view = it }, {}, firstTile = row)
                Row(Modifier.focusRequester(row)) { androidx.compose.foundation.layout.Box(Modifier.size(1.dp)); Focusable({}, Modifier.testTag("tile0").size(100.dp)) { _ -> } ; Focusable({}, Modifier.testTag("tile1").size(100.dp)) { _ -> } }
            }
        }
        rule.onNodeWithTag("chip-all-time").requestFocus(); focused("chip-all-time")
        press("chip-all-time", Key.DirectionRight); focused("chip-weekly")
        press("chip-weekly", Key.DirectionLeft); focused("chip-all-time")
        press("chip-all-time", Key.Enter); assertEquals(ShelfView.ALL_TIME, view)
        focused("chip-all-time")          // focus stays on the chosen chip
        press("chip-all-time", Key.DirectionDown); focused("tile0")          // and down returns to the shelf
    }
}
