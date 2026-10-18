package app.streamsetu.core.data.repo

import app.streamsetu.core.data.repo.Similarity.Facts
import app.streamsetu.core.data.repo.Similarity.Item
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SimilarityTests {
    private fun m(id: String, title: String, year: Int? = 2020, rating: Double? = 7.0, plot: String? = null, folder: String? = "F1") = Item(id, title, year, rating, plot, folder)

    @Test fun stemDropsYearQualityLanguageAndSequelMarkers() {
        assertEquals("rolling loud", Similarity.stem("Rolling Loud: The Movie (2026) (HDCAM)"))
        assertEquals("john wick", Similarity.stem("John Wick 3"))
        assertEquals("fast furious", Similarity.stem("Fast & Furious IV"))
        assertEquals("sully", Similarity.stem("Sully (2016) (Tamil)"))
    }

    @Test fun languageIsReadFromTitleOrFolder() {
        assertEquals("tamil", Similarity.languageOf("Sully (2016) (Tamil)", null))
        assertEquals("english", Similarity.languageOf("Sully", "ENGLISH | FHD 2025"))
    }

    @Test fun aSequelRanksFirst() {
        val target = m("t", "John Wick (2014)", 2014, 7.4, "A retired hitman seeks vengeance for the killing of his dog.")
        val r = Similarity.rank(target, null, listOf(m("a", "Toy Story"), m("b", "John Wick 2 (2017)", 2017), m("c", "Notebook", plot = "Two lovers")))
        assertEquals("b", r.first().id)
        assertEquals("Same franchise", r.first().reason)
    }

    @Test fun theSameTitleIsNeverASuggestion() {
        val target = m("t", "Sully (2016)")
        assertFalse(Similarity.rank(target, null, listOf(m("x", "Sully (2016)"), m("y", "Sully 2"))).any { it.id == "x" || it.id == "t" })
    }

    @Test fun aDubOfTheSameShowIsTheSameTitle() {
        val target = m("t", "VisionQuest (Telugu)", folder = "TELUGU")
        val r = Similarity.rank(target, null, listOf(m("a", "VisionQuest (Tamil)", folder = "TAMIL"), m("b", "VisionQuest 2 (Telugu)", folder = "TELUGU")))
        assertFalse(r.any { it.id == "a" })
        assertTrue(r.any { it.id == "b" })
    }

    @Test fun sameDirectorAndGenreCountWhenKnown() {
        val target = m("t", "Inception")
        val tf = Similarity.facts("Action, Sci-Fi", "Leonardo DiCaprio, Elliot Page", "Christopher Nolan")
        val pool = listOf(m("a", "Interstellar"), m("b", "Random Comedy"), m("c", "Heat"))
        val known = mapOf("a" to Similarity.facts("Adventure, Sci-Fi", "Matthew McConaughey", "Christopher Nolan"), "b" to Similarity.facts("Comedy", "", "Someone Else"), "c" to Similarity.facts("Action, Crime", "Al Pacino", "Michael Mann"))
        val r = Similarity.rank(target, tf, pool, known)
        assertEquals("a", r.first().id)
        assertEquals("Same director", r.first().reason)
        assertTrue(r.any { it.id == "c" && it.reason == "Same genre" })
        assertEquals("From the same folder", r.first { it.id == "b" }.reason)   // a thin pool is topped up from the folder, after every real match
        assertEquals("b", r.last().id)
    }

    @Test fun similarStoryUsesRareWords() {
        val target = m("t", "A", plot = "A detective hunts a serial killer through the foggy docks of London.")
        val r = Similarity.rank(target, null, listOf(
            m("a", "B", plot = "Detective chases a serial killer along the docks of Paris."),
            m("b", "C", plot = "A baker opens a shop and falls in love with a customer."),
        ))
        assertEquals("a", r.first().id)
        assertEquals("Similar story", r.first().reason)
    }

    @Test fun otherLanguageIsPenalisedAndAFolderFillsASparsePool() {
        val target = m("t", "Alpha (Tamil)", folder = "TAMIL")
        val r = Similarity.rank(target, null, listOf(m("a", "Beta (Hindi)", folder = "HINDI"), m("b", "Gamma (Tamil)", folder = "TAMIL")))
        assertEquals(listOf("b"), r.map { it.id })
    }

    @Test fun aFranchiseIsListedInTheOrderTheFilmsCameOut() {
        val target = m("t", "Spider-Man: Far From Home (2019)", 2019)
        val pool = listOf(m("a", "Spider-Man: No Way Home (2021)", 2021), m("b", "Spider-Man: Homecoming (2017)", 2017), m("c", "Toy Story (1995)", 1995), m("d", "Spider-Man: Brand New Day (2026)", 2026))
        assertEquals(listOf("b", "t", "a", "d"), Similarity.franchise(target, pool).map { it.id })
    }

    @Test fun aDubOfTheSameFilmAppearsOnlyOnce() {
        val target = m("t", "John Wick (2014)", 2014)
        val pool = listOf(m("a", "John Wick 2 (2017) (Hindi)", 2017, rating = 7.4), m("b", "John Wick 2 (2017) (English)", 2017, rating = null), m("c", "John Wick 3 (2019)", 2019))
        val ids = Similarity.franchise(target, pool).map { it.id }
        assertEquals(listOf("t", "a", "c"), ids)
    }

    @Test fun aFilmWithNoSequelsIsNotAFranchise() {
        assertTrue(Similarity.franchise(m("t", "Sully (2016)", 2016), listOf(m("a", "Toy Story (1995)", 1995))).isEmpty())
    }

    @Test fun theOpenFilmIsKeptEvenIfAnotherCopyLooksBetter() {
        val target = m("t", "Heat (1995)", 1995, rating = null)
        val pool = listOf(m("a", "Heat (1995) (Hindi)", 1995, rating = 8.0), m("b", "Heat 2 (2026)", 2026))
        assertEquals(listOf("t", "b"), Similarity.franchise(target, pool).map { it.id })
    }

    @Test fun unrelatedFilmsThatShareAThemeOrAnArticleAreNotAFranchise() {
        val target = m("t", "The Amazing Spider-Man (2012)", 2012)
        val pool = listOf(m("a", "The Amazing Bulk (2012)", 2012), m("b", "The Amazing Colossal Man (1957)", 1957), m("c", "The Amazing Spider-Man 2 (2014)", 2014))
        assertEquals(listOf("t", "c"), Similarity.franchise(target, pool).map { it.id })
    }

    @Test fun twoUnrelatedFilmsWithTheSameOneWordNameAreNotAFranchise() {
        assertTrue(Similarity.franchise(m("t", "Crash (2004)", 2004), listOf(m("a", "Crash (1996)", 1996))).isEmpty())
        assertEquals(listOf("a", "t"), Similarity.franchise(m("t", "Rocky II (1979)", 1979), listOf(m("a", "Rocky (1976)", 1976))).map { it.id })
    }

    @Test fun everyTagShapeOfTheSameFilmIsOneFilm() {
        val target = m("t", "John Wick (2014) (Telugu)", 2014)
        val pool = listOf(m("a", "John Wick (2014)[Tam, Tel, Hin, Kan, Eng]", 2014, rating = 7.4), m("b", "John Wick Chapter 1 - Keanu Reeves (2014)", 2014), m("c", "John Wick: Chapter 2 (2017)[Tam, Tel]", 2017), m("d", "John Wick: Chapter 2 (2017) (Telugu)", 2017))
        assertEquals(listOf(2014, 2017), Similarity.franchise(target, pool).map { it.year })
        assertEquals("t", Similarity.franchise(target, pool).first().id)       // the open film is the one shown for its year
    }

    @Test fun twoSmallWordsAloneAreNotAFranchise() {
        val target = m("t", "It's a Medical Miracle (2026)", 2026)
        val pool = listOf(m("a", "It's a Good Day to Die (2024)", 2024), m("b", "It's a Medical Miracle 2 (2027)", 2027))
        assertEquals(listOf("t", "b"), Similarity.franchise(target, pool).map { it.id })
    }
}
