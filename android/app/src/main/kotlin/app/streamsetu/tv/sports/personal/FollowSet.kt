package app.streamsetu.tv.sports.personal

import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.sports.discovery.FollowStatus
import app.streamsetu.tv.sports.discovery.IdentityIndex
import app.streamsetu.tv.sports.discovery.SportsIdentity

/**
 * One thing a person follows. [key] is what events are matched by: a sport's own name, or a `v2:` identity (see [SportsIdentity]). A team or competition whose key is not a `v2:` identity was
 * followed before identities were strict; it matches nothing until it is resolved against the guide. [displayName] is the name as they chose it.
 */
data class Follow(val kind: FollowKind, val sport: Sport, val key: String, val displayName: String) {
    val legacy: Boolean get() = kind != FollowKind.SPORT && !SportsIdentity.isV2(key)
}

/** Why an event is in My Sports: the strongest follow that matches it. */
data class FollowReason(val kind: FollowKind, val displayName: String)

/**
 * The follows of the active profile, as something events can be asked about. Pure: it never reads the guide itself. The [index] (built from the events that are loaded) says how names are scoped; with
 * none, a name is its plain strict identity. A follow that cannot be tied to exactly one identity (an old follow with several candidates, or a name that now exists under two unrelated playlists)
 * matches nothing: events, reminders and recordings of the candidates are never combined under it.
 */
class FollowSet(val follows: List<Follow>, val index: IdentityIndex = IdentityIndex.EMPTY) {
    val isEmpty get() = follows.isEmpty()
    fun withIndex(i: IdentityIndex) = FollowSet(follows, i)

    private val sports = follows.filter { it.kind == FollowKind.SPORT }.map { it.sport }.toSet()
    private val competitions: Map<Sport, Map<String, Follow>> = byKey(FollowKind.COMPETITION)
    private val participants: Map<Sport, Map<String, Follow>> = byKey(FollowKind.PARTICIPANT)

    private fun byKey(kind: FollowKind): Map<Sport, Map<String, Follow>> =
        follows.filter { it.kind == kind && status(it) == FollowStatus.ACTIVE }.groupBy { it.sport }.mapValues { (_, l) -> l.associateBy { it.key } }

    /** What this follow can do now. */
    fun status(f: Follow): FollowStatus = when {
        f.kind == FollowKind.SPORT -> FollowStatus.ACTIVE
        f.legacy -> when (index.legacyCandidates(f.kind, f.sport, f.key).size) { 0 -> FollowStatus.UNAVAILABLE; else -> FollowStatus.UNRESOLVED }
        SportsIdentity.isScoped(f.key) -> FollowStatus.ACTIVE
        index.isAmbiguous(f.key) -> FollowStatus.UNRESOLVED
        else -> FollowStatus.ACTIVE
    }

    /** The identities a follow could stand for: the person picks one ("Choose the team"). */
    fun candidates(f: Follow): List<String> = when {
        f.kind == FollowKind.SPORT -> emptyList()
        f.legacy -> index.legacyCandidates(f.kind, f.sport, f.key)
        else -> index.expand(f.key)
    }

    /** The strongest reason this event matches (a side, then the competition, then the sport), or null. */
    fun reason(e: SportsEvent): FollowReason? {
        participants[e.sport]?.let { byKey -> index.participants(e).firstNotNullOfOrNull { byKey[it] } }?.let { return FollowReason(FollowKind.PARTICIPANT, it.displayName) }
        index.competition(e)?.let { c -> competitions[e.sport]?.get(c) }?.let { return FollowReason(FollowKind.COMPETITION, it.displayName) }
        if (e.sport in sports) return FollowReason(FollowKind.SPORT, follows.first { it.kind == FollowKind.SPORT && it.sport == e.sport }.displayName)
        return null
    }

    fun matches(e: SportsEvent) = reason(e) != null

    fun isFollowing(kind: FollowKind, sport: Sport, key: String) = follows.any { it.kind == kind && it.sport == sport && it.key == key && status(it) == FollowStatus.ACTIVE }

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
