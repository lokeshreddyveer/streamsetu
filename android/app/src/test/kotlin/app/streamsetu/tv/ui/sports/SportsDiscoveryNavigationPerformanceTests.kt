package app.streamsetu.tv.ui.sports

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.SportsFollowEntity
import app.streamsetu.core.sports.Sport
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.discovery.*
import app.streamsetu.tv.sports.personal.*
import app.streamsetu.tv.ui.components.LocalContentEntry
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

/** Rapid remote input and repeated openings on a large guide: nothing is loaded, classified or asked of a provider by moving, and memory does not climb. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsDiscoveryNavigationPerformanceTests {
    @get:Rule val rule = createComposeRule()
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob() + kotlinx.coroutines.CoroutineExceptionHandler { _, _ -> })
    private lateinit var db: AppDatabase
    private lateinit var deps: FakeSportsDeps
    private lateinit var rdeps: FakeReminderDeps
    private lateinit var vm: SportsViewModel
    private lateinit var nav: Navigator
    private val events = D.large(700)

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        deps = FakeSportsDeps(); rdeps = FakeReminderDeps(); rdeps.time = D.NOW; deps.nowMs = D.NOW
        nav = Navigator(); nav.base = Base.Shell; nav.tab = Tab.SPORTS
    }
    @After fun stop() { scope.cancel(); db.close() }

    private fun ms(n: Long) = n / 1_000_000.0
    private fun stats(label: String, nanos: List<Long>, size: String) {
        val s = nanos.sorted(); fun p(q: Double) = s[minOf(s.size - 1, (s.size * q).toInt())]
        println(String.format(java.util.Locale.US, "PERF %-46s n=%-4d median=%8.2f ms  p95=%8.2f ms  worst=%8.2f ms  [%s]", label, s.size, ms(p(0.5)), ms(p(0.95)), ms(s.last()), size))
    }
    private fun usedMb(): Long { repeat(3) { System.gc(); Thread.sleep(40) }; val r = Runtime.getRuntime(); return (r.totalMemory() - r.freeMemory()) / (1024 * 1024) }
    private fun has(tag: String) = rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
    private fun until(msg: String = "", p: () -> Boolean) = try { rule.waitUntil(15_000, p) } catch (e: Throwable) { println("DBG timeout $msg tags=" + rule.onAllNodes(androidx.compose.ui.test.SemanticsMatcher("t") { true }).fetchSemanticsNodes().mapNotNull { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) }.take(40)); throw e }
    private fun focusedTags() = rule.onAllNodes(isFocused()).fetchSemanticsNodes().map { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "?" }
    private fun key(k: Key) { rule.onAllNodes(isFocused()).onFirst().performKeyInput { pressKey(k) }; rule.waitForIdle() }

    private fun show(): FocusRequester {
        deps.result = { events }; deps.tick()
        val follows = SportsFollowService(db.sports(), rdeps, rdeps.profileFlow, { }) { D.NOW }
        runBlocking { listOf(D.team(Sport.CRICKET, "Team 7 CRI"), D.team(Sport.FOOTBALL, "Team 14 FOO"), D.comp(Sport.RUGBY, "Comp 5 RUG")).forEach { f -> db.sports().insertFollow(SportsFollowEntity(profileId = "main", kind = f.kind.name, sport = f.sport.name, normKey = f.key, displayName = f.displayName, createdAt = 1)) }
            db.sports().insertFollow(SportsFollowEntity(profileId = "main", kind = "SPORT", sport = "TENNIS", normKey = "tennis", displayName = "Tennis", createdAt = 1)) }
        vm = SportsViewModel(deps, scope, 40L, SportsDiagnostics.Log, null, null, follows, SportsReminderService(db.sports(), rdeps, scope, { }))
        val entry = FocusRequester()
        rule.setContent { CompositionLocalProvider(LocalContentEntry provides entry) { SportsScreenHost(vm, nav) { } } }
        until("show") { has("sports-list") }; rule.waitForIdle()
        return entry
    }

    @Test fun twoHundredFiftyRapidKeysOnTheHubMySportsAndAPageAskNothingOfAnyone() {
        show(); until("my chip") { has("sports-filter-MY") }
        val loads = deps.loads.get(); val hist = deps.historyCalls.get()
        val dirs = listOf(Key.DirectionRight, Key.DirectionRight, Key.DirectionDown, Key.DirectionLeft, Key.DirectionUp, Key.DirectionDown, Key.DirectionRight, Key.DirectionUp)
        var pressed = 0
        val hub = ArrayList<Long>(); val my = ArrayList<Long>(); val page = ArrayList<Long>()
        fun burst(into: MutableList<Long>, count: Int) { repeat(count) { i ->
                        val t = System.nanoTime(); key(dirs[i % dirs.size]); pressed++; into.add(System.nanoTime() - t)
            assertEquals("one thing holds the remote after every key", 1, focusedTags().size) } }
        rule.onNodeWithTag("sports-refresh").requestFocus(); rule.waitForIdle()
        burst(hub, 90)
        rule.runOnUiThread { vm.selectMy() }; until("my board") { vm.uiState.value.board != null && vm.historySettled.get() >= 1 }
        rule.waitForIdle()
        until("my settled") { vm.historySettled.get() >= 1 }; rule.waitForIdle()                // the page's own Catch-Up lookup has answered: what follows is only the remote
        val buildsAtMy = vm.discoveryBuilds.get()
        burst(my, 80)
        assertEquals("moving in My Sports rebuilt nothing", buildsAtMy, vm.discoveryBuilds.get())
        val index = IdentityIndex.build(events)
        val buildsBeforePage = vm.discoveryBuilds.get()
        val ref = events.first { it.sport == Sport.CRICKET }.let { e -> PageRef(PageKind.TEAM, e.sport, index.participants(e).first(), "T") }
        rule.runOnUiThread { vm.openPage(ref) }; until("page") { has("sports-page") }
        until("page settled") { vm.uiState.value.page != null && vm.historySettled.get() >= 2 }; rule.waitForIdle()
        val buildsAtPage = vm.discoveryBuilds.get()
        burst(page, 80)
        assertEquals("moving on a page rebuilt nothing", buildsAtPage, vm.discoveryBuilds.get())
        assertEquals("every key was processed", 250, pressed)
        assertEquals("no page or board was built on the main thread", 0, vm.buildsOnMain.get())
        val last = focusedTags(); assertEquals("one settled focus owner", 1, last.size); assertTrue("a valid target, not nowhere: $last", last.single().let { it.startsWith("sports-") && it != "?" })
        stats("Remote key on the hub (700 events)", hub, "90 keys"); stats("Remote key in My Sports", my, "80 keys"); stats("Remote key on a team page", page, "80 keys")
        assertEquals("moving loaded nothing", loads, deps.loads.get()); assertEquals("moving asked for no Catch-Up", hist, deps.historyCalls.get())
        println("PERF keys: ${hub.size + my.size + page.size} pressed; loads during them: ${deps.loads.get() - loads}; Catch-Up requests during them: ${deps.historyCalls.get() - hist}; provider requests: 0 (Sports has no network path)")
    }

    @Test fun openingAndClosingPagesRepeatedlyDoesNotGrowMemory() {
        show(); until { has("sports-filter-MY") }
        val index = IdentityIndex.build(events)
        val refs = events.take(40).flatMap { e -> index.participants(e).map { PageRef(PageKind.TEAM, e.sport, it, "T") } }.distinct()
        repeat(10) { i -> rule.runOnUiThread { vm.openPage(refs[i % refs.size]) }; until { has("sports-page") }; rule.runOnUiThread { vm.closePage() }; until { !has("sports-page") } }
        val before = usedMb(); val times = ArrayList<Long>()
        repeat(60) { i -> val t = System.nanoTime(); rule.runOnUiThread { vm.openPage(refs[i % refs.size]) }; until { has("sports-page") }; rule.runOnUiThread { vm.closePage() }; until { !has("sports-page") }; times.add(System.nanoTime() - t) }
        val after = usedMb()
        assertEquals("no page was built on the main thread", 0, vm.buildsOnMain.get())
        stats("Open a team page and close it again", times, "700 events, page on screen and gone")
        println("PERF memory heap used before=$before MB after=$after MB across 60 page openings")
        assertTrue("no steady growth ($before -> $after MB)", after - before < 40)
    }
}
