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
}
