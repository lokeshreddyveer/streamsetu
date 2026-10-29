package app.streamsetu.tv.ui.sports

import android.app.AlarmManager
import android.content.Context
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
import app.streamsetu.core.model.Channel
import app.streamsetu.core.net.RecordableFormat
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.record.ScheduledRecordings
import app.streamsetu.tv.sports.recording.*
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
import org.robolectric.Shadows
import org.robolectric.annotation.Config

/** Recording, start over and catch-up on the event screen: the real screen and ViewModel over the real recording service, a real in-memory database and the real scheduled-recording executor. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class SportsRecordingScreenTests {
    @get:Rule val rule = createComposeRule()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val h = 3_600_000L; private val min = 60_000L
    private val now0 = 1_800_000_000_000L + 2 * h
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob() + kotlinx.coroutines.CoroutineExceptionHandler { _, _ -> })
    private lateinit var db: AppDatabase
    private lateinit var deps: FakeSportsDeps
    private lateinit var rdeps: FakeRecordingDeps
    private lateinit var service: SportsRecordingService
    private lateinit var vm: SportsViewModel
    private lateinit var nav: Navigator

    @Before fun setUp() {
        context.getSharedPreferences("scheduled-recordings", Context.MODE_PRIVATE).edit().clear().commit()
        ScheduledRecordings.load(context); ScheduledRecordings.items.value.forEach { ScheduledRecordings.cancel(context, it.id) }
        Shadows.shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms.clear()
        db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).allowMainThreadQueries().build()
        deps = FakeSportsDeps(); rdeps = FakeRecordingDeps(context); rdeps.time = now0
        service = SportsRecordingService(db.sports(), rdeps) { }; service.start(scope)
        nav = Navigator(); nav.base = Base.Shell; nav.tab = Tab.SPORTS
    }
    @After fun stop() { scope.cancel(); db.close() }

    private fun event(id: String, startMin: Long, vararg chans: String, sides: List<String> = listOf("India", "Australia")): SportsEvent {
        chans.forEach { rdeps.auth.channels[it] = Channel(it, "A", "cat", "Channel $it", null, null, "ref-$it", null, catchupDays = 3) }
        return SportsEvent(id, Sport.CRICKET, SportsEventKind.HEAD_TO_HEAD, "Test Series", sides, null, sides.joinToString(" vs "), now0 + startMin * min, now0 + startMin * min + 3 * h,
            chans.map { SportsFeed(it, "A", "Channel $it", null, MetadataSource.UNKNOWN, null, MetadataSource.UNKNOWN, null, it, 0, false) }, 0.95, setOf("A"), "r")
    }

    private fun show(events: List<SportsEvent>): FocusRequester {
        deps.result = { events }; deps.nowMs = now0; deps.tick()
        vm = SportsViewModel(deps, scope, 40L, SportsDiagnostics.Log, null, null, null, null, service)
        val entry = FocusRequester()
        rule.setContent { CompositionLocalProvider(LocalContentEntry provides entry) { SportsScreenHost(vm, nav) { } } }
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("sports-list").fetchSemanticsNodes().isNotEmpty() }; rule.waitForIdle()
        return entry
    }
    private fun key(k: Key) { rule.onAllNodes(isFocused()).onFirst().performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focusedTags() = rule.onAllNodes(isFocused()).fetchSemanticsNodes().map { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag) ?: "?" }
    private fun until(p: () -> Boolean) = rule.waitUntil(5_000, p)
    private fun has(tag: String) = rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
    private fun openDetail(id: String) { rule.runOnUiThread { vm.openDetail(id) }; until { focusedTags() == listOf("sports-detail-close") } }
    private fun <T> run(b: suspend () -> T): T = runBlocking { b() }
    private val rows get() = run { db.sports().recordings("main") }

    @Test fun recordIsOfferedOnlyWhenAFeedCanBeRecordedAndHlsGetsAnHonestHint() {
        val ok = event("a", 120, "1"); val hls = event("b", 150, "2", sides = listOf("X", "Y")); rdeps.formats["2"] = RecordableFormat.HLS
        show(listOf(ok, hls)); openDetail("a"); until { has("sports-record") }; rule.onAllNodesWithTag("sports-record-hint").assertCountEquals(0)
        rule.runOnUiThread { vm.openDetail("b") }; until { has("sports-record-hint") }
        rule.onNodeWithTag("sports-record-hint").assert(hasText("Recording isn't supported for this stream format yet.")); rule.onAllNodesWithTag("sports-record").assertCountEquals(0)
    }

    @Test fun movingTheRemoteOverRecordOrAnArchiveActionAsksNothingAndCreatesNothing() {
        val e = event("a", -60, "1"); rdeps.xtream.add("A"); rdeps.programmes["1"] = e.startMs to e.endMs
        show(listOf(e)); openDetail("a"); until { has("sports-record") && has("sports-start-over") }
        rule.onNodeWithTag("sports-record").requestFocus(); rule.waitForIdle(); rule.onNodeWithTag("sports-start-over").requestFocus(); rule.waitForIdle(); key(Key.DirectionDown); key(Key.DirectionUp)
        assertEquals(0, rows.size); assertTrue(ScheduledRecordings.items.value.isEmpty()); assertTrue("no archive request from focus", rdeps.archivePlays.isEmpty())
    }

    @Test fun confirmingShowsThePreviewThenSchedulesOnceAndTheCardShowsAMark() {
        val e = event("a", 120, "1"); show(listOf(e)); openDetail("a"); until { has("sports-record") }
        rule.onNodeWithTag("sports-record").requestFocus(); key(Key.Enter); until { has("sports-record-panel") }
        rule.onNodeWithTag("sports-record-storage").assert(hasText("estimate", substring = true)); assertTrue(has("sports-record-confirm")); assertEquals("nothing yet", 0, rows.size)
        rule.onNodeWithTag("sports-record-confirm").requestFocus(); key(Key.Enter)
        until { rows.size == 1 && !has("sports-record-panel") }; until { has("sports-recording-line") }
        rule.onNodeWithTag("sports-recording-line").assert(hasText("Recording scheduled", substring = true)); assertEquals(1, ScheduledRecordings.items.value.size)
    }

    @Test fun theCardShowsACompactRecordingMarkAndNothingElse() {
        val e = event("a", 120, "1"); run { service.record(e, null, 0, 0) }
        show(listOf(e)); until { rule.onAllNodesWithTag("sports-recording-mark", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }; rule.onNodeWithTag("sports-recording-mark", useUnmergedTree = true).assert(hasText("Recording scheduled"))
    }

    @Test fun backClosesThePreviewFirstAndCreatesNothing() {
        val e = event("a", 120, "1"); show(listOf(e)); openDetail("a"); until { has("sports-record") }
        rule.onNodeWithTag("sports-record").requestFocus(); key(Key.Enter); until { has("sports-record-panel") }
        rule.runOnUiThread { assertTrue(nav.back()) }; until { !has("sports-record-panel") }; assertEquals(0, rows.size); assertTrue("the event is still open", has("sports-detail"))
    }

    @Test fun aConflictIsExplainedAndCannotBeConfirmed() {
        val a = event("a", 120, "1"); val b = event("b", 150, "2", sides = listOf("X", "Y"))
        run { service.record(a, null, 0, 0) }
        show(listOf(a, b)); openDetail("b"); until { has("sports-record") }
        rule.onNodeWithTag("sports-record").requestFocus(); key(Key.Enter); until { has("sports-record-panel") }
        until { has("sports-record-problem") }; rule.onNodeWithTag("sports-record-problem").assert(hasText("no free connection", substring = true)); rule.onAllNodesWithTag("sports-record-confirm").assertCountEquals(0)
        assertEquals("the first recording is untouched", 1, rows.size)
    }

    @Test fun cancelAndStopNeedAConfirmationAndStopKeepsWhatWasRecorded() {
        val e = event("a", 120, "1"); show(listOf(e)); val id = run { (service.record(e, null, 0, 0) as RecordOutcome.Scheduled).id }
        openDetail("a"); until { has("sports-recording-cancel") }
        rule.onNodeWithTag("sports-recording-cancel").requestFocus(); key(Key.Enter); rule.waitForIdle(); assertEquals("asking is not cancelling", "SCHEDULED", run { db.sports().recording(id)!!.status })
        rule.runOnUiThread { vm.cancelRecording(id) }; until { run { db.sports().recording(id)!!.status } == "CANCELLED" }; assertTrue(ScheduledRecordings.items.value.isEmpty())
    }

    @Test fun aWaitingForReviewRecordingShowsTheReviewActionAndNeverStarts() {
        val a = event("a", 120, "1"); val b = event("b", 300, "1"); val id = run { (service.record(a, null, 0, 0, guide = listOf(a, b)) as RecordOutcome.Scheduled).id }
        val twin = event("c", 125, "1")
        show(listOf(a, twin)); openDetail("a"); until { has("sports-recording-review") }
        rule.onNodeWithTag("sports-recording-line").assert(hasText("Schedule changed — review required")); assertEquals("REVIEW_REQUIRED", run { db.sports().recording(id)!!.status }); assertTrue(ScheduledRecordings.items.value.isEmpty())
    }

    @Test fun startOverStartsTheCatchUpPlaybackAndOpensThePlayerOnlyOnOk() {
        val e = event("a", -60, "1"); rdeps.xtream.add("A"); rdeps.programmes["1"] = e.startMs to e.endMs
        show(listOf(e)); openDetail("a"); until { has("sports-start-over") }
        rule.onNodeWithTag("sports-start-over").requestFocus(); key(Key.Enter)
        until { org.robolectric.shadows.ShadowLooper.idleMainLooper(); nav.top == Overlay.Player }; assertEquals(1, rdeps.archivePlays.size)
    }
}
