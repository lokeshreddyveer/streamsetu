package app.streamsetu.tv.ui.sports

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import app.streamsetu.tv.sports.multiview.*
import app.streamsetu.tv.ui.screens.sports.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The Multiview builder and tiles on the remote: the real composables, with every action recorded. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsMultiviewScreenTests {
    @get:Rule val rule = createComposeRule()
    private fun key(k: Key) { rule.onAllNodes(isFocused()).onFirst().performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focusedTags() = rule.onAllNodes(isFocused()).fetchSemanticsNodes().map { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "?" }

    private fun tile(id: Long, ch: String, status: TileStatus = TileStatus.PLAYING, audio: Boolean = false) =
        TileUi(id, ch, "Channel $ch", "Event $ch", "e$ch", status, null, audio, if (status == TileStatus.FAILED) "This feed could not be played" else null, false)
    private fun state(vararg t: TileUi) = MultiviewState(t.toList(), 4, null, null)

    // ---- the builder

    private class Calls { val added = ArrayList<String>(); val chosen = ArrayList<String>(); val opened = ArrayList<Int>(); var started = 0; var cleared = 0; var closed = 0 }
    private fun builder(sel: SelectionState, cands: List<MultiviewCandidate>, calls: Calls, replacing: Int? = null) = rule.setContent {
        MultiviewBuilder(sel, cands, replacing, BuilderActions({ calls.added += it }, { calls.chosen += it }, { calls.opened += it }, { calls.started++ }, { calls.cleared++ }, { calls.closed++ }))
    }
    private val cands = listOf(MultiviewCandidate("a", "Arsenal v Chelsea", "Football", 2, false), MultiviewCandidate("b", "India v Australia", "Cricket", 1, true))
    private val entries = listOf(MultiviewEntry("a", "1", "A", "Arsenal v Chelsea", "Sky Sports"), MultiviewEntry("b", "2", "A", "India v Australia", "Willow"))

    @Test fun theBuilderShowsTheSelectedFeedsTheLiveEventsAndStart() {
        val calls = Calls(); builder(SelectionState(entries, 4), cands, calls)
        rule.onNodeWithTag("mv-builder").assertExists(); rule.onNodeWithTag("mv-entry-0").assertExists(); rule.onNodeWithTag("mv-entry-1").assertExists()
        rule.onNodeWithTag("mv-event-a").assertExists(); rule.onNodeWithTag("mv-start").assertExists()
        assertEquals("4 views at most is shown", 0, calls.started)
    }

    @Test fun focusAloneAddsStartsAndChangesNothing() {
        val calls = Calls(); builder(SelectionState(emptyList(), 4), cands, calls)
        rule.waitForIdle(); repeat(3) { key(Key.DirectionRight) }; key(Key.DirectionDown); key(Key.DirectionUp)
        assertEquals(0, calls.added.size + calls.chosen.size + calls.opened.size + calls.started + calls.cleared)
    }

    @Test fun okOnAnEventAddsItAndOkOnStartStartsOnlyWithTwoFeeds() {
        val calls = Calls(); builder(SelectionState(listOf(entries[0]), 4), cands, calls)
        rule.onNodeWithTag("mv-event-a").requestFocus(); key(Key.Enter); assertEquals(listOf("a"), calls.added)
        rule.onNodeWithTag("mv-start").requestFocus(); key(Key.Enter); assertEquals("Start is offered but the builder asks the caller; the caller checks the count", 1, calls.started)
    }

    @Test fun theBuilderPutsTheRemoteOnTheFirstEventAndStartsNothing() {
        val calls = Calls(); builder(SelectionState(emptyList(), 4), cands, calls); rule.waitForIdle()
        assertEquals(listOf("mv-event-a"), focusedTags()); assertEquals(0, calls.started)
    }

    @Test fun anEntryOpensItsMenuOnOkOnly() {
        val calls = Calls(); builder(SelectionState(entries, 4), cands, calls)
        rule.onNodeWithTag("mv-entry-1").requestFocus(); assertTrue(calls.opened.isEmpty()); key(Key.Enter); assertEquals(listOf(1), calls.opened)
    }

    // ---- the tiles

    private fun tiles(s: MultiviewState, calls: ArrayList<String> = ArrayList()) = rule.setContent {
        MultiviewTiles(s, { _, _ -> null }, TileActions({ calls += "open:" + it.channelId }, { calls += "retry:" + it.channelId }, { calls += "replace:" + it.channelId }, { calls += "remove:" + it.channelId }, { calls += "two" }, { calls += "one" }, { calls += "builder" }))
    }
    private fun bounds(tag: String) = rule.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot

    @Test fun everyLayoutKeepsEveryTileInsideTheScreenAndTheOnlySpeakerIsMarked() {
        tiles(state(tile(1, "1", audio = true), tile(2, "2"), tile(3, "3"), tile(4, "4")))
        rule.waitForIdle()
        val root = rule.onNodeWithTag("mv-tiles").fetchSemanticsNode().boundsInRoot
        for (ch in listOf("1", "2", "3", "4")) { val b = bounds("mv-tile-$ch"); assertTrue("$ch: $b in $root", b.left >= root.left - 1 && b.top >= root.top - 1 && b.right <= root.right + 1 && b.bottom <= root.bottom + 1 && b.width > 100 && b.height > 100) }
        rule.onAllNodesWithTag("mv-audio", useUnmergedTree = true).assertCountEquals(1); rule.onAllNodesWithTag("mv-muted", useUnmergedTree = true).assertCountEquals(3)
        val b1 = bounds("mv-tile-1"); val b2 = bounds("mv-tile-2"); val b3 = bounds("mv-tile-3")
        assertTrue("2x2 grid", b2.left > b1.left && b3.top > b1.top)
    }

    @Test fun threeTilesPutThePrimaryLargeOnTheLeft() {
        tiles(state(tile(1, "1", audio = true), tile(2, "2"), tile(3, "3"))); rule.waitForIdle()
        val p = bounds("mv-tile-1"); val a = bounds("mv-tile-2"); val b = bounds("mv-tile-3")
        assertTrue("primary is about twice as wide and as tall as a side tile", p.width > a.width * 1.5f && p.height > a.height * 1.5f && a.left >= p.right - 6 && b.top >= a.bottom - 6)
    }

    @Test fun directionKeysMoveBetweenTilesByPositionAndStopAtTheEdge() {
        tiles(state(tile(1, "1", audio = true), tile(2, "2"), tile(3, "3"), tile(4, "4"))); rule.waitForIdle()
        rule.onNodeWithTag("mv-focus-1").requestFocus(); rule.waitForIdle()
        key(Key.DirectionRight); key(Key.DirectionDown); key(Key.DirectionLeft); key(Key.DirectionUp)
        assertEquals("back on the first tile after a full circuit", 1, focusedTags().size)
        key(Key.DirectionLeft); key(Key.DirectionUp); assertEquals("edges do nothing and nothing is lost", 1, focusedTags().size)
    }

    @Test fun rapidKeysLeaveOneFocusOwner() {
        val calls = ArrayList<String>(); tiles(state(tile(1, "1", audio = true), tile(2, "2"), tile(3, "3")), calls); rule.waitForIdle()
        rule.onNodeWithTag("mv-focus-1").requestFocus(); rule.waitForIdle()
        val rnd = java.util.Random(3); val ks = listOf(Key.DirectionUp, Key.DirectionDown, Key.DirectionLeft, Key.DirectionRight)
        repeat(120) { key(ks[rnd.nextInt(4)]); assertTrue("one owner at most: ${focusedTags()}", focusedTags().size <= 1) }
        assertTrue("and no tile was opened by moving", calls.isEmpty())
    }

    @Test fun okOnATileOpensItsActionsAndAFailedTileShowsItsOwnChoices() {
        val calls = ArrayList<String>(); tiles(state(tile(1, "1", audio = true), tile(2, "2", TileStatus.FAILED)), calls); rule.waitForIdle()
        rule.onNodeWithTag("mv-focus-1").requestFocus(); rule.waitForIdle(); key(Key.Enter); assertEquals(listOf("open:1"), calls)
        rule.onNodeWithTag("mv-retry").assertExists(); rule.onNodeWithTag("mv-replace").assertExists(); rule.onNodeWithTag("mv-remove").assertExists()
        rule.onNodeWithTag("mv-retry").requestFocus(); key(Key.Enter); rule.onNodeWithTag("mv-replace").requestFocus(); key(Key.Enter); rule.onNodeWithTag("mv-remove").requestFocus(); key(Key.Enter)
        assertEquals(listOf("open:1", "retry:2", "replace:2", "remove:2"), calls)
    }

    @Test fun aNoDecoderTileOffersTwoViewsAndReplace() {
        val calls = ArrayList<String>(); tiles(state(tile(1, "1", audio = true), tile(2, "2", TileStatus.NO_DECODER).copy(message = "This device cannot play another video at the same time.")), calls); rule.waitForIdle()
        rule.onNodeWithTag("mv-use-two").requestFocus(); key(Key.Enter); assertEquals(listOf("two"), calls); rule.onNodeWithTag("mv-replace").assertExists()
    }

    @Test fun whenOnlyOneViewIsLeftTheScreenOffersTheWayOn() {
        val calls = ArrayList<String>(); tiles(MultiviewState(listOf(tile(1, "1", audio = true)), 4, MultiviewNotice.ONE_LEFT), calls); rule.waitForIdle()
        rule.onNodeWithTag("mv-continue-one").assertExists(); rule.onNodeWithTag("mv-to-builder").requestFocus(); key(Key.Enter); assertEquals(listOf("builder"), calls)
    }

    // ---- the ordinary Multi-View's own screens

    @Test fun anOversizedSetAsksWhichToKeepAndNeverStartsThemAll() {
        val started = ArrayList<List<MultiviewEntry>>(); var cancelled = 0
        val all = (1..5).map { MultiviewEntry("", "$it", "A", "", "Channel $it") }
        rule.setContent { app.streamsetu.tv.ui.screens.PresetChooser(3, all, { started += it }, { cancelled++ }) }
        rule.onNodeWithTag("mvo-chooser-title").assertExists()
        rule.onNodeWithTag("mvo-pick-4").requestFocus(); key(Key.Enter)                      // already three kept: a fourth is not accepted
        rule.onNodeWithTag("mvo-pick-1").requestFocus(); key(Key.Enter)                      // drops one
        rule.onNodeWithTag("mvo-pick-4").requestFocus(); key(Key.Enter)                      // now there is room
        rule.onNodeWithTag("mvo-chooser-start").requestFocus(); key(Key.Enter)
        assertEquals(listOf(listOf("2", "3", "4")), started.map { l -> l.map { it.channelId } }); assertEquals(0, cancelled)
    }

    @Test fun aDeviceWithoutMultiviewSaysSoPlainly() {
        var closed = 0; var one = 0
        rule.setContent { app.streamsetu.tv.ui.screens.MultiviewUnsupported({ closed++ }, { one++ }) }
        rule.onNodeWithTag("mvo-unsupported").assertExists()
        rule.onNodeWithTag("mvo-watch-one").requestFocus(); key(Key.Enter); assertEquals(1, one)
        rule.onNodeWithTag("mvo-close").requestFocus(); key(Key.Enter); assertEquals(1, closed)
    }

    @Test fun backWalksMenuThenTilesThenBuilderThenSports() {
        assertEquals(BackStep.CLOSE_MENU, multiviewBack(menuOpen = true, replacing = true, watching = true))
        assertEquals(BackStep.CANCEL_REPLACE, multiviewBack(false, true, true)); assertEquals(BackStep.TO_BUILDER, multiviewBack(false, false, true)); assertEquals(BackStep.LEAVE, multiviewBack(false, false, false))
    }
}
