package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.WatchTimeEntity
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** What the person has watched, added up from the watch time stored on this device. Nothing here leaves the device. */
data class ViewingStatistics(
    val totalMs: Long = 0,
    /** The last [DAYS] days, oldest first, every day present (zero when nothing was watched). */
    val days: List<Pair<LocalDate, Long>> = emptyList(),
    /** Milliseconds watched in each hour of the day, 0 to 23. */
    val hours: List<Long> = List(24) { 0L },
    val liveMs: Long = 0, val movieMs: Long = 0, val seriesMs: Long = 0,
    val topChannels: List<Top> = emptyList(), val topMovies: List<Top> = emptyList(), val topSeries: List<Top> = emptyList(),
) {
    data class Top(val id: String, val title: String, val ms: Long)
    val isEmpty get() = totalMs <= 0
    val busiestHour: Int? get() = hours.withIndex().maxByOrNull { it.value }?.takeIf { it.value > 0 }?.index
    companion object { const val DAYS = 14 }
}

/** Records and adds up watch time. A recorded slice never counts for more than a few seconds beyond its tick, so a stream left on cannot distort the numbers. */
class StatisticsRepository(private val db: AppDatabase) {
    suspend fun record(itemId: String, kind: String, title: String, ms: Long, zone: ZoneId = ZoneId.systemDefault(), now: Long = System.currentTimeMillis()) {
        if (ms <= 0) return
        val t = Instant.ofEpochMilli(now).atZone(zone)
        db.extras().addWatchTime(t.toLocalDate().toEpochDay(), t.hour, itemId, kind, title.take(120), ms.coerceAtMost(30_000))
    }

    /** [sinceDays] of history: 7, 30 or 365; 0 is everything. */
    suspend fun compute(sinceDays: Int, zone: ZoneId = ZoneId.systemDefault(), now: Long = System.currentTimeMillis()): ViewingStatistics {
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val rows = db.extras().watchTimeSince(if (sinceDays <= 0) 0 else today.toEpochDay() - sinceDays + 1)
        return aggregate(rows, today)
    }

    suspend fun clear() = db.extras().clearWatchTime()

    companion object {
        fun aggregate(rows: List<WatchTimeEntity>, today: LocalDate, topCount: Int = 5): ViewingStatistics {
            val perDay = rows.groupBy { it.day }.mapValues { (_, v) -> v.sumOf { it.ms } }
            val days = (ViewingStatistics.DAYS - 1 downTo 0).map { back -> today.minusDays(back.toLong()).let { it to (perDay[it.toEpochDay()] ?: 0L) } }
            val hours = MutableList(24) { 0L }; rows.forEach { hours[it.hour.coerceIn(0, 23)] += it.ms }
            fun top(kind: String) = rows.filter { it.kind == kind }.groupBy { it.itemId }.map { (id, v) -> ViewingStatistics.Top(id, v.last().title, v.sumOf { it.ms }) }.sortedByDescending { it.ms }.take(topCount)
            fun sum(kind: String) = rows.filter { it.kind == kind }.sumOf { it.ms }
            return ViewingStatistics(rows.sumOf { it.ms }, days, hours, sum("CHANNEL"), sum("MOVIE"), sum("SERIES"), top("CHANNEL"), top("MOVIE"), top("SERIES"))
        }
    }
}
