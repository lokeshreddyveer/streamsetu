package app.streamsetu.core.data.repo

import java.text.DateFormat
import java.util.Calendar
import java.util.Date

/** What a provider says about the subscription behind a connection: its state and when it ends (0 when there is no end date). */
data class AccountStatus(val status: String, val expiresMs: Long, val maxConnections: Int = 0) {
    enum class Level { FINE, SOON, ENDED }

    val isActive: Boolean get() = status.equals("active", ignoreCase = true)

    private fun dayStart(ms: Long) = Calendar.getInstance().apply { timeInMillis = ms; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis

    /** Whole days left (0 on the last day, negative once it has ended); null without an end date. */
    fun daysLeft(now: Long = System.currentTimeMillis()): Int? = if (expiresMs <= 0) null else Math.round((dayStart(expiresMs) - dayStart(now)) / 86_400_000.0).toInt()

    /** A warning from a week out; "ended" when the provider says it is not active or the date has passed. */
    fun level(now: Long = System.currentTimeMillis()): Level {
        if (!isActive) return Level.ENDED
        val d = daysLeft(now) ?: return Level.FINE
        return if (d < 0) Level.ENDED else if (d <= 7) Level.SOON else Level.FINE
    }

    /** "Ends 12 Dec 2026 (54 days left)", "Ends today", "Ended 3 days ago", "No end date". */
    fun summary(now: Long = System.currentTimeMillis()): String {
        if (!isActive) return "Not active ($status)"
        val d = daysLeft(now) ?: return "No end date"
        val date = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(expiresMs))
        return when {
            d < -1 -> "Ended ${-d} days ago ($date)"
            d == -1 -> "Ended yesterday ($date)"
            d == 0 -> "Ends today ($date)"
            d == 1 -> "Ends tomorrow ($date)"
            else -> "Ends $date ($d days left)"
        }
    }
}
