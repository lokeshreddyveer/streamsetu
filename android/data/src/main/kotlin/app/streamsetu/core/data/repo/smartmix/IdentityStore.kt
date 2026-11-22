package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.data.db.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

/** What a playlist read changed in the identity table, for the things that keep lists built from it. */
data class ChangeSet(
    val sourceId: String, val kind: String, val added: Int, val removed: Int, val changed: Int,
    /** Ids, only while each list stays within [CAP]; above it the set is [bulk] (a first read, or a provider that renumbered everything) and callers rebuild instead of patching. */
    val addedIds: List<String> = emptyList(), val removedIds: List<String> = emptyList(), val changedIds: List<String> = emptyList(), val bulk: Boolean = false,
) {
    val isEmpty get() = added == 0 && removed == 0 && changed == 0
    companion object { const val CAP = 5_000 }
}

/**
 * The derived identity table (`content_identity`): written beside the catalog as a playlist is read, filled in the background for what was read before, and never read to change a
 * playlist row. Rows whose title, folder and year did not change cost one comparison; only added and changed rows are derived.
 */
class IdentityStore(private val db: AppDatabase) {
    private val dao get() = db.identity()

    /** One pass over one kind of one playlist, used by the catalog write: [apply] for each batch written, [removed] for rows that are gone, [finish] at the end. */
    class Pass internal constructor(private val store: IdentityStore, val sourceId: String, val kind: String, private val known: HashMap<String, Long>, private val categoryNames: Map<String, String>) {
        private var added = 0; private var changed = 0; private var removed = 0
        private val addedIds = ArrayList<String>(); private val changedIds = ArrayList<String>(); private val removedIds = ArrayList<String>()

        /** Derives and saves the rows of [rows] that are new or whose source words changed. Called inside the transaction that writes the same rows. */
        suspend fun apply(rows: List<UnderivedRow>) {
            val out = ArrayList<ContentIdentityEntity>()
            for (r in rows) {
                val cat = r.categoryId?.let { categoryNames[it] }
                val h = Derive.inHash(kind, r.title, cat, r.year)
                val was = known[r.id]
                if (was == h) continue
                out += store.entity(kind, r, cat)
                if (was == null) { added++; if (addedIds.size < ChangeSet.CAP) addedIds += r.id } else { changed++; if (changedIds.size < ChangeSet.CAP) changedIds += r.id }
                known[r.id] = h
            }
            if (out.isNotEmpty()) store.dao.putAll(out)
        }

        /** Rows the provider no longer lists. */
        suspend fun removed(ids: List<String>) {
            if (ids.isEmpty()) return
            store.dao.delete(ids); ids.forEach { known.remove(it) }
            removed += ids.size; for (id in ids) if (removedIds.size < ChangeSet.CAP) removedIds += id
        }

        fun finish(): ChangeSet = ChangeSet(sourceId, kind, added, removed, changed, addedIds, removedIds, changedIds, bulk = added > ChangeSet.CAP || removed > ChangeSet.CAP || changed > ChangeSet.CAP).also { if (!it.isEmpty) _changes.tryEmit(it) }
    }

    suspend fun begin(sourceId: String, kind: String, categoryNames: Map<String, String>): Pass {
        val known = HashMap<String, Long>()
        for (h in dao.hashes(sourceId, kind)) known[h.itemId] = h.inHash
        return Pass(this, sourceId, kind, known, categoryNames)
    }

    internal fun entity(kind: String, r: UnderivedRow, categoryName: String?): ContentIdentityEntity {
        val d = Derive.derive(kind, r.title, categoryName, r.year)
        return ContentIdentityEntity(r.id, kind, r.sourceId, d.identityKey, d.year, d.lang, d.qualityRank, d.isCam, d.folderKey, d.inHash, IdentityKey.VERSION)
    }

    /** Share of the catalog that has a current identity row (1.0 when there is nothing to derive). Below [READY] readers use the slower path that derives the few titles they need. */
    suspend fun coverage(): Double {
        val total = db.catalog().movieTotal() + db.catalog().seriesTotal()
        if (total == 0) return 1.0
        return dao.derivedCount(IdentityKey.VERSION).toDouble() / total
    }

    /**
     * Fills in rows for titles read before the identity table existed (or by an older rule), [batch] titles at a time. Returns how many were derived in this call; call again until 0. Each step
     * carries on after the last row of the previous one (rows are visited in id order), so the whole fill reads every row once and not the same front of the table again and again. A pass that is
     * stopped half way is resumed by the next call (rows already written are not looked at again: the query finds only titles without a current row).
     */
    suspend fun backfillStep(batch: Int = 2000): Int {
        val movies = dao.underivedMovies(IdentityKey.VERSION, batch, moviesAfter)
        val series = if (movies.size < batch) dao.underivedSeries(IdentityKey.VERSION, batch - movies.size, seriesAfter) else emptyList()
        if (movies.isEmpty() && series.isEmpty()) { moviesAfter = ""; seriesAfter = ""; return 0 }
        movies.lastOrNull()?.let { moviesAfter = it.id }; series.lastOrNull()?.let { seriesAfter = it.id }
        val cats = HashMap<String, String>()
        for (kind in listOf("MOVIE", "SERIES")) db.catalog().categoriesOfKind(kind).forEach { cats[it.id] = it.name }
        db.identity().putAll(movies.map { entity("MOVIE", it, it.categoryId?.let(cats::get)) } + series.map { entity("SERIES", it, it.categoryId?.let(cats::get)) })
        return movies.size + series.size
    }
    private var moviesAfter = ""
    private var seriesAfter = ""

    /** The fill has finished: what was derived is announced as one big change, so Home rebuilds its recommendations with the identities now there. */
    fun announceBackfill(derived: Int) { if (derived > 0) _changes.tryEmit(ChangeSet("", "ALL", derived, 0, 0, bulk = true)) }

    companion object {
        const val READY = 0.99
        private val _changes = MutableSharedFlow<ChangeSet>(extraBufferCapacity = 16)
        /** One set for each kind of each playlist read, after its rows are written, only when something changed (the same stream whichever store instance wrote them). */
        val changes: SharedFlow<ChangeSet> = _changes
    }
}

/** Whether two playlists carry the same content (the same playlist added twice, or two providers reselling one catalog): how many of one's titles are in the other. */
object SourceTwins {
    const val TWIN_AT = 0.9

    /** Recomputes the table for every pair of usable playlists; call after a playlist is read or the set of playlists changes. Cheap lookups on the identity index, run off the screen's thread. */
    suspend fun recompute(db: AppDatabase) {
        val usable = db.sources().all().filter { it.enabled && !it.draft }.sortedBy { it.id }
        val rows = ArrayList<SourceTwinEntity>()
        val now = System.currentTimeMillis()
        for (kind in listOf("MOVIE", "SERIES")) for (i in usable.indices) for (j in i + 1 until usable.size) {
            val a = usable[i].id; val b = usable[j].id
            rows += SourceTwinEntity(kind, a, b, db.identity().matched(a, b, kind), db.identity().countOf(a, kind), db.identity().countOf(b, kind), now)
        }
        db.identity().clearTwins(); db.identity().putTwins(rows)
    }

    fun isTwin(r: SourceTwinEntity) = minOf(r.totalA, r.totalB).let { it > 0 && r.matched.toDouble() / it >= TWIN_AT }
}
