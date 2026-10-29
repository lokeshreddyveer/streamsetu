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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import app.streamsetu.tv.sports.discovery.IdentityIndex
import app.streamsetu.tv.sports.discovery.SportsIdentity

sealed interface FollowResult {
    data object Followed : FollowResult
    data object AlreadyFollowing : FollowResult
    /** The event is not (or no longer) one this profile may see, or the name is not part of it: nothing was saved. */
    data object Refused : FollowResult
}

data class ResolveReport(val upgraded: Int, val unresolved: Int, val unavailable: Int)

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

    /** One thing the event offers to follow. [key] is what is saved. */
    data class Option(val kind: FollowKind, val name: String, val key: String)

    /** What the event offers to follow: its sport, its competition, and each side, by their strict identities. Names only; nothing is saved. */
    fun options(e: SportsEvent, index: IdentityIndex = IdentityIndex.EMPTY): List<Option> = eventOptions(e, index)

    suspend fun follow(event: SportsEvent, kind: FollowKind, name: String, index: IdentityIndex = IdentityIndex.EMPTY): FollowResult {
        val owner = profile.value
        val option = options(event, index).firstOrNull { it.kind == kind && SportsIdentity.strict(it.name) == SportsIdentity.strict(name) } ?: return FollowResult.Refused
        // The event must still be one this profile may see: at least one of its feeds passes every check right now.
        if (SportsAuthorizer.authorizedFeeds(auth, event, owner).isEmpty() || profile.value != owner) return FollowResult.Refused
        val id = dao.insertFollow(SportsFollowEntity(profileId = owner, kind = kind.name, sport = event.sport.name, normKey = option.key, displayName = name.trim(), createdAt = nowMs()))
        report(owner)
        return if (id == -1L) FollowResult.AlreadyFollowing else FollowResult.Followed
    }

    private val mutex = Mutex()

    /**
     * Old follows were kept by the classifier's key, which treats "Barcelona" and "Barcelona SC" as one. Against the guide as it is now, an old follow that fits exactly one strict identity
     * becomes that identity (in one transaction: repeating or racing this changes nothing more). One that fits several stays as it is and is shown as "Choose the team"; one that fits nothing is kept.
     * A follow is never deleted here, and no reminder or recording is touched.
     */
    suspend fun resolveLegacy(index: IdentityIndex): ResolveReport = mutex.withLock {
        val owner = profile.value
        var upgraded = 0; var unresolved = 0; var unavailable = 0
        for (row in dao.follows(owner)) {
            val f = row.toFollow() ?: continue
            if (!f.legacy) continue
            val candidates = index.legacyCandidates(f.kind, f.sport, f.key)
            if (candidates.isEmpty()) { unavailable++; continue }
            val chosen = candidates.singleOrNull()                                          // several fit: never guessed from the spelling or the order
            if (chosen == null) { unresolved++; continue }
            if (profile.value != owner) break
            if (dao.replaceFollowKey(owner, f.kind.name, f.sport.name, f.key, chosen, f.displayName, nowMs())) upgraded++
        }
        if (upgraded > 0) report(owner)
        ResolveReport(upgraded, unresolved, unavailable)
    }

    /** The person chose which team or competition an unresolved follow means. */
    suspend fun choose(f: Follow, candidateKey: String, index: IdentityIndex): Boolean = mutex.withLock {
        val owner = profile.value
        if (candidateKey !in FollowSet(listOf(f), index).candidates(f)) return false
        val done = dao.replaceFollowKey(owner, f.kind.name, f.sport.name, f.key, candidateKey, f.displayName, nowMs())
        if (done) report(owner)
        done
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

/** The sport, competition and sides of an event as follow options, by strict identity (pure). */
fun eventOptions(e: SportsEvent, index: IdentityIndex): List<SportsFollowService.Option> = buildList {
    add(SportsFollowService.Option(FollowKind.SPORT, e.sport.title, SportsKeys.sportKey(e.sport)))
    val c = index.competition(e)
    if (e.competition != null && c != null) add(SportsFollowService.Option(FollowKind.COMPETITION, e.competition!!, c))
    val keys = index.participants(e)
    e.participants.filter { SportsIdentity.strict(it).isNotEmpty() }.forEach { n ->
        val base = SportsIdentity.participant(e.sport, n) ?: return@forEach
        keys.firstOrNull { SportsIdentity.base(it) == base }?.let { add(SportsFollowService.Option(FollowKind.PARTICIPANT, n, it)) }
    }
}
