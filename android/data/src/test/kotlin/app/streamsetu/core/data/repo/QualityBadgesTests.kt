package app.streamsetu.core.data.repo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QualityBadgesTests {
    @Test fun theWordsInATitleBecomeBadges() {
        assertEquals(listOf("4K", "HDR", "Atmos", "5.1"), QualityBadges.from(listOf("Dune Part Two (2024) [4K HDR] Atmos 5.1")))
        assertEquals(listOf("1080p", "Dolby Vision"), QualityBadges.from(listOf("Heat (1995) 1080p DV")))
        assertEquals(listOf("4K", "HDR10+", "7.1"), QualityBadges.from(listOf("Movie.2020.2160p.UHD.BluRay.HDR10+.DDP7.1")))
    }

    @Test fun aTitleWithNoSuchWordsShowsNothing() {
        assertTrue(QualityBadges.from(listOf("The Matrix (1999)")).isEmpty())
        assertTrue(QualityBadges.from(listOf(null, "")).isEmpty())
        assertTrue(QualityBadges.from(listOf("Dvorak: The Story")).isEmpty())            // "dv" inside a word is not Dolby Vision
        assertTrue(QualityBadges.from(listOf("Chapter 5 1 and 25.10")).isEmpty())         // numbers that only look like channel layouts
    }

    @Test fun onlyTheBestPictureSizeIsShownAndThereIsAnUpperLimit() {
        assertEquals(listOf("4K"), QualityBadges.from(listOf("4K 1080p 720p")))
        assertEquals(4, QualityBadges.from(listOf("4K HDR10+ Dolby Vision Atmos 7.1 5.1")).size)
    }

    @Test fun theFolderNameCounts() = assertEquals(listOf("4K"), QualityBadges.from(listOf("Some Film (2020)", "ENGLISH | 4K")))
}
