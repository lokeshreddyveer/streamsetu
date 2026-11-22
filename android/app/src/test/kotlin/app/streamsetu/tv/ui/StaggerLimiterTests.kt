package app.streamsetu.tv.ui

import app.streamsetu.tv.ui.components.StaggerLimiter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The first-appearance stagger: rows that appear together come in one after another, never more than six steps apart, and only the first time in a session. */
class StaggerLimiterTests {
    private var clock = 1_000L
    private val s = StaggerLimiter { clock }

    @Test fun rowsAppearingTogetherComeInOneAfterAnother() {
        assertEquals(listOf(0L, 35L, 70L, 105L), (1..4).map { s.delayFor("row$it") })
    }

    @Test fun aLongListIsNeverHeldBackMoreThanSixSteps() {
        val delays = (1..20).map { s.delayFor("row$it")!! }
        assertEquals(6 * StaggerLimiter.STEP_MS, delays.max())
    }

    @Test fun aRowThatAppearedBeforeIsSimplyThere() {
        s.delayFor("home:Continue Watching")
        clock += 10_000
        assertNull(s.delayFor("home:Continue Watching"))
    }

    @Test fun aLaterBurstStartsAgainFromZero() {
        s.delayFor("a"); s.delayFor("b")
        clock += StaggerLimiter.BURST_MS + 1
        assertEquals(0L, s.delayFor("c"))
    }
}
