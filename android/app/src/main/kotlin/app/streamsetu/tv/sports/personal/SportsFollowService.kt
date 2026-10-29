package app.streamsetu.tv.sports.personal

import app.streamsetu.core.data.db.SportsDao
import app.streamsetu.core.data.db.SportsFollowEntity
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.sports.SportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorizer
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map

sealed interface FollowResult {
    data object Followed : FollowResult
    data object AlreadyFollowing : FollowResult
    /** The event is not (or no longer) one this profile may see, or the name is not part of it: nothing was saved. */
    data object Refused : FollowResult
}

/**
 * What the active profile follows. Follows are kept per profile, matched by normalized key, and shown by the name the person chose. Following does nothing else: no notification, no playback, no
 * recording. Before anything is saved the event it came from is checked again, so a name from an old, since-restricted detail is never stored.
 */
class SportsFollowService(
    private val dao: SportsDao,
    private val auth: SportsAuthorization,
    private val profile: StateFlow<String>,
    private val diagnostics: PersonalDiagnostics = PersonalDiagnostics.Log,
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) {
    /** The active profile's follows; switches by itself when the profile does, so profiles are never mixed. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val follows: Flow<FollowSet> = profile.flatMapLatest { p -> dao.followsFlow(p) }.map { rows -> FollowSet(rows.mapNotNull { it.toFollow() }) }

    private fun SportsFollowEntity.toFollow(): Follow? {
        val k = runCatching { FollowKind.valueOf(kind) }.getOrNull() ?: return null
        val s = Sport.values().firstOrNull { it.name == sport } ?: return null
        return Follow(k, s, normKey, displayName)
    }

    /** What the event offers to follow: its sport, its competition, and each side. Names only; nothing is saved. */
    fun options(e: SportsEvent): List<Pair<FollowKind, String>> = buildList {
        add(FollowKind.SPORT to e.sport.title)
        e.competition?.takeIf { SportsKeys.competition(e) != null }?.let { add(FollowKind.COMPETITION to it) }
        e.participants.filter { SportsKeys.key(it).isNotEmpty() }.forEach { add(FollowKind.PARTICIPANT to it) }
    }

    suspend fun follow(event: SportsEvent, kind: FollowKind, name: String): FollowResult {
        val owner = profile.value
        if (options(event).none { it.first == kind && SportsKeys.key(it.second) == SportsKeys.key(name) }) return FollowResult.Refused
        // The event must still be one this profile may see: at least one of its feeds passes every check right now.
        if (SportsAuthorizer.authorizedFeeds(auth, event, owner).isEmpty() || profile.value != owner) return FollowResult.Refused
        val key = if (kind == FollowKind.SPORT) SportsKeys.sportKey(event.sport) else SportsKeys.key(name)
        val id = dao.insertFollow(SportsFollowEntity(profileId = owner, kind = kind.name, sport = event.sport.name, normKey = key, displayName = name.trim(), createdAt = nowMs()))
        report(owner)
        return if (id == -1L) FollowResult.AlreadyFollowing else FollowResult.Followed
    }

    suspend fun unfollow(f: Follow) {
        val owner = profile.value
        dao.deleteFollow(owner, f.kind.name, f.sport.name, f.key); report(owner)
    }

    suspend fun clear() { val owner = profile.value; dao.clearFollows(owner); report(owner) }

    suspend fun current(): FollowSet = FollowSet(dao.follows(profile.value).mapNotNull { it.toFollow() })

    private suspend fun report(owner: String) {
        val rows = dao.follows(owner)
        diagnostics.record(PersonalReport(rows.count { it.kind == "SPORT" }, rows.count { it.kind == "COMPETITION" }, rows.count { it.kind == "PARTICIPANT" }, 0, 0, 0, 0, 0, 0, null, null))
    }
}
