package app.streamsetu.core

import app.streamsetu.core.playback.IntroSkip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntroSkipTests {
    @Test fun buttonShowsInTheOpeningOnly() {
        assertNull(IntroSkip.target(1_000, null))                       // the first seconds: too early
        assertEquals(90_000L, IntroSkip.target(10_000, null))           // default length
        assertNull(IntroSkip.target(89_000, null))                      // nearly over
        assertNull(IntroSkip.target(200_000, null))
        assertEquals(60_000L, IntroSkip.target(10_000, 60_000))         // learned from an earlier skip
        assertNull(IntroSkip.target(10 * 60_000, 20 * 60_000))          // never outside the first five minutes
    }

    @Test fun aBigEarlyJumpIsLearned() {
        assertTrue(IntroSkip.isOpeningSkip(5_000, 75_000))
        assertFalse(IntroSkip.isOpeningSkip(5_000, 20_000))             // a small seek
        assertFalse(IntroSkip.isOpeningSkip(10 * 60_000, 11 * 60_000)) // later in the episode
        assertFalse(IntroSkip.isOpeningSkip(75_000, 5_000))             // backwards
    }
}
