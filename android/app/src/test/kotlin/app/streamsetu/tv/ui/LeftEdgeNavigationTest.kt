package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.items as rowItems
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.LocalRailReveal
import app.streamsetu.tv.ui.components.leftGoesTo
import app.streamsetu.tv.ui.components.railOnLeft
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Left at the edge of a page. Compose's own search would pick the nearest item to the left and below (a poster in the first column, a category beside the row you were on); these pin
 * down that it goes where the screen says instead.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class LeftEdgeNavigationTest {
    @get:Rule val rule = createComposeRule()
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private var reveals = 0

    private fun page(content: @androidx.compose.runtime.Composable () -> Unit) = rule.setContent {
        CompositionLocalProvider(LocalRailReveal provides { reveals++ }) { Column(Modifier.railOnLeft(), content = { content() }) }
    }

    @Test fun leftFromAnInsetHeaderButtonShowsTheRailInsteadOfJumpingToAPosterBelow() {
        reveals = 0
        page {
            Row(Modifier.railOnLeft().padding(start = 300.dp)) { Focusable({}, Modifier.testTag("tool")) { Label("Folders") } }
            LazyRow(Modifier.railOnLeft()) { rowItems((0 until 6).toList()) { i -> Focusable({}, Modifier.testTag("p$i").width(120.dp).height(160.dp)) { Label("P$i") } } }
        }
        rule.onNodeWithTag("tool").requestFocus()
        press("tool", Key.DirectionLeft)
        assertEquals(1, reveals); rule.onNodeWithTag("tool").assertIsFocused()
    }

    @Test fun leftFromTheFirstPosterOfARowShowsTheRailAndMovingRightStillWorks() {
        reveals = 0
        page { LazyRow(Modifier.railOnLeft()) { rowItems((0 until 6).toList()) { i -> Focusable({}, Modifier.testTag("p$i").width(120.dp).height(160.dp)) { Label("P$i") } } } }
        rule.onNodeWithTag("p0").requestFocus()
        press("p0", Key.DirectionRight); rule.onNodeWithTag("p1").assertIsFocused()
        press("p1", Key.DirectionLeft); rule.onNodeWithTag("p0").assertIsFocused(); assertEquals(0, reveals)         // inside the row Left still moves
        press("p0", Key.DirectionLeft); assertEquals(1, reveals)
    }

    @Test fun leftFromTheFirstColumnOfAGridShowsTheRailNotARowAbove() {
        reveals = 0
        page { LazyVerticalGrid(GridCells.Fixed(4), Modifier.width(600.dp).height(500.dp).railOnLeft()) { gridItems((0 until 16).toList()) { i -> Focusable({}, Modifier.testTag("g$i").height(100.dp)) { Label("G$i") } } } }
        rule.onNodeWithTag("g4").requestFocus()                       // first column, second row
        press("g4", Key.DirectionLeft)
        assertEquals(1, reveals); rule.onNodeWithTag("g4").assertIsFocused()
    }

    @Test fun leftFromTheSettingsPanelReturnsToTheSelectedCategoryNotTheOneBesideTheRow() {
        val selected = FocusRequester()
        rule.setContent {
            Row {
                Column(Modifier.width(200.dp)) { repeat(6) { i -> Focusable({}, (if (i == 1) Modifier.focusRequester(selected) else Modifier).testTag("cat$i").height(60.dp)) { Label("Category $i") } } }
                Column(Modifier.leftGoesTo(selected)) { repeat(6) { i -> Focusable({}, Modifier.testTag("row$i").height(60.dp)) { Label("Setting $i") } } }
            }
        }
        rule.onNodeWithTag("row4").requestFocus()                     // level with category 4
        press("row4", Key.DirectionLeft)
        rule.onNodeWithTag("cat1").assertIsFocused()                  // the open category, not cat4
    }

    @Test fun insideADialogLeftDoesNotShowTheRailBehindIt() {
        reveals = 0
        rule.setContent {
            CompositionLocalProvider(LocalRailReveal provides { reveals++ }) {
                CompositionLocalProvider(LocalRailReveal provides null) {          // what TvDialog does
                    Column(Modifier.railOnLeft()) { Focusable({}, Modifier.testTag("menu0")) { Label("Open") } }
                }
            }
        }
        rule.onNodeWithTag("menu0").requestFocus()
        press("menu0", Key.DirectionLeft)
        assertEquals(0, reveals); rule.onNodeWithTag("menu0").assertIsFocused()
    }

    @Test fun otherDirectionsAreNeverTakenByTheEdgeRule() {
        reveals = 0
        page { Row(Modifier.railOnLeft()) { Focusable({}, Modifier.testTag("a").width(100.dp).height(60.dp)) { Label("A") }; Focusable({}, Modifier.testTag("b").width(100.dp).height(60.dp)) { Label("B") } } }
        rule.onNodeWithTag("a").requestFocus()
        press("a", Key.DirectionRight); rule.onNodeWithTag("b").assertIsFocused()
        press("b", Key.DirectionUp); press("b", Key.DirectionDown); press("b", Key.DirectionRight)
        assertEquals(0, reveals)
    }
}
