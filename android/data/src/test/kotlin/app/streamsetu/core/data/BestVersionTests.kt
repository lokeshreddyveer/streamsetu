package app.streamsetu.core.data

import app.streamsetu.core.data.repo.BestVersion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BestVersionTests {
    private data class Copy(val title: String, val folder: String? = null)
    private val words = { c: Copy -> listOf(c.title, c.folder) }

    @Test fun higherResolutionWinsAndHdrAndSoundBreakTies() {
        val sd = Copy("Film (2024)", "ENGLISH | SD"); val plain = Copy("Film (2024)"); val hd = Copy("Film (2024) 720p"); val fhd = Copy("Film (2024)", "ENGLISH | FHD")
        val uhd = Copy("Film (2024) [4K HDR]"); val uhdDv = Copy("Film (2024) 4K Dolby Vision Atmos")
        assertEquals(listOf(uhdDv, uhd, fhd, hd, plain, sd), BestVersion.order(listOf(sd, plain, hd, fhd, uhd, uhdDv), words))
    }

    @Test fun aCinemaRecordingRanksBelowEverythingElse() {
        val cam = Copy("Whalefall (2026) (English) (HDCAM)", "ENGLISH | 1080p"); val sd = Copy("Whalefall (2026)", "SD")
        assertTrue(BestVersion.score(*words(cam).toTypedArray()) < BestVersion.score(*words(sd).toTypedArray()))
        assertEquals(sd, BestVersion.pick(listOf(cam, sd), cam, words))
    }

    @Test fun theChosenCopyStaysWhenNothingIsBetter() {
        val a = Copy("Film 1080p"); val b = Copy("Film FHD")
        assertEquals(b, BestVersion.pick(listOf(a, b), b, words)); assertEquals(a, BestVersion.pick(listOf(a, b), a, words))
        assertEquals(a, BestVersion.pick(emptyList(), a, words))
    }

    @Test fun copiesThatScoreTheSameKeepTheirOrder() {
        val x = Copy("A"); val y = Copy("B"); val z = Copy("C")
        assertEquals(listOf(x, y, z), BestVersion.order(listOf(x, y, z), words))
    }

    @Test fun aWordInsideAnotherWordIsNotARipOrAResolution() {
        assertEquals(100, BestVersion.score("Tsunami (2004)")); assertEquals(100, BestVersion.score("Scream"))
    }
}
