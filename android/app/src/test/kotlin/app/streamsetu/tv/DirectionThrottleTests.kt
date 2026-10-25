package app.streamsetu.tv

import app.streamsetu.tv.nav.DirectionThrottle
import org.junit.Assert.*
import org.junit.Test

class DirectionThrottleTests {
    private val DOWN = 20; private val UP = 19

    @Test fun aSinglePressAlwaysGoesThrough() = assertTrue(DirectionThrottle().accept(DOWN, 1000, 1000))

    @Test fun ordinaryTappingIsNeverDropped() {
        val t = DirectionThrottle(); var now = 1000L
        repeat(20) { assertTrue("tap $it", t.accept(DOWN, now, now)); now += 180 }          // about 5 taps a second
    }

    @Test fun aHeldButtonIsThinnedToTheMinimumGap() {
        val t = DirectionThrottle(minGapMs = 40); var now = 1000L; var taken = 0
        repeat(100) { if (t.accept(DOWN, now, now)) taken++; now += 10 }                     // 100 presses at 100 a second
        assertTrue("took $taken", taken in 20..26)                                           // about one in four
    }

    @Test fun aDifferentDirectionAlwaysGoesThroughAtOnce() {
        val t = DirectionThrottle(); t.accept(DOWN, 1000, 1000)
        assertTrue(t.accept(UP, 1005, 1005))
    }

    @Test fun aPressTooSoonAfterTheLastOneIsDropped() {
        val t = DirectionThrottle(minGapMs = 40); t.accept(DOWN, 1000, 1000)
        assertFalse(t.accept(DOWN, 1010, 1010))
        assertTrue(t.accept(DOWN, 1045, 1045))
    }

    @Test fun aPauseStartsAFreshStream() {
        val t = DirectionThrottle(); t.accept(DOWN, 1000, 1000)
        assertTrue(t.accept(DOWN, 2000, 2000))
    }

    @Test fun backlogBehindASlowFrameIsDroppedSoTheCursorStopsWhenTheButtonIsReleased() {
        val t = DirectionThrottle(minGapMs = 40, maxAgeMs = 120)
        var now = 1000L; assertTrue(t.accept(DOWN, now, now))
        // the screen was busy for 140 ms; ten presses piled up in the queue meanwhile and are delivered together
        val queued = (1..10).map { 1000L + it * 12 }
        now += 140
        val handled = queued.count { ev -> t.accept(DOWN, ev, now) }
        assertTrue("handled $handled", handled <= 1)                                          // the stale ones are dropped; at most the newest still counts
    }

    @Test fun resetForgetsTheStream() {
        val t = DirectionThrottle(); t.accept(DOWN, 1000, 1000); t.reset()
        assertTrue(t.accept(DOWN, 1001, 1001))
    }
}
