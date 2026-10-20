package app.streamsetu.core.data.repo

import app.streamsetu.core.data.repo.AccountStatus.Level
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AccountStatusTests {
    private val now = 1_800_000_000_000L
    private fun st(days: Int?, status: String = "Active") = AccountStatus(status, if (days == null) 0 else now + days * 86_400_000L)

    @Test fun levelsFollowTheEndDate() {
        assertEquals(Level.FINE, st(60).level(now)); assertEquals(Level.SOON, st(7).level(now)); assertEquals(Level.SOON, st(1).level(now))
        assertEquals(Level.ENDED, st(-2).level(now)); assertEquals(Level.FINE, st(null).level(now))
        assertEquals(Level.ENDED, st(60, "Expired").level(now))
        assertTrue(st(60, "Disabled").summary(now).startsWith("Not active"))
    }

    @Test fun summariesReadNaturally() {
        assertTrue(st(54).summary(now).endsWith("(54 days left)")); assertTrue(st(0).summary(now).startsWith("Ends today"))
        assertTrue(st(1).summary(now).startsWith("Ends tomorrow")); assertTrue(st(-1).summary(now).startsWith("Ended yesterday"))
        assertTrue(st(-5).summary(now).startsWith("Ended 5 days ago")); assertEquals("No end date", st(null).summary(now))
    }
}
