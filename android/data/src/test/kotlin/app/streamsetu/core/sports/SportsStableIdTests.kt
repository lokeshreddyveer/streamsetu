package app.streamsetu.core.sports

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** An event keeps its id when its feeds change. Phase 2 (focus, scroll position, reminders) relies on this. */
class SportsStableIdTests {
    private val a = "srcA"; private val b = "srcB"
    private val t0 = 1_800_000_000_000L; private val h = 3_600_000L; private val min = 60_000L
    private val ctx = SportsContext("main", false, emptySet(), emptySet())
    private val from = t0 - 6 * h; private val to = t0 + 20 * h

    private fun events(g: FakeGuide, tolerance: Long = 45 * min) = runBlocking { SportsEventService(g, tolerance).events(from, to, ctx) }
    private fun base(): FakeGuide {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "Sports 1"), "Premier League: Arsenal v Chelsea", t0)
        g.add(g.channel("c2", a, "Sports 2"), "Premier League: Arsenal v Chelsea", t0 + 5 * min)
        return g
    }

    @Test fun anEarlierFeedAppearingDoesNotChangeTheId() {
        val before = events(base()).first()
        val g = base(); g.add(g.channel("c3", a, "Sports 3"), "Premier League: Arsenal v Chelsea", t0 - 30 * min)
        val after = events(g).first()
        assertTrue(after.startMs < before.startMs); assertEquals(3, after.feeds.size); assertEquals("the same event", before.id, after.id)
    }

    @Test fun aLaterFeedAppearingDoesNotChangeTheId() {
        val before = events(base()).first()
        val g = base(); g.add(g.channel("c3", a, "Sports 3"), "Premier League: Arsenal v Chelsea", t0 + 40 * min)
        val after = events(g).first(); assertEquals(3, after.feeds.size); assertEquals(before.id, after.id)
    }

    @Test fun removingAFeedEvenTheEarliestDoesNotChangeTheId() {
        val g = base(); g.add(g.channel("c3", a, "Sports 3"), "Premier League: Arsenal v Chelsea", t0 + 20 * min)
        val full = events(g).first()
        for (gone in listOf("c1", "c2", "c3")) {
            val g2 = FakeGuide(); g2.revisions = hashMapOf(a to "r1")
            for (c in g.channels) if (c.id != gone) g2.add(c, "Premier League: Arsenal v Chelsea", g.programmes.getValue(c.id)[0].startMs)
            val after = events(g2).first(); assertEquals(2, after.feeds.size); assertEquals("without $gone", full.id, after.id)
        }
    }

    @Test fun aSmallEpgTimeCorrectionDoesNotChangeTheId() {
        val before = events(base()).first(); val orig = base()
        for (shift in listOf(-20L, -5L, 10L, 25L)) {
            val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
            for (c in orig.channels) g.add(c, "Premier League: Arsenal v Chelsea", orig.programmes.getValue(c.id)[0].startMs + shift * min)
            val after = events(g).first(); assertEquals("shifted by $shift minutes", before.id, after.id); assertNotEquals(before.startMs, after.startMs)
        }
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "Sports 1"), "Premier League: Arsenal v Chelsea", t0 + 12 * min); g.add(g.channel("c2", a, "Sports 2"), "Premier League: Arsenal v Chelsea", t0 + 5 * min)
        assertEquals(before.id, events(g).first().id)
    }

    @Test fun aSourceRefreshKeepsTheIdWhileTheRevisionChanges() {
        val g = base(); val before = events(g).first()
        g.revisions = hashMapOf(a to "r2")
        val after = events(g).first(); assertEquals(before.id, after.id); assertNotEquals(before.guideRevision, after.guideRevision)
        g.revisions = hashMapOf(a to "r3", b to "x1"); g.add(g.channel("b1", b, "B Sports"), "Premier League: Arsenal vs Chelsea", t0 + 8 * min)
        val both = events(g).first(); assertEquals(before.id, both.id); assertEquals(setOf(a, b), both.sourceIds)
    }

    @Test fun theSameSidesPlayingTwiceOnTheSameDateAreTwoStableEvents() {
        val g = base(); g.add(g.channel("c3", a, "Sports 3"), "Premier League: Arsenal v Chelsea", t0 + 8 * h)
        val two = events(g); assertEquals(2, two.size); assertEquals(2, two.map { it.id }.toSet().size)
        g.add(g.channel("c4", a, "Sports 4"), "Premier League: Arsenal v Chelsea", t0 + 8 * h + 15 * min); g.add(g.channel("c5", a, "Sports 5"), "Premier League: Arsenal v Chelsea", t0 - 10 * min)
        val more = events(g)
        assertEquals(2, more.size); assertEquals(two[0].id, more[0].id); assertEquals(two[1].id, more[1].id); assertEquals(3, more[0].feeds.size); assertEquals(2, more[1].feeds.size)
        repeat(5) { assertEquals(more.map { it.id }, events(g).map { it.id }) }
    }

    @Test fun differentEventsGetDifferentIdsAndTheToleranceDoesNotEnterTheId() {
        val g = base(); g.add(g.channel("n1", a, "NBA 1"), "NBA: Lakers vs Celtics", t0)
        val evs = events(g); assertEquals(2, evs.size); assertNotEquals(evs[0].id, evs[1].id)
        assertEquals(evs.map { it.id }, events(g, 20 * min).map { it.id }); assertEquals(evs.map { it.id }, events(g, 3 * h).map { it.id })
    }

    @Test fun reversedSidesAndOtherTitleFormsKeepTheSameId() {
        val g = base(); val before = events(g).first()
        g.add(g.channel("c3", a, "Sports 3"), "Premier League | Chelsea @ Arsenal HD", t0 + 2 * min)
        assertEquals(before.id, events(g).first().id)
    }
}
