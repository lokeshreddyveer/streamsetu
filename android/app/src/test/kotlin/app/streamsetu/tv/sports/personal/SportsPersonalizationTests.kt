package app.streamsetu.tv.sports.personal

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.SportsReminderEntity
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.ui.screens.sports.SportsSections
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.TimeZone

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SportsPersonalizationTests {
    private val h = 3_600_000L; private val min = 60_000L
    private val now = 1_800_000_000_000L
    private val utc = TimeZone.getTimeZone("UTC")
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private lateinit var db: AppDatabase
    @Before fun open() { db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build() }
    @After fun close() { db.close(); scope.cancel() }

    private fun feed() = SportsFeed("1", "A", "Channel 1", null, MetadataSource.UNKNOWN, null, MetadataSource.UNKNOWN, null, "1", 0L, false)
    private fun event(id: String, startMs: Long, sides: List<String>, sport: Sport = Sport.CRICKET, competition: String? = "League") =
        SportsEvent(id, sport, SportsEventKind.HEAD_TO_HEAD, competition, sides, null, sides.joinToString(" vs "), startMs, startMs + 2 * h, listOf(feed()), 0.95, setOf("A"), "r")
    private val follows = FollowSet(listOf(
        Follow(FollowKind.SPORT, Sport.CRICKET, "cricket", "Cricket"), Follow(FollowKind.COMPETITION, Sport.CRICKET, "v2:competition:cricket:ipl", "IPL"), Follow(FollowKind.PARTICIPANT, Sport.CRICKET, "v2:participant:cricket:india", "India"),
    ))
    private fun ids(l: List<app.streamsetu.tv.ui.screens.sports.SportsEventCard>) = l.map { it.id }
    private fun build(events: List<SportsEvent>, p: Personalization, sel: Sport? = null) = SportsSections.build(events, now, utc, sel, null, emptyMap(), personal = p)

    @Test fun insideASectionRemindedThenSidesThenCompetitionsThenSportsThenTime() {
        val t = now + 5 * h                                                                            // all of them Today, in the same section
        val events = listOf(
            event("none", t, listOf("Brazil", "Chile"), Sport.FOOTBALL, "Cup"), event("sport", t + 1 * min, listOf("Pakistan", "Sri Lanka"), competition = "Other"), event("comp", t + 2 * min, listOf("Pakistan", "Sri Lanka"), competition = "IPL"),
            event("side", t + 3 * min, listOf("India", "Nepal")), event("reminded", t + 4 * min, listOf("Pakistan", "Nepal"), competition = "Other"), event("none2", t + 5 * min, listOf("Italy", "Spain"), Sport.FOOTBALL, "Cup"),
        )
        val r = build(events, Personalization(follows, setOf("reminded")))
        val section = r.today.ifEmpty { r.soon }.ifEmpty { r.upcoming }
        assertEquals(listOf("reminded", "side", "comp", "sport", "none", "none2"), ids(section))
    }

    @Test fun personalizationNeverCrossesSections() {
        val live = event("live", now - h, listOf("Brazil", "Chile"), Sport.FOOTBALL, "Cup"); val remindedLater = event("later", now + 30 * h, listOf("India", "Nepal"))
        val r = build(listOf(remindedLater, live), Personalization(follows, setOf("later")))
        assertEquals(listOf("live"), ids(r.live)); assertEquals(listOf("later"), ids(r.upcoming)); assertTrue("a reminded upcoming event does not jump ahead of a live one", r.today.isEmpty() && r.soon.isEmpty())
    }

    @Test fun theOrderIsStableAndRepeatable() {
        val t = now + 5 * h; val events = (1..20).map { event("e$it", t + (it % 4) * min, listOf("Team $it", "Other $it"), competition = if (it % 3 == 0) "IPL" else "X") }
        val a = ids(build(events, Personalization(follows)).today); val b = ids(build(events.shuffled(java.util.Random(1)), Personalization(follows)).today)
        assertEquals(a, b)
    }

    @Test fun myIsFirstOnlyWithFollowsAndIncludesAnyMatchWithItsReason() {
        val t = now + 5 * h
        val events = listOf(event("a", t, listOf("India", "Nepal")), event("b", t, listOf("Brazil", "Chile"), Sport.FOOTBALL, "Cup"), event("c", t, listOf("Pakistan", "Nepal"), competition = "IPL"))
        assertTrue(build(events, Personalization(FollowSet.NONE)).filters.none { it.my })
        val none = build(events, Personalization(follows)); assertEquals("My Sports is first", true, none.filters.first().my); assertEquals(2, none.filters.first().count)
        val my = build(events, Personalization(follows, mySports = true)); assertTrue(my.my)
        val cards = my.today + my.soon + my.upcoming + my.live
        assertEquals(setOf("a", "c"), cards.map { it.id }.toSet()); assertEquals("Because you follow India", cards.first { it.id == "a" }.reason); assertEquals("Because you follow IPL", cards.first { it.id == "c" }.reason)
        assertTrue("outside My Sports there is no reason text", (build(events, Personalization(follows)).today).all { it.reason == null })
    }

    @Test fun followingChangesTheViewWithoutClassifyingAnythingAgain() {
        val events = listOf(event("a", now + 5 * h, listOf("India", "Nepal")))
        val before = build(events, Personalization(FollowSet.NONE)); val after = build(events, Personalization(follows))
        assertEquals("the same events in the same sections", ids(before.today + before.soon + before.upcoming), ids(after.today + after.soon + after.upcoming))
    }

    // ---- measurements

    private fun bigGuide(n: Int) = (0 until n).map { i -> event("g$i", now + (i % 70) * h + (i % 13) * min, listOf("Team ${i % 400}", "Rival ${(i * 7) % 400}"), Sport.values()[i % Sport.values().size], "Comp ${i % 40}") }

    @Test fun measuredPersonalViewsAndReassociation() = runBlocking {
        val events = bigGuide(5_000)
        val big = FollowSet((0 until 60).map { Follow(FollowKind.PARTICIPANT, Sport.values()[it % Sport.values().size], "team ${it * 3}", "Team ${it * 3}") })
        var t = System.nanoTime(); val r = build(events, Personalization(big, mySports = true)); val myMs = (System.nanoTime() - t) / 1_000_000
        t = System.nanoTime(); build(events, Personalization(FollowSet(big.follows.drop(1)), mySports = true)); val followMs = (System.nanoTime() - t) / 1_000_000
        // 1,000 reminders against the 5,000-event guide: one batch.
        val rows = (0 until 1_000).map { i -> val e = events[i * 5]; SportsReminderEntity("r$i", "main", e.sport.name, SportsKeys.identity(e), SportsKeys.competition(e), SportsKeys.participantsKey(e), e.startMs, e.endMs, 15 * min, SportsKeys.slot(e.startMs), 1, "", null, "", "UNMATCHED", 0, 0, false, 1, 1) }
        t = System.nanoTime(); val assoc = ReminderMatcher.associate(rows.map { it.forMatching() }, events, now + 80 * h); val matchMs = (System.nanoTime() - t) / 1_000_000
        val matched = assoc.count { it is Association.Matched }; val ambiguous = assoc.count { it is Association.Ambiguous }
        println("SPORTS PERSONAL: My Sports over 5,000 events ${myMs} ms (${(r.today + r.soon + r.live + r.upcoming).size} shown), follow change rebuild $followMs ms, 1,000 reminders vs 5,000 events $matchMs ms ($matched matched, $ambiguous ambiguous)")
        assertTrue("My Sports $myMs ms", myMs < 3_000); assertTrue("matching $matchMs ms", matchMs < 3_000); assertTrue(matched > 900)
    }

    @Test fun measuredSchedulingProfileSwitchAndFiftyRefreshes() = runBlocking {
        val d = FakeReminderDeps(); d.time = now
        d.auth.channels["1"] = Channel("1", "A", "cat", "Channel 1", null, null, "ref", null)
        val reports = java.util.Collections.synchronizedList(ArrayList<PersonalReport>())
        val svc = SportsReminderService(db.sports(), d, scope) { reports.add(it) }
        val events = bigGuide(2_000).filter { it.startMs > now + 3 * h }.take(1_000)
        val rows = events.mapIndexed { i, e -> SportsReminderEntity("r$i", "main", e.sport.name, SportsKeys.identity(e), SportsKeys.competition(e), SportsKeys.participantsKey(e), e.startMs, e.endMs, 15 * min, SportsKeys.slot(e.startMs), 1, "", null, "", "UNMATCHED", 0, 0, false, 1, 1) }
        rows.forEach { db.sports().insertReminder(it) }
        var t = System.nanoTime(); svc.reassociate(events); val first = (System.nanoTime() - t) / 1_000_000
        val armsAfterFirst = d.scheduler.arms; val active = d.scheduler.active.size
        t = System.nanoTime(); repeat(50) { svc.reassociate(events) }; val fifty = (System.nanoTime() - t) / 1_000_000
        assertEquals("fifty unchanged refreshes schedule nothing more", armsAfterFirst, d.scheduler.arms); assertEquals(active, d.scheduler.active.size)
        t = System.nanoTime(); d.profileFlow.value = "kid"; svc.securityChanged(); svc.rescheduleAll(); val switchMs = (System.nanoTime() - t) / 1_000_000
        println("SPORTS REMINDERS: first association of ${rows.size} reminders $first ms (${armsAfterFirst} alarms armed, $active active), 50 further refreshes $fifty ms with ${d.scheduler.arms - armsAfterFirst} extra arms, profile switch cleanup $switchMs ms (${d.scheduler.cancels} alarms cancelled, ${d.scheduler.active.size} left)")
        assertEquals("another profile's alarms are all gone", 0, d.scheduler.active.size); assertTrue(switchMs < 5_000)
    }
}
