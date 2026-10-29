package app.streamsetu.tv.ui.sports

import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.ui.screens.sports.SportsSections
import org.junit.Assert.*
import org.junit.Test
import java.util.TimeZone

class SportsSectionsTests {
    private val utc = TimeZone.getTimeZone("UTC")
    private val h = 3_600_000L; private val min = 60_000L
    // 2027-01-15 10:00 UTC
    private val now = 1_800_000_000_000L + 2 * h

    private fun feed(ch: String, source: String = "A", language: String? = null, ls: MetadataSource = MetadataSource.UNKNOWN, quality: String? = null, qs: MetadataSource = MetadataSource.UNKNOWN, catchUp: Boolean = false, logo: String? = null) =
        SportsFeed(ch, source, "Channel $ch", language, ls, quality, qs, null, ch, 0, catchUp, logo)
    private fun event(id: String, start: Long, end: Long = start + 2 * h, sport: Sport = Sport.FOOTBALL, feeds: List<SportsFeed> = listOf(feed(id)), confidence: Double = 0.95, title: String = "Event $id") =
        SportsEvent(id, sport, SportsEventKind.HEAD_TO_HEAD, "League", listOf("X", "Y"), null, title, start, end, feeds, confidence, setOf("A"), "rev")
    private fun build(events: List<SportsEvent>, selected: Sport? = null, detail: String? = null, zone: TimeZone = utc, at: Long = now) = SportsSections.build(events, at, zone, selected, detail, mapOf("A" to "Playlist A"), java.util.Locale.US)

    @Test fun sectionsFollowTheRules() {
        val live = event("live", now - 30 * min); val liveJustStarted = event("live2", now)
        val soonNow = event("soon1", now + 1 * min); val soonEdge = event("soon2", now + 2 * h)
        val today = event("today", now + 3 * h); val todayLate = event("today2", now + 13 * h)                // 10:00 now: 13:00 and 23:00 are today
        val tomorrow = event("tom", now + 14 * h); val later = event("later", now + 30 * h)                  // 00:00 and later are not today
        val finished = event("done", now - 4 * h, now - 2 * h)
        val r = build(listOf(finished, later, tomorrow, todayLate, today, soonEdge, soonNow, liveJustStarted, live))
        assertEquals(listOf("live", "live2"), r.live.map { it.id })
        assertEquals(listOf("soon1", "soon2"), r.soon.map { it.id })
        assertEquals(listOf("today", "today2"), r.today.map { it.id })
        assertEquals(listOf("tom", "later"), r.upcoming.map { it.id })
        val all = (r.live + r.soon + r.today + r.upcoming).map { it.id }
        assertFalse("a finished event is not listed", "done" in all); assertEquals("every event is in exactly one section", all.size, all.toSet().size)
        assertTrue(r.live.all { it.live } && r.soon.none { it.live })
    }

    @Test fun todayIsTheUsersLocalCalendarDay() {
        // 10:00 UTC is 21:00 in Sydney (UTC+11 in January): the local day ends in three hours
        val sydney = TimeZone.getTimeZone("Australia/Sydney")
        val e = listOf(event("a", now + 3 * h + 30 * min), event("b", now + 5 * h))
        val r = build(e, zone = sydney)
        assertEquals("both are after local midnight, so not today", emptyList<String>(), r.today.map { it.id })
        assertEquals(listOf("a", "b"), r.upcoming.map { it.id })
        val r2 = build(e, zone = utc); assertEquals(listOf("a", "b"), r2.today.map { it.id })
    }

    @Test fun theDayBoundaryAcrossDaylightSavingIsALocalMidnight() {
        val ny = TimeZone.getTimeZone("America/New_York")
        val sat = 1_773_000_000_000L          // an instant on 2026-03-08 (the clocks go forward that night in New York)
        val end = SportsSections.endOfLocalDay(sat, ny)
        assertTrue("midnight is in the future and within 25 hours", end > sat && end - sat <= 25 * h)
        val c = java.util.Calendar.getInstance(ny); c.timeInMillis = end
        assertEquals(0, c.get(java.util.Calendar.HOUR_OF_DAY)); assertEquals(0, c.get(java.util.Calendar.MINUTE))
    }

    @Test fun filtersListAllAndOnlySportsThatHaveEvents() {
        val ev = listOf(event("f1", now + h, sport = Sport.FOOTBALL), event("f2", now + 3 * h, sport = Sport.FOOTBALL), event("c1", now + h, sport = Sport.CRICKET), event("old", now - 5 * h, now - 3 * h, sport = Sport.TENNIS))
        val r = build(ev)
        assertEquals(listOf(null, Sport.FOOTBALL, Sport.CRICKET), r.filters.map { it.sport }); assertEquals(listOf(3, 2, 1), r.filters.map { it.count })
        assertEquals("All Sports", r.filters.first().label)
        assertTrue("a sport with only finished events is not offered", r.filters.none { it.sport == Sport.TENNIS })
    }

    @Test fun filteringHappensOnTheLoadedEventsAndAMissingSportFallsBackToAll() {
        val ev = listOf(event("f1", now + h, sport = Sport.FOOTBALL), event("c1", now + h, sport = Sport.CRICKET))
        assertEquals(listOf("c1"), build(ev, selected = Sport.CRICKET).soon.map { it.id }); assertEquals(Sport.CRICKET, build(ev, selected = Sport.CRICKET).selected)
        val gone = build(ev, selected = Sport.TENNIS)
        assertNull("falls back to All", gone.selected); assertEquals(2, gone.soon.size)
    }

    @Test fun oneCardPerEventWhateverTheNumberOfFeedsAndTheCardShowsTheBestLogoAndCatchUp() {
        val e = event("m", now + h, feeds = listOf(feed("1", logo = null), feed("2", logo = "http://logo/2", catchUp = true), feed("3", logo = "http://logo/3")))
        val r = build(listOf(e))
        assertEquals(1, r.soon.size); val c = r.soon.single()
        assertEquals(3, c.feedCount); assertEquals("http://logo/2", c.logoUrl); assertTrue(c.catchUp)
        assertEquals("League", c.competition); assertEquals("Football", c.sportLabel)
        assertNull(build(listOf(event("n", now + h, feeds = listOf(feed("1"))))).soon.single().logoUrl)
    }

    @Test fun detailListsFeedsInEventOrderAndMarksInferredValues() {
        val e = event("m", now + h, feeds = listOf(
            feed("1", language = "hi", ls = MetadataSource.PROVIDER, quality = "FHD", qs = MetadataSource.PROVIDER, catchUp = true),
            feed("2", language = "te", ls = MetadataSource.PARSED_FROM_NAME, quality = "HD", qs = MetadataSource.PARSED_FROM_NAME),
            feed("3")), confidence = 0.6)
        val d = build(listOf(e), detail = "m").detail!!
        assertEquals(listOf("Channel 1", "Channel 2", "Channel 3"), d.feeds.map { it.channelName }); assertEquals("Playlist A", d.feeds[0].sourceName)
        assertEquals(false, d.feeds[0].language!!.inferred); assertEquals("Hindi", d.feeds[0].language!!.text); assertEquals(false, d.feeds[0].quality!!.inferred)
        assertEquals(true, d.feeds[1].language!!.inferred); assertEquals("Telugu", d.feeds[1].language!!.text); assertEquals(true, d.feeds[1].quality!!.inferred)
        assertNull(d.feeds[2].language); assertNull(d.feeds[2].quality)
        assertTrue("a low-confidence event says so", d.lowConfidence); assertEquals("Upcoming", d.stateLabel)
        assertFalse(build(listOf(event("x", now + h))).detail != null); assertFalse(build(listOf(event("y", now + h, confidence = 0.95)), detail = "y").detail!!.lowConfidence)
        assertEquals("Live now", build(listOf(event("z", now - h)), detail = "z").detail!!.stateLabel)
        assertNull("a detail for an event that is gone is none", build(listOf(event("q", now + h)), detail = "missing").detail)
    }

    @Test fun cardsCarryTheirTimeAndStatusWordsInTheUsersZone() {
        val soon = event("s", now + 45 * min); val live = event("l", now - h); val later = event("x", now + 30 * h); val today = event("t", now + 5 * h)
        val r = build(listOf(soon, live, later, today))
        assertEquals("LIVE", r.live.single().statusLabel); assertEquals("Starts in 45 min", r.soon.single().statusLabel); assertEquals("Upcoming", r.today.single().statusLabel)
        assertEquals("10:45 AM", r.soon.single().timeLabel); assertEquals("3:00 PM", r.today.single().timeLabel)
        assertEquals("Sat 4:00 PM", r.upcoming.single().timeLabel)                                                      // 2027-01-16 16:00 UTC
        assertEquals("the same instant reads differently in another zone", "Sun 3:00 AM", build(listOf(later), zone = TimeZone.getTimeZone("Australia/Sydney")).upcoming.single().timeLabel)
        assertEquals("10:45 AM – 12:45 PM", build(listOf(soon), detail = "s").detail!!.timeRange)
    }

    @Test fun noUrlsOrProviderAddressesReachTheState() {
        val e = event("m", now + h, feeds = listOf(feed("1", logo = "http://u:p@host/logo.png")))
        val d = build(listOf(e), detail = "m").detail!!
        val text = d.toString().replace("http://u:p@host/logo.png", "")
        assertFalse("only the logo address (for the image loader) is carried, never shown as text", text.contains("http"))
    }
}
