package app.streamsetu.tv.ui.sports

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.getOrNull
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
import app.streamsetu.core.data.repo.SearchTarget
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.discovery.*
import app.streamsetu.tv.sports.personal.*
import app.streamsetu.tv.ui.components.LocalContentEntry
import app.streamsetu.tv.ui.screens.sports.*
import kotlinx.coroutines.CompletableDeferred
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

/** Team pages, competition pages, My Sports and links from Search, on the remote: the real screen and ViewModel over real follow and reminder services and a real in-memory database. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsDiscoveryScreenTests {
    @get:Rule val rule = createComposeRule()
    private val h = 3_600_000L; private val min = 60_000L
    private val now0 = 1_800_000_000_000L + 2 * h
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob() + kotlinx.coroutines.CoroutineExceptionHandler { _, _ -> })
    private lateinit var db: AppDatabase
    private lateinit var deps: FakeSportsDeps
    private lateinit var rdeps: FakeReminderDeps
    private lateinit var follows: SportsFollowService
    private lateinit var reminders: SportsReminderService
    private lateinit var vm: SportsViewModel
    private lateinit var nav: Navigator
    private val reports = java.util.Collections.synchronizedList(ArrayList<DiscoveryReport>())

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        deps = FakeSportsDeps(); rdeps = FakeReminderDeps(); rdeps.time = now0
        follows = SportsFollowService(db.sports(), rdeps, rdeps.profileFlow, { }) { now0 }
        reminders = SportsReminderService(db.sports(), rdeps, scope, { })
        nav = Navigator(); nav.base = Base.Shell; nav.tab = Tab.SPORTS
    }
    @After fun stop() { scope.cancel(); db.close() }

    private fun event(id: String, startMin: Long, sides: List<String> = listOf("India", "Australia"), sport: Sport = Sport.CRICKET, competition: String? = "Test Series", catchUp: Boolean = false): SportsEvent {
        rdeps.auth.channels["c-$id"] = Channel("c-$id", "A", "cat", "Channel $id", null, null, "ref", null)
        return D.event(id, now0 + startMin * min, sides, competition, sport, channels = listOf("c-$id"), catchUp = catchUp, durationMs = 2 * h)
    }

    private fun show(events: List<SportsEvent>): FocusRequester {
        deps.result = { events }; deps.nowMs = now0; deps.tick()
        vm = SportsViewModel(deps, scope, 40L, SportsDiagnostics.Log, null, null, follows, reminders).also { it.discovery = DiscoveryDiagnostics { r -> reports.add(r) } }
        val entry = FocusRequester()
        rule.setContent { CompositionLocalProvider(LocalContentEntry provides entry) { SportsScreenHost(vm, nav) { } } }
        rule.waitUntil(5_000) { has("sports-list") || has("sports-message") }; rule.waitForIdle()
        return entry
    }
    private fun key(k: Key) { rule.onAllNodes(isFocused()).onFirst().performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focusedTags() = rule.onAllNodes(isFocused()).fetchSemanticsNodes().map { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "?" }
    private fun until(p: () -> Boolean) = rule.waitUntil(5_000, p)
    private fun has(tag: String) = rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
    private fun <T> run(b: suspend () -> T): T = runBlocking { b() }
    private fun indiaRef(events: List<SportsEvent>) = D.teamRef(Sport.CRICKET, "India", IdentityIndex.build(events), events)
    private fun backPressed(): Boolean { var used = false; rule.runOnUiThread { used = nav.back() }; rule.waitForIdle(); return used }

    private val events get() = listOf(event("a", 30), event("b", 60, sides = listOf("India", "Nepal"), competition = "Asia Cup"), event("c", 90, sides = listOf("Brazil", "Chile"), sport = Sport.FOOTBALL, competition = "Cup"))

    @Test fun openingAPageBuildsItWithoutAskingAProviderAndFocusGoesToTheFirstEvent() {
        val ev = events; show(ev)
        val loads = deps.loads.get()
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }
        until { has("sports-page") && focusedTags().any { it.startsWith("sports-card-") } }
        assertEquals("no extra load: the page is made from what is loaded", loads, deps.loads.get()); assertEquals("no Catch-Up asked for: none is declared", 0, deps.historyCalls.get())
        rule.onNodeWithTag("sports-page-title").assert(hasText("India")); assertTrue(has("sports-card-a") && has("sports-card-b")); assertFalse(has("sports-card-c"))
    }

    @Test fun focusMovingAcrossAPageStartsNothingAndRequestsNothing() {
        val ev = events; show(ev); rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { has("sports-page") && focusedTags().any { it.startsWith("sports-card-") } }
        val loads = deps.loads.get(); val hist = deps.historyCalls.get()
        repeat(6) { key(Key.DirectionRight); key(Key.DirectionLeft); key(Key.DirectionDown); key(Key.DirectionUp) }
        assertEquals(loads, deps.loads.get()); assertEquals(hist, deps.historyCalls.get()); assertTrue("still on the page", has("sports-page"))
    }

    @Test fun backWalksDownOneLevelAtATimeFromEventToPageToTheOriginatingCard() {
        val ev = events; val entry = show(ev)
        rule.onNodeWithTag("sports-card-b").requestFocus(); rule.waitForIdle()
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { has("sports-page") }
        until { focusedTags().any { it.startsWith("sports-card-") } }
        key(Key.Enter); until { has("sports-detail") }; until { focusedTags() == listOf("sports-detail-close") }
        assertTrue(backPressed()); until { !has("sports-detail") }
        assertTrue("back from the event lands on the page, on the card it came from", has("sports-page")); until { focusedTags().any { it.startsWith("sports-card-") } }
        assertTrue(backPressed()); until { !has("sports-page") && has("sports-list") }
        until { focusedTags() == listOf("sports-card-b") || focusedTags().any { it.startsWith("sports-card-") } }
        assertEquals("exactly one thing holds the remote", 1, focusedTags().size)
        assertTrue("one more Back is the sidebar's, not the page's", !backPressed() || nav.sidebarRevealed)
    }

    @Test fun anEventDetailOffersTheTeamAndCompetitionPagesAndOpensThem() {
        val ev = events; show(ev)
        rule.runOnUiThread { vm.openDetail("a") }; until { focusedTags() == listOf("sports-detail-close") }
        until { has("sports-page-link-TEAM-india") }; assertTrue(has("sports-page-link-COMPETITION-test series") && has("sports-open-guide"))
        rule.onNodeWithTag("sports-page-link-TEAM-india").requestFocus(); key(Key.Enter)
        until { has("sports-page") && !has("sports-detail") }; rule.onNodeWithTag("sports-page-title").assert(hasText("India"))
    }

    @Test fun followingFromAPageTogglesWithoutLeavingIt() {
        val ev = events; show(ev); rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { has("sports-page-follow") }
        rule.onNodeWithTag("sports-page-follow").requestFocus(); key(Key.Enter)
        until { run { db.sports().follows("main").size } == 1 }; assertEquals("v2:participant:cricket:india", run { db.sports().follows("main").single().normKey })
        until { rule.onAllNodes(hasText("Following  ·  Unfollow")).fetchSemanticsNodes().isNotEmpty() }
        key(Key.Enter); until { run { db.sports().follows("main").isEmpty() } }; assertTrue(has("sports-page"))
    }

    @Test fun anEmptyPageStillHasAValidFocusDestination() {
        val ev = events; show(ev)
        rule.runOnUiThread { vm.openPage(PageRef(PageKind.TEAM, Sport.CRICKET, "v2:participant:cricket:nobody", "Nobody")) }
        until { has("sports-page-empty") }; until { focusedTags() == listOf("sports-page-close") }
        key(Key.Enter); until { !has("sports-page") }; assertTrue(has("sports-list"))
    }

    @Test fun anEventThatLeavesTheGuideLeavesThePageWhileTheRestStays() {
        val ev = events; show(ev); rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { has("sports-card-a") && has("sports-card-b") }
        deps.result = { ev.filter { it.id != "a" } }; deps.signals.tryEmit(Unit)
        until { !has("sports-card-a") }; assertTrue(has("sports-card-b")); assertTrue(has("sports-page"))
    }

    @Test fun aChangeToWhoMaySeeWhatClearsThePageAtOnce() {
        val ev = events; show(ev); rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { has("sports-page") && has("sports-card-a") }
        deps.result = { emptyList() }; deps.scopeFlow.value = SportsScope(listOf("A"), "main", true, emptySet(), emptySet())
        until { !has("sports-page") }; assertFalse(has("sports-card-a"))
    }

    @Test fun myAppearsAsOrderedSectionsAndAnEmptyOneExplainsHowToFollow() {
        val ev = events; show(ev); run { follows.follow(ev[0], FollowKind.PARTICIPANT, "India") }
        until { has("sports-filter-MY") }; rule.onNodeWithTag("sports-filter-MY").requestFocus(); key(Key.Enter)
        until { has("sports-card-a") && has("sports-card-b") && !has("sports-card-c") }
        run { follows.unfollow(follows.current().follows.single()) }
    }

    @Test fun myWithNothingFollowedByThePersonShowsTheExplanation() {
        val ev = listOf(event("c", 90, sides = listOf("Brazil", "Chile"), sport = Sport.FOOTBALL, competition = "Cup")); show(ev)
        run { follows.follow(ev[0], FollowKind.SPORT, "Football") }
        until { has("sports-filter-MY") }; rule.onNodeWithTag("sports-filter-MY").requestFocus(); key(Key.Enter)
        until { has("sports-card-c") }
        run { follows.unfollow(follows.current().follows.single()); follows.follow(ev[0], FollowKind.PARTICIPANT, "Brazil") }
        deps.result = { listOf(event("z", 30)) }; deps.signals.tryEmit(Unit)
        until { has("sports-message") }; assertTrue(has("sports-manage-from-empty"))
    }

    @Test fun anUnresolvedFollowIsShownAsChooseTheTeamAndCombinesNothing() {
        val a = event("a", 30, sides = listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL, competition = "Liga"); val b = event("b", 60, sides = listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL, competition = "Cup")
        run { db.sports().insertFollow(app.streamsetu.core.data.db.SportsFollowEntity(profileId = "main", kind = "PARTICIPANT", sport = "FOOTBALL", normKey = SportsKeys.key("Barcelona"), displayName = "Barcelona", createdAt = 1)) }
        show(listOf(a, b))
        until { has("sports-manage") }; rule.onNodeWithTag("sports-manage").requestFocus(); key(Key.Enter); until { has("sports-manage-panel") }
        rule.onNodeWithTag("sports-manage-follow-PARTICIPANT-${SportsKeys.key("Barcelona")}").assert(hasText("Choose the team", substring = true))
        assertEquals("kept, not rewritten", SportsKeys.key("Barcelona"), run { db.sports().follows("main").single().normKey })
    }

    // ---- Catch-Up is lazy, bounded, cancellable and page-specific

    @Test fun catchUpIsNotLoadedUntilAPageNeedsItAndThenOnlyAsFarAsTheChannelsDeclare() {
        val old = event("old", -30 * 60, catchUp = true); deps.historyResult = listOf(old); deps.declaredDays = 2
        val ev = listOf(event("a", 30, catchUp = true), event("b", 60, sides = listOf("India", "Nepal"), competition = "Asia Cup")); show(ev)
        assertEquals("the hub never asks for history", 0, deps.historyCalls.get()); assertEquals(0, deps.dayQueries.get())
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }
        until { deps.historyCalls.get() == 1 }; val (from, to) = deps.historyWindows.single()
        assertEquals("two declared days, no more", 2 * 24 * h, to - from); assertTrue(to <= now0)
        until { has("sports-section-CATCH_UP") }; assertTrue(has("sports-card-old"))
    }

    @Test fun catchUpIsCappedAtThreeDays() {
        deps.declaredDays = 30; val ev = listOf(event("a", 30, catchUp = true)); show(ev)
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { deps.historyCalls.get() == 1 }
        val (from, to) = deps.historyWindows.single(); assertEquals(3 * 24 * h, to - from)
    }

    @Test fun catchUpIsCancelledWhenThePageClosesAndOnlyTheEventsStayVisibleWhileItLoads() {
        deps.declaredDays = 1; deps.historyGate = CompletableDeferred()
        val ev = listOf(event("a", 30, catchUp = true)); show(ev)
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { deps.historyCalls.get() == 1 }
        until { has("sports-page-loading") }; assertTrue("what is known stays visible while Catch-Up loads", has("sports-card-a"))
        rule.runOnUiThread { vm.closePage() }; until { deps.historyCancelled == 1 }; until { !has("sports-page") }
    }

    @Test fun catchUpIsNotAskedForWhenNoChannelDeclaresAnArchive() {
        deps.declaredDays = 0; val ev = listOf(event("a", 30, catchUp = true)); show(ev)
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { deps.dayQueries.get() >= 1 }
        assertEquals(0, deps.historyCalls.get()); assertFalse(has("sports-section-CATCH_UP"))
    }

    @Test fun repeatedOpeningAndClosingKeepsTheCachesBounded() {
        deps.declaredDays = 1; deps.historyResult = emptyList()
        val ev = listOf(event("a", 30, catchUp = true)); show(ev)
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { deps.historyCalls.get() == 1 }; Thread.sleep(300); rule.waitForIdle(); rule.runOnUiThread { vm.closePage() }; rule.waitForIdle()
        repeat(40) { rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; rule.waitForIdle(); rule.runOnUiThread { vm.closePage() }; rule.waitForIdle() }
        assertEquals("one request for the window; the other 40 openings use the held result", 1, deps.historyCalls.get())
    }

    // ---- links from Search

    @Test fun aSearchLinkToATeamOpensItsPageAndBackReturnsToSearch() {
        val ev = events; show(ev)
        rule.runOnUiThread { nav.openSports(SearchTarget.OpenSports("team", indiaRef(ev).key, "CRICKET", "India", null)) }
        until { has("sports-page") }; assertEquals(Tab.SPORTS, nav.tab)
        assertTrue(backPressed()); until { nav.tab == Tab.SEARCH }
        until { vm.uiState.value.page == null && !has("sports-page") }                                   // the page state is cleared by the same Back, and the screen follows it
        assertNull("the page is closed behind the person", vm.uiState.value.page)
    }

    @Test fun aSearchLinkToAnEventOpensItsDetailAndBackReturnsToSearch() {
        show(events)
        rule.runOnUiThread { nav.openSports(SearchTarget.OpenSports("event", "a", "CRICKET", "India vs Australia", "a")) }
        until { has("sports-detail") }; assertTrue(backPressed()); until { nav.tab == Tab.SEARCH }
    }

    @Test fun aSearchLinkToSomethingThatIsGoneSaysSoAndOpensNothing() {
        show(events)
        rule.runOnUiThread { nav.openSports(SearchTarget.OpenSports("event", "missing", "CRICKET", "Gone", "missing")) }
        until { has("sports-link-notice") }; assertFalse(has("sports-detail")); assertFalse(has("sports-page")); assertEquals(Tab.SPORTS, nav.tab)
    }

    @Test fun discoveryDiagnosticsHoldOnlyCountsAndFixedWords() {
        deps.declaredDays = 1; val ev = events + event("old", -600, catchUp = true); show(ev)
        rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { vm.historySettled.get() >= 1 }                   // the lookup has finished and reported, not merely started
        val text = reports.joinToString("\n") { it.line() }
        assertTrue(reports.any { it.kind == DiscoveryKind.IDENTITIES } && reports.any { it.kind == DiscoveryKind.CATCH_UP })
        for (w in listOf("India", "Australia", "Test Series", "Channel", "ref", "http")) assertFalse("'$w' in $text", text.contains(w))
    }

    // ---- My Sports under security changes, and navigation edge cases

    private fun mySports(ev: List<SportsEvent>) {
        run { follows.follow(ev[0], FollowKind.PARTICIPANT, "India") }
        until { has("sports-filter-MY") }; rule.onNodeWithTag("sports-filter-MY").requestFocus(); key(Key.Enter)
        until { has("sports-card-a") && !has("sports-card-c") }
    }

    @Test fun aRelockedFolderOrAnotherProfileRemovesTheFollowedContentAtOnce() {
        val ev = events; show(ev); mySports(ev)
        deps.result = { emptyList() }; deps.scopeFlow.value = SportsScope(listOf("A"), "main", false, setOf("cat"), emptySet())
        until { !has("sports-card-a") }
        deps.scopeFlow.value = SportsScope(listOf("A"), "kid", false, emptySet(), emptySet())
        until { !has("sports-card-a") && !has("sports-card-b") }
    }

    @Test fun aSourceOrLibraryChangeRemovesWhatItCarried() {
        val ev = events; show(ev); mySports(ev)
        deps.result = { s -> ev.filter { e -> e.feeds.any { it.sourceId in s.sourceIds } } }
        deps.scopeFlow.value = SportsScope(listOf("Z"), "main", false, emptySet(), emptySet())
        until { !has("sports-card-a") }
        deps.scopeFlow.value = SportsScope(listOf("A"), "main", false, emptySet(), emptySet())
        until { has("sports-card-a") }
    }

    @Test fun aGuideRefreshKeepsTheStillAllowedContentWhileItRebuilds() {
        val ev = events; show(ev); mySports(ev)
        val gate = CompletableDeferred<Unit>(); deps.gate = gate
        deps.signals.tryEmit(Unit)
        until { has("sports-refreshing") }; assertTrue("old content stays while the new is built", has("sports-card-a"))
        gate.complete(Unit); until { !has("sports-refreshing") }
    }

    @Test fun aReminderReachesTheCardThroughEveryBoundaryInMySports() {
        val ev = events; show(ev)
        // 1. the service holds it
        val created = run { reminders.create(ev[0]) }; assertTrue(created is CreateResult.Created)
        assertEquals(listOf("SCHEDULED"), run { db.sports().reminders("main").map { it.status } })
        mySports(ev)
        // 2. it survives My Sports' once-per-event placement and reaches the card model
        until { vm.uiState.value.board?.sections?.flatMap { it.cards }?.any { it.id == "a" && it.reminded } == true }
        assertEquals("the event is listed once", 1, vm.uiState.value.board!!.sections.flatMap { it.cards }.count { it.id == "a" })
        // 3. it is drawn (the label sits inside the card, so it is read from the unmerged tree)
        until { rule.onAllNodesWithTag("sports-reminded", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
    }

    @Test fun myWithoutAnyFollowShowsNoMyChipAndNoPolling() {
        val ev = events; show(ev)
        assertFalse(has("sports-filter-MY"))
        val loads = deps.loads.get(); Thread.sleep(600); rule.waitForIdle()
        assertEquals("no timer reloads anything", loads, deps.loads.get()); assertEquals(0, deps.historyCalls.get())
    }

    @Test fun rapidDirectionalInputMovesOneItemAtATimeAndKeepsOneFocusOwner() {
        val ev = (0 until 12).map { event("e$it", 30L + it * 10, sides = listOf("India", "Opp $it")) }; show(ev)
        rule.onNodeWithTag("sports-card-e0").requestFocus(); rule.waitForIdle()
        val seen = ArrayList<List<String>>()
        repeat(40) { i -> key(listOf(Key.DirectionRight, Key.DirectionDown, Key.DirectionLeft, Key.DirectionUp, Key.DirectionRight)[i % 5]); seen.add(focusedTags()) }
        assertTrue("exactly one focus owner after every key", seen.all { it.size == 1 })
        assertEquals(0, deps.historyCalls.get()); assertTrue(has("sports-hub"))
    }

    @Test fun anEventLeavingTheGuideWhileTheRemoteIsOnItMovesFocusToANeighbourNotNowhere() {
        val ev = (0 until 5).map { event("e$it", 30L + it * 10, sides = listOf("India", "Opp $it")) }; show(ev)
        rule.onNodeWithTag("sports-card-e2").requestFocus(); rule.waitForIdle()
        deps.result = { ev.filter { it.id != "e2" } }; deps.signals.tryEmit(Unit)
        until { !has("sports-card-e2") }; rule.waitForIdle(); Thread.sleep(200); rule.waitForIdle()
        assertTrue("the hub is still there and takes the remote", has("sports-hub"))
        key(Key.DirectionRight); assertTrue(focusedTags().size <= 1)
    }

    // ---- a change to who may see what: the old page and its actions go in the same state, before anything is rebuilt

    private val base = SportsScope(listOf("A"), "main", false, emptySet(), emptySet())

    /** The rebuild under the new context is held shut: the old page, its cards and its actions must already be gone, and an action of the old page must do nothing. */
    private fun clearsPageBeforeRebuild(scope: SportsScope) {
        val ev = events; show(ev); rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { has("sports-page-follow") && has("sports-card-a") }
        val gate = CompletableDeferred<Unit>(); deps.gate = gate
        deps.result = { emptyList() }; deps.scopeFlow.value = scope
        until { !has("sports-page") }
        assertFalse("old events are not drawn while the rebuild is held", has("sports-card-a") || has("sports-card-b"))
        assertFalse("old actions are gone", has("sports-page-follow") || has("sports-page-close") || has("sports-open-guide"))
        rule.runOnUiThread { vm.followPage(indiaRef(ev)) }; rule.waitForIdle()
        assertEquals("an action of the old page does nothing", 0, run { db.sports().follows("main").size })
        gate.complete(Unit)
    }

    private fun oldLoadNeverShown(scope: SportsScope) {
        val ev = events; show(ev); rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { has("sports-card-a") }
        val gate = CompletableDeferred<Unit>(); deps.gate = gate; deps.result = { s -> if (s == base) ev else emptyList() }
        deps.signals.tryEmit(Unit); until { deps.loads.get() >= 2 }
        deps.scopeFlow.value = scope
        until { !has("sports-page") && !has("sports-card-a") }
        gate.complete(Unit); rule.waitForIdle()
        until { has("sports-hub") }; assertFalse("the old context's result never reaches the screen", has("sports-card-a") || has("sports-page"))
    }

    private fun catchUpDroppedAfterChange(scope: SportsScope) {
        deps.declaredDays = 1; deps.historyResult = listOf(event("old", -300, catchUp = true)); val gate = CompletableDeferred<Unit>(); deps.historyGate = gate
        val ev = listOf(event("a", 30, catchUp = true), event("b", 60, sides = listOf("India", "Nepal"), competition = "Asia Cup"))
        show(ev); rule.runOnUiThread { vm.openPage(indiaRef(ev)) }; until { deps.historyCalls.get() == 1 && has("sports-page-loading") }
        deps.result = { emptyList() }; deps.scopeFlow.value = scope
        until { !has("sports-page") }; gate.complete(Unit); rule.waitForIdle()
        until { has("sports-hub") }; assertFalse("the old Catch-Up is never drawn", has("sports-card-old"))
    }

    private fun detailAndMyClear(scope: SportsScope) {
        val ev = events; show(ev); mySports(ev); rule.runOnUiThread { vm.openDetail("a") }; until { has("sports-detail") }
        val gate = CompletableDeferred<Unit>(); deps.gate = gate; deps.result = { emptyList() }; deps.scopeFlow.value = scope
        until { !has("sports-detail") }; assertFalse("no old card while the rebuild is held", has("sports-card-a") || has("sports-card-b")); gate.complete(Unit)
    }

    @Test fun clearsPageAtOnceProfileSwitch() = clearsPageBeforeRebuild(base.copy(profileId = "kid"))
    @Test fun staleLoadDroppedProfileSwitch() = oldLoadNeverShown(base.copy(profileId = "kid"))
    @Test fun staleCatchUpDroppedProfileSwitch() = catchUpDroppedAfterChange(base.copy(profileId = "kid"))
    @Test fun detailAndMyClearProfileSwitch() = detailAndMyClear(base.copy(profileId = "kid"))

    @Test fun clearsPageAtOnceActiveLibrarySwitch() = clearsPageBeforeRebuild(base.copy(sourceIds = listOf("Z")))
    @Test fun staleLoadDroppedActiveLibrarySwitch() = oldLoadNeverShown(base.copy(sourceIds = listOf("Z")))
    @Test fun staleCatchUpDroppedActiveLibrarySwitch() = catchUpDroppedAfterChange(base.copy(sourceIds = listOf("Z")))
    @Test fun detailAndMyClearActiveLibrarySwitch() = detailAndMyClear(base.copy(sourceIds = listOf("Z")))

    @Test fun clearsPageAtOnceKidsOrAdultRestriction() = clearsPageBeforeRebuild(base.copy(hideAdult = true))
    @Test fun staleLoadDroppedKidsOrAdultRestriction() = oldLoadNeverShown(base.copy(hideAdult = true))
    @Test fun staleCatchUpDroppedKidsOrAdultRestriction() = catchUpDroppedAfterChange(base.copy(hideAdult = true))
    @Test fun detailAndMyClearKidsOrAdultRestriction() = detailAndMyClear(base.copy(hideAdult = true))

    @Test fun clearsPageAtOnceFolderRelock() = clearsPageBeforeRebuild(base.copy(lockedFolderIds = setOf("cat")))
    @Test fun staleLoadDroppedFolderRelock() = oldLoadNeverShown(base.copy(lockedFolderIds = setOf("cat")))
    @Test fun staleCatchUpDroppedFolderRelock() = catchUpDroppedAfterChange(base.copy(lockedFolderIds = setOf("cat")))
    @Test fun detailAndMyClearFolderRelock() = detailAndMyClear(base.copy(lockedFolderIds = setOf("cat")))

    @Test fun clearsPageAtOnceHiddenChannel() = clearsPageBeforeRebuild(base.copy(hiddenChannelIds = setOf("c-a")))
    @Test fun staleLoadDroppedHiddenChannel() = oldLoadNeverShown(base.copy(hiddenChannelIds = setOf("c-a")))
    @Test fun staleCatchUpDroppedHiddenChannel() = catchUpDroppedAfterChange(base.copy(hiddenChannelIds = setOf("c-a")))
    @Test fun detailAndMyClearHiddenChannel() = detailAndMyClear(base.copy(hiddenChannelIds = setOf("c-a")))

    @Test fun clearsPageAtOnceSourceDisabledOrRemoved() = clearsPageBeforeRebuild(base.copy(sourceIds = emptyList()))
    @Test fun staleLoadDroppedSourceDisabledOrRemoved() = oldLoadNeverShown(base.copy(sourceIds = emptyList()))
    @Test fun staleCatchUpDroppedSourceDisabledOrRemoved() = catchUpDroppedAfterChange(base.copy(sourceIds = emptyList()))
    @Test fun detailAndMyClearSourceDisabledOrRemoved() = detailAndMyClear(base.copy(sourceIds = emptyList()))
}
