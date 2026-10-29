package app.streamsetu.tv.ui.sports

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onNodeWithText
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.screens.settings.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** "Open Guide Settings" must land on the page that really holds the guide's refresh, address, time shift and time-zone settings. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class GuideSettingsTests {
    @get:Rule val rule = createComposeRule()

    private fun model(vararg names: String) = GuideSettingsModel(names.mapIndexed { i, n -> GuideConnection("s$i", n, null) }, 30, "UTC", "Asia/Kolkata", null)

    @Test fun theGuidePageHoldsRefreshAddressShiftAndTimeSettings() {
        var refreshed = 0; var changed: String? = null; var shift: Int? = null; var zone: String? = null
        rule.setContent { GuideSettingsContent(model("Home"), GuideSettingsActions({ refreshed++ }, { changed = it }, { shift = it }, { zone = it })) }
        rule.onNodeWithText("Refresh guide now").assertExists()
        rule.onNodeWithText("Guide (EPG) address").assertExists()
        rule.onNodeWithText("Guide time shift").assertExists()
        rule.onNodeWithText("Catch-up start time").assertExists()
        rule.onNodeWithText("Time zone").assertExists()
        rule.onAllNodesWithText("Asia/Kolkata").assertCountEquals(1)
        rule.onNodeWithText("Refresh").performClick(); rule.waitForIdle(); assertEquals(1, refreshed)
        rule.onNodeWithText("Change").performClick(); rule.waitForIdle(); assertEquals("s0", changed)
    }

    @Test fun eachConnectionGetsItsOwnAddressRowAndNoneMeansNone() {
        rule.setContent { GuideSettingsContent(model("One", "Two"), GuideSettingsActions({}, {}, {}, {})) }
        rule.onNodeWithText("Guide (EPG) address: One").assertExists(); rule.onNodeWithText("Guide (EPG) address: Two").assertExists()
    }

    @Test fun theSportsActionNamesTheGuidePageAndSettingsOpensIt() {
        val nav = Navigator()
        nav.pendingSettings = GuideSettingsPage.request; nav.go(Tab.SETTINGS)
        assertEquals(Tab.SETTINGS, nav.tab)
        assertEquals(Category.LIVE, categoryFromRequest(nav.pendingSettings))
        assertEquals("the page that holds the guide settings is the Live TV page", GuideSettingsPage.category, categoryFromRequest(nav.pendingSettings))
        assertNull("a name that is not a page opens nothing", categoryFromRequest("NOPE")); assertNull(categoryFromRequest(null))
    }
}
