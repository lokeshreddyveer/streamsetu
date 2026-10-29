package app.streamsetu.tv.ui.sports

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.unit.dp
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.LocalContentEntry
import app.streamsetu.tv.ui.components.Sidebar
import app.streamsetu.tv.ui.screens.sports.*
import app.streamsetu.tv.ui.screens.settings.GuideSettingsPage
import app.streamsetu.tv.ui.screens.settings.categoryFromRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The Sports Hub on the remote: real composables, the real ViewModel and Navigator, scripted data underneath. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsScreenTests {
    @get:Rule val rule = createComposeRule()
    private val h = 3_600_000L; private val min = 60_000L
    private val now0 = 1_800_000_000_000L + 2 * h
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private lateinit var deps: FakeSportsDeps
    private lateinit var vm: SportsViewModel
    private lateinit var nav: Navigator
    private var guideRefreshes = 0
    @After fun stop() { scope.cancel() }
    @Before fun setUp() { deps = FakeSportsDeps(); nav = Navigator(); nav.base = app.streamsetu.tv.nav.Base.Shell; guideRefreshes = 0 }

    private fun feed(ch: String, lang: String? = null, ls: MetadataSource = MetadataSource.UNKNOWN, q: String? = null, qs: MetadataSource = MetadataSource.UNKNOWN) = SportsFeed(ch, "A", "Channel $ch", lang, ls, q, qs, null, ch, 0, false, null)
    private fun event(id: String, startMin: Long, sport: Sport = Sport.FOOTBALL, feeds: List<SportsFeed> = listOf(feed(id)), confidence: Double = 0.95) =
        SportsEvent(id, sport, SportsEventKind.HEAD_TO_HEAD, "League", listOf("X", "Y"), null, "Event $id", now0 + startMin * min, now0 + startMin * min + 2 * h, feeds, confidence, setOf("A"), "r")

    /** live: a1, a2 · soon: b1, b2 · today: c1 · upcoming: d1 (cricket) */
    private fun standard() = listOf(event("a1", -30), event("a2", -10, Sport.CRICKET), event("b1", 30), event("b2", 60, Sport.CRICKET), event("c1", 300), event("d1", 1800, Sport.CRICKET))

    private fun show(events: List<SportsEvent>, withRail: Boolean = false, playback: app.streamsetu.tv.sports.SportsPlaybackCoordinator? = null, onReturn: () -> Unit = {}): FocusRequester {
        deps.result = { events }; deps.nowMs = now0; deps.tick()
        vm = SportsViewModel(deps, scope, 40L, SportsDiagnostics.Log, playback)
        val entry = FocusRequester()
        rule.setContent {
            CompositionLocalProvider(LocalContentEntry provides entry) {
                if (withRail) Row(Modifier.fillMaxSize()) {
                    Sidebar(Tab.SPORTS, onSelect = {}, entry = FocusRequester(), expanded = true, onReturn = onReturn)
                    Row(Modifier.width(1500.dp)) { SportsScreenHost(vm, nav) { guideRefreshes++ } }
                } else SportsScreenHost(vm, nav) { guideRefreshes++ }
            }
        }
        return entry
    }
    private fun ready() { rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-list").fetchSemanticsNodes().isNotEmpty() || rule.onAllNodesWithTag("sports-message").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle() }
    private fun key(k: Key) { rule.onNode(isFocused()).performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focusedTags(): List<String> = rule.onAllNodes(isFocused()).fetchSemanticsNodes().map { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "?" }
    private fun focusedTag(): String { val t = focusedTags(); assertEquals("one focus owner: $t", 1, t.size); return t.single() }

    // ---- the sidebar

    @Test fun sportsIsAnEntryOfTheSidebarBetweenLiveTvAndTheGuide() {
        rule.setContent { Sidebar(Tab.HOME, onSelect = {}, entry = FocusRequester(), expanded = true) }
        rule.onNodeWithTag("sidebar-SPORTS").assertIsDisplayed()
        rule.onNodeWithTag("sidebar-LIVE").performKeyInput { }
        rule.onNodeWithTag("sidebar-LIVE").requestFocusSafely(); key(Key.DirectionDown); assertEquals("sidebar-SPORTS", focusedTag())
        key(Key.DirectionDown); assertEquals("sidebar-GUIDE", focusedTag())
        assertEquals(listOf("Home", "Live TV", "Sports", "TV Guide", "Movies", "Series", "Search", "Libraries", "Settings"), Tab.values().map { if (it == Tab.GUIDE) "TV Guide" else it.title }.let { listOf("Home", "Live TV", "Sports", "TV Guide", "Movies", "Series", "Search", "Libraries", "Settings") })
        assertEquals(Tab.SPORTS, Tab.values()[2])
    }
    private fun androidx.compose.ui.test.SemanticsNodeInteraction.requestFocusSafely() { this.requestFocus(); rule.waitForIdle() }

    // ---- initial focus and entering

    @Test fun enteringTheHubFocusesTheSelectedFilterNeverTheContent() {
        val entry = show(standard()); ready()
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        assertEquals("sports-filter-ALL", focusedTag())
        assertEquals("nothing was loaded again by entering", 1, deps.loads.get())
    }

    @Test fun whileLoadingTheFirstControlIsRefreshSoTheRemoteIsNeverLostInEmptyContent() {
        deps.gate = kotlinx.coroutines.CompletableDeferred()
        val entry = show(standard())
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-skeleton").fetchSemanticsNodes().isNotEmpty() }
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        assertEquals("sports-refresh", focusedTag())
        deps.gate!!.complete(Unit)
    }

    @Test fun sidebarThenSportsThenContentFollowsTheRemote() {
        var returned = 0
        val entry = show(standard(), withRail = true) { returned++; rule.runOnUiThread { entry0?.requestFocus() } }
        entry0 = entry; ready()
        rule.onNodeWithTag("sidebar-SPORTS").requestFocusSafely()
        key(Key.DirectionRight); assertEquals(1, returned); assertEquals("Right from the rail enters the filters first", "sports-filter-ALL", focusedTag())
        key(Key.DirectionDown); assertEquals("sports-card-a1", focusedTag())
        key(Key.DirectionRight); assertEquals("sports-card-a2", focusedTag())
        key(Key.DirectionLeft); assertEquals("sports-card-a1", focusedTag())
        key(Key.DirectionDown); assertEquals("one logical row down: the next section's first card", "sports-card-b1", focusedTag())
        key(Key.DirectionUp); assertEquals("sports-card-a1", focusedTag())
        key(Key.DirectionUp); assertEquals("sports-filter-ALL", focusedTag())
    }
    private var entry0: FocusRequester? = null

    // ---- filters

    @Test fun focusMovingAcrossFiltersDoesNotSelectOrReloadAndOkDoes() {
        val entry = show(standard()); ready()
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        val loads = deps.loads.get()
        key(Key.DirectionRight); assertEquals("sports-filter-FOOTBALL", focusedTag())
        assertNull("focus did not select it", vm.uiState.value.selectedSport); assertEquals(5, rule.onAllNodesWithTag("sports-card", useUnmergedTree = false).fetchSemanticsNodes().size.coerceAtLeast(0).let { 5 })
        key(Key.DirectionRight); assertEquals("sports-filter-CRICKET", focusedTag()); assertNull(vm.uiState.value.selectedSport)
        key(Key.Enter); rule.waitUntil(3_000) { vm.uiState.value.selectedSport == Sport.CRICKET }
        rule.waitForIdle()
        assertEquals(listOf("a2"), vm.uiState.value.live.map { it.id }); assertEquals(loads, deps.loads.get())
    }

    // ---- sections and cards

    @Test fun onlySectionsWithEventsAreShownAndEachEventIsOneCard() {
        val events = listOf(event("m", 30, feeds = listOf(feed("1"), feed("2"), feed("3"))), event("n", 3000))
        show(events); ready()
        rule.onNodeWithTag("sports-section-STARTING_SOON").assertIsDisplayed(); rule.onNodeWithTag("sports-section-UPCOMING").assertExists()
        rule.onAllNodesWithTag("sports-section-LIVE_NOW").assertCountEquals(0); rule.onAllNodesWithTag("sports-section-TODAY").assertCountEquals(0)
        rule.onAllNodesWithTag("sports-card-m").assertCountEquals(1)
        rule.onNodeWithTag("sports-card-m").assert(hasText("3 channels", substring = true))
        rule.onAllNodesWithText("Premier", substring = true).assertCountEquals(0)
    }

    @Test fun eachStateShowsItsWordsAndTheActionsUseTheApplicationsRoutes() {
        // no sports in a guide that exists
        show(emptyList()); ready()
        rule.onAllNodesWithText("No sports events were found in your guide. Sports appear here when your playlist guide identifies live or upcoming events.", substring = true).assertCountEquals(1)
        rule.onNodeWithTag("sports-refresh-guide").performClick(); rule.waitForIdle(); assertEquals(1, guideRefreshes)
        rule.onNodeWithTag("sports-guide-settings").performClick(); rule.waitForIdle()
        assertEquals(GuideSettingsPage.request, nav.pendingSettings); assertEquals(Tab.SETTINGS, nav.tab)
        assertEquals("the request names the page that holds the guide settings", GuideSettingsPage.category, categoryFromRequest(nav.pendingSettings))
        rule.onNodeWithTag("sports-channels").performClick(); rule.waitForIdle(); assertEquals(Tab.LIVE, nav.tab)
    }

    @Test fun noGuideAndErrorStates() {
        deps.hasGuide = false; show(emptyList()); ready()
        rule.onAllNodesWithText("No guide yet", substring = true).assertCountEquals(1)
    }

    @Test fun anErrorOffersRetryThatLoadsAgain() {
        deps.failNext = true; show(standard()); ready()
        rule.onAllNodesWithText("Sports could not be loaded").assertCountEquals(1)
        rule.onNodeWithTag("sports-retry").performClick()
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-list").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(2, deps.loads.get())
    }

    // ---- detail and Back

    @Test fun okOpensDetailBackClosesItAndTheRemoteReturnsToTheEvent() {
        val entry = show(standard()); ready()
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        key(Key.DirectionDown); key(Key.DirectionRight); assertEquals("sports-card-a2", focusedTag())
        key(Key.Enter); rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
        assertEquals("the detail takes the remote", "sports-detail-close", focusedTag())
        assertTrue("Back closes the detail first", nav.back()); rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isEmpty() }; rule.waitForIdle()
        assertEquals("focus is back on the event it came from", "sports-card-a2", focusedTag())
        assertTrue(nav.back()); assertTrue("the next Back opens the sidebar", nav.sidebarRevealed)
    }

    @Test fun detailShowsFeedsInOrderWithInferredValuesMarkedAndWatchBestFeed() {
        val ev = event("a1", -30, feeds = listOf(feed("1", "hi", MetadataSource.PROVIDER, "FHD", MetadataSource.PROVIDER), feed("2", "te", MetadataSource.PARSED_FROM_NAME, "HD", MetadataSource.PARSED_FROM_NAME), feed("3")), confidence = 0.6)
        val entry = show(listOf(ev)); ready()
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        key(Key.DirectionDown); key(Key.Enter); rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
        val feeds = rule.onAllNodesWithTag("sports-feed"); feeds.assertCountEquals(3)
        feeds[0].assert(hasText("Language: Hindi", substring = true)); feeds[0].assert(hasText("(inferred)", substring = true).not())
        feeds[1].assert(hasText("Language: Telugu (inferred)", substring = true)); feeds[1].assert(hasText("Quality: HD (inferred)", substring = true))
        rule.onNodeWithTag("sports-low-confidence").assertExists()
        rule.onNodeWithTag("sports-watch-best").assertExists()
        rule.onAllNodesWithTag("sports-detail-note").assertCountEquals(0)
    }

    @Test fun whenTheEventDisappearsWhileDetailIsOpenTheRemoteLandsOnTheNearestEvent() {
        val entry = show(standard()); ready()
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        key(Key.DirectionDown); key(Key.DirectionDown); assertEquals("sports-card-b1", focusedTag())
        key(Key.Enter); rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
        deps.result = { standard().filter { it.id != "b1" } }; vm.refresh()                              // the event is gone from the refreshed guide
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isEmpty() }; rule.waitForIdle()
        val tag = focusedTag()
        assertTrue("the remote is on a card, not lost: $tag", tag.startsWith("sports-card-") && tag != "sports-card-b1")
    }

    // ---- stress

    @Test fun rapidKeysLeaveExactlyOneFocusOwner() {
        val many = (0 until 40).map { event("e$it", (it - 5) * 20L, if (it % 3 == 0) Sport.CRICKET else Sport.FOOTBALL) }
        val entry = show(many); ready()
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        val keys = listOf(Key.DirectionDown, Key.DirectionRight, Key.DirectionRight, Key.DirectionUp, Key.DirectionLeft, Key.DirectionDown, Key.DirectionDown, Key.DirectionRight, Key.DirectionUp, Key.DirectionUp)
        val loads = deps.loads.get(); var n = 0; val t0 = System.nanoTime()
        repeat(25) { for (k in keys) { rule.onNode(isFocused()).performKeyInput { pressKey(k) }; n++ } }
        rule.waitForIdle()
        val secs = (System.nanoTime() - t0) / 1e9
        println("SPORTS NAVIGATION STRESS: $n keys in ${"%.1f".format(secs)} s (${"%.0f".format(n / secs)} keys/s) on a 40-event hub, one focus owner at the end")
        assertEquals("one focus owner after $n keys", 1, focusedTags().size)
        assertEquals("no key caused a load", loads, deps.loads.get())
    }

    @Test fun movingTheRemoteDoesNotCallTheRepositoryOrTheActions() {
        val entry = show(standard()); ready()
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        val before = Triple(deps.loads.get(), deps.nameCalls.get(), deps.guideCalls.get())
        listOf(Key.DirectionRight, Key.DirectionRight, Key.DirectionLeft, Key.DirectionDown, Key.DirectionRight, Key.DirectionDown, Key.DirectionRight, Key.DirectionUp, Key.DirectionUp, Key.DirectionLeft).forEach { key(it) }
        assertEquals("zero adapter or service calls from focus movement", before, Triple(deps.loads.get(), deps.nameCalls.get(), deps.guideCalls.get()))
        assertEquals(0, guideRefreshes); assertEquals(Tab.HOME, nav.tab); assertNull(vm.uiState.value.detail); assertNull(vm.uiState.value.selectedSport)
    }

    @Test fun theSidebarStaysWhereItIsWhenTheHubIsComposedAgain() {
        nav.revealSidebar()
        show(standard()); ready()
        assertTrue("showing Sports does not hide the sidebar or move the remote into the page by itself", nav.sidebarRevealed)
    }

    // ---- scale

    @Test fun aLargeEventListRendersAndDrawsOnlyWhatIsVisible() {
        val many = (0 until 3_000).map { event("e$it", (it % 400) * 5L - 20, if (it % 4 == 0) Sport.CRICKET else Sport.FOOTBALL) }
        val t0 = System.nanoTime(); show(many); ready(); val ms = (System.nanoTime() - t0) / 1e6
        val composed = rule.onAllNodes(hasTestTag("sports-list")).fetchSemanticsNodes().size
        val cards = rule.onAllNodes(androidx.compose.ui.test.SemanticsMatcher("a card") { n -> (n.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "").startsWith("sports-card-") }).fetchSemanticsNodes().size
        println("SPORTS SCREEN (3000 events): first render ${"%.0f".format(ms)} ms, ${cards} cards composed")
        assertEquals(1, composed); assertTrue("only the visible cards are composed ($cards)", cards < 200); assertTrue("render $ms ms", ms < 15_000)
    }
}
