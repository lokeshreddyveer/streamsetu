package app.streamsetu.core.data.repo

import app.streamsetu.core.data.repo.OtherVersions.Candidate
import app.streamsetu.core.data.repo.OtherVersions.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OtherVersionsTests {
    private fun movie(id: String, title: String, year: Int? = null, folder: String? = null, source: String = "s1", playlist: String? = "Home",
                      duration: Int? = null, rating: String? = null, plot: String? = null, provider: String? = null) =
        Candidate(id, Kind.MOVIE, title, year, folder, source, playlist, rating = rating, plot = plot, durationSec = duration, providerKey = provider)

    @Test fun dubsListedAsSeparateTitlesAreGrouped() {
        val open = movie("ta", "Leo (2023) (Tamil) FHD")
        val r = OtherVersions.group(open, listOf(open, movie("hi", "Leo 2023 Hindi"), movie("te", "Leo (2023)", folder = "TELUGU MOVIES"), movie("x", "Leon (1994)")))
        assertEquals(listOf("ta", "hi", "te"), r.map { it.id })
        assertEquals(listOf("Tamil", "Hindi", "Telugu"), r.map { it.language })
        assertEquals(listOf("தமிழ்", "हिन्दी", "తెలుగు"), r.map { it.native })
        assertEquals(listOf("FHD", null, null), r.map { it.quality })
        assertTrue(r.first().current); assertTrue(r.drop(1).none { it.current })
    }

    @Test fun aTwinFromADuplicatePlaylistIsHidden() {
        val open = movie("a", "Leo (2023)", folder = "TAMIL | GENERAL", source = "s1", playlist = "Lokesh")
        val pool = listOf(
            movie("a2", "Leo (2023)", folder = "TAMIL | GENERAL", source = "s2", playlist = "Lokesh"),          // the same film in the duplicate playlist
            movie("h", "Leo (2023)", folder = "HINDI | GENERAL"), movie("h2", "Leo (2023)", folder = "HINDI | GENERAL", source = "s2", playlist = "Lokesh"),
        )
        assertEquals(listOf("Tamil", "Hindi"), OtherVersions.group(open, pool).map { it.language })
        // The same provider id and running time is a twin too, whatever the folder is called there.
        assertTrue(OtherVersions.twin(movie("x", "Leo", provider = "77", duration = 9000), movie("y", "LEO 2023", source = "s2", provider = "77", duration = 9000)))
    }

    @Test fun aFurtherVersionOfTheSameLanguageIsToldApartByItsFolderNeverByAPlaylistName() {
        val open = movie("a", "Leo (2023)", folder = "TAMIL | GENERAL", source = "s1", playlist = "Lokesh")
        val r = OtherVersions.group(open, listOf(movie("b", "Leo (2023)", folder = "TAMIL | 2026", source = "s2", playlist = "Lokesh")))
        assertEquals(listOf("தமிழ்", "2026"), r.map { it.native })
        assertTrue("no playlist name anywhere", r.none { "Lokesh" in it.label || "Playlist" in it.label || it.native?.contains("Playlist") == true })
    }

    @Test fun withNothingInTheFolderTheQualityAndLengthTellTheVersionsApart() {
        val open = movie("a", "Leo (2023)", folder = "TAMIL", source = "s1")
        val r = OtherVersions.group(open, listOf(movie("b", "Leo (2023) FHD", folder = "TAMIL", source = "s2", duration = 6480)))
        assertEquals(listOf("தமிழ்", "FHD · 1h 48m"), r.map { it.native })
        val bare = OtherVersions.group(open, listOf(movie("b", "Leo (2023) FHD", folder = "TAMIL MOVIES", source = "s2")))
        assertEquals("Movies", bare[1].native)
    }

    @Test fun aFolderNameIsCleanedOfItsLanguageAndSeparators() {
        assertEquals("2026", OtherVersions.folderWords("TELUGU | 2026"))
        assertEquals("FHD 2025", OtherVersions.folderWords("ENGLISH | FHD 2025"))
        assertEquals("General", OtherVersions.folderWords("TAMIL | GENERAL"))
        assertNull(OtherVersions.folderWords("HINDI"))
    }

    @Test fun theLanguageIsReadFromTheFolderWithDubsAndSubtitlesUnderstood() {
        assertEquals(OtherVersions.Language("Hindi", true, null), OtherVersions.languageOf("Leo", "ENGLISH | HINDI DUBBED"))
        assertEquals(OtherVersions.Language("Hindi", true, null), OtherVersions.languageOf("Leo", "SOUTH INDIAN | HINDI DUBBED"))
        assertEquals(OtherVersions.Language("Hindi", true, null), OtherVersions.languageOf("Leo", "DUBBED IN HINDI"))
        assertEquals("Bengali", OtherVersions.languageOf("Leo", "BANGLA | GENERAL").name)
        assertEquals("English", OtherVersions.languageOf("Leo", "ENGLISH | ARABIC SUBTITLES").name)
        assertEquals("Telugu", OtherVersions.languageOf("Leo", "TELUGU | GENERAL").name)
        // A tag in the title wins over the folder.
        assertEquals("Tamil", OtherVersions.languageOf("Leo (Tamil)", "TELUGU | GENERAL").name)
        // No language anywhere: the folder's own words.
        assertEquals(OtherVersions.Language(null, false, "Indian"), OtherVersions.languageOf("Leo", "INDIAN | GENERAL"))
        assertEquals("Multi language", OtherVersions.languageOf("Leo", "(MULTI LANGUAGE)").folderLabel)
    }

    @Test fun aHindiDubIsNotDroppedAsAnEnglishDuplicate() {
        val open = movie("e", "Oppenheimer (2023)", folder = "ENGLISH | GENERAL")
        val r = OtherVersions.group(open, listOf(movie("h", "Oppenheimer (2023)", folder = "ENGLISH | HINDI DUBBED")))
        assertEquals(listOf("English", "Hindi"), r.map { it.language })
        assertEquals("Dubbed", r[1].native); assertTrue(r[1].dubbed)
        assertEquals("Hindi, dubbed", r[1].label)
    }

    @Test fun aYearApartMatchesOnlyWithSomethingElseAgreeing() {
        val open = movie("a", "Kalki 2898 AD (2024)", folder = "TELUGU | GENERAL", duration = 10_860)
        assertEquals(2, OtherVersions.group(open, listOf(movie("b", "Kalki 2898 AD (2023)", folder = "HINDI | GENERAL", duration = 10_800))).size)
        assertTrue("different running time", OtherVersions.group(open, listOf(movie("b", "Kalki 2898 AD (2023)", folder = "HINDI | GENERAL", duration = 7_200))).isEmpty())
        assertTrue("two years apart", OtherVersions.group(open, listOf(movie("b", "Kalki 2898 AD (2022)", folder = "HINDI | GENERAL", duration = 10_860))).isEmpty())
        // The same rating or the same start of the description agrees too.
        assertEquals(2, OtherVersions.group(movie("a", "Kalki 2898 AD (2024)", rating = "7.4"), listOf(movie("b", "Kalki 2898 AD (2023) Hindi", rating = "7.4"))).size)
    }

    @Test fun aShortOneWordTitleNeedsTwoSignalsForAYearApart() {
        val open = movie("a", "Stolen (2023)", folder = "ENGLISH | GENERAL", duration = 6000, rating = "6.1")
        assertTrue(OtherVersions.group(open, listOf(movie("b", "Stolen (2024)", folder = "HINDI | GENERAL", duration = 6020))).isEmpty())
        assertEquals(2, OtherVersions.group(open, listOf(movie("b", "Stolen (2024)", folder = "HINDI | GENERAL", duration = 6020, rating = "6.1"))).size)
    }

    @Test fun aMissingYearMatchesALongerTitleOrWithASignal() {
        assertEquals(2, OtherVersions.group(movie("a", "Kalki 2898 AD (2024)", folder = "TELUGU"), listOf(movie("b", "Kalki 2898 AD", folder = "HINDI"))).size)
        assertTrue(OtherVersions.group(movie("a", "Stolen (2024)", folder = "ENGLISH"), listOf(movie("b", "Stolen", folder = "HINDI"))).isEmpty())
        assertEquals(2, OtherVersions.group(movie("a", "Stolen (2024)", folder = "ENGLISH", rating = "6.1"), listOf(movie("b", "Stolen", folder = "HINDI", rating = "6.1"))).size)
    }

    @Test fun aSequelIsNeverAnotherVersion() {
        assertTrue(OtherVersions.group(movie("a", "John Wick (2014) Hindi"), listOf(movie("b", "John Wick 2 Tamil"), movie("c", "John Wick Chapter 2"))).isEmpty())
    }

    @Test fun aMovieNeverGroupsWithASeries() {
        val open = movie("a", "Leo (2023) Tamil")
        assertTrue(OtherVersions.group(open, listOf(Candidate("s", Kind.SERIES, "Leo (2023) Hindi", null, null, "s1", "Home"))).isEmpty())
    }

    @Test fun anUnknownLanguageIsLabelledByItsFolderOrQuality() {
        val r = OtherVersions.group(movie("a", "Leo (2023)", folder = "TAMIL"), listOf(movie("b", "Leo (2023)", folder = "INDIAN | GENERAL"), movie("c", "Leo (2023) 4K")))
        assertEquals(listOf("Tamil", "Indian", null), r.map { it.language })
        assertEquals("4K", r[2].label)
    }

    @Test fun spellingOfTheTitleDoesNotKeepVersionsApart() {
        assertEquals(OtherVersions.key("The Fast & Furious (2009)"), OtherVersions.key("Fast and Furious 2009 Hindi"))
    }

    @Test fun thePreferredLanguageComesRightAfterTheOpenOne() {
        val open = movie("a", "Leo (2023) Tamil")
        val r = OtherVersions.group(open, listOf(movie("h", "Leo 2023 Hindi"), movie("t", "Leo 2023 Telugu"), movie("e", "Leo 2023 English")), preferred = "telugu")
        assertEquals(listOf("Tamil", "Telugu", "English", "Hindi"), r.map { it.language })
    }

    @Test fun qualityAndYearAreReadFromTheTitle() {
        assertEquals("4K", OtherVersions.qualityOf("Leo UHD")); assertEquals("CAM", OtherVersions.qualityOf("Leo HDCAM")); assertEquals("FHD", OtherVersions.qualityOf("Leo 1080p"))
        assertNull(OtherVersions.qualityOf("Leo"))
        assertEquals(2023, OtherVersions.yearOf("Leo (2023)", null)); assertEquals(1999, OtherVersions.yearOf("Leo (2023)", 1999)); assertNull(OtherVersions.yearOf("Leo 12345", null))
    }

    @Test fun nothingWhenThereIsNoOtherVersion() {
        val open = movie("a", "Leo (2023) Tamil")
        assertTrue(OtherVersions.group(open, listOf(open)).isEmpty())
        assertTrue(OtherVersions.group(movie("x", "2023"), listOf(movie("y", "2023 Tamil"))).isEmpty())
        assertFalse(OtherVersions.sameTitle(movie("x", "Leo"), Candidate("y", Kind.SERIES, "Leo", null, null, "s1", null)))
    }
}

class OpenVersionLabelTests {
    @Test fun theOpenVersionIsDescribedForTheLineUnderTheTitle() {
        val v = OtherVersions.describe(Candidate("h", Kind.MOVIE, "Leo (2023) FHD", 2023, "ENGLISH | HINDI DUBBED", "s1", "Home"))
        assertEquals("Hindi · Dubbed · FHD", v.label)
        assertEquals("Tamil", OtherVersions.describe(Candidate("t", Kind.MOVIE, "Leo (2023)", 2023, "TAMIL | GENERAL", "s1", null)).label)
        assertEquals("", OtherVersions.describe(Candidate("x", Kind.MOVIE, "Leo (2023)", 2023, null, "s1", null)).label)
    }
}
