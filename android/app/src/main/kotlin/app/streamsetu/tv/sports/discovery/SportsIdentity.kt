package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.sports.personal.FollowKind
import app.streamsetu.tv.sports.personal.SportsKeys

/**
 * The identity Sports pages and follows are kept by. It is stricter than the classifier's own matching key (which drops "FC", "SC", "Club" and so on so that two listings of one match meet):
 * here only case, accents, punctuation and repeated spaces are ignored, so "Barcelona" and "Barcelona SC", or "Athletic" and "Athletic Club", are different identities. The classifier's key is
 * left as it is; reminders and recordings keep matching by it.
 *
 *     v2:participant:<sport>:<name>        v2:competition:<sport>:<name>
 *
 * When one exact name is carried by playlists that share no event (so nothing shows they mean the same team), the identity is scoped to the playlists that do: `…:<name>@<playlist>`.
 */
object SportsIdentity {
    const val V2 = "v2:"
    private val marks = Regex("\\p{M}+")
    private val other = Regex("[^\\p{L}\\p{N}]+")

    /** The name with case, accents, punctuation and repeated spaces removed. Every word is kept. */
    fun strict(name: String): String {
        val folded = java.text.Normalizer.normalize(name, java.text.Normalizer.Form.NFD).replace(marks, "")
        return other.replace(folded.lowercase(java.util.Locale.ROOT), " ").trim()
    }

    fun participant(sport: Sport, name: String): String? = strict(name).ifEmpty { null }?.let { "${V2}participant:${sport.name.lowercase()}:$it" }
    fun competition(sport: Sport, name: String): String? = strict(name).ifEmpty { null }?.let { "${V2}competition:${sport.name.lowercase()}:$it" }

    fun isV2(key: String) = key.startsWith(V2)
    /** The identity without any playlist scope. */
    fun base(key: String) = key.substringBefore('@')
    fun isScoped(key: String) = '@' in key
}

/** What a follow is worth right now, with the guide as it is. */
enum class FollowStatus {
    /** Matches events by its key. */
    ACTIVE,
    /** Several identities fit it (an old follow, or a name that now exists under more than one playlist): the person chooses; until then it matches nothing. */
    UNRESOLVED,
    /** An old follow that nothing in the current guide fits. It is kept, and matches nothing. */
    UNAVAILABLE,
}

/**
 * The identities found in the events that are loaded (the ones this person may see), and how they are scoped. Built once per load, off the main thread; every lookup after that is a map read.
 */
class IdentityIndex private constructor(
    private val participantKeys: Map<String, List<String>>,
    private val competitionKeys: Map<String, String>,
    private val ambiguousBases: Set<String>,
    private val names: Map<String, String>,
    private val legacy: Map<String, List<String>>,
) {
    /** How many names are carried by playlists that do not share an event. */
    val ambiguousCount: Int get() = ambiguousBases.size
    val identityCount: Int get() = names.size

    fun participants(e: SportsEvent): List<String> = participantKeys[e.id] ?: e.participants.mapNotNull { SportsIdentity.participant(e.sport, it) }
    fun competition(e: SportsEvent): String? = competitionKeys[e.id] ?: e.competition?.let { SportsIdentity.competition(e.sport, it) }
    fun isAmbiguous(base: String) = base in ambiguousBases
    fun displayName(key: String): String? = names[key]

    /** Every identity (a scoped one counts on its own) that a key stands for: itself, or the scoped identities behind an unscoped name that is now ambiguous. */
    fun expand(key: String): List<String> =
        if (SportsIdentity.isScoped(key) || !isAmbiguous(key)) listOf(key) else names.keys.filter { SportsIdentity.base(it) == key }.sorted()

    /** The identities whose classifier key is [legacyKey]: what an old follow could mean. */
    fun legacyCandidates(kind: FollowKind, sport: Sport, legacyKey: String): List<String> = legacy["${kind.name}:${sport.name}:$legacyKey"].orEmpty()

    companion object {
        val EMPTY = IdentityIndex(emptyMap(), emptyMap(), emptySet(), emptyMap(), emptyMap())

        fun build(events: List<SportsEvent>): IdentityIndex {
            // Playlists that carry the same event are one group: that is the evidence two playlists mean the same thing by a name.
            val parent = HashMap<String, String>()
            fun find(x: String): String { var r = x; while (true) { val p = parent[r]; if (p == null) { parent[r] = r; return r }; if (p == r) return r; r = p } }
            fun union(a: String, b: String) { val ra = find(a); val rb = find(b); if (ra != rb) { if (ra < rb) parent[rb] = ra else parent[ra] = rb } }          // the smallest playlist id is the root
            for (e in events) { val ids = e.sourceIds.sorted(); ids.forEach { find(it) }; for (i in 1 until ids.size) union(ids[0], ids[i]) }
            fun group(e: SportsEvent): String = e.sourceIds.minOrNull()?.let { find(it) } ?: ""

            val groupsByBase = HashMap<String, MutableSet<String>>()
            for (e in events) {
                val g = group(e)
                e.participants.forEach { n -> SportsIdentity.participant(e.sport, n)?.let { groupsByBase.getOrPut(it) { HashSet() }.add(g) } }
                e.competition?.let { n -> SportsIdentity.competition(e.sport, n)?.let { groupsByBase.getOrPut(it) { HashSet() }.add(g) } }
            }
            val ambiguous = groupsByBase.filter { it.value.size > 1 }.keys
            fun scoped(base: String, g: String) = if (base in ambiguous) "$base@$g" else base

            val participants = HashMap<String, List<String>>(events.size * 2)
            val competitions = HashMap<String, String>(events.size * 2)
            val counts = HashMap<String, HashMap<String, Int>>()
            val legacy = HashMap<String, MutableSet<String>>()
            for (e in events) {
                val g = group(e)
                participants[e.id] = e.participants.mapNotNull { n ->
                    SportsIdentity.participant(e.sport, n)?.let { b -> scoped(b, g).also { k ->
                        counts.getOrPut(k) { HashMap() }.merge(n.trim(), 1, Int::plus)
                        legacy.getOrPut("${FollowKind.PARTICIPANT.name}:${e.sport.name}:${SportsKeys.key(n)}") { HashSet() }.add(k)
                    } }
                }.distinct()
                e.competition?.let { n -> SportsIdentity.competition(e.sport, n)?.let { b -> scoped(b, g).also { k ->
                    competitions[e.id] = k; counts.getOrPut(k) { HashMap() }.merge(n.trim(), 1, Int::plus)
                    legacy.getOrPut("${FollowKind.COMPETITION.name}:${e.sport.name}:${SportsKeys.key(n)}") { HashSet() }.add(k)
                } } }
            }
            val names = counts.mapValues { (_, byName) -> byName.entries.sortedWith(compareBy({ -it.value }, { it.key })).first().key }
            return IdentityIndex(participants, competitions, ambiguous, names, legacy.mapValues { it.value.sorted() })
        }
    }
}
