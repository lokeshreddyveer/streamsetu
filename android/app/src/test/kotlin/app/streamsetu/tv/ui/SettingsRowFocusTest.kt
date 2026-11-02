package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.screens.settings.LocalSettingFocus
import app.streamsetu.tv.ui.screens.settings.SettingFocusTarget
import app.streamsetu.tv.ui.screens.settings.SettingRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Settings search opens a page and puts the remote on one real row of it. The target is let go only when that row itself says it has the focus. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
class SettingsRowFocusTest {
    @get:Rule val rule = createComposeRule()

    private fun page(target: SettingFocusTarget?, count: Int = 60) {
        rule.setContent {
            CompositionLocalProvider(LocalSettingFocus provides target) {
                Column(Modifier.height(500.dp).verticalScroll(rememberScrollState())) { repeat(count) { i -> SettingRow("Row $i", "Detail $i", "Value") {} } }
            }
        }
    }

    @Test fun aRowFarDownThePageTakesTheRemoteAndOnlyThenIsTheTargetLetGo() {
        var done = 0; val t = SettingFocusTarget("Row 45", FocusRequester()) { done++ }
        page(t); rule.waitForIdle()
        rule.onNodeWithText("Row 45").assertIsFocused()
        assertTrue(t.landed); assertEquals(1, done)
    }

    @Test fun aRowThatIsNotOnThePageNeverCountsAsFocusedAndTheTargetIsNotReportedDone() {
        var done = 0; val t = SettingFocusTarget("A setting that is not here", FocusRequester()) { done++ }
        page(t, count = 10); rule.waitForIdle()
        assertFalse(t.landed); assertEquals(0, done)
    }

    @Test fun aRowDeepInALazyPageThatDoesNotExistYetIsBuiltAndTakesTheRemote() {
        // The Statistics page is a lazy list: "Clear statistics" is far below the first screenful, so it has to be scrolled to before it can take the remote.
        var done = 0; val t = SettingFocusTarget("Clear statistics", FocusRequester()) { done++ }
        rule.setContent {
            val state = androidx.compose.foundation.lazy.rememberLazyListState()
            app.streamsetu.tv.ui.screens.settings.SweepToSettingTarget(state, t)
            CompositionLocalProvider(LocalSettingFocus provides t) {
                androidx.compose.foundation.lazy.LazyColumn(Modifier.height(400.dp), state = state) {
                    items(120) { i -> SettingRow(if (i == 100) "Clear statistics" else "Statistic $i", "Detail", "Value") {} }
                }
            }
        }
        rule.waitForIdle()
        rule.onNodeWithText("Clear statistics").assertIsFocused()
        assertTrue(t.landed); assertEquals(1, done)
    }

    @Test fun theSweepFindsARowDeepInALazyPageWithinAboutASecondOfFrames() {
        rule.mainClock.autoAdvance = false
        val t = SettingFocusTarget("Clear statistics", FocusRequester()) {}
        rule.setContent {
            val state = androidx.compose.foundation.lazy.rememberLazyListState()
            app.streamsetu.tv.ui.screens.settings.SweepToSettingTarget(state, t)
            CompositionLocalProvider(LocalSettingFocus provides t) {
                androidx.compose.foundation.lazy.LazyColumn(Modifier.height(400.dp), state = state) { items(120) { i -> SettingRow(if (i == 100) "Clear statistics" else "Statistic $i", "Detail", "Value") {} } }
            }
        }
        var frames = 0
        while (!t.landed && frames < 120) { rule.mainClock.advanceTimeByFrame(); frames++ }
        assertTrue("took $frames frames", t.landed && frames <= app.streamsetu.tv.ui.screens.settings.MAX_FOCUS_TRIES)
    }

    @Test fun aMissingRowEndsTheSweepWithinTheBoundAndSendsTheRemoteToThePage() {
        rule.mainClock.autoAdvance = false
        var missing = 0; val t = SettingFocusTarget("Not on this page", FocusRequester()) {}
        rule.setContent {
            val state = androidx.compose.foundation.lazy.rememberLazyListState()
            app.streamsetu.tv.ui.screens.settings.SweepToSettingTarget(state, t) { missing++ }
            CompositionLocalProvider(LocalSettingFocus provides t) { androidx.compose.foundation.lazy.LazyColumn(Modifier.height(400.dp), state = state) { items(120) { i -> SettingRow("Statistic $i", "Detail", "Value") {} } } }
        }
        var frames = 0
        while (missing == 0 && frames < 200) { rule.mainClock.advanceTimeByFrame(); frames++ }
        assertEquals(1, missing); assertFalse(t.landed); assertTrue("took $frames frames", frames <= app.streamsetu.tv.ui.screens.settings.MAX_FOCUS_TRIES + 2)
    }

    @Test fun withNoTargetNoRowTakesTheRemote() {
        page(null, count = 5); rule.waitForIdle()
        rule.onNodeWithText("Row 0")   // exists, but nothing asked for focus
    }
}
