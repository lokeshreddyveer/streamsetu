package app.streamsetu.core

import app.streamsetu.core.playback.Chapter
import app.streamsetu.core.playback.EpisodeMarks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EpisodeMarksTests {
    private val chapters = listOf(Chapter("Previously on", 0), Chapter("Opening", 75_000), Chapter("End Credits", 1_500_000))

    @Test fun aRecapIsFoundFromItsChapterAndSkippedToTheNextOne() {
        assertEquals(75_000L, EpisodeMarks.recapEnd(chapters, 20_000, 1_560_000))
        assertNull(EpisodeMarks.recapEnd(chapters, 74_000, 1_560_000))              // already at the end of it
        assertNull(EpisodeMarks.recapEnd(chapters, 300_000, 1_560_000))
        assertNull(EpisodeMarks.recapEnd(listOf(Chapter("Chapter 1", 0)), 10_000, 1_560_000))
    }

    @Test fun creditsComeFromAChapterOrFromTheFirstSkipInTheSeries() {
        assertEquals(1_500_000L, EpisodeMarks.creditsStart(chapters, 1_560_000, null))
        assertNull(EpisodeMarks.creditsStart(emptyList(), 1_560_000, null))         // nothing known yet
        assertEquals(1_620_000L, EpisodeMarks.creditsStart(emptyList(), 1_700_000, 80_000))   // 80 seconds before the end, for every episode
        assertNull(EpisodeMarks.creditsStart(emptyList(), 300_000, 80_000))         // too short to have credits
    }

    @Test fun aJumpToTheEndIsTheCreditsBeingSkipped() {
        assertTrue(EpisodeMarks.isCreditsSkip(1_480_000, 1_550_000, 1_560_000))
        assertFalse(EpisodeMarks.isCreditsSkip(600_000, 700_000, 1_560_000))        // not near the end
        assertFalse(EpisodeMarks.isCreditsSkip(1_480_000, 1_500_000, 1_560_000))    // does not reach the end
    }
}
