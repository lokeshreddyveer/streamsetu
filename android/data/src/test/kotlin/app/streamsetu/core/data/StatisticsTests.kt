package app.streamsetu.core.data

import app.streamsetu.core.data.db.WatchTimeEntity
import app.streamsetu.core.data.repo.StatisticsRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class StatisticsTests {
    private val today = LocalDate.of(2026, 10, 14)
    private fun row(daysAgo: Int, hour: Int, id: String, kind: String, title: String, ms: Long) = WatchTimeEntity(today.minusDays(daysAgo.toLong()).toEpochDay(), hour, id, kind, title, ms)

    @Test fun nothingWatchedIsEmptyWithFourteenZeroDays() {
        val s = StatisticsRepository.aggregate(emptyList(), today)
        assertTrue(s.isEmpty); assertEquals(14, s.days.size); assertEquals(today, s.days.last().first); assertNull(s.busiestHour)
    }

    @Test fun totalsSplitByKindAndRankTheTopItems() {
        val rows = listOf(
            row(0, 20, "c1", "CHANNEL", "BBC One", 3_600_000), row(0, 21, "c1", "CHANNEL", "BBC One", 1_800_000), row(1, 20, "c2", "CHANNEL", "CNN", 600_000),
            row(2, 9, "m1", "MOVIE", "Heat", 7_200_000), row(3, 22, "s1", "SERIES", "The Bear", 2_400_000),
        )
        val s = StatisticsRepository.aggregate(rows, today)
        assertEquals(3_600_000L + 1_800_000 + 600_000 + 7_200_000 + 2_400_000, s.totalMs)
        assertEquals(6_000_000L, s.liveMs); assertEquals(7_200_000L, s.movieMs); assertEquals(2_400_000L, s.seriesMs)
        assertEquals(listOf("BBC One", "CNN"), s.topChannels.map { it.title }); assertEquals(5_400_000L, s.topChannels.first().ms)
        assertEquals(9, s.busiestHour)
        assertEquals(5_400_000L, s.days.last().second); assertEquals(600_000L, s.days[12].second)
    }
}
