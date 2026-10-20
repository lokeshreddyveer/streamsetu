package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.WatchTimeEntity
import java.time.LocalDate

/** "Your week": what was watched in the last seven days, what is new and what needs attention. Worked out on this device; nothing is sent anywhere. */
data class WeeklyDigest(
    val thisWeekMs: Long = 0, val lastWeekMs: Long = 0, val topTitle: String? = null, val busiestHour: Int? = null,
    val seriesWithNewEpisodes: Int = 0, val subscriptionNotes: List<String> = emptyList(),
) {
    val isEmpty get() = thisWeekMs <= 0 && seriesWithNewEpisodes == 0 && subscriptionNotes.isEmpty()
    val headline get() = if (thisWeekMs <= 0) "A quiet week" else "You watched ${duration(thisWeekMs)} this week"
    val comparison: String?
        get() {
            if (thisWeekMs <= 0 || lastWeekMs <= 0) return null
            val diff = Math.round((thisWeekMs - lastWeekMs).toDouble() / lastWeekMs * 100).toInt()
            return when { Math.abs(diff) < 5 -> "About the same as the week before"; diff > 0 -> "$diff% more than the week before"; else -> "${-diff}% less than the week before" }
        }
    val lines: List<String>
        get() = buildList {
            comparison?.let { add(it) }
            topTitle?.let { add("Most watched: $it") }
            if (thisWeekMs > 0) busiestHour?.let { add("You mostly watch around %02d:00".format(it)) }
            if (seriesWithNewEpisodes > 0) add(if (seriesWithNewEpisodes == 1) "New episodes are waiting in 1 series" else "New episodes are waiting in $seriesWithNewEpisodes series")
            addAll(subscriptionNotes)
        }
    val notificationBody get() = lines.take(3).joinToString(". ").ifEmpty { headline }

    companion object {
        fun duration(ms: Long): String {
            val m = Math.round(ms / 60000.0).toInt()
            return if (m >= 60) (if (m % 60 == 0) "${m / 60} h" else "${m / 60} h ${m % 60} min") else "$m min"
        }

        fun make(week: ViewingStatistics, previousWeekMs: Long, seriesWithNew: Int, notes: List<String>): WeeklyDigest {
            val top = listOfNotNull(week.topSeries.firstOrNull(), week.topMovies.firstOrNull(), week.topChannels.firstOrNull()).maxByOrNull { it.ms }
            return WeeklyDigest(week.totalMs, previousWeekMs, top?.title, week.busiestHour, seriesWithNew, notes)
        }
    }
}

/** What StreamSetu keeps on this device and what it can send out, with each item's current state. It follows the privacy policy and is built from live settings. */
data class PrivacyReport(val stored: List<Item>, val sentOut: List<Item>) {
    enum class Status { ON, OFF, WHEN_YOU_ASK }
    data class Item(val id: String, val title: String, val detail: String, val status: Status)
    data class State(
        val diagnosticsOn: Boolean = true, val hasTmdbKey: Boolean = false, val hasOpenSubtitles: Boolean = false, val lanSync: Boolean = false,
        val profileCount: Int = 1, val historyCount: Int = 0, val favoriteCount: Int = 0, val searchCount: Int = 0, val playlistCount: Int = 0,
    )

    companion object {
        val never = listOf("No account to create", "No advertising identifiers", "No analytics", "No selling or sharing of your data", "No automatic crash reporting")
        private fun n(c: Int, one: String, many: String) = if (c == 1) "1 $one" else "$c $many"

        fun make(s: State) = PrivacyReport(
            stored = listOf(
                Item("history", "Watch history and resume points", n(s.historyCount, "title", "titles") + ". Titles played with Watch Privately are never saved.", Status.ON),
                Item("fav", "Favourites and collections", n(s.favoriteCount, "favourite", "favourites") + ".", Status.ON),
                Item("search", "Recent searches", n(s.searchCount, "search", "searches") + ".", Status.ON),
                Item("profiles", "Profiles", n(s.profileCount, "profile", "profiles") + ". Each keeps its own history and favourites.", Status.ON),
                Item("logins", "Playlist logins", n(s.playlistCount, "playlist", "playlists") + ". Passwords stay in encrypted storage.", Status.ON),
            ),
            sentOut = listOf(
                Item("provider", "Your IPTV provider", "Everything you play and browse goes to the provider you added. It sees what its own server serves, as with any player.", Status.ON),
                Item("diag", "StreamSetu playback log", "After a stream fails for good: player used, timings, error codes and device model. Server names are masked. Never titles, logins or stream addresses. Deleted after 30 days.", if (s.diagnosticsOn) Status.ON else Status.OFF),
                Item("tmdb", "The Movie Database (TMDB)", "A title and year, to fetch artwork and details. Only with your own key.", if (s.hasTmdbKey) Status.ON else Status.OFF),
                Item("subs", "OpenSubtitles", "Title, year and language, and your own account to sign in. Only when you ask for subtitles.", if (s.hasOpenSubtitles) Status.WHEN_YOU_ASK else Status.OFF),
                Item("trailer", "YouTube trailers", "Only when you open a trailer.", Status.WHEN_YOU_ASK),
                Item("podcast", "Apple podcast directory", "The words you type, when you search for a podcast.", Status.WHEN_YOU_ASK),
                Item("lan", "Wi-Fi sync", "Between your own devices on this network, encrypted and paired with a code. Nothing goes through the internet.", if (s.lanSync) Status.ON else Status.OFF),
            ),
        )
    }
}

/** The time of day the person usually starts watching, and what they usually put on then, learned from their own watch time on this device. */
data class UsualPick(val itemId: String, val hour: Int, val days: Int, val kind: String = "", val title: String = "")

object UsualEvening {
    const val LOOK_BACK_DAYS = 28
    const val MINIMUM_DAYS = 4

    /** The hour with the most different days of viewing (within an hour either side) and what was watched most often in that window. */
    fun pick(rows: List<WatchTimeEntity>, today: LocalDate): UsualPick? {
        val from = today.toEpochDay() - LOOK_BACK_DAYS + 1
        val recent = rows.filter { it.day in from..today.toEpochDay() && it.ms >= 60_000 }
        if (recent.size < MINIMUM_DAYS) return null
        fun window(h: Int) = recent.filter { val d = Math.abs(it.hour - h); minOf(d, 24 - d) <= 1 }
        var best: Pair<Int, Int>? = null
        for (h in 0..23) {
            val days = window(h).map { it.day }.toSet().size
            if (days >= MINIMUM_DAYS && days >= (best?.second ?: 0)) best = h to days          // later hours win a tie: the evening
        }
        val (hour, days) = best ?: return null
        val top = window(hour).groupBy { it.itemId.substringBefore("|catchup|") }.maxWithOrNull(compareBy({ it.value.size }, { it.value.maxOf { r -> r.day } })) ?: return null
        val last = top.value.maxByOrNull { it.day }!!
        return UsualPick(top.key, hour, days, last.kind, last.title)
    }
}

/** "Start from the beginning" for a live channel: the programme on now began a while ago and the provider keeps an archive for the channel. */
object StartOver {
    const val MINIMUM_ELAPSED_MS = 5 * 60_000L
    const val MINIMUM_LENGTH_MS = 15 * 60_000L
    const val SHOW_FOR_MS = 25_000L

    fun canOffer(startMs: Long, endMs: Long, archiveDays: Int, nowMs: Long = System.currentTimeMillis()): Boolean {
        if (archiveDays <= 0 || nowMs < startMs || nowMs >= endMs || endMs - startMs < MINIMUM_LENGTH_MS) return false
        val elapsed = nowMs - startMs
        return elapsed >= MINIMUM_ELAPSED_MS && elapsed <= archiveDays * 86_400_000L
    }
}

/** How much a kids profile may watch: minutes a day, and hours of the night when nothing plays. */
data class ViewingLimit(val dailyMinutes: Int = 0, val bedtimeOn: Boolean = false, val bedtimeStart: Int = 21 * 60, val bedtimeEnd: Int = 7 * 60) {
    val isOff get() = dailyMinutes == 0 && !bedtimeOn
    fun inBedtime(minuteOfDay: Int) = bedtimeOn && bedtimeStart != bedtimeEnd &&
        (if (bedtimeStart < bedtimeEnd) minuteOfDay in bedtimeStart until bedtimeEnd else minuteOfDay >= bedtimeStart || minuteOfDay < bedtimeEnd)

    fun summary(): String {
        val parts = buildList {
            if (dailyMinutes > 0) add(if (dailyMinutes % 60 == 0) "${dailyMinutes / 60} h a day" else "$dailyMinutes min a day")
            if (bedtimeOn) add("none ${clock(bedtimeStart)} to ${clock(bedtimeEnd)}")
        }
        return if (parts.isEmpty()) "No limits" else parts.joinToString(", ")
    }

    companion object { fun clock(m: Int) = "%02d:%02d".format(m / 60, m % 60) }
}

sealed interface ViewingBlock {
    data object DailyLimit : ViewingBlock
    /** Minutes after midnight when the night ends. */
    data class Bedtime(val untilMinuteOfDay: Int) : ViewingBlock
}

/** Where limits and the day's watched time are kept; the app uses shared preferences, tests a map. */
interface LimitStore { fun get(key: String): String?; fun put(key: String, value: String?) }

class ViewingLimits(private val store: LimitStore) {
    private fun limitKey(id: String) = "viewingLimit.$id"
    private fun usageKey(id: String) = "viewingUsed.$id"

    fun limit(id: String): ViewingLimit {
        val p = store.get(limitKey(id))?.split("|") ?: return ViewingLimit()
        if (p.size != 4) return ViewingLimit()
        return ViewingLimit(p[0].toIntOrNull() ?: 0, p[1] == "1", p[2].toIntOrNull() ?: 21 * 60, p[3].toIntOrNull() ?: 7 * 60)
    }

    fun set(id: String, l: ViewingLimit) = store.put(limitKey(id), if (l.isOff) null else "${l.dailyMinutes}|${if (l.bedtimeOn) 1 else 0}|${l.bedtimeStart}|${l.bedtimeEnd}")

    /** Seconds watched and extra seconds granted on [day] (an epoch day); other days read as zero. */
    private fun today(id: String, day: Long): Pair<Double, Double> {
        val p = store.get(usageKey(id))?.split("|") ?: return 0.0 to 0.0
        if (p.size != 3 || p[0].toLongOrNull() != day) return 0.0 to 0.0
        return (p[1].toDoubleOrNull() ?: 0.0) to (p[2].toDoubleOrNull() ?: 0.0)
    }

    private fun save(id: String, day: Long, used: Double, extra: Double) = store.put(usageKey(id), "$day|$used|$extra")

    fun secondsUsed(id: String, day: Long) = today(id, day).first
    fun addUsage(id: String, seconds: Double, day: Long) { if (seconds > 0) today(id, day).let { save(id, day, it.first + seconds, it.second) } }
    fun grantExtra(id: String, day: Long, minutes: Int = EXTRA_MINUTES) = today(id, day).let { save(id, day, it.first, it.second + minutes * 60.0) }

    fun remaining(id: String, day: Long): Double? {
        val l = limit(id)
        if (l.dailyMinutes <= 0) return null
        val t = today(id, day)
        return maxOf(0.0, l.dailyMinutes * 60.0 + t.second - t.first)
    }

    /** What stops playback for this profile right now. Bedtime comes first because it can be waited out; the day's time can be extended. */
    fun block(id: String, day: Long, minuteOfDay: Int): ViewingBlock? {
        val l = limit(id)
        if (l.inBedtime(minuteOfDay)) return ViewingBlock.Bedtime(l.bedtimeEnd)
        if ((remaining(id, day) ?: 1.0) <= 0.0) return ViewingBlock.DailyLimit
        return null
    }

    companion object { const val EXTRA_MINUTES = 30 }
}

/** Many providers allow only a few streams at once for one subscription, and every tile in multi-view is a stream. This says so before a tile that would go over the limit is opened. */
object ConnectionAdvice {
    fun message(tilesFromSource: Int, limit: Int?): String? {
        if (limit == null || limit <= 0 || tilesFromSource + 1 <= limit) return null
        val allowed = if (limit == 1) "1 stream at a time" else "$limit streams at a time"
        return "Your provider allows $allowed for this playlist. Opening another may stop one of the others, or fail to load."
    }
}

/** The person who is in the most of the titles watched lately (at least two), and how many. */
object FavouritePerson {
    fun pick(watched: Map<String, List<String>>): Pair<String, Int>? {
        fun norm(s: String) = s.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        val counts = HashMap<String, Pair<String, Int>>()
        for (names in watched.values) for (n in names.map { norm(it) }.filter { it.isNotEmpty() }.toSet()) {
            val shown = names.firstOrNull { norm(it) == n } ?: n
            counts[n] = shown to ((counts[n]?.second ?: 0) + 1)
        }
        return counts.values.filter { it.second >= 2 }.maxWithOrNull(compareBy({ it.second }, { -it.first.length }, { it.first }))
    }
}
