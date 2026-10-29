package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.ContentKind
import app.streamsetu.tv.nav.SearchSession
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.Sidebar
import app.streamsetu.tv.ui.components.TvButton
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The real television canvas: the interface is laid out for 960 x 540 dp (Tokens), which is what a 1080p screen gives it, not the 1920 x 1080 dp the other tests use (twice the room).
 * These run the shared building blocks at that size, and at 150% text, the way a remote drives them. What needs a whole screen with its data (Settings, Guide, Search with a library)
 * is checked on the device by the scripted run; see android/SPEC-STATUS.md.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w960dp-h540dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class TvCanvasLayoutTest {
    @get:Rule val rule = createComposeRule()
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun withText(scale: Float, content: @androidx.compose.runtime.Composable () -> Unit) = rule.setContent {
        CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, scale)) { content() }
    }

    // ---- the rail ----
    private fun everyRailEntryIsReachable(scale: Float) {
        withText(scale) { Row { Sidebar(Tab.HOME, onSelect = {}, entry = FocusRequester(), expanded = true, onReturn = {}) } }
        val order = listOf(Tab.HOME, Tab.LIVE, Tab.GUIDE, Tab.MOVIES, Tab.SERIES, Tab.SEARCH, Tab.LIBRARIES, Tab.SETTINGS)
        rule.onNodeWithTag("sidebar-HOME").requestFocus()
        order.zipWithNext().forEach { (a, b) -> press("sidebar-${a.name}", Key.DirectionDown); rule.onNodeWithTag("sidebar-${b.name}").assertIsFocused() }
        rule.onNodeWithTag("sidebar-SETTINGS").assertIsDisplayed()
    }
    @Test fun everyRailEntryIsReachableAndVisibleAtNormalText() = everyRailEntryIsReachable(1f)
    @Test fun everyRailEntryIsReachableAndVisibleAtLargeText() = everyRailEntryIsReachable(1.5f)

    // ---- long titles: no focus target may disappear ----
    private val titles = listOf(
        "ఒక్కడు (2003) (Telugu) 4K HDR Dolby Atmos Extended Director's Cut Special Edition",
        "सिंघम रिटर्न्स: एक बहुत लंबा हिंदी फ़िल्म शीर्षक जो एक पंक्ति में नहीं समाता (2014)",
        "The Extraordinarily Long English Title of a Film That Goes On and On and On (Remastered 2026)",
        "Short",
    )
    @Test fun aRowOfCardsWithVeryLongTitlesCanBeWalkedFromEndToEnd() {
        val names = (0 until 12).map { titles[it % titles.size] + " $it" }
        withText(1.5f) { LazyRow { items(names, key = { it }) { n -> Focusable({}, Modifier.testTag("card-$n").width(150.dp)) { Label(n, maxLines = 2) } } } }
        rule.onNodeWithTag("card-${names[0]}").requestFocus()
        for (i in 0 until names.size - 1) press("card-${names[i]}", Key.DirectionRight)
        rule.onNodeWithTag("card-${names.last()}").assertIsFocused()
    }

    // ---- one list: the field, many AI rows, then the local results ----
    @Test fun eightAiRowsAboveTheResultsNeverCutTheLocalResultsOff() {
        withText(1.5f) {
            LazyColumn {
                item(key = "field") { Focusable({}, Modifier.testTag("field")) { Label("Search") } }
                items((0 until 8).toList(), key = { "ai$it" }) { i -> Focusable({}, Modifier.testTag("ai-$i")) { Label("AI suggestion $i") } }
                item(key = "results") { LazyRow { items((0 until 6).toList(), key = { it }) { i -> Focusable({}, Modifier.testTag("local-$i").width(140.dp)) { Label("Local $i") } } } }
            }
        }
        rule.onNodeWithTag("field").requestFocus()
        repeat(8) { i -> press(if (i == 0) "field" else "ai-${i - 1}", Key.DirectionDown) }
        rule.onNodeWithTag("ai-7").assertIsFocused()
        press("ai-7", Key.DirectionDown)
        rule.onNodeWithTag("local-0").assertIsFocused(); rule.onNodeWithTag("local-0").assertIsDisplayed()
    }

    // ---- states that must keep a visible, focusable action ----
    @Test fun anEmptyLibraryKeepsTheRemoteOnAVisibleAction() {
        withText(1.5f) { Column { Label("Nothing here yet"); TvButton("Add a connection", {}, Modifier.testTag("add")) } }
        rule.onNodeWithTag("add").requestFocus()
        rule.onNodeWithTag("add").assertIsDisplayed(); rule.onNodeWithTag("add").assertIsFocused()
    }
    @Test fun aFailedSearchShowsARetryThatTakesTheRemote() {
        var retried = 0
        withText(1.5f) { LazyColumn { item { Label("Search could not be completed") }; item { TvButton("Retry", { retried++ }, Modifier.testTag("retry")) } } }
        rule.onNodeWithTag("retry").requestFocus(); rule.onNodeWithTag("retry").assertIsDisplayed()
        press("retry", Key.Enter)
        assertEquals(1, retried)
    }

    // ---- rapid repeats ----
    @Test fun aHeldDirectionKeyLeavesTheRemoteOnSomethingVisible() {
        withText(1f) { LazyColumn { items((0 until 40).toList(), key = { it }) { i -> Focusable({}, Modifier.testTag("row-$i")) { Label("Row $i") } } } }
        rule.onNodeWithTag("row-0").requestFocus()
        repeat(60) { rule.onRoot().performKeyInput { pressKey(Key.DirectionDown) } }; rule.waitForIdle()
        assertTrue((0 until 40).any { runCatching { rule.onNodeWithTag("row-$it").assertIsFocused() }.isSuccess })
    }

    // ---- what Search keeps when the person leaves and comes back (the logic, without a screen) ----
    @Test fun theSearchSessionIsKeptForTheSameLibraryProfileAndScopeAndDroppedOtherwise() {
        val s = SearchSession()
        s.open("lib1|p1|ALL").apply { query = "mahesh babu"; type = ContentKind.MOVIE; typeSet = true; focusedId = "m-9"; scrollIndex = 4; scrollOffset = 30 }
        val again = s.open("lib1|p1|ALL")
        assertEquals("mahesh babu", again.query); assertEquals("m-9", again.focusedId); assertEquals(4, again.scrollIndex)
        val other = s.open("lib1|p2|ALL")                         // another profile
        assertEquals("", other.query); assertNull(other.focusedId); assertEquals(false, other.typeSet)
        s.open("lib1|p2|MOVIES").query = "x"; s.open("lib2|p2|MOVIES")      // another library
        assertEquals("", s.open("lib2|p2|MOVIES").query)
    }
}
