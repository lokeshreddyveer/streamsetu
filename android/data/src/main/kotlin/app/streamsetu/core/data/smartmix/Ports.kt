package app.streamsetu.core.data.smartmix

/** Signals about this profile (watch_time / progress / favourites), never derived from locked or hidden items. */
data class Signals(
    val preferredLang: String? = null,
    val affinity: Affinity = Affinity.NONE,
    /** Identity keys of the last watched titles, newest first (Because You Watched uses the first 4 as seeds). */
    val recentWatchedIdentityKeys: List<String> = emptyList(),
)

data class PoolRequest(val profileId: String, val shelfId: String, val dayKey: String, val seedIdentityKeys: List<String> = emptyList(), val limit: Int)

/**
 * Port to the canonical-identity layer (Room 10 -> 11 `content_identity` + candidate DAO). Returns library MEMBERS (copies) for the shelf:
 * narrow projection (no title, no url), restricted flags and dismissal marks filled, indexed pool of about [PoolRequest.limit] groups.
 * The engine groups twins, chooses the representative and enforces every exclusion again, so the adapter may over-deliver but never under-flag.
 */
interface CandidateSource {
    fun pool(request: PoolRequest): List<Candidate>
    fun signals(profileId: String): Signals
    /** Slim library members for trending title matching (restricted flags filled). */
    fun matchCandidates(profileId: String): List<Candidate>
    /** Only the copies whose identity key is one of [names] (the folded titles of the public trending list): what a device with a large library asks for instead of every copy. */
    fun matchCandidates(profileId: String, names: Set<String>): List<Candidate> = matchCandidates(profileId).filter { it.identityKey in names }
    /** How many titles each genre has today (see [GenreShelves.counts]): not restricted, not dismissed, not CAM-only, with a poster. */
    fun genreCounts(profileId: String): Map<String, Int> = emptyMap()
    /** How many titles of the open library could be shown (one per title, not CAM, with a poster): the base of a mood's floor of 1.5%. 0 = unknown (the floor is then 8). */
    fun showableTotal(profileId: String): Int = 0
    /** The genres of the titles watched most lately, most first (at most 3). */
    fun affinityGenreKeys(profileId: String): List<String> = emptyList()
}

data class ShownRow(val identityKey: String, val year: Int?, val itemId: String, val loadSeq: Int)

data class ShelfState(val refreshCounter: Int = 0, val loadKey: String = "", val loadSeq: Int = 0)

/** Per-profile persisted state (`smartmix_state`, `smartmix_shown`). */
interface SmartMixStore {
    fun state(profileId: String, shelfId: String): ShelfState
    fun saveState(profileId: String, shelfId: String, state: ShelfState)
    fun shown(profileId: String, shelfId: String): List<ShownRow>
    fun replaceShown(profileId: String, shelfId: String, rows: List<ShownRow>)
    fun clearProfile(profileId: String)
}

class InMemorySmartMixStore : SmartMixStore {
    private val states = HashMap<Pair<String, String>, ShelfState>()
    private val rows = HashMap<Pair<String, String>, List<ShownRow>>()
    @Synchronized override fun state(profileId: String, shelfId: String) = states[profileId to shelfId] ?: ShelfState()
    @Synchronized override fun saveState(profileId: String, shelfId: String, state: ShelfState) { states[profileId to shelfId] = state }
    @Synchronized override fun shown(profileId: String, shelfId: String) = rows[profileId to shelfId] ?: emptyList()
    @Synchronized override fun replaceShown(profileId: String, shelfId: String, rows: List<ShownRow>) { this.rows[profileId to shelfId] = rows }
    @Synchronized override fun clearProfile(profileId: String) { states.keys.removeAll { it.first == profileId }; rows.keys.removeAll { it.first == profileId } }
}
