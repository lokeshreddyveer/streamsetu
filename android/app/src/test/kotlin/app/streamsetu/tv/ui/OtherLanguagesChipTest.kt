package app.streamsetu.tv.ui

import android.content.pm.PackageManager
import androidx.activity.ComponentActivity
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import app.streamsetu.core.data.repo.OtherVersions
import app.streamsetu.tv.ui.components.PhoneOtherLanguages
import app.streamsetu.tv.ui.components.TvOtherLanguages
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Every route into a detail page (Home rows, the hero, Movies and Series, Search, Favorites, Continue Watching, collections, the similar rows) opens the same detail page, whose
 * Other languages row is this one: choosing a chip must hand back exactly that version, by OK on the remote or by a tap, and the open version must not be choosable.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
@OptIn(ExperimentalTestApi::class)
class OtherLanguagesChipTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    private fun c(id: String, t: String, f: String) = OtherVersions.Candidate(id, OtherVersions.Kind.MOVIE, t, 2023, f, "s1", "Home")
    private val versions = OtherVersions.group(c("ta", "Leo (2023)", "TAMIL | GENERAL"), listOf(c("hi", "Leo (2023)", "ENGLISH | HINDI DUBBED"), c("te", "Leo (2023)", "TELUGU | GENERAL"))).map { it to it.id }

    @Test @Config(qualifiers = "w1280dp-h720dp-land") fun okOnAChipOpensThatVersionOnATelevision() {
        shadowOf(rule.activity.packageManager).setSystemFeature(PackageManager.FEATURE_LEANBACK, true)
        val opened = ArrayList<String>()
        rule.setContent { TvOtherLanguages(versions, { null }) { opened += it } }
        rule.onNode(hasClickAction() and (hasText("Telugu", substring = true) or hasAnyDescendant(hasText("Telugu", substring = true))), useUnmergedTree = true).requestFocus()
        rule.onNode(hasClickAction() and (hasText("Telugu", substring = true) or hasAnyDescendant(hasText("Telugu", substring = true))), useUnmergedTree = true).performKeyInput { pressKey(Key.DirectionCenter) }
        rule.waitForIdle()
        assertEquals(listOf("te"), opened)
        // The open version (Tamil) is shown but cannot be chosen.
        assertEquals(0, rule.onAllNodes(hasClickAction() and (hasText("Tamil", substring = true) or hasAnyDescendant(hasText("Tamil", substring = true))), useUnmergedTree = true).fetchSemanticsNodes().size)
    }

    @Test fun aTapOnAChipOpensThatVersionOnAPhone() {
        shadowOf(rule.activity.packageManager).setSystemFeature(PackageManager.FEATURE_TOUCHSCREEN, true)
        val opened = ArrayList<String>()
        rule.setContent { PhoneOtherLanguages(versions, { null }, { opened += it }) }
        rule.onNode(hasContentDescription("Hindi", substring = true)).performClick()
        rule.waitForIdle()
        assertEquals(listOf("hi"), opened)
    }
}
