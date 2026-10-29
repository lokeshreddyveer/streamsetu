package app.streamsetu.tv.sports.personal

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.sports.FakePlaybackDeps
import app.streamsetu.tv.sports.SportsAuthorization
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

class FakeScheduler : ReminderScheduler {
    val active = java.util.Collections.synchronizedMap(HashMap<String, Long>())
    @Volatile var arms = 0; @Volatile var cancels = 0
    override fun arm(id: String, atMs: Long) { arms++; active[id] = atMs }
    override fun cancel(id: String) { cancels++; active.remove(id) }
}

class FakeNotifier : ReminderNotifier {
    @Volatile var state = NotificationState.NOT_ASKED
    @Volatile var asked = 0
    @Volatile var grantOnAsk = true
    val posts = java.util.Collections.synchronizedList(ArrayList<Triple<String, String, Long>>())
    override fun permission() = state
    override fun requestPermission() { asked++; state = if (grantOnAsk) NotificationState.GRANTED else NotificationState.DENIED }
    override fun post(id: String, title: String, startMs: Long): Boolean { if (state == NotificationState.DENIED) return false; posts.add(Triple(id, title, startMs)); return true }
    override fun cancel(id: String) {}
}

class FakeReminderDeps(val auth: FakePlaybackDeps = FakePlaybackDeps()) : ReminderDeps, SportsAuthorization by auth {
    val profileFlow = MutableStateFlow("main")
    override val profileId: String get() = profileFlow.value
    override val activeProfile: StateFlow<String> get() = profileFlow
    @Volatile var time = 1_800_000_000_000L
    override fun nowMs() = time
    @Volatile var live: List<SportsEvent> = emptyList()
    override suspend fun events(fromMs: Long, toMs: Long) = live
    override val scheduler = FakeScheduler()
    override val notifier = FakeNotifier()
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SportsPersonalTests {
    private lateinit var db: AppDatabase
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val h = 3_600_000L; private val min = 60_000L
    private lateinit var d: FakeReminderDeps
    private lateinit var reports: MutableList<PersonalReport>
    private lateinit var follows: SportsFollowService
    private lateinit var reminders: SportsReminderService
    private val t0 = 1_800_000_000_000L

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        d = FakeReminderDeps(); d.time = t0
        for (c in listOf("1", "2", "3")) d.auth.channels[c] = Channel(c, "A", "cat", "Channel $c", null, null, "http://u:SECRET@h.example/$c", null)
        reports = java.util.Collections.synchronizedList(ArrayList())
        follows = SportsFollowService(db.sports(), d, d.profileFlow, { reports.add(it) }) { d.time }
        reminders = SportsReminderService(db.sports(), d, scope, { reports.add(it) })
    }
    @After fun close() { db.close(); scope.cancel() }

    private fun feed(ch: String) = SportsFeed(ch, "A", "Channel $ch", null, MetadataSource.UNKNOWN, null, MetadataSource.UNKNOWN, null, ch, 0L, false)
    private fun event(id: String, start: Long, sides: List<String> = listOf("India", "Australia"), competition: String? = "Test Series", sport: Sport = Sport.CRICKET, confidence: Double = 0.95, channels: List<String> = listOf("1"), title: String = sides.joinToString(" vs ")) =
        SportsEvent(id, sport, SportsEventKind.HEAD_TO_HEAD, competition, sides, null, title, start, start + 3 * h, channels.map(::feed), confidence, setOf("A"), "r")
    private fun <T> run(b: suspend () -> T): T = runBlocking { b() }

    // ---- matching

    private fun reminder(e: SportsEvent, lead: Long = 15 * min) = SportsEventReminder("r", SportsKeys.identity(e), SportsKeys.competition(e), e.startMs)
    private fun match(r: SportsEventReminder, events: List<SportsEvent>) = ReminderMatcher.associate(listOf(r), events, t0 + 72 * h).single()

    @Test fun theTemporaryEventIdPlaysNoPartInIdentity() {
        val a = event("id-one", t0 + 2 * h); val b = event("id-two", t0 + 2 * h + 10 * min, channels = listOf("2", "3"))
        assertEquals(SportsKeys.identity(a), SportsKeys.identity(b)); assertTrue(match(reminder(a), listOf(b)) is Association.Matched)
    }

    @Test fun aCorrectedStartAcrossUtcOrLocalMidnightIsStillThatEvent() {
        val day = (t0 / 86_400_000L + 1) * 86_400_000L                                   // a UTC midnight
        val before = event("a", day - 10 * min); val moved = event("b", day + 20 * min)
        val m = match(reminder(before), listOf(moved)); assertTrue(m is Association.Matched); assertEquals(day + 20 * min, (m as Association.Matched).event.startMs)
    }

    @Test fun twoFixturesOfTheSameSidesInOneDayStayApart() {
        val early = event("e", t0 + 1 * h); val late = event("l", t0 + 8 * h)
        assertEquals("e", ((match(reminder(early), listOf(early, late))) as Association.Matched).event.id)
        assertEquals("l", ((match(reminder(late), listOf(early, late))) as Association.Matched).event.id)
        assertTrue("a time that is near neither is not guessed", match(SportsEventReminder("r", SportsKeys.identity(early), SportsKeys.competition(early), t0 + 4 * h + 30 * min), listOf(early, late)) !is Association.Matched)
        val a = event("a", t0 + 1 * h); val b = event("b", t0 + 4 * h)
        assertTrue("a time that fits both equally is ambiguous", match(SportsEventReminder("r", SportsKeys.identity(a), SportsKeys.competition(a), t0 + 2 * h + 30 * min), listOf(a, b)) is Association.Ambiguous)
    }

    @Test fun aDifferentCompetitionNeverMatches() {
        val a = event("a", t0 + h, competition = "Test Series"); val other = event("b", t0 + h, competition = "World Cup")
        assertTrue(match(reminder(a), listOf(other)) is Association.Unmatched)
        assertTrue("an unknown competition on the new event is compatible", match(reminder(a), listOf(event("c", t0 + h, competition = null))) is Association.Matched)
    }

    @Test fun aLowConfidenceOrCrowdedMatchIsNeverAssociatedSilently() {
        val a = event("a", t0 + h)
        assertTrue(match(reminder(a), listOf(event("w", t0 + h, confidence = 0.5))) is Association.Ambiguous)
        assertTrue(match(reminder(a), listOf(event("x", t0 + h), event("y", t0 + h + 20 * min))) is Association.Ambiguous)
    }

    @Test fun anEventThatLeavesAndReturnsIsFoundAgain() {
        val a = event("a", t0 + h); val r = reminder(a)
        assertTrue(match(r, emptyList()) is Association.Unmatched)
        assertTrue(match(r, listOf(event("zz", t0 + h + 5 * min))) is Association.Matched)
        assertTrue("moved by more than the tolerance", match(r, listOf(event("far", t0 + h + 5 * h))) is Association.Unmatched)
    }

    @Test fun aReminderBeyondTheLoadedGuideIsLeftAlone() {
        val a = event("a", t0 + 100 * h); assertTrue(ReminderMatcher.associate(listOf(reminder(a)), emptyList(), t0 + 72 * h).single() is Association.NotYet)
    }

    // ---- timing

    @Test fun theTimingRules() {
        val s = t0 + h; val e = s + 3 * h
        assertEquals(ReminderPlan.Arm(s - 15 * min), ReminderTiming.plan(s, e, 15 * min, 0, t0))
        assertEquals(ReminderPlan.Arm(s), ReminderTiming.plan(s, e, 0, 0, t0))
        assertEquals("the lead time passed but the event has not started: once, now", ReminderPlan.NotifyNow, ReminderTiming.plan(s, e, 15 * min, 0, s - 5 * min))
        assertEquals("started: not announced late", ReminderPlan.Done(ReminderStatus.MISSED), ReminderTiming.plan(s, e, 15 * min, 0, s + min))
        assertEquals("over: never", ReminderPlan.Done(ReminderStatus.ENDED), ReminderTiming.plan(s, e, 15 * min, 0, e))
        assertEquals("already announced", ReminderPlan.Done(ReminderStatus.FIRED), ReminderTiming.plan(s, e, 15 * min, t0, t0 + 10))
        assertEquals("Reminder set · 15 minutes before", ReminderLeads.setText(15 * min)); assertEquals("Reminder set · at start time", ReminderLeads.setText(0)); assertEquals("1 hour before", ReminderLeads.label(60 * min))
    }

    // ---- follows

    @Test fun everyKindCanBeFollowedAndUnfollowedAndNormalizedDuplicatesCollapse() = run {
        val e = event("e", t0 + h, sides = listOf("India", "FC Australia"), competition = "Premier League")
        assertEquals(FollowResult.Followed, follows.follow(e, FollowKind.SPORT, "Cricket")); assertEquals(FollowResult.Followed, follows.follow(e, FollowKind.COMPETITION, "Premier League")); assertEquals(FollowResult.Followed, follows.follow(e, FollowKind.PARTICIPANT, "India"))
        assertEquals(FollowResult.Followed, follows.follow(e, FollowKind.PARTICIPANT, "FC Australia"))
        assertEquals("the same normalized name is one follow", FollowResult.AlreadyFollowing, follows.follow(e, FollowKind.PARTICIPANT, "australia")); assertEquals(FollowResult.AlreadyFollowing, follows.follow(e, FollowKind.COMPETITION, "premier league"))
        val set = follows.current()
        assertEquals(4, set.follows.size); assertEquals("the name as first chosen is kept", "FC Australia", set.follows.first { it.key == "australia" }.displayName)
        follows.unfollow(set.follows.first { it.kind == FollowKind.COMPETITION }); assertEquals(3, follows.current().follows.size)
        follows.clear(); assertTrue(follows.current().isEmpty)
    }

    @Test fun aNameThatIsNotPartOfTheEventIsNotSaved() = run {
        val e = event("e", t0 + h)
        assertEquals(FollowResult.Refused, follows.follow(e, FollowKind.PARTICIPANT, "Brazil")); assertEquals(FollowResult.Refused, follows.follow(e, FollowKind.COMPETITION, "Other Cup")); assertTrue(follows.current().isEmpty)
    }

    @Test fun followsAreCheckedAgainstWhatTheProfileMaySeeBeforeTheyAreSaved() = run {
        val e = event("e", t0 + h)
        d.auth.lockedCategories.add("cat")                                                // the folder was relocked after this detail was drawn
        assertEquals(FollowResult.Refused, follows.follow(e, FollowKind.PARTICIPANT, "India")); assertTrue(follows.current().isEmpty)
        d.auth.lockedCategories.clear(); d.auth.hiddenChannels.add("1"); assertEquals(FollowResult.Refused, follows.follow(e, FollowKind.SPORT, "Cricket"))
        d.auth.hiddenChannels.clear(); d.auth.adultFilter = true; d.auth.adultCategories.add("cat"); assertEquals(FollowResult.Refused, follows.follow(e, FollowKind.SPORT, "Cricket"))
    }

    @Test fun profilesNeverShareFollowsOrReminders() = run {
        val e = event("e", t0 + h)
        follows.follow(e, FollowKind.PARTICIPANT, "India"); reminders.create(e)
        d.profileFlow.value = "kid"
        assertTrue(follows.current().isEmpty); assertTrue(db.sports().reminders("kid").isEmpty()); assertEquals(1, db.sports().reminders("main").size)
        d.profileFlow.value = "main"; assertEquals(1, follows.current().follows.size)
    }

    @Test fun followingStartsNothingAndSchedulesNothing() = run {
        follows.follow(event("e", t0 + h), FollowKind.SPORT, "Cricket")
        assertTrue(d.scheduler.active.isEmpty() && d.notifier.posts.isEmpty() && d.auth.played.isEmpty() && d.notifier.asked == 0)
    }

    @Test fun theFollowSetAnswersByStrongestReasonAndSport() {
        val set = FollowSet(listOf(Follow(FollowKind.SPORT, Sport.CRICKET, "cricket", "Cricket"), Follow(FollowKind.COMPETITION, Sport.CRICKET, "test series", "Test Series"), Follow(FollowKind.PARTICIPANT, Sport.CRICKET, "india", "India")))
        val e = event("e", t0)
        assertEquals(FollowReason(FollowKind.PARTICIPANT, "India"), set.reason(e))
        assertEquals(FollowReason(FollowKind.COMPETITION, "Test Series"), set.reason(event("f", t0, sides = listOf("Brazil", "Chile"))))
        assertEquals(FollowReason(FollowKind.SPORT, "Cricket"), set.reason(event("g", t0, sides = listOf("Brazil", "Chile"), competition = "Other")))
        assertNull("a followed name only counts within its sport", set.reason(event("h", t0, sport = Sport.FOOTBALL, sides = listOf("India", "Chile"), competition = null)))
        assertEquals("Because you follow India", Personalization(set).reasonText(e))
    }

    // ---- reminders

    @Test fun aReminderIsDurableAndScheduledOnceAtItsLeadTime() = run {
        val e = event("e", t0 + 2 * h); val r = reminders.create(e) as CreateResult.Created
        val row = db.sports().reminder(r.id)!!
        assertEquals(ReminderStatus.SCHEDULED.name, row.status); assertEquals(e.startMs, row.startMs); assertEquals(SportsKeys.identity(e), row.identity); assertEquals("e", row.matchedEventId)
        assertEquals(mapOf(r.id to e.startMs - 15 * min), d.scheduler.active)
        assertEquals("a second tap does not make a second reminder", CreateResult.Exists(r.id), reminders.create(e))
        assertEquals(1, db.sports().reminders("main").size)
    }

    @Test fun changingAndRemovingARemindersMovesAndCancelsItsAlarm() = run {
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id
        reminders.change(id, 60 * min); assertEquals(mapOf(id to e.startMs - 60 * min), d.scheduler.active)
        reminders.remove(id); assertTrue(d.scheduler.active.isEmpty()); assertNull(db.sports().reminder(id))
    }

    @Test fun theNotificationPermissionIsAskedOnlyForTheFirstReminderAndADenialKeepsTheReminder() = run {
        d.notifier.grantOnAsk = false
        val r1 = reminders.create(event("e1", t0 + 2 * h)) as CreateResult.Created; val r2 = reminders.create(event("e2", t0 + 4 * h, sides = listOf("A", "B"))) as CreateResult.Created
        assertEquals(1, d.notifier.asked); assertEquals(NotificationState.DENIED, r1.permission); assertEquals(NotificationState.DENIED, r2.permission)
        assertEquals("both reminders are kept in the app", 2, db.sports().reminders("main").size)
    }

    @Test fun aRestrictedEventCannotGetAReminder() = run {
        d.auth.hiddenChannels.add("1"); assertEquals(CreateResult.Refused, reminders.create(event("e", t0 + h))); assertTrue(db.sports().reminders("main").isEmpty())
        assertEquals("and nothing was asked of the person", 0, d.notifier.asked)
    }

    @Test fun aGuideChangeMovesTheAlarmWithoutADuplicate() = run {
        val e = event("e", t0 + 3 * h); val id = (reminders.create(e) as CreateResult.Created).id
        val moved = event("zz", t0 + 3 * h + 40 * min, channels = listOf("2", "3"))
        reminders.reassociate(listOf(moved))
        val row = db.sports().reminder(id)!!
        assertEquals(moved.startMs, row.startMs); assertEquals("zz", row.matchedEventId); assertEquals("2,3", row.candidateChannelIds)
        assertEquals("still exactly one alarm, at the new time", mapOf(id to moved.startMs - 15 * min), d.scheduler.active); assertEquals(1, db.sports().reminders("main").size)
    }

    @Test fun fiftyRefreshesLeaveOneActiveScheduleAndDoNotNotify() = run {
        val e = event("e", t0 + 3 * h); val id = (reminders.create(e) as CreateResult.Created).id
        repeat(50) { reminders.reassociate(listOf(event("e$it", t0 + 3 * h))) }
        assertEquals(1, d.scheduler.active.size); assertEquals(1, db.sports().reminders("main").size); assertTrue(d.notifier.posts.isEmpty())
        assertEquals(e.startMs - 15 * min, d.scheduler.active[id])
    }

    @Test fun anEventThatLeavesStaysPendingKeepsItsAlarmAndIsFoundWhenItReturns() = run {
        val e = event("e", t0 + 3 * h); val id = (reminders.create(e) as CreateResult.Created).id
        reminders.reassociate(emptyList())
        assertEquals(ReminderStatus.UNMATCHED.name, db.sports().reminder(id)!!.status); assertNull(db.sports().reminder(id)!!.matchedEventId); assertEquals("still armed at the stored time", e.startMs - 15 * min, d.scheduler.active[id])
        reminders.keep(id); assertTrue(db.sports().reminder(id)!!.kept)
        reminders.reassociate(listOf(event("back", t0 + 3 * h + 10 * min)))
        val row = db.sports().reminder(id)!!; assertEquals(ReminderStatus.SCHEDULED.name, row.status); assertEquals("back", row.matchedEventId); assertFalse(row.kept)
    }

    @Test fun anAmbiguousGuideAssociatesNothing() = run {
        val e = event("e", t0 + 3 * h); val id = (reminders.create(e) as CreateResult.Created).id
        reminders.reassociate(listOf(event("x", t0 + 3 * h), event("y", t0 + 3 * h + 30 * min)))
        assertEquals(ReminderStatus.AMBIGUOUS.name, db.sports().reminder(id)!!.status); assertNull(db.sports().reminder(id)!!.matchedEventId)
    }

    @Test fun aReminderWhoseLeadTimePassedIsAnnouncedOnceAndNeverAfterTheEvent() = run {
        d.time = t0 + 2 * h - 5 * min                                                     // 5 minutes before an event, with a 15-minute lead
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e, 15 * min) as CreateResult.Created).id
        assertEquals("announced at once, once", 1, d.notifier.posts.size); assertEquals("India vs Australia", d.notifier.posts.single().second); assertEquals(ReminderStatus.FIRED.name, db.sports().reminder(id)!!.status)
        reminders.reassociate(listOf(e)); reminders.rescheduleAll(); reminders.fire(id)
        assertEquals("never twice", 1, d.notifier.posts.size); assertTrue(d.scheduler.active.isEmpty())
        d.time = t0 + 2 * h + 4 * h; val late = event("late", t0 + 5 * h); assertEquals("a reminder for an event that is over is never sent", 1, run2(late, 15 * min))
    }
    private suspend fun run2(e: SportsEvent, lead: Long): Int { val x = SportsReminderService(db.sports(), d, scope) { }; x.create(e, lead); return d.notifier.posts.size }

    @Test fun aReminderForAnEventAlreadyUnderwayIsMarkedMissedNotAnnounced() = run {
        d.time = t0 + 2 * h + 5 * min
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id
        assertTrue(d.notifier.posts.isEmpty()); assertEquals(ReminderStatus.MISSED.name, db.sports().reminder(id)!!.status)
    }

    @Test fun aDelayedAlarmFiresOnceEvenIfDeliveredTwice() = run {
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id
        d.live = listOf(e); d.time = t0 + 2 * h - 10 * min
        assertTrue(reminders.fire(id)); assertFalse("a second delivery does nothing", reminders.fire(id)); assertEquals(1, d.notifier.posts.size)
    }

    @Test fun anEventThatMovedLaterIsAnnouncedAtItsNewTimeNotNow() = run {
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id
        d.live = listOf(event("moved", t0 + 3 * h)); d.time = t0 + 2 * h - 14 * min              // the old alarm goes off
        assertFalse(reminders.fire(id)); assertTrue(d.notifier.posts.isEmpty()); assertEquals(t0 + 3 * h - 15 * min, d.scheduler.active[id])
    }

    @Test fun aTimeZoneChangeKeepsTheSameInstants() = run {
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id; val before = d.scheduler.active.toMap()
        val saved = java.util.TimeZone.getDefault()
        try { java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("Pacific/Auckland")); reminders.rescheduleAll(); assertEquals(before, d.scheduler.active)
              java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("America/Los_Angeles")); reminders.rescheduleAll(); assertEquals(before, d.scheduler.active); assertEquals(1, d.scheduler.active.size) } finally { java.util.TimeZone.setDefault(saved) }
        assertEquals(e.startMs - 15 * min, d.scheduler.active[id])
    }

    @Test fun theDaylightSavingJumpDoesNotMoveAnAbsoluteReminder() = run {
        // 2026-03-08 07:00 UTC is the instant the US clocks jump; a reminder is an instant, so 15 minutes before is the same 15 minutes either side.
        val start = 1_772_953_200_000L                                                    // 2026-03-08T07:00:00Z
        d.time = start - 3 * h; val e = event("e", start); val id = (reminders.create(e) as CreateResult.Created).id
        assertEquals(start - 15 * min, d.scheduler.active[id])
    }

    @Test fun rebootRestoresOnlyTheActiveProfilesAlarms() = run {
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id
        d.profileFlow.value = "kid"; val other = (reminders.create(event("k", t0 + 3 * h, sides = listOf("A", "B"))) as CreateResult.Created).id
        d.scheduler.active.clear(); reminders.rescheduleAll()
        assertEquals("only the kid profile's", setOf(other), d.scheduler.active.keys)
        d.profileFlow.value = "main"; d.scheduler.active.clear(); reminders.rescheduleAll(); assertEquals(setOf(id), d.scheduler.active.keys)
    }

    // ---- security

    @Test fun anotherProfilesReminderNeverFiresHere() = run {
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id
        d.profileFlow.value = "kid"; d.live = listOf(e); d.time = t0 + 2 * h - 10 * min
        assertFalse(reminders.fire(id)); assertTrue(d.notifier.posts.isEmpty())
    }

    /** Makes a reminder for [e], then lets its alarm go off at [before] its start, with the guide as [guide] and [change] applied first. */
    private fun fireWith(e: SportsEvent, guide: List<SportsEvent>, change: () -> Unit = {}): Pair<String, SportsReminderService> = run {
        val id = (reminders.create(e) as CreateResult.Created).id
        d.live = guide; d.time = e.startMs - 10 * min; change()
        reminders.fire(id); id to reminders
    }

    @Test fun anAlarmThatFindsNoSafeMatchShowsNothingAtAll() = run {
        val e = event("e", t0 + 2 * h, title = "SECRET FC v SECRET United")
        val (id, _) = fireWith(e, guide = emptyList())                                    // the event left the guide
        assertTrue("no event notification and no general one", d.notifier.posts.isEmpty())
        val row = db.sports().reminder(id)!!
        assertEquals(ReminderStatus.UNMATCHED.name, row.status); assertEquals("not marked as announced", 0L, row.notifiedAt); assertNull(row.matchedEventId)
        reminders.fire(id); assertTrue("a second delivery shows nothing either", d.notifier.posts.isEmpty())
        d.live = listOf(event("back", t0 + 2 * h + 5 * min, title = "SECRET FC v SECRET United")); d.time = t0 + 2 * h - 5 * min      // it returns before it starts
        assertTrue("found again, so it is announced then, once", reminders.fire(id)); assertEquals(1, d.notifier.posts.size)
    }

    @Test fun anAlarmWithAnAmbiguousGuideShowsNothingAtAll() = run {
        val e = event("e", t0 + 2 * h); val (id, _) = fireWith(e, listOf(event("x", t0 + 2 * h), event("y", t0 + 2 * h + 30 * min)))
        assertTrue(d.notifier.posts.isEmpty()); assertEquals(ReminderStatus.AMBIGUOUS.name, db.sports().reminder(id)!!.status); assertEquals(0L, db.sports().reminder(id)!!.notifiedAt)
    }

    @Test fun anAlarmForAnEventWhoseChannelsAreAllRestrictedShowsNothingAtAll() = run {
        val e = event("e", t0 + 2 * h, title = "SECRET FC v SECRET United")
        val (id, _) = fireWith(e, listOf(e)) { d.auth.hiddenChannels.add("1") }
        assertTrue("no notification, so no title either", d.notifier.posts.isEmpty()); assertEquals(0L, db.sports().reminder(id)!!.notifiedAt)
        d.auth.hiddenChannels.clear(); assertTrue("allowed again before the start: announced then", reminders.fire(id)); assertEquals("SECRET FC v SECRET United", d.notifier.posts.single().second)
    }

    @Test fun aMatchedAllowedEventIsAnnouncedByItsCurrentTitleOnly() = run {
        val e = event("e", t0 + 2 * h); val (_, _) = fireWith(e, listOf(event("renamed", t0 + 2 * h, title = "India vs Australia")))
        assertEquals("India vs Australia", d.notifier.posts.single().second)
    }

    @Test fun theBannerIsHiddenAtOnceWhenTheEventBecomesRestrictedOrTheProfileSwitches() = run {
        val e = event("e", t0 + 2 * h); reminders.create(e); d.time = t0 + 2 * h - 10 * min
        reminders.evaluate(); assertNotNull(reminders.banner.value); assertEquals("India vs Australia", reminders.banner.value?.title)
        d.auth.lockedCategories.add("cat"); reminders.evaluate(); assertNull("a locked folder removes it", reminders.banner.value)
        d.auth.lockedCategories.clear(); reminders.evaluate(); assertNotNull(reminders.banner.value)
        d.profileFlow.value = "kid"; reminders.securityChanged(); assertNull(reminders.banner.value)
    }

    @Test fun aDismissedBannerIsNotShownAgain() = run {
        val e = event("e", t0 + 2 * h); val id = (reminders.create(e) as CreateResult.Created).id; d.time = t0 + 2 * h - 10 * min
        reminders.evaluate(); assertEquals(id, reminders.banner.value?.id)
        reminders.bannerDone(id); reminders.evaluate(); assertNull("dismissed: not shown again", reminders.banner.value)
    }

    // ---- privacy

    @Test fun diagnosticsCarryOnlyCountsAndFixedWords() = run {
        val e = event("e", t0 + 2 * h, sides = listOf("SECRET FC", "SECRET United"), competition = "SECRET League", title = "SECRET FC v SECRET United")
        follows.follow(e, FollowKind.PARTICIPANT, "SECRET FC"); val id = (reminders.create(e) as CreateResult.Created).id
        reminders.reassociate(listOf(e)); d.live = listOf(e); d.time = t0 + 2 * h - 10 * min; reminders.fire(id)
        val text = reports.joinToString("\n") { it.line() }
        assertTrue(reports.isNotEmpty()); assertFalse(text, text.uppercase().contains("SECRET") || text.contains("http"))
        val kinds = PersonalReport::class.java.declaredFields.filter { !it.name.startsWith("$") }.map { it.type }.toSet()
        assertTrue(kinds.toString(), kinds.none { it == String::class.java })
        val row = db.sports().reminder(id)!!
        assertFalse("no stream, login or description is stored", row.toString().contains("http") || row.toString().contains("u:SECRET@"))
        val fields = app.streamsetu.core.data.db.SportsReminderEntity::class.java.declaredFields.map { it.name }
        assertTrue(fields.toString(), fields.none { it in setOf("title", "description", "url", "streamRef", "plot") })
    }

    @Test fun theNotificationCarriesOnlyTheReminderIdAndNeverAnAddress() {
        val src = java.io.File("src/main/kotlin/app/streamsetu/tv/sports/personal/RealReminderDeps.kt").readText()
        assertTrue(src.count { false } == 0)
        val extras = Regex("putExtra\\(([^,]+),").findAll(src).map { it.groupValues[1].trim() }.toList()
        assertTrue("only the id is carried: $extras", extras.all { it == "\"id\"" || it == "EXTRA" })
    }

    // ---- the same sides twice

    private fun channel(id: String) { d.auth.channels[id] = Channel(id, "A", "cat", "Channel $id", null, null, "ref", null) }
    private fun fixture(id: String, start: Long, vararg channels: String): SportsEvent { channels.forEach(::channel); return event(id, start, channels = channels.toList()) }
    private suspend fun made(e: SportsEvent, guide: List<SportsEvent>): String = (reminders.create(e, guide = guide) as CreateResult.Created).id
    private suspend fun row(id: String) = db.sports().reminder(id)!!
    private fun silent() = assertTrue("nothing was sent", d.notifier.posts.isEmpty())

    @Test fun twoFixturesOnTheSameChannelsKeepTheirReminderOnlyWhileTheirStartsHoldStill() = run {
        val a = fixture("first", t0 + 2 * h, "1"); val b = fixture("second", t0 + 5 * h, "1")
        val ida = made(a, listOf(a, b)); val idb = made(b, listOf(a, b))
        assertEquals(listOf(2, 2), listOf(ida, idb).map { row(it).siblings }); assertEquals("nothing tells them apart by channel", listOf("", ""), listOf(ida, idb).map { row(it).distinguishing })
        reminders.reassociate(listOf(fixture("first-r", t0 + 2 * h + 2 * min, "1"), fixture("second-r", t0 + 5 * h, "1")))        // a new revision, the times unchanged
        assertEquals("first-r", row(ida).matchedEventId); assertEquals("second-r", row(idb).matchedEventId)
    }

    @Test fun sameChannelsAfterARefreshThatMovedOneFixtureIsAmbiguousAndSendsNothing() = run {
        val a = fixture("first", t0 + 2 * h, "1"); val b = fixture("second", t0 + 5 * h, "1"); val ida = made(a, listOf(a, b)); val idb = made(b, listOf(a, b))
        val delayed = fixture("first2", t0 + 4 * h + 30 * min, "1")                       // the first was delayed to just before the second
        reminders.reassociate(listOf(delayed, b))
        for (id in listOf(ida, idb)) { assertEquals(ReminderStatus.AMBIGUOUS.name, row(id).status); assertNull(row(id).matchedEventId) }
        d.live = listOf(delayed, b); d.time = t0 + 2 * h - 5 * min; reminders.fire(ida); d.time = t0 + 5 * h - 5 * min; reminders.fire(idb); silent()
    }

    @Test fun aSwapWhoseChannelsAlsoChangedIsAmbiguousForBoth() = run {
        val a = fixture("first", t0 + 4 * h, "1"); val b = fixture("second", t0 + 5 * h, "2"); val ida = made(a, listOf(a, b)); val idb = made(b, listOf(a, b))
        reminders.reassociate(listOf(fixture("first", t0 + 5 * h + 30 * min, "3"), fixture("second", t0 + 4 * h + 30 * min, "4")))
        for (id in listOf(ida, idb)) { assertEquals(ReminderStatus.AMBIGUOUS.name, row(id).status); assertNull(row(id).matchedEventId) }
    }

    @Test fun aSwapWhereTheStoredChannelsIdentifyOneFixtureEachStillMatchesCorrectly() = run {
        val a = fixture("first", t0 + 2 * h, "1"); val b = fixture("second", t0 + 3 * h, "2"); val ida = made(a, listOf(a, b)); val idb = made(b, listOf(a, b))
        assertEquals(listOf("1", "2"), listOf(ida, idb).map { row(it).distinguishing })
        reminders.reassociate(listOf(fixture("first", t0 + 4 * h, "1"), fixture("second", t0 + 3 * h, "2")))               // the first now plays after the second
        assertEquals("the reminder for the first follows its channel to the later slot", t0 + 4 * h, row(ida).startMs); assertEquals("first", row(ida).matchedEventId)
        assertEquals("second", row(idb).matchedEventId); assertEquals(t0 + 3 * h, row(idb).startMs)
    }

    @Test fun whenOnlyOneFixtureRemainsItMatchesOnlyWhenItIsProvablyTheSame() = run {
        val a = fixture("first", t0 + 2 * h, "1"); val b = fixture("second", t0 + 5 * h, "1"); val ida = made(a, listOf(a, b))
        reminders.reassociate(listOf(b)); assertEquals("the other fixture alone, far from the stored start and on the same channel: not guessed", ReminderStatus.AMBIGUOUS.name, row(ida).status)
        reminders.reassociate(listOf(fixture("first2", t0 + 2 * h + 3 * min, "1"))); assertEquals("a start that has hardly moved is the same fixture", "first2", row(ida).matchedEventId)
        val c = fixture("c-first", t0 + 7 * h, "5"); val e = fixture("c-second", t0 + 9 * h, "6"); val idc = made(c, listOf(c, e))
        reminders.reassociate(listOf(fixture("c-first-moved", t0 + 8 * h, "5"))); assertEquals("its own channel, though the start moved", "c-first-moved", row(idc).matchedEventId)
        reminders.reassociate(listOf(fixture("c-second-lone", t0 + 8 * h + 30 * min, "6"))); assertEquals("the other fixture's channel is no evidence", ReminderStatus.AMBIGUOUS.name, row(idc).status)
    }

    @Test fun anAmbiguousReminderThatBecomesIdentifiableIsAssociatedOnceAndAnnouncedOnce() = run {
        val a = fixture("first", t0 + 2 * h, "1"); val b = fixture("second", t0 + 5 * h, "1"); val ida = made(a, listOf(a, b))
        val delayed = fixture("first2", t0 + 4 * h + 30 * min, "1"); reminders.reassociate(listOf(delayed, b))
        assertEquals(ReminderStatus.AMBIGUOUS.name, row(ida).status)
        val back = fixture("first3", t0 + 2 * h + 4 * min, "1"); reminders.reassociate(listOf(back, b))                       // the guide puts it back where it was
        assertEquals(ReminderStatus.SCHEDULED.name, row(ida).status); assertEquals("first3", row(ida).matchedEventId)
        repeat(3) { reminders.reassociate(listOf(back, b)) }
        assertEquals("one alarm", 1, d.scheduler.active.keys.count { it == ida }); assertTrue(d.notifier.posts.isEmpty())
        d.live = listOf(back, b); d.time = t0 + 2 * h - 10 * min
        assertTrue(reminders.fire(ida)); assertFalse(reminders.fire(ida)); reminders.reassociate(listOf(back, b))
        assertEquals("one notification, however many refreshes and deliveries", 1, d.notifier.posts.size)
    }

    @Test fun aLoneFixtureThatGainsASecondStaysWithTheOneWhoseStartHasNotMoved() = run {
        val a = event("a", t0 + 2 * h); val id = made(a, listOf(a))
        val extra = event("rerun", t0 + 5 * h)
        reminders.reassociate(listOf(a, extra)); assertEquals("a", row(id).matchedEventId)
        val moved = event("moved", t0 + 2 * h + 40 * min)                                  // the original moved and another appeared: neither is provably the same
        reminders.reassociate(listOf(moved, extra)); assertEquals(ReminderStatus.AMBIGUOUS.name, row(id).status)
    }

    @Test fun theMatcherNeverDecidesByOrderOrNearestStartAlone() {
        val a = event("a", t0 + 2 * h); val b = event("b", t0 + 5 * h)
        val doubleheader = SportsEventReminder("r", SportsKeys.identity(a), SportsKeys.competition(a), a.startMs, siblings = 2, distinguishing = emptySet())
        val m = ReminderMatcher.associate(listOf(doubleheader), listOf(event("a2", t0 + 4 * h + 45 * min), b), t0 + 72 * h).single()
        assertTrue("two fixtures, none at the stored start, no channel evidence: ambiguous however near one is", m is Association.Ambiguous)
    }
}
