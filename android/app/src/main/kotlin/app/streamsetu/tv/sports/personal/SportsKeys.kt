package app.streamsetu.tv.sports.personal

import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsClassifier
import app.streamsetu.core.sports.SportsEvent

enum class FollowKind { SPORT, COMPETITION, PARTICIPANT }

/**
 * The normalized facts a follow or a reminder is kept by. The inferred event id is not one of them: it is only good for the guide as it is now. Everything here is the same after a feed appears
 * or goes, a start time is corrected, or a playlist is refreshed, because it comes from the sides, the competition, the stage and the sport, with accents, case, punctuation and club markers removed.
 */
object SportsKeys {
    fun key(name: String): String = SportsClassifier.teamKey(name)

    fun competition(e: SportsEvent): String? = e.competition?.let(::key)?.ifEmpty { null }

    fun participants(e: SportsEvent): List<String> = e.participants.map(::key).filter { it.isNotEmpty() }

    /** The sides in a fixed order, or the event's own name when it has no sides (a race, a tournament round). */
    fun participantsKey(e: SportsEvent): String = participants(e).sorted().joinToString("|").ifEmpty { key(e.title) }

    fun identity(e: SportsEvent): String = listOf(e.sport.name.lowercase(), e.kind.name.lowercase(), participantsKey(e), key(e.stage.orEmpty())).joinToString("|")

    /** The half hour an event was planned for: two reminders for the same event are not made twice, while the same sides playing twice in a day stay apart. */
    fun slot(startMs: Long): Long { val q = startMs / 1_800_000L; return if (startMs % 1_800_000L != 0L && startMs < 0) q - 1 else q }          // not Math.floorDiv: that needs Android 7

    fun sportKey(sport: Sport): String = sport.name.lowercase()
}
