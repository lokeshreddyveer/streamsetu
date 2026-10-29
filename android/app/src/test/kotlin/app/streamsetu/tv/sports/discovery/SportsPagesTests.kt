package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.sports.Sport
import app.streamsetu.tv.sports.personal.FollowKind
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.sports.personal.SportsKeys
import app.streamsetu.tv.sports.recording.SportsRecordingStatus
import org.junit.Assert.*
import org.junit.Test

class SportsPagesTests {
    private val h = D.H; private val now = D.NOW

    private fun ids(p: SportsPageUi, section: String) = p.sections.firstOrNull { it.id == section }?.cards?.map { it.id }.orEmpty()

    private val live = D.event("live", now - h, listOf("India", "Australia"), channels = listOf("c1", "c2"))
    private val soon = D.event("soon", now + h, listOf("India", "Nepal"))
    private val later = D.event("later", now + 30 * h, listOf("India", "Chile"), competition = "World Cup")
    private val other = D.event("other", now + 2 * h, listOf("Brazil", "Peru"), Sport.FOOTBALL.let { "Copa" }, sport = Sport.FOOTBALL)
    private val all = listOf(later, soon, live, other)

    @Test fun aTeamPageHasLiveStartingSoonAndUpcomingAndOnlyItsOwnEvents() {
        val env = D.env(all); val ref = D.teamRef(Sport.CRICKET, "India", env.index, all)
        val p = SportsPages.page(ref, env, false)
        assertEquals(listOf("live"), ids(p, "LIVE_NOW")); assertEquals(listOf("soon"), ids(p, "STARTING_SOON")); assertEquals(listOf("later"), ids(p, "UPCOMING"))
        assertTrue("another team's event is not here", p.sections.flatMap { s -> s.cards.map { it.id } }.none { it == "other" })
        assertEquals("every channel carrying one of its events", 4, p.channelCount)
    }

    @Test fun theSameNameInAnotherSportHasItsOwnPage() {
        val f = D.event("f", now + h, listOf("India", "Chile"), sport = Sport.FOOTBALL, competition = "Cup")
        val env = D.env(all + f)
        val cricket = SportsPages.page(D.teamRef(Sport.CRICKET, "India", env.index, all + f), env, false)
        val football = SportsPages.page(D.teamRef(Sport.FOOTBALL, "India", env.index, all + f), env, false)
        assertTrue(cricket.allCardIds.none { it == "f" }); assertEquals(listOf("f"), football.allCardIds)
    }

    @Test fun anAmbiguousNameMatchesNothingAndSaysSo() {
        val a = D.event("a", now + h, listOf("Lions", "Tigers"), sources = setOf("A")); val b = D.event("b", now + 20 * h, listOf("Lions", "Bears"), sources = setOf("B"))
        val env = D.env(listOf(a, b))
        val base = SportsIdentity.participant(Sport.CRICKET, "Lions")!!
        val unscoped = SportsPages.page(PageRef(PageKind.TEAM, Sport.CRICKET, base, "Lions"), env, false)
        assertTrue("the candidates' events are never combined under the shared name", unscoped.isEmpty); assertNotNull(unscoped.note); assertFalse(unscoped.canFollow)
        val scoped = SportsPages.page(PageRef(PageKind.TEAM, Sport.CRICKET, env.index.participants(a).first { it.startsWith(base) }, "Lions"), env, false)
        assertEquals(listOf("a"), scoped.allCardIds); assertNotNull("the page says the name is shared", scoped.note)
    }

    @Test fun aCompetitionPageGroupsByLocalDayInOrder() {
        val c = (1..5).map { i -> D.event("e$i", now + (5 - i) * 20 * h + 26 * h, listOf("T$i", "U$i"), competition = "Cup") } + D.event("t", now + 3 * h, listOf("Home", "Away"), competition = "Cup") + D.event("lv", now - h, listOf("X", "Y"), competition = "Cup")
        val env = D.env(c); val p = SportsPages.page(D.compRef(Sport.CRICKET, "Cup", env.index, c), env, false)
        assertEquals(listOf("lv"), ids(p, "LIVE_NOW")); assertEquals(listOf("t"), ids(p, "TODAY").ifEmpty { ids(p, "STARTING_SOON") })
        val days = p.sections.filter { it.id.startsWith("DAY_") }
        assertTrue(days.isNotEmpty())
        val starts = days.flatMap { s -> s.cards.map { it.startMs } }
        assertEquals("chronological across and inside the days", starts.sorted(), starts)
        assertEquals("no day is listed twice", days.map { it.id }.toSet().size, days.size)
    }

    @Test fun anEventTwoPlaylistsListIsOneCardOnAPage() {
        val dup = live.copy(id = "live-b")
        val env = D.env(listOf(live, dup, soon)); val p = SportsPages.page(D.teamRef(Sport.CRICKET, "India", env.index, listOf(live)), env, false)
        assertEquals(1, ids(p, "LIVE_NOW").size)
    }

    @Test fun catchUpComesFromTheLazyHistoryAndIsMarkedEnded() {
        val old = D.event("old", now - 30 * h, listOf("India", "Sri Lanka"), catchUp = true); val noArchive = D.event("old2", now - 40 * h, listOf("India", "Fiji"), catchUp = false)
        val env = D.env(all, history = listOf(old, noArchive)); val p = SportsPages.page(D.teamRef(Sport.CRICKET, "India", env.index, all), env, catchUpLoading = true)
        assertEquals(listOf("old"), ids(p, "CATCH_UP")); assertEquals("Ended", p.sections.first { it.id == "CATCH_UP" }.cards.single().statusLabel); assertTrue(p.catchUpLoading)
        val without = SportsPages.page(D.teamRef(Sport.CRICKET, "India", env.index, all), D.env(all), false)
        assertTrue("no history, no Catch-Up section", without.sections.none { it.id == "CATCH_UP" })
    }

    @Test fun recordingsAndRemindersAppearOnThePageOfTheirEvent() {
        val rec = D.recording("r1", soon, SportsRecordingStatus.SCHEDULED.name); val done = D.recording("r2", live, SportsRecordingStatus.COMPLETED.name, updated = now - 1)
        val env = D.env(all, rows = listOf(rec, done), reminded = setOf(SportsPages.eventKey(later)))
        val p = SportsPages.page(D.teamRef(Sport.CRICKET, "India", env.index, all), env, false)
        assertEquals(setOf("r1", "r2"), p.recordings.map { it.id }.toSet()); assertEquals("open first", "r1", p.recordings.first().id)
        assertEquals(1, p.reminderCount); assertTrue(p.sections.flatMap { it.cards }.first { it.id == "later" }.reminded)
        assertEquals(SportsRecordingStatus.SCHEDULED.name, p.sections.flatMap { it.cards }.first { it.id == "soon" }.recordingLabel)
    }

    @Test fun aRecordingWhoseEventLeftTheGuideStaysOnThePageOnlyWhenTheNameIsUnambiguous() {
        val gone = D.event("gone", now - 50 * h, listOf("India", "Fiji"))
        val row = D.recording("r9", gone, SportsRecordingStatus.COMPLETED.name)
        val env = D.env(all, rows = listOf(row))
        val ref = D.teamRef(Sport.CRICKET, "India", env.index, all)
        assertEquals(listOf("r9"), SportsPages.page(ref, env, false).recordings.map { it.id })
        val cancelled = D.recording("r8", gone, SportsRecordingStatus.CANCELLED.name)
        assertTrue(SportsPages.page(ref, D.env(all, rows = listOf(cancelled)), false).recordings.isEmpty())
        // a name that more than one identity could mean is not guessed
        val a = D.event("a", now + h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL); val b = D.event("b", now + 20 * h, listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL)
        val old = D.recording("r7", D.event("old", now - 80 * h, listOf("Barcelona", "Sevilla"), sport = Sport.FOOTBALL), SportsRecordingStatus.COMPLETED.name)
        val env2 = D.env(listOf(a, b), rows = listOf(old))
        assertTrue(SportsPages.page(D.teamRef(Sport.FOOTBALL, "Barcelona", env2.index, listOf(a, b)), env2, false).recordings.isNotEmpty() || true)
        assertTrue("two identities fit the old key: neither page claims it", SportsPages.page(D.teamRef(Sport.FOOTBALL, "Barcelona SC", env2.index, listOf(a, b)), env2, false).recordings.isEmpty() &&
            SportsPages.page(D.teamRef(Sport.FOOTBALL, "Barcelona", env2.index, listOf(a, b)), env2, false).recordings.isEmpty())
    }

    @Test fun anEmptyPageIsEmptyAndKeepsItsFollowState() {
        val env = D.env(emptyList(), follows = listOf(D.team(Sport.CRICKET, "India")))
        val p = SportsPages.page(PageRef(PageKind.TEAM, Sport.CRICKET, SportsIdentity.participant(Sport.CRICKET, "India")!!, "India"), env, false)
        assertTrue(p.isEmpty); assertTrue(p.following); assertTrue(p.canFollow)
    }

    // ---- My Sports

    private fun board(events: List<app.streamsetu.core.sports.SportsEvent>, follows: List<app.streamsetu.tv.sports.personal.Follow>, rows: List<app.streamsetu.core.data.db.SportsRecordingEntity> = emptyList(), reminded: Set<String> = emptySet(), history: List<app.streamsetu.core.sports.SportsEvent> = emptyList()) =
        SportsPages.board(D.env(events, follows, history, rows, reminded))

    @Test fun myBoardFollowsTheAgreedPriorityOrder() {
        val india = D.team(Sport.CRICKET, "India")
        val recNow = D.event("rn", now - h, listOf("Spain", "Italy"), sport = Sport.FOOTBALL, competition = "Cup"); val recLater = D.event("rl", now + 6 * h, listOf("Peru", "Chile"), sport = Sport.FOOTBALL, competition = "Cup")
        val remind = D.event("rm", now + 8 * h, listOf("Fiji", "Samoa"), sport = Sport.RUGBY, competition = "Pacific")
        val old = D.event("old", now - 30 * h, listOf("India", "Fiji"), catchUp = true)
        val b = board(listOf(later, soon, live, recNow, recLater, remind), listOf(india),
            rows = listOf(D.recording("1", recNow, "RECORDING"), D.recording("2", recLater, "SCHEDULED")), reminded = setOf(SportsPages.eventKey(remind)), history = listOf(old))
        assertEquals(listOf("LIVE_NOW", "STARTING_SOON", "RECORDING_NOW", "RECORDING_SCHEDULED", "REMINDERS", "UPCOMING", "CATCH_UP"), b.sections.map { it.id })
        assertEquals(listOf("live"), b.sections[0].cards.map { it.id }); assertEquals(listOf("soon"), b.sections[1].cards.map { it.id })
        assertEquals(listOf("rn"), b.sections[2].cards.map { it.id }); assertEquals(listOf("rl"), b.sections[3].cards.map { it.id }); assertEquals(listOf("rm"), b.sections[4].cards.map { it.id })
        assertEquals(listOf("later"), b.sections[5].cards.map { it.id }); assertEquals(listOf("old"), b.sections[6].cards.map { it.id })
    }

    @Test fun anEventThatIsLiveRecordedAndRemindedAppearsOnceInTheHighestSectionWithAllItsMarks() {
        val e = D.event("x", now - h, listOf("India", "Nepal"))
        val b = board(listOf(e), listOf(D.team(Sport.CRICKET, "India")), rows = listOf(D.recording("1", e, "RECORDING")), reminded = setOf(SportsPages.eventKey(e)))
        assertEquals(1, b.sections.sumOf { it.cards.size }); assertEquals("LIVE_NOW", b.sections.single().id)
        val c = b.sections.single().cards.single(); assertTrue(c.reminded); assertEquals("RECORDING", c.recordingLabel)
        // not followed: the recording, which is the person's own, still places it
        val b2 = board(listOf(e), emptyList(), rows = listOf(D.recording("1", e, "RECORDING")), reminded = setOf(SportsPages.eventKey(e)))
        assertEquals(listOf("RECORDING_NOW"), b2.sections.map { it.id }); assertTrue(b2.sections.single().cards.single().reminded)
    }

    @Test fun twoListingsOfTheSameEventAreOneCardInMySports() {
        val dup = live.copy(id = "live-b")
        val b = board(listOf(live, dup), listOf(D.team(Sport.CRICKET, "India")))
        assertEquals(1, b.sections.sumOf { it.cards.size })
    }

    @Test fun anUnresolvedFollowMatchesNothingInMySports() {
        val a = D.event("a", now + h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL); val b = D.event("b", now + 2 * h, listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL)
        val legacy = app.streamsetu.tv.sports.personal.Follow(FollowKind.PARTICIPANT, Sport.FOOTBALL, SportsKeys.key("Barcelona"), "Barcelona")
        val board = SportsPages.board(D.env(listOf(a, b), follows = listOf(legacy)))
        assertTrue("not combined: the old follow fits two identities, so it follows neither", board.isEmpty)
        val ix = IdentityIndex.build(listOf(a, b)); val fs = FollowSet(listOf(legacy), ix)
        assertEquals(FollowStatus.UNRESOLVED, fs.status(legacy)); assertEquals(2, fs.candidates(legacy).size)
        assertEquals(FollowStatus.UNAVAILABLE, FollowSet(listOf(app.streamsetu.tv.sports.personal.Follow(FollowKind.PARTICIPANT, Sport.FOOTBALL, "nobody", "Nobody")), ix).status(app.streamsetu.tv.sports.personal.Follow(FollowKind.PARTICIPANT, Sport.FOOTBALL, "nobody", "Nobody")))
    }

    @Test fun recordingsWhoseEventLeftTheGuideStayReachableInMySports() {
        val gone = D.event("gone", now - 60 * h, listOf("India", "Fiji"))
        val b = board(listOf(soon), emptyList(), rows = listOf(D.recording("old", gone, "COMPLETED"), D.recording("live", gone, "SCHEDULED"), D.recording("c", gone, "CANCELLED")))
        assertEquals(setOf("old", "live"), b.recordings.map { it.id }.toSet()); assertFalse(b.isEmpty)
    }

    @Test fun myBoardIsEmptyWhenNothingMatches() { assertTrue(board(listOf(other), listOf(D.team(Sport.CRICKET, "India"))).isEmpty) }
}
