package app.streamsetu.core.data

import app.streamsetu.core.data.repo.SmartQuery
import app.streamsetu.core.data.repo.Spelling
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SmartSearchTests {
    @Test fun aYearNarrowsAndFillerWordsAreDropped() {
        assertEquals(SmartQuery.Parsed("hindi", 2024), SmartQuery.parse("hindi movies 2024"))
        assertEquals(SmartQuery.Parsed("batman", 2022), SmartQuery.parse("new batman 2022"))
    }

    @Test fun oneWordIsTakenAsItIs() {
        assertEquals(SmartQuery.Parsed("1917", null), SmartQuery.parse("1917"))
        assertEquals(SmartQuery.Parsed("movies", null), SmartQuery.parse("movies"))
        assertEquals(SmartQuery.Parsed("", null), SmartQuery.parse("   "))
    }

    @Test fun onlyFillerAndAYearLeavesTheYear() {
        assertEquals(SmartQuery.Parsed("", 2024), SmartQuery.parse("movies 2024"))
    }

    @Test fun aNumberThatIsNotAYearStaysInTheTitle() {
        assertEquals(SmartQuery.Parsed("ocean 11", null), SmartQuery.parse("ocean 11"))
        // A four-digit number in range is read as a year, as on the iPhone; the result still has to hold "2049" in its title or year, so the film is found.
        assertEquals(SmartQuery.Parsed("blade runner", 2049), SmartQuery.parse("blade runner 2049"))
    }

    private val vocab = mapOf("inception" to 9, "interstellar" to 5, "batman" to 20, "weapons" to 4, "cricket" to 12, "star" to 30, "sports" to 30)

    @Test fun aMisspeltWordIsFixedFromTheLibrary() {
        assertEquals("inception", Spelling.correct("incepton", vocab))
        assertEquals("batman", Spelling.correct("batmam", vocab))
        assertEquals("star sports", Spelling.correct("star sprots", vocab))        // a swapped pair counts as one slip
    }

    @Test fun aWordBeingTypedIsNotAMistake() {
        assertNull(Spelling.correct("incep", vocab))
        assertNull(Spelling.correct("crick", vocab))
    }

    @Test fun aKnownWordIsLeftAlone() {
        assertNull(Spelling.correct("batman", vocab))
        assertNull(Spelling.correct("xyz", vocab))          // too short to judge
    }

    @Test fun nothingCloseMeansNoGuess() {
        assertNull(Spelling.correct("zzzzzzzz", vocab))
        assertNull(Spelling.correct("anything", emptyMap()))
    }

    @Test fun editDistanceCountsASwapAsOne() {
        assertEquals(1, Spelling.distance("sprots", "sports", 2))
        assertEquals(1, Spelling.distance("batmam", "batman", 2))
        assertEquals(3, Spelling.distance("abcdef", "uvwxyz", 2))           // above the limit it just says "too far"
    }
}
