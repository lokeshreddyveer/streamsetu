package app.streamsetu.core.data

import app.streamsetu.core.data.repo.SearchText
import org.junit.Assert.*
import org.junit.Test

class SearchTextTests {
    @Test fun normalizeRemovesCaseAccentsAndPunctuation() {
        assertEquals("amelie", SearchText.normalize("Am\u00E9lie"))
        assertEquals("spider man no way home", SearchText.normalize("Spider-Man: No Way Home!"))
    }
    @Test fun matchQueryUsesPrefixes() = assertEquals("bat* man*", SearchText.matchQuery("  Bat  Man "))
    @Test fun rankingPrefersExactThenPrefixThenWord() {
        val exact = SearchText.score("Heat", "heat")
        val prefix = SearchText.score("Heat Wave", "heat")
        val word = SearchText.score("The Heat", "heat")
        val part = SearchText.score("Wheat Fields", "heat")
        assertTrue(exact > prefix && prefix > word && word > part && part > 0)
        assertEquals(0, SearchText.score("Casablanca", "heat"))
    }
    @Test fun fuzzyFindsSmallTyposOnly() {
        assertTrue(SearchText.fuzzyScore("Interstellar", "intersteler") > 0)
        assertEquals(0, SearchText.fuzzyScore("Interstellar", "gladiator"))
    }
    @Test fun distanceIsBounded() {
        assertEquals(1, SearchText.distance("kitten", "kittan"))
        assertTrue(SearchText.distance("abcdef", "uvwxyz") > 2)
    }
}
