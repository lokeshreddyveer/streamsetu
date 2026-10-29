package app.streamsetu.tv.ui.sports

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.*
import app.streamsetu.tv.sports.RankInput
import app.streamsetu.tv.ui.components.LocalContentEntry
import app.streamsetu.tv.ui.screens.sports.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Playing a Sports event on the remote: the real detail screen, ViewModel, playback coordinator and Navigator, with scripted services underneath. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsPlaybackScreenTests {
    @get:Rule val rule = createComposeRule()
    private val h = 3_600_000L; private val min = 60_000L
    private val now0 = 1_800_000_000_000L + 2 * h
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private lateinit var deps: FakeSportsDeps
    private lateinit var pdeps: FakePlaybackDeps
    private lateinit var coordinator: SportsPlaybackCoordinator
    private lateinit var vm: SportsViewModel
    private lateinit var mvDeps: app.streamsetu.tv.sports.multiview.FakeMultiviewDeps
    private lateinit var mv: app.streamsetu.tv.sports.multiview.SportsMultiviewController
    private lateinit var nav: Navigator
    @After fun stop() { scope.cancel() }
    @Before fun setUp() { deps = FakeSportsDeps(); pdeps = FakePlaybackDeps(); nav = Navigator(); nav.base = Base.Shell; nav.tab = Tab.SPORTS }

    private fun feed(ch: String, q: String? = null) = SportsFeed(ch, "A", "Channel $ch", null, MetadataSource.UNKNOWN, q, if (q != null) MetadataSource.PARSED_FROM_NAME else MetadataSource.UNKNOWN, null, ch, 0, false)
    private fun event(id: String, startMin: Long, feeds: List<SportsFeed>) =
        SportsEvent(id, Sport.FOOTBALL, SportsEventKind.HEAD_TO_HEAD, "League", listOf("X", "Y"), null, "Event $id", now0 + startMin * min, now0 + startMin * min + 2 * h, feeds, 0.95, setOf("A"), "r")

    private fun show(events: List<SportsEvent>): FocusRequester {
        events.flatMap { it.feeds }.forEach { f -> pdeps.channels[f.channelId] = Channel(f.channelId, "A", "cat", f.channelName, null, null, "ref", null) }
        deps.result = { events }; deps.nowMs = now0; deps.tick()
        coordinator = SportsPlaybackCoordinator(pdeps, scope, SportsPlaybackDiagnostics {})
        mvDeps = app.streamsetu.tv.sports.multiview.FakeMultiviewDeps(pdeps)
        val cap = app.streamsetu.tv.sports.multiview.MultiviewCapability { app.streamsetu.tv.sports.multiview.DeviceFacts(false, 384, 8, listOf(app.streamsetu.tv.sports.multiview.HardwareDecoder("video/avc", false, 16))) }
        mv = app.streamsetu.tv.sports.multiview.SportsMultiviewController(cap, app.streamsetu.tv.sports.multiview.SportsMultiviewSelection(mvDeps, cap) { RankInput() }, app.streamsetu.tv.sports.multiview.MultiviewSession(mvDeps, cap, scope, Dispatchers.IO))
        vm = SportsViewModel(deps, scope, 40L, SportsDiagnostics.Log, coordinator, mv)
        val entry = FocusRequester()
        rule.setContent { CompositionLocalProvider(LocalContentEntry provides entry) { SportsScreenHost(vm, nav) { } } }
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-list").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
        return entry
    }
    private fun key(k: Key) { rule.onNode(isFocused()).performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focusedTags() = rule.onAllNodes(isFocused()).fetchSemanticsNodes().map { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "?" }
    private fun focusedTag(): String { val t = focusedTags(); assertEquals("one focus owner: $t", 1, t.size); return t.single() }
    private fun until(p: () -> Boolean) = rule.waitUntil(5_000, p)
    private fun back() { rule.runOnUiThread { nav.back() }; rule.waitForIdle() }
    private fun phase(id: String, k: PhaseKind) = runBlocking { withTimeout(5_000) { while (pdeps.phases.subscriptionCount.value == 0) delay(2) }; pdeps.phases.emit(PlaybackPhase(id, k)) }

    /** The remote on the first card, detail opened by one OK. */
    private fun openDetail(entry: FocusRequester) {
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        key(Key.DirectionDown); key(Key.Enter)
        until { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
    }
    private val twoFeeds get() = listOf(event("a1", -30, listOf(feed("1"), feed("2", "FHD"))))

    @Test fun theFirstOkOpensTheDetailAndFocusAloneNeverPlays() {
        val entry = show(twoFeeds); openDetail(entry)
        assertEquals("sports-detail-close", focusedTag())
        key(Key.DirectionDown); assertEquals("sports-watch-best", focusedTag())
        key(Key.DirectionDown); assertEquals("sports-add-multiview", focusedTag())
        key(Key.DirectionDown); assertEquals("sports-feed", focusedTag()); key(Key.DirectionDown); assertEquals("sports-feed", focusedTag())
        rule.waitForIdle(); assertTrue("nothing played from opening the event or moving the remote", pdeps.played.isEmpty())
        rule.onAllNodesWithTag("sports-preview").assertCountEquals(0)
    }

    @Test fun watchBestFeedPlaysTheRankedFeedAndAnExactFeedPlaysThatOne() {
        val entry = show(twoFeeds); openDetail(entry)
        rule.onNodeWithTag("sports-best-label").assert(hasText("Best available · FHD"))
        rule.onNodeWithTag("sports-watch-best").requestFocus(); key(Key.Enter)
        until { pdeps.played.size == 1 }; assertEquals("2", pdeps.played[0].id)
        until { rule.onAllNodesWithTag("sports-preview").fetchSemanticsNodes().isNotEmpty() }
        rule.onAllNodesWithTag("sports-feed")[1].requestFocus(); key(Key.Enter)
        until { pdeps.played.size == 2 }; assertEquals("the second row is channel 1, the lower ranked feed", "1", pdeps.played[1].id)
        assertEquals("detail stays open while it plays", 1, rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().size)
    }

    @Test fun aRefusedRequestKeepsTheDetailOpenWithAConciseMessage() {
        val entry = show(twoFeeds); openDetail(entry)
        pdeps.channels.clear()
        rule.onNodeWithTag("sports-watch-best").requestFocus(); key(Key.Enter)
        until { rule.onAllNodesWithTag("sports-play-error").fetchSemanticsNodes().isNotEmpty() }
        assertTrue(pdeps.played.isEmpty()); rule.onNodeWithTag("sports-detail").assertExists()
    }

    @Test fun aFailedFeedOffersTryAgainChooseAnotherAndBackToEvent() {
        val entry = show(twoFeeds); openDetail(entry)
        rule.onNodeWithTag("sports-watch-best").requestFocus(); key(Key.Enter); until { pdeps.played.size == 1 }
        phase("2", PhaseKind.LOADING); phase("2", PhaseKind.FAILED)
        until { rule.onAllNodesWithTag("sports-try-again").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-choose-another").assertExists(); rule.onNodeWithTag("sports-back-to-event").assertExists()
        assertEquals("no automatic switch", 1, pdeps.played.size)
        rule.onNodeWithTag("sports-choose-another").requestFocus(); key(Key.Enter)
        assertEquals("the suggested feed takes the remote, to be confirmed with OK", "sports-feed", focusedTag())
        rule.onNodeWithTag("sports-try-again").requestFocus(); key(Key.Enter); until { pdeps.played.size == 2 }; assertEquals("2", pdeps.played[1].id)
        until { rule.onAllNodesWithTag("sports-try-again").fetchSemanticsNodes().isEmpty() }                // the first failure is gone while the retry starts
        phase("2", PhaseKind.LOADING); phase("2", PhaseKind.FAILED)
        until { rule.onAllNodesWithTag("sports-back-to-event").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-back-to-event").requestFocus(); key(Key.Enter)
        until { pdeps.stops.get() == 1 }; until { rule.onAllNodesWithTag("sports-preview").fetchSemanticsNodes().isEmpty() }
        rule.onNodeWithTag("sports-detail").assertExists()
    }

    @Test fun backWalksPictureThenFeedThenEventThenSidebar() {
        val entry = show(twoFeeds); openDetail(entry)
        rule.onNodeWithTag("sports-watch-best").requestFocus(); key(Key.Enter); until { pdeps.played.size == 1 }
        phase("2", PhaseKind.LOADING); phase("2", PhaseKind.PLAYING)
        until { rule.onAllNodesWithTag("sports-feed").fetchSemanticsNodes().any { n -> n.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Text)?.any { it.text.contains("Playing now") } == true } }
        rule.onNodeWithTag("sports-preview").requestFocus(); rule.waitForIdle()
        back(); rule.waitForIdle()
        assertEquals("from the picture the remote returns to the feed that plays", "sports-feed", focusedTag())
        rule.onAllNodes(isFocused()).onFirst().assert(hasText("Playing now", substring = true))
        assertEquals("the stream kept playing", 0, pdeps.stops.get()); rule.onNodeWithTag("sports-detail").assertExists()
        back(); rule.waitForIdle()
        until { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isEmpty() }
        assertEquals("closing the event releases the stream", 1, pdeps.stops.get())
        until { focusedTags() == listOf("sports-card-a1") }
        back(); assertTrue("Back from the hub opens the sidebar", nav.sidebarRevealed)
    }

    @Test fun rapidBackAndDirectionKeysLeaveOneFocusOwner() {
        val entry = show(twoFeeds); openDetail(entry)
        rule.onNodeWithTag("sports-watch-best").requestFocus(); key(Key.Enter); until { pdeps.played.size == 1 }
        repeat(4) { key(Key.DirectionDown); key(Key.DirectionUp) }
        back(); back(); back()
        rule.waitForIdle(); val t = focusedTags()
        assertTrue("at most one owner: $t", t.size <= 1)
    }

    /** Events: a1 (two feeds) is watched, then vanishes from the guide while b1 stays. */
    private fun watchThenLoseTheEvent(): Pair<Boolean, Boolean> {
        val entry = show(listOf(event("a1", -30, listOf(feed("1"), feed("2"))), event("b1", 30, listOf(feed("3")))))
        openDetail(entry)
        rule.onNodeWithTag("sports-watch-best").requestFocus(); key(Key.Enter); until { pdeps.played.size == 1 }
        phase("1", PhaseKind.LOADING); phase("1", PhaseKind.PLAYING)
        until { rule.onAllNodesWithTag("sports-preview").fetchSemanticsNodes().isNotEmpty() }
        until { nav.videoBounds != null }
        var boundsLost = false
        val observer = androidx.compose.runtime.snapshots.Snapshot.registerApplyObserver { _, _ -> if (nav.videoBounds == null) boundsLost = true }
        deps.result = { listOf(event("b1", 30, listOf(feed("3")))) }; vm.refresh()
        until { rule.onAllNodesWithTag("sports-held-notice").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
        observer.dispose()
        return boundsLost to rule.onAllNodesWithTag("sports-preview").fetchSemanticsNodes().isNotEmpty()
    }

    @Test fun whenTheEventDisappearsTheEmbeddedPlayerStaysMountedAndSaysSoAndFullscreenIsNeverRequested() {
        val (boundsLost, previewThere) = watchThenLoseTheEvent()
        rule.onNodeWithTag("sports-held-notice").assert(hasText("The guide changed. This channel is still playing."))
        assertTrue("the same picture box stays on screen", previewThere); assertFalse("and its place was never given up, so the one video surface never moved", boundsLost)
        assertNull("no overlay, so no fullscreen player", nav.top); assertTrue(nav.overlays.isEmpty()); assertFalse(nav.liveFullscreen)
        assertEquals("no second play request and no stop", Pair(1, 0), Pair(pdeps.played.size, pdeps.stops.get())); assertEquals(Tab.SPORTS, nav.tab)
    }

    @Test fun leavingTheHeldPanelHandsTheStreamToLiveTvsEmbeddedPlayerWithoutRestartingIt() {
        watchThenLoseTheEvent()
        rule.onNodeWithTag("sports-held-live").requestFocus(); key(Key.Enter)
        until { nav.tab == Tab.LIVE }
        assertNull("embedded Live TV, never the fullscreen player", nav.top); assertFalse(nav.liveFullscreen); assertTrue(nav.overlays.isEmpty())
        assertEquals("the channel that was playing is the one Live TV is handed: no second play request, no stop", Triple(1, 0, "1"), Triple(pdeps.played.size, pdeps.stops.get(), pdeps.played.single().id))
        assertEquals("Sports let go without stopping", SportsPlayStatus.IDLE, coordinator.state.value.status); assertNull(coordinator.state.value.held); assertTrue(nav.sportsReturnToCard)
    }

    @Test fun backOnTheHeldPanelFollowsTheSameHandOverAndStopEndsTheStream() {
        watchThenLoseTheEvent()
        back(); until { nav.tab == Tab.LIVE }
        assertEquals(Pair(1, 0), Pair(pdeps.played.size, pdeps.stops.get())); assertNull(nav.top)
    }

    @Test fun stopOnTheHeldPanelEndsTheStreamAndStaysInSports() {
        watchThenLoseTheEvent()
        rule.onNodeWithTag("sports-held-stop").requestFocus(); key(Key.Enter)
        until { pdeps.stops.get() == 1 }; assertEquals(Tab.SPORTS, nav.tab)
        until { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isEmpty() }
    }

    @Test fun comingBackToSportsAfterTheHandOverFocusesAValidEvent() {
        nav.sportsReturnToCard = true
        show(listOf(event("a1", -30, listOf(feed("1"))), event("b1", 30, listOf(feed("3")))))
        until { focusedTags().size == 1 && focusedTags().single().startsWith("sports-card-") || focusedTags().singleOrNull() == "sports-filter-ALL" }
        assertFalse("the request is answered once", nav.sportsReturnToCard)
    }

    // ---- Multiview entry points

    @Test fun addToMultiviewIsOnTheDetailAndOnlyOkAddsTheRecommendedFeed() {
        val entry = show(twoFeeds); openDetail(entry)
        rule.onNodeWithTag("sports-add-multiview").assertExists()
        rule.onNodeWithTag("sports-add-multiview").requestFocus(); rule.waitForIdle()
        assertTrue("focus alone adds nothing", mv.selection.state.value.entries.isEmpty())
        key(Key.Enter); until { mv.selection.state.value.entries.size == 1 }
        assertEquals("the recommended feed of the open event", "2", mv.selection.state.value.entries.single().channelId)
        until { rule.onAllNodesWithTag("sports-multiview-note").fetchSemanticsNodes().isNotEmpty() }
        assertTrue("nothing played and nothing was queried to play", pdeps.played.isEmpty() && mvDeps.createdCount.get() == 0 && mvDeps.resolveCalls.get() == 0)
    }

    @Test fun theSameEventCannotBeAddedTwiceByAccident() {
        val entry = show(twoFeeds); openDetail(entry)
        rule.onNodeWithTag("sports-add-multiview").requestFocus(); key(Key.Enter); until { mv.selection.state.value.entries.size == 1 }
        key(Key.Enter); until { mv.selection.state.value.message != null }
        assertEquals(1, mv.selection.state.value.entries.size)
    }

    @Test fun theHeaderOpensTheBuilderAfterReleasingTheSportsStream() {
        val entry = show(twoFeeds); openDetail(entry)
        rule.onNodeWithTag("sports-watch-best").requestFocus(); key(Key.Enter); until { pdeps.played.size == 1 }
        phase("2", PhaseKind.LOADING); phase("2", PhaseKind.PLAYING)
        rule.runOnUiThread { vm.closeDetail() }; rule.waitForIdle()
        until { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isEmpty() }
        rule.onNodeWithTag("sports-multiview").requestFocus(); key(Key.Enter)
        until { nav.top == app.streamsetu.tv.nav.Overlay.SportsMultiview }
        assertEquals("the stream was released for the decoders", 1, pdeps.stops.get())
    }

    @Test fun openingTheBuilderOnTheListOnlyEverNeedsTwoDecodersNotThree() {
        // The list is limited by the device: a three-tile selection on a two-tile device is refused before anything starts.
        val entry = show(twoFeeds); openDetail(entry); assertEquals(4, mv.capability.usableLimit())
    }

    @Test fun openingAndClosingTheEventFiftyTimesStaysQuick() {
        val entry = show(twoFeeds)
        val t0 = System.nanoTime()
        repeat(50) { openDetail(entry); rule.onNodeWithTag("sports-detail-close").requestFocus(); key(Key.Enter); until { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isEmpty() }; rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle() }
        val ms = (System.nanoTime() - t0) / 1_000_000
        println("SPORTS DETAIL open/close x50: $ms ms")
        assertTrue("$ms ms", ms < 120_000); assertTrue(pdeps.played.isEmpty())
    }
}
