package app.streamsetu.core.data.repo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeywordAlertsTests {
    @Test fun wordsAreValidated() {
        assertEquals(emptyList<String>(), KeywordAlerts.add(emptyList(), "a"))
        assertEquals(listOf("Cricket"), KeywordAlerts.add(emptyList(), "  Cricket "))
        assertEquals(listOf("Cricket"), KeywordAlerts.add(listOf("Cricket"), "cricket"))
        val full = (1..20).map { "word$it" }
        assertEquals(full, KeywordAlerts.add(full, "extra"))
    }

    @Test fun onlyWhatIsComingUpSoonEnoughIsAnnounced() {
        val now = 1_800_000_000_000L
        assertFalse(KeywordAlerts.inWindow(now + 60_000, now))          // too soon
        assertFalse(KeywordAlerts.inWindow(now - 1_800_000, now))       // already started
        assertTrue(KeywordAlerts.inWindow(now + 90 * 60_000, now))
        assertFalse(KeywordAlerts.inWindow(now + 40 * 3_600_000L, now)) // too far ahead
    }

    @Test fun aProgrammeAndWordMakeOneKey() = assertEquals("e1|cricket", KeywordAlerts.key("e1", "Cricket"))
}
