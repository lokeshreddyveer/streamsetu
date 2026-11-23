package app.streamsetu.core.data.repo

import org.junit.Assert.*
import org.junit.Test

class TitlePageTextTests {
    @Test fun onlyACredibleRatingIsShown() {
        assertEquals("★ 7.4", TitlePageText.rating("7.4")); assertEquals("★ 8.0", TitlePageText.rating(" 8 "))
        for (junk in listOf(null, "", "0", "0.0", "10", "10.0", "abc", "-1", "11")) assertNull("junk $junk", TitlePageText.rating(junk))
    }
    @Test fun metaLineIsOneQuietLineInOrder() {
        assertEquals("2006 · 2h 48m · PG-13 · FHD · ★ 7.4", TitlePageText.metaLine(2006, "2h 48m", "PG-13", "FHD", "7.4"))
        assertEquals("2006", TitlePageText.metaLine(2006, null, null, null, "10.0"))
        assertEquals("", TitlePageText.metaLine(null, null, null, null, null))
    }
    @Test fun runtimeAndQuality() {
        assertEquals("1h 48m", TitlePageText.runtime("01:48:00")); assertEquals("45m", TitlePageText.runtime("45 min")); assertEquals("2h", TitlePageText.runtime("7200"))
        assertNull(TitlePageText.runtime("00:00:00")); assertNull(TitlePageText.runtime(null))
        assertEquals("FHD", TitlePageText.quality("Heat 1995 [FHD]")); assertEquals("4K", TitlePageText.quality("Heat UHD")); assertEquals("HD", TitlePageText.quality("Heat 720p")); assertNull(TitlePageText.quality("Heat"))
    }
    @Test fun versionPickerShowsOnlyWithMoreThanOneVersion() {
        assertNull(TitlePageText.pickerLabel("English", 1)); assertNull(TitlePageText.pickerLabel(null, 0))
        assertEquals("English · 2 versions ▾", TitlePageText.pickerLabel("English", 2))
        assertEquals("3 versions ▾", TitlePageText.pickerLabel(null, 3))
    }
    @Test fun playLabels() {
        assertEquals("Play", TitlePageText.playMovie(0, 0, false))
        assertEquals("Resume · 34m left", TitlePageText.playMovie(66 * 60_000L, 100 * 60_000L, true))
        assertEquals("Resume · 1h 4m left", TitlePageText.playMovie(10 * 60_000L, 74 * 60_000L, true))
        assertEquals("Play S1 E3", TitlePageText.playSeries(null, 1 to 3, 1 to 1, false, false))
        assertEquals("Resume S2 E4", TitlePageText.playSeries(2 to 4, null, 1 to 1, false, false))
        assertEquals("Play S1 E1", TitlePageText.playSeries(null, null, 1 to 1, false, false))
        assertEquals("Watch again", TitlePageText.playSeries(null, null, 1 to 1, true, false))
        assertEquals("Loading episodes…", TitlePageText.playSeries(null, null, null, false, true))
    }
    @Test fun genresPeopleAndDetails() {
        assertEquals(listOf("Action", "Drama", "Thriller"), TitlePageText.genres("Action, Drama / Thriller"))
        assertEquals(listOf("A B", "C D", "E F"), TitlePageText.people("A B, C D and E F"))
        val rows = TitlePageText.details("Dir One", "A B, C D", null, null, "2006-04-28", true)
        assertEquals(listOf("Directed by", "Starring", "Released", "In folder"), rows.map { it.label })
        assertEquals(listOf("A B", "C D"), rows[1].names); assertTrue(rows.last().folder)
        assertTrue(TitlePageText.details(null, null, null, null, null, false).isEmpty())
    }
}
