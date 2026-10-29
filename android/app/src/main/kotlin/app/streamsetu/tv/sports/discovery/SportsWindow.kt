package app.streamsetu.tv.sports.discovery

/** The windows the Sports screens ask the event service for. One definition, so the hub, Search and the pages all hit the same cache entries. */
object SportsWindow {
    private const val QUARTER = 900_000L
    private const val HOUR = 3_600_000L
    const val MAX_CATCH_UP_DAYS = 3

    /** Live, starting soon and upcoming: four hours back to three days ahead, on quarter hours. */
    fun hub(nowMs: Long): Pair<Long, Long> { val from = nowMs / QUARTER * QUARTER - 4 * HOUR; return from to from + 72 * HOUR }

    /** Catch-Up for a page: back as far as the channels declare (at most three days), up to the quarter hour now. */
    fun history(nowMs: Long, days: Int): Pair<Long, Long> { val to = nowMs / QUARTER * QUARTER; return (to - days.coerceIn(0, MAX_CATCH_UP_DAYS) * 24 * HOUR) to to }
}
