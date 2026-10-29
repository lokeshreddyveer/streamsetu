package app.streamsetu.tv.ui.sports

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.personal.*
import app.streamsetu.tv.ui.components.BannerActions
import app.streamsetu.tv.ui.components.LocalContentEntry
import app.streamsetu.tv.ui.components.SportsReminderBannerContent
import app.streamsetu.tv.ui.screens.sports.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** My Sports, following, reminders and the management panel on the remote: the real screen and ViewModel, real follow and reminder services on a real in-memory database. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsPersonalScreenTests {
    @get:Rule val rule = createComposeRule()
    private val h = 3_600_000L; private val min = 60_000L
    private val now0 = 1_800_000_000_000L + 2 * h
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob() + kotlinx.coroutines.CoroutineExceptionHandler { _, _ -> })          // work still running when a test ends may meet its closed database; that is not a failure of the next test
    private lateinit var db: AppDatabase
    private lateinit var deps: FakeSportsDeps
    private lateinit var rdeps: FakeReminderDeps
    private lateinit var follows: SportsFollowService
    private lateinit var reminders: SportsReminderService
    private lateinit var vm: SportsViewModel
    private lateinit var nav: Navigator

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        deps = FakeSportsDeps(); rdeps = FakeReminderDeps(); rdeps.time = now0
        rdeps.auth.channels["1"] = Channel("1", "A", "cat", "Channel 1", null, null, "ref", null)
        follows = SportsFollowService(db.sports(), rdeps, rdeps.profileFlow, { }) { now0 }
        reminders = SportsReminderService(db.sports(), rdeps, scope, { })
        nav = Navigator(); nav.base = Base.Shell; nav.tab = Tab.SPORTS
    }
    @After fun stop() { scope.cancel(); db.close() }

    private fun feed(ch: String = "1") = SportsFeed(ch, "A", "Channel $ch", null, MetadataSource.UNKNOWN, null, MetadataSource.UNKNOWN, null, ch, 0, false)
    private fun event(id: String, startMin: Long, sides: List<String> = listOf("India", "Australia"), sport: Sport = Sport.CRICKET, competition: String? = "Test Series") =
        SportsEvent(id, sport, SportsEventKind.HEAD_TO_HEAD, competition, sides, null, sides.joinToString(" vs "), now0 + startMin * min, now0 + startMin * min + 2 * h, listOf(feed()), 0.95, setOf("A"), "r")

    private fun show(events: List<SportsEvent>): FocusRequester {
        deps.result = { events }; deps.nowMs = now0; deps.tick()
        vm = SportsViewModel(deps, scope, 40L, SportsDiagnostics.Log, null, null, follows, reminders)
        val entry = FocusRequester()
        rule.setContent { CompositionLocalProvider(LocalContentEntry provides entry) { SportsScreenHost(vm, nav) { } } }
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-list").fetchSemanticsNodes().isNotEmpty() || rule.onAllNodesWithTag("sports-message").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
        return entry
    }
    private fun key(k: Key) { rule.onAllNodes(isFocused()).onFirst().performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focusedTags() = rule.onAllNodes(isFocused()).fetchSemanticsNodes().map { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "?" }
    private fun until(p: () -> Boolean) = rule.waitUntil(5_000, p)
    private fun <T> run(b: suspend () -> T): T = runBlocking { b() }
    /** Opens the event and waits for the detail to give the remote to Close (it does that by itself, after a frame or two), so a test's own focus request is not undone. */
    private fun openDetail(id: String) { rule.runOnUiThread { vm.openDetail(id) }; until { focusedTags() == listOf("sports-detail-close") } }
    private fun followIndia(e: SportsEvent) = run { follows.follow(e, FollowKind.PARTICIPANT, "India") }
    private val events get() = listOf(event("a", 30), event("b", 60, sides = listOf("Brazil", "Chile"), sport = Sport.FOOTBALL, competition = "Cup"))

    @Test fun myMustAppearFirstOnlyWhenSomethingIsFollowed() {
        show(events)
        rule.onAllNodesWithTag("sports-filter-MY").assertCountEquals(0)
        run { follows.follow(events[0], FollowKind.PARTICIPANT, "India") }
        until { rule.onAllNodesWithTag("sports-filter-MY").fetchSemanticsNodes().isNotEmpty() }
        val my = rule.onNodeWithTag("sports-filter-MY").fetchSemanticsNode().boundsInRoot.left; val all = rule.onNodeWithTag("sports-filter-ALL").fetchSemanticsNode().boundsInRoot.left
        assertTrue("My Sports is the first chip, before All Sports ($my, $all)", my < all)
    }

    @Test fun focusingMyChangesNothingAndOkSelectsItShowingWhyEachEventIsThere() {
        show(events); followIndia(events[0]); until { rule.onAllNodesWithTag("sports-filter-MY").fetchSemanticsNodes().isNotEmpty() }
        val loads = deps.loads.get(); val rows = run { db.sports().follows("main").size }
        rule.onNodeWithTag("sports-filter-MY").requestFocus(); rule.waitForIdle(); key(Key.DirectionRight); key(Key.DirectionLeft)
        rule.onAllNodesWithTag("sports-reason").assertCountEquals(0)
        assertEquals("focus did not query or write", Triple(loads, rows, 0), Triple(deps.loads.get(), run { db.sports().follows("main").size }, run { db.sports().reminders("main").size }))
        key(Key.Enter); until { rule.onAllNodesWithTag("sports-card-a").fetchSemanticsNodes().isNotEmpty() && rule.onAllNodesWithTag("sports-card-b").fetchSemanticsNodes().isEmpty() }
        rule.onNodeWithTag("sports-reason", useUnmergedTree = true).assertExists(); rule.onAllNodes(hasText("Because you follow India", substring = true)).onFirst().assertExists()
        assertEquals("following and choosing My Sports reclassified nothing", loads, deps.loads.get())
    }

    @Test fun whenNothingFollowedIsInTheGuideTheEmptyStateOffersTheWayOn() {
        show(events); run { follows.follow(events[0], FollowKind.SPORT, "Cricket") }; until { rule.onAllNodesWithTag("sports-filter-MY").fetchSemanticsNodes().isNotEmpty() }
        deps.result = { listOf(events[1]) }; rule.runOnUiThread { vm.refresh() }; rule.waitForIdle()
        rule.runOnUiThread { vm.selectMy() }
        until { rule.onAllNodesWithTag("sports-view-all").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-manage-from-empty").assertExists()
        rule.onNodeWithTag("sports-view-all").requestFocus(); key(Key.Enter); until { rule.onAllNodesWithTag("sports-card-b").fetchSemanticsNodes().isNotEmpty() }
    }

    @Test fun followingFromTheDetailSavesOneRecordAndUnfollowRemovesIt() {
        val entry = show(events); rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        openDetail("a")
        rule.onNodeWithTag("sports-follow-PARTICIPANT-india").requestFocus(); rule.waitForIdle()
        assertEquals("focus alone follows nothing", 0, run { db.sports().follows("main").size })
        key(Key.Enter); until { run { db.sports().follows("main").size } == 1 }
        until { rule.onAllNodes(hasText("Following India", substring = true)).fetchSemanticsNodes().isNotEmpty() }
        key(Key.Enter); until { run { db.sports().follows("main").size } == 0 }
    }

    @Test fun remindMeOffersTheLeadTimesAndShowsWhatWasSet() {
        show(events); openDetail("a"); until { rule.onAllNodesWithTag("sports-remind").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-remind").requestFocus(); rule.waitForIdle(); assertEquals("focus alone sets nothing", 0, run { db.sports().reminders("main").size })
        key(Key.Enter)
        for (label in listOf("At start time", "5 minutes before", "15 minutes before", "30 minutes before", "1 hour before")) until { rule.onAllNodes(hasText(label, substring = true)).fetchSemanticsNodes().isNotEmpty() }
        until { rule.onAllNodes(isFocused() and hasText("At start time", substring = true)).fetchSemanticsNodes().isNotEmpty() }        // the menu opens on its first row, and nothing is set yet
        assertEquals(0, run { db.sports().reminders("main").size })
        rule.runOnUiThread { vm.remind(app.streamsetu.tv.sports.personal.ReminderLeads.DEFAULT_MS) }                                  // choosing the default row is exactly this call
        until { run { db.sports().reminders("main").size } == 1 }
        until { rule.onAllNodesWithTag("sports-reminder-set").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-reminder-set").assert(hasText("Reminder set · 15 minutes before", substring = true))
        assertEquals("the alarm is for 15 minutes before the start", 1, rdeps.scheduler.active.size)
        rule.onNodeWithTag("sports-reminder-remove").requestFocus(); key(Key.Enter); until { run { db.sports().reminders("main").size } == 0 }; assertTrue(rdeps.scheduler.active.isEmpty())
    }

    @Test fun manageMySportsListsUnfollowsAndClearsOnlyAfterConfirmation() {
        show(events); run { follows.follow(events[0], FollowKind.SPORT, "Cricket"); follows.follow(events[0], FollowKind.COMPETITION, "Test Series"); follows.follow(events[0], FollowKind.PARTICIPANT, "India") }
        until { rule.onAllNodesWithTag("sports-manage").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-manage").requestFocus(); key(Key.Enter); until { rule.onAllNodesWithTag("sports-manage-panel").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-manage-follow-SPORT-cricket").assertExists(); rule.onNodeWithTag("sports-manage-follow-COMPETITION-test series").assertExists(); rule.onNodeWithTag("sports-manage-follow-PARTICIPANT-india").assertExists()
        rule.onNodeWithTag("sports-manage-follow-PARTICIPANT-india").requestFocus(); key(Key.Enter); until { run { db.sports().follows("main").size } == 2 }
        rule.onNodeWithTag("sports-manage-clear").requestFocus(); key(Key.Enter)
        assertEquals("nothing is cleared until it is confirmed", 2, run { db.sports().follows("main").size })
        rule.runOnUiThread { assertTrue(nav.back()) }; rule.waitForIdle(); assertEquals("Back closed the confirmation, not the panel", 2, run { db.sports().follows("main").size })
    }

    @Test fun backClosesManageFirstAndThenTheSidebarOpens() {
        show(events); run { follows.follow(events[0], FollowKind.SPORT, "Cricket") }
        until { rule.onAllNodesWithTag("sports-manage").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-manage").requestFocus(); key(Key.Enter); until { rule.onAllNodesWithTag("sports-manage-panel").fetchSemanticsNodes().isNotEmpty() }
        rule.runOnUiThread { assertTrue(nav.back()) }; until { rule.onAllNodesWithTag("sports-manage-panel").fetchSemanticsNodes().isEmpty() }
        assertFalse(nav.sidebarRevealed); rule.runOnUiThread { assertTrue(nav.back()) }; assertTrue(nav.sidebarRevealed)
    }

    @Test fun anEventInTheGuideWithAnUnavailableReminderIsOfferedKeepOrRemoveInManage() {
        show(events)
        val id = run { (reminders.create(events[0]) as CreateResult.Created).id }
        run { reminders.reassociate(listOf(events[1])) }                                    // the event left the guide
        run { follows.follow(events[0], FollowKind.SPORT, "Cricket") }
        until { rule.onAllNodesWithTag("sports-manage").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-manage").requestFocus(); key(Key.Enter)
        until { rule.onAllNodesWithTag("sports-manage-reminder-$id").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("sports-manage-reminder-$id").assert(hasText("Schedule unavailable", substring = true))
    }

    @Test fun rapidKeysAcrossTheHubWithMyLeaveOneFocusOwner() {
        val entry = show(events); followIndia(events[0]); until { rule.onAllNodesWithTag("sports-filter-MY").fetchSemanticsNodes().isNotEmpty() }
        rule.runOnUiThread { entry.requestFocus() }; rule.waitForIdle()
        val rnd = java.util.Random(5); val ks = listOf(Key.DirectionUp, Key.DirectionDown, Key.DirectionLeft, Key.DirectionRight)
        repeat(80) { key(ks[rnd.nextInt(4)]); assertTrue(focusedTags().toString(), focusedTags().size <= 1) }
        assertEquals("moving changed no record", 1, run { db.sports().follows("main").size }); assertEquals(0, run { db.sports().reminders("main").size })
    }

    // ---- tapping a reminder always starts from the reminder's id, for the active profile

    @Test fun aReminderOfAnotherProfileOpensNothing() {
        show(events); val id = run { (reminders.create(events[0]) as CreateResult.Created).id }
        rdeps.profileFlow.value = "kid"; rule.runOnUiThread { vm.openReminder(id) }; rule.waitForIdle(); Thread.sleep(150)
        rule.onAllNodesWithTag("sports-detail").assertCountEquals(0)
    }

    @Test fun aReminderWhoseEventIsNoLongerAllowedOpensNothingAndOneThatIsOpensItsEvent() {
        show(events); run { reminders.create(events[0]) }
        val id = run { db.sports().reminders("main").single().id }
        deps.result = { listOf(events[1]) }; rule.runOnUiThread { vm.refresh() }; rule.waitForIdle()            // the event is not among what this profile may see now
        rule.runOnUiThread { vm.openReminder(id) }; rule.waitForIdle(); Thread.sleep(150); rule.onAllNodesWithTag("sports-detail").assertCountEquals(0)
        deps.result = { events }; rule.runOnUiThread { vm.refresh() }; rule.waitForIdle()
        rule.runOnUiThread { vm.openReminder(id) }; until { rule.onAllNodesWithTag("sports-detail").fetchSemanticsNodes().isNotEmpty() }
    }

    @Test fun anUnknownReminderIdOpensNothing() {
        show(events); rule.runOnUiThread { vm.openReminder("not-a-reminder") }; rule.waitForIdle(); Thread.sleep(100); rule.onAllNodesWithTag("sports-detail").assertCountEquals(0)
    }

    // ---- the in-app banner

    private val banner = ReminderBanner("r", "India vs Australia", now0 + 15 * min)

    @Test fun theBannerSaysWhenTheEventStartsAndOffersOpenAndDismiss() {
        val calls = ArrayList<String>()
        rule.setContent { SportsReminderBannerContent(banner, interactive = true, nowMs = now0, actions = BannerActions({ calls += "open" }, { calls += "dismiss" })) }
        rule.onNodeWithTag("sports-banner-text").assert(hasText("India vs Australia starts in 15 minutes"))
        rule.waitForIdle(); assertTrue("it does not take the remote", focusedTags().isEmpty())
        rule.onNodeWithTag("sports-banner-open").requestFocus(); key(Key.Enter); assertEquals(listOf("open"), calls); rule.onNodeWithTag("sports-banner-dismiss").requestFocus(); key(Key.Enter); assertEquals(listOf("open", "dismiss"), calls)
    }

    @Test fun duringPlaybackTheBannerIsAPassiveNoticeThatTakesNoRemote() {
        val calls = ArrayList<String>()
        rule.setContent { SportsReminderBannerContent(banner, interactive = false, nowMs = now0, actions = BannerActions({ calls += "open" }, { calls += "dismiss" })) }
        rule.onNodeWithTag("sports-banner-text").assert(hasText("India vs Australia starts in 15 minutes")); rule.onAllNodesWithTag("sports-banner-open").assertCountEquals(0)
        assertTrue("nothing took the remote", focusedTags().isEmpty())
    }

    @Test fun theBannerAppearingAndGoingNeverMovesTheRemoteFromWhereItWas() {
        for (interactive in listOf(true, false)) {
            val shown = androidx.compose.runtime.mutableStateOf(false)
            rule.setContent {
                androidx.compose.foundation.layout.Column {
                    app.streamsetu.tv.ui.components.TvButton("Unrelated", { }, androidx.compose.ui.Modifier.testTag("unrelated"))
                    if (shown.value) SportsReminderBannerContent(banner, interactive = interactive, nowMs = now0, actions = BannerActions({ }, { }))
                }
            }
            rule.onNodeWithTag("unrelated").requestFocus(); rule.waitForIdle(); assertEquals(listOf("unrelated"), focusedTags())
            rule.runOnUiThread { shown.value = true }; rule.waitForIdle()
            rule.onNodeWithTag("sports-banner-text").assertExists(); assertEquals("it appeared; the remote stayed (interactive=$interactive)", listOf("unrelated"), focusedTags())
            rule.runOnUiThread { shown.value = false }; rule.waitForIdle()
            assertEquals("it went; the remote still stayed", listOf("unrelated"), focusedTags())
            return
        }
    }

    @Test fun aBannerWithNoPermittedTitleNamesNothing() {
        rule.setContent { SportsReminderBannerContent(banner.copy(title = null), interactive = true, nowMs = now0, actions = BannerActions({ }, { })) }
        rule.onNodeWithTag("sports-banner-text").assert(hasText("A sports event you set a reminder for starts in 15 minutes"))
    }
}
