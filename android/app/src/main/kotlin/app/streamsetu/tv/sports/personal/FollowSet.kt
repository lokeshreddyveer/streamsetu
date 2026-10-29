package app.streamsetu.tv.sports.personal

import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent

/** One thing a person follows. [key] is what events are matched by; [displayName] is the name as they chose it. */
data class Follow(val kind: FollowKind, val sport: Sport, val key: String, val displayName: String)

/** Why an event is in My Sports: the strongest follow that matches it. */
data class FollowReason(val kind: FollowKind, val displayName: String)

/**
 * The follows of the active profile, as something events can be asked about. Pure: it never reads the guide, so following or unfollowing re-orders what is already loaded and classifies nothing.
 */
class FollowSet(val follows: List<Follow>) {
    val isEmpty get() = follows.isEmpty()
    private val sports = follows.filter { it.kind == FollowKind.SPORT }.map { it.sport }.toSet()
    private val competitions = follows.filter { it.kind == FollowKind.COMPETITION }.groupBy { it.sport }.mapValues { (_, l) -> l.associateBy { it.key } }
    private val participants = follows.filter { it.kind == FollowKind.PARTICIPANT }.groupBy { it.sport }.mapValues { (_, l) -> l.associateBy { it.key } }

    /** The strongest reason this event matches (a side, then the competition, then the sport), or null. */
    fun reason(e: SportsEvent): FollowReason? {
        participants[e.sport]?.let { byKey -> SportsKeys.participants(e).firstNotNullOfOrNull { byKey[it] } }?.let { return FollowReason(FollowKind.PARTICIPANT, it.displayName) }
        SportsKeys.competition(e)?.let { c -> competitions[e.sport]?.get(c) }?.let { return FollowReason(FollowKind.COMPETITION, it.displayName) }
        if (e.sport in sports) return FollowReason(FollowKind.SPORT, follows.first { it.kind == FollowKind.SPORT && it.sport == e.sport }.displayName)
        return null
    }

    fun matches(e: SportsEvent) = reason(e) != null

    fun isFollowing(kind: FollowKind, sport: Sport, key: String) = follows.any { it.kind == kind && it.sport == sport && it.key == key }

    companion object { val NONE = FollowSet(emptyList()) }
}

/**
 * What personalizes the Sports Hub: the follows, and the events that have a reminder. It orders events inside a section and chooses what My Sports shows; it never moves an event to another section.
 */
class Personalization(val follows: FollowSet = FollowSet.NONE, val remindedEventIds: Set<String> = emptySet(), val mySports: Boolean = false) {
    /** 0 reminded, 1 a followed side, 2 a followed competition, 3 a followed sport, 4 nothing: lower comes first, then the usual order by time. */
    fun rank(e: SportsEvent): Int {
        if (e.id in remindedEventIds) return 0
        return when (follows.reason(e)?.kind) { FollowKind.PARTICIPANT -> 1; FollowKind.COMPETITION -> 2; FollowKind.SPORT -> 3; null -> 4 }
    }

    /** "Because you follow India". */
    fun reasonText(e: SportsEvent): String? = follows.reason(e)?.let { "Because you follow ${it.displayName}" }

    companion object { val NONE = Personalization() }
}
