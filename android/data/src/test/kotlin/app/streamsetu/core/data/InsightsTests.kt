package app.streamsetu.core.data

import app.streamsetu.core.data.db.WatchTimeEntity
import app.streamsetu.core.data.repo.*
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class InsightsTests {
    private class MapStore : LimitStore {
        val m = mutableMapOf<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String?) { if (value == null) m.remove(key) else m[key] = value }
    }
    private val today = LocalDate.of(2026, 10, 28)
    private fun row(daysAgo: Int, hour: Int, item: String, ms: Long = 600_000) = WatchTimeEntity(today.minusDays(daysAgo.toLong()).toEpochDay(), hour, item, "CHANNEL", item, ms)

    @Test fun digestComparesWithTheWeekBefore() {
        val s = ViewingStatistics(totalMs = 3 * 3600_000L)
        val d = WeeklyDigest.make(s, 2 * 3600_000L, 0, emptyList())
        assertEquals("You watched 3 h this week", d.headline)
        assertEquals("50% more than the week before", d.comparison)
    }
    @Test fun aQuietWeekSaysSo() {
        val d = WeeklyDigest.make(ViewingStatistics(), 3600_000L, 0, emptyList())
        assertEquals("A quiet week", d.headline); assertNull(d.comparison); assertTrue(d.isEmpty)
    }
    @Test fun notificationKeepsToThreeLines() {
        val s = ViewingStatistics(totalMs = 3600_000L, hours = List(24) { if (it == 21) 3600_000L else 0L }, topSeries = listOf(ViewingStatistics.Top("s", "Show", 3000_000L)))
        val d = WeeklyDigest.make(s, 3600_000L, 1, listOf("A: Ends today"))
        assertEquals(3, d.notificationBody.split(". ").size)
    }
    @Test fun privacyReflectsSettings() {
        val r = PrivacyReport.make(PrivacyReport.State(diagnosticsOn = false, hasTmdbKey = true, lanSync = false, historyCount = 1))
        fun st(id: String) = r.sentOut.first { it.id == id }.status
        assertEquals(PrivacyReport.Status.OFF, st("diag")); assertEquals(PrivacyReport.Status.ON, st("tmdb")); assertEquals(PrivacyReport.Status.OFF, st("lan"))
        assertTrue(r.stored.first { it.id == "history" }.detail.startsWith("1 title."))
    }
    @Test fun usualEveningFindsTheHabit() {
        val rows = listOf(row(1, 21, "show"), row(2, 21, "show"), row(3, 20, "news"), row(4, 21, "show"), row(5, 12, "lunch"))
        val p = UsualEvening.pick(rows, today)
        assertEquals("show", p?.itemId); assertEquals(21, p?.hour); assertEquals(4, p?.days)
    }
    @Test fun tooFewDaysIsNoHabit() = assertNull(UsualEvening.pick(listOf(row(1, 21, "a"), row(2, 21, "a"), row(3, 21, "a")), today))
    @Test fun oldViewingIsIgnored() = assertNull(UsualEvening.pick((40..45).map { row(it, 21, "a") }, today))
    @Test fun startOverRules() {
        val now = 1_800_000_000_000L
        fun min(m: Long) = now + m * 60_000L
        assertTrue(StartOver.canOffer(min(-30), min(60), 3, now))
        assertFalse(StartOver.canOffer(min(-2), min(90), 3, now))
        assertFalse(StartOver.canOffer(min(-30), min(60), 0, now))
        assertFalse(StartOver.canOffer(min(-10), min(3), 3, now))
        assertFalse(StartOver.canOffer(min(-90), min(-30), 3, now))
    }
    @Test fun limitCountsDownAndAParentCanAddTime() {
        val l = ViewingLimits(MapStore()); val day = today.toEpochDay()
        l.set("k", ViewingLimit(dailyMinutes = 30))
        l.addUsage("k", 20 * 60.0, day)
        assertEquals(600.0, l.remaining("k", day)!!, 0.001)
        assertNull(l.block("k", day, 12 * 60))
        l.addUsage("k", 10 * 60.0, day)
        assertEquals(ViewingBlock.DailyLimit, l.block("k", day, 12 * 60))
        l.grantExtra("k", day)
        assertNull(l.block("k", day, 12 * 60))
        assertNull(l.block("k", day + 1, 9 * 60))
    }
    @Test fun bedtimeAcrossMidnight() {
        val l = ViewingLimits(MapStore()); val day = today.toEpochDay()
        l.set("k", ViewingLimit(bedtimeOn = true, bedtimeStart = 21 * 60, bedtimeEnd = 7 * 60))
        assertNull(l.block("k", day, 15 * 60))
        assertEquals(ViewingBlock.Bedtime(7 * 60), l.block("k", day, 22 * 60))
        assertEquals(ViewingBlock.Bedtime(7 * 60), l.block("k", day, 3 * 60))
        assertNull(l.block("k", day, 7 * 60))
    }
    @Test fun eachProfileHasItsOwnLimit() {
        val l = ViewingLimits(MapStore()); val day = today.toEpochDay()
        l.set("a", ViewingLimit(dailyMinutes = 30)); l.addUsage("a", 1800.0, day)
        assertEquals(ViewingBlock.DailyLimit, l.block("a", day, 600)); assertNull(l.block("b", day, 600))
    }
    @Test fun summaryReadsPlainly() {
        assertEquals("No limits", ViewingLimit().summary())
        assertEquals("90 min a day, none 21:00 to 07:00", ViewingLimit(90, true).summary())
        assertEquals("2 h a day", ViewingLimit(120).summary())
    }

    @Test fun connectionAdvice() {
        assertNotNull(ConnectionAdvice.message(1, 1)); assertNull(ConnectionAdvice.message(0, 1)); assertNull(ConnectionAdvice.message(2, 3)); assertNotNull(ConnectionAdvice.message(3, 3))
        assertNull(ConnectionAdvice.message(4, null)); assertNull(ConnectionAdvice.message(4, 0))
        assertTrue(ConnectionAdvice.message(1, 1)!!.contains("1 stream at a time")); assertTrue(ConnectionAdvice.message(2, 2)!!.contains("2 streams at a time"))
    }
    @Test fun favouritePerson() {
        assertEquals("Mahesh Babu" to 2, FavouritePerson.pick(mapOf("a" to listOf("Mahesh Babu", "Rajamouli"), "b" to listOf("Mahesh Babu", "Other"), "c" to listOf("Someone"))))
        assertNull(FavouritePerson.pick(mapOf("a" to listOf("X"), "b" to listOf("Y")))); assertNull(FavouritePerson.pick(emptyMap()))
        assertEquals(2, FavouritePerson.pick(mapOf("a" to listOf("Keanu Reeves"), "b" to listOf("keanu  reeves")))?.second)
    }
}
