package app.streamsetu.core.data.repo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NaturalQueryTests {
    @Test fun aSentenceBecomesFilters() {
        val q = NaturalQuery.parse("telugu movies 2024 I haven't watched")
        assertEquals("Telugu", q.language); assertEquals(2024, q.year); assertTrue(q.unwatched); assertEquals("", q.text)
        assertEquals(listOf("Telugu", "2024", "unwatched"), q.summary)
    }

    @Test fun whatIsNotUnderstoodStaysAsTheTitle() {
        val q = NaturalQuery.parse("hindi action heist 4k")
        assertEquals("Hindi", q.language); assertEquals("4K", q.quality); assertEquals("action heist", q.text)
    }

    @Test fun ordinaryTitlesAreUntouched() {
        for (t in listOf("Heat", "Look Who's Back", "1917", "2012", "The Outsider", "Sarkaru Vaari Paata")) { val q = NaturalQuery.parse(t); assertFalse(t, q.isStructured); assertEquals(t, q.text) }
        val o = NaturalQuery.parse("Oppenheimer 2023"); assertEquals(2023, o.year); assertEquals("oppenheimer", o.text)
    }

    @Test fun decadesRatingsAndRecency() {
        assertEquals(1990, NaturalQuery.parse("action 90s").decade); assertEquals(8.0, NaturalQuery.parse("thriller rated 8+").minRating!!, 0.0)
        assertEquals(8.0, NaturalQuery.parse("best rated english").minRating!!, 0.0); assertTrue(NaturalQuery.parse("my favourites in 1080p").favorites)
        assertTrue(NaturalQuery.parse("recently added telugu").recent)
    }
}
