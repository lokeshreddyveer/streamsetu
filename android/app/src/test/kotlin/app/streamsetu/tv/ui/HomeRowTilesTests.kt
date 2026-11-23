package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.width
import app.streamsetu.core.data.smartmix.HomeLayoutTokens
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

/** The collection tile (two cards peeking behind the lead poster, name, "N titles") and the loading rows of Home. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class HomeRowTilesTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = PatientIdle()
    @Before fun setup() { UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }

    @Test fun aCollectionTileShowsItsNameItsCountAndTwoCardsPeekingBehindAndOpensOnTap() {
        var opened = 0
        rule.setContent { CollectionTile("John Wick", 4, null, "m1", { opened++ }) }
        rule.onNodeWithTag("collection-tile-m1").assertExists()
        rule.onNodeWithTag("collection-peek-1", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("collection-peek-2", useUnmergedTree = true).assertExists()
        rule.onAllNodesWithText("John Wick", useUnmergedTree = true).assertCountEquals(2)          // the empty poster draws the name too; the caption is the second
        rule.onNodeWithText("4 titles", useUnmergedTree = true).assertExists()
        // The tile is the poster width plus the two peeks, so the row beside it keeps its rhythm.
        val w = rule.onNodeWithTag("collection-tile-m1").getBoundsInRoot().width
        assertEquals((Tokens.posterWidth + CollectionPeek * 2).value, w.value, 0.6f)
        rule.onNodeWithTag("collection-tile-m1").performClick(); rule.waitForIdle()
        assertEquals(1, opened)
    }

    @Test fun theLoadingRowsAreTheNumberTheLayoutRulesAskFor() {
        rule.setContent { Column { HomeSkeleton(Modifier.testTag("home-skeleton")) } }
        rule.onNodeWithTag("home-skeleton").assertExists()
        assertEquals(3, HomeLayoutTokens.SKELETON_ROWS)
    }
}
