package app.streamsetu.tv.sports.personal

import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.data.db.SportsReminderEntity

enum class ReminderStatus { SCHEDULED, UNMATCHED, AMBIGUOUS, FIRED, MISSED, ENDED }

/** Where a reminder stands against the guide as it is now. */
sealed interface Association {
    val reminderId: String
    /** One safe match. */
    data class Matched(override val reminderId: String, val event: SportsEvent) : Association
    /** Nothing in the guide fits; the reminder stays pending. */
    data class Unmatched(override val reminderId: String) : Association
    /** Something fits but not safely (several candidates, or only a low-confidence one): nothing is associated. */
    data class Ambiguous(override val reminderId: String) : Association
    /** The reminder is for a time the loaded guide does not reach yet: nothing is decided. */
    data class NotYet(override val reminderId: String) : Association
}

/**
 * Finds, for each durable reminder, the event it is for in the guide as it is now. The inferred event id plays no part: the event is found by its normalized identity, a compatible competition and a
 * start close to the one the reminder was made for.
 *
 *  - Same sport, kind, sides (or event name) and stage.
 *  - A competition that is known on both sides must be the same.
 *  - The start within [TOLERANCE_MS] of the reminder's.
 *  - The same sides twice within the tolerance (a doubleheader) are never told apart by their order. A reminder made when there were two keeps its fixture only if the channels that carried it
 *    and not the other still single out exactly one fixture now, or if exactly one fixture still starts where the reminder says (within [EXACT_MS]) with the others well away. Otherwise nothing is
 *    associated and the reminder stays pending.
 *  - A reminder made for a lone fixture, when a second now appears, stays with the one whose start is still what it was; if none is, nothing is associated.
 *  - An event the rules were unsure of ([MIN_CONFIDENCE]) is never associated silently.
 *
 * The events are indexed once, so a thousand reminders cost one pass, not a thousand queries.
 */
object ReminderMatcher {
    const val TOLERANCE_MS = 3 * 3_600_000L
    const val EXACT_MS = 5 * 60_000L
    const val NEAR_MS = 60 * 60_000L
    const val MIN_CONFIDENCE = 0.75

    fun associate(reminders: List<SportsEventReminder>, events: List<SportsEvent>, windowEndMs: Long): List<Association> {
        val byIdentity = events.groupBy { SportsKeys.identity(it) }
        return reminders.map { r ->
            if (r.startMs - TOLERANCE_MS > windowEndMs) return@map Association.NotYet(r.id)
            val near = byIdentity[r.identity].orEmpty().filter { e ->
                val c = SportsKeys.competition(e)
                (r.competitionKey == null || c == null || r.competitionKey == c) && kotlin.math.abs(e.startMs - r.startMs) <= TOLERANCE_MS
            }
            if (near.isEmpty()) return@map Association.Unmatched(r.id)
            val sure = near.filter { it.confidence >= MIN_CONFIDENCE }
            if (sure.isEmpty()) return@map Association.Ambiguous(r.id)
            if (r.siblings >= 2) {
                // A doubleheader when it was made. A fixture of low confidence in the mix means the occurrence cannot be proven.
                if (sure.size != near.size) return@map Association.Ambiguous(r.id)
                fun carries(e: SportsEvent) = e.feeds.any { it.channelId in r.distinguishing }
                val byChannel = if (r.distinguishing.isEmpty()) emptyList() else near.filter(::carries)
                if (byChannel.size == 1) return@map Association.Matched(r.id, byChannel[0])
                val same = near.filter { kotlin.math.abs(it.startMs - r.startMs) <= EXACT_MS }
                return@map if (same.size == 1 && near.filter { it !== same[0] }.all { kotlin.math.abs(it.startMs - r.startMs) >= NEAR_MS }) Association.Matched(r.id, same[0]) else Association.Ambiguous(r.id)
            }
            if (sure.size == 1) return@map Association.Matched(r.id, sure[0])
            // Made for a lone fixture, and now there are several: only one whose start has hardly moved is provably the same, and no other may be close to it.
            val same = sure.filter { kotlin.math.abs(it.startMs - r.startMs) <= EXACT_MS }
            if (same.size == 1 && sure.filter { it !== same[0] }.all { kotlin.math.abs(it.startMs - r.startMs) >= NEAR_MS }) Association.Matched(r.id, same[0]) else Association.Ambiguous(r.id)
        }
    }
}

/** The part of a stored reminder that matching needs. */
data class SportsEventReminder(val id: String, val identity: String, val competitionKey: String?, val startMs: Long, val siblings: Int = 1, val distinguishing: Set<String> = emptySet())

fun SportsReminderEntity.forMatching() = SportsEventReminder(id, identity, competitionKey, startMs, siblings, distinguishing.split(',').filter { it.isNotEmpty() }.toSet())
