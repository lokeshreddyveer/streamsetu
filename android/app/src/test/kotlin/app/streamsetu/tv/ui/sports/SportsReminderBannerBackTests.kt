package app.streamsetu.tv.ui.sports

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.requestFocus
import app.streamsetu.tv.sports.personal.ReminderBanner
import app.streamsetu.tv.ui.components.BannerActions
import app.streamsetu.tv.ui.components.SportsReminderBannerContent
import app.streamsetu.tv.ui.components.TvButton
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Back belongs to whatever the person is on. It dismisses the reminder banner only while the banner itself is focused. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsReminderBannerBackTests {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    private val banner = ReminderBanner("r", "India vs Australia", 1_800_000_000_000L + 15 * 60_000L)

    @Test fun backDismissesTheBannerOnlyWhileItIsFocused() {
        val dismissed = ArrayList<String>(); var otherBack = 0
        rule.setContent {
            androidx.activity.compose.BackHandler(enabled = true) { otherBack++ }                      // the page underneath
            Column {
                TvButton("Unrelated", { }, Modifier.testTag("unrelated"))
                SportsReminderBannerContent(banner, interactive = true, nowMs = 1_800_000_000_000L, actions = BannerActions({ }, { dismissed += "dismiss" }))
            }
        }
        rule.onNodeWithTag("unrelated").requestFocus(); rule.waitForIdle()
        rule.runOnUiThread { rule.activity.onBackPressedDispatcher.onBackPressed() }; rule.waitForIdle()
        assertEquals("Back went to the page, not the banner", 1, otherBack); assertTrue(dismissed.isEmpty())
        rule.onNodeWithTag("sports-banner-dismiss").requestFocus(); rule.waitForIdle()
        rule.runOnUiThread { rule.activity.onBackPressedDispatcher.onBackPressed() }; rule.waitForIdle()
        assertEquals("on the banner, Back dismisses it", listOf("dismiss"), dismissed); assertEquals(1, otherBack)
    }
}
