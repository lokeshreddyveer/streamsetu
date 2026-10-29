package app.streamsetu.tv.sports.personal

/** The lead times a reminder offers, and the one chosen when none is. */
object ReminderLeads {
    const val DEFAULT_MS = 15 * 60_000L
    val OPTIONS: List<Long> = listOf(0L, 5 * 60_000L, 15 * 60_000L, 30 * 60_000L, 60 * 60_000L)

    fun label(leadMs: Long): String = when (leadMs) {
        0L -> "At start time"
        60 * 60_000L -> "1 hour before"
        else -> "${leadMs / 60_000L} minutes before"
    }

    /** "Reminder set · 15 minutes before". */
    fun setText(leadMs: Long): String = "Reminder set · " + if (leadMs == 0L) "at start time" else label(leadMs)
}

/** What to do with a reminder at a given moment. All times are absolute instants; only the display is local. */
sealed interface ReminderPlan {
    /** Arm an alarm for [atMs]. */
    data class Arm(val atMs: Long) : ReminderPlan
    /** The lead time has passed but the event has not started: tell the person once, now. */
    data object NotifyNow : ReminderPlan
    /** The event has started or is over (or was already announced): nothing is sent and nothing is armed. */
    data class Done(val status: ReminderStatus) : ReminderPlan
}

object ReminderTiming {
    fun fireAt(startMs: Long, leadMs: Long) = startMs - leadMs

    /**
     * A reminder is never sent after its event ended, never twice, and not after the event started (a missed reminder is marked, not announced late). One whose time has passed while the event is still
     * ahead is sent once at once.
     */
    fun plan(startMs: Long, endMs: Long, leadMs: Long, notifiedAt: Long, nowMs: Long): ReminderPlan = when {
        nowMs >= endMs -> ReminderPlan.Done(ReminderStatus.ENDED)
        notifiedAt > 0 -> ReminderPlan.Done(ReminderStatus.FIRED)
        fireAt(startMs, leadMs) > nowMs -> ReminderPlan.Arm(fireAt(startMs, leadMs))
        nowMs < startMs -> ReminderPlan.NotifyNow
        else -> ReminderPlan.Done(ReminderStatus.MISSED)
    }
}
