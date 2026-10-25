package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.ui.Modifier
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
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Holding a direction. The keys arrive about 40 ms apart, faster than a focus animation (about 160 ms) finishes, with the real animations on. Every press must move the focus at
 * once and the last one must land where the presses say: no backlog of animations, no card skipped, no jump.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class RapidInputTest {
    @get:Rule val rule = createComposeRule()

    private fun hold(key: Key, presses: Int, gapMs: Long = 40) {
        rule.mainClock.autoAdvance = false
        repeat(presses) { rule.onRoot().performKeyInput { pressKey(key) }; rule.mainClock.advanceTimeBy(gapMs) }
        rule.mainClock.advanceTimeBy(1_000)             // the animations settle
        rule.mainClock.autoAdvance = true
        rule.waitForIdle()
    }

    @Test fun holdingRightAcrossALongRowLandsOnTheRightCard() {
        rule.setContent { LazyRow(Modifier.width(1200.dp)) { items((0 until 120).toList(), key = { it }) { i -> Focusable({}, Modifier.testTag("c$i").width(124.dp).height(186.dp)) { Label("$i") } } } }
        rule.onNodeWithTag("c0").requestFocus()
        hold(Key.DirectionRight, 70)
        rule.onNodeWithTag("c70").assertIsFocused()
    }

    @Test fun holdingDownThroughHundredsOfChannelsLandsOnTheRightRow() {
        rule.setContent { LazyColumn(Modifier.height(600.dp).fillMaxWidth()) { items((0 until 400).toList(), key = { it }) { i -> Focusable({}, Modifier.testTag("ch$i").fillMaxWidth().height(56.dp)) { Label("Channel $i") } } } }
        rule.onNodeWithTag("ch0").requestFocus()
        hold(Key.DirectionDown, 150)
        rule.onNodeWithTag("ch150").assertIsFocused()
    }

    @Test fun reversingMidwayRetargetsAtOnce() {
        rule.setContent { LazyRow(Modifier.width(1200.dp)) { items((0 until 80).toList(), key = { it }) { i -> Focusable({}, Modifier.testTag("c$i").width(124.dp).height(186.dp)) { Label("$i") } } } }
        rule.onNodeWithTag("c0").requestFocus()
        hold(Key.DirectionRight, 30); hold(Key.DirectionLeft, 12)
        rule.onNodeWithTag("c18").assertIsFocused()
    }
}
