package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.FolderPrefEntity
import app.streamsetu.core.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*

/**
 * Provider folders as the person arranged them: favourite, pinned, hidden, locked, renamed, reordered. Movies, Series and Live TV keep separate arrangements.
 * Only a local table is written; the provider's own folder names and order are never changed.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FolderRepository(
    private val db: AppDatabase, private val library: LibraryRepository, private val parental: ParentalControls,
    private val scope: kotlinx.coroutines.CoroutineScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default),
    private val relockAfterMs: () -> Long = { Long.MAX_VALUE },
) {
    private fun scopeName(kind: ContentKind) = kind.name
    private companion object { const val EXPIRY_CHECK_MS = 3_000L }

    /** Folders the person unlocked with the PIN since the app started; they lock again when a library is closed. */
    private val unlockedAt: MutableMap<String, Long> = java.util.concurrent.ConcurrentHashMap()          // typed as a Map: the concurrent class's own key view needs Android 7
    private val unlocked = MutableStateFlow<Set<String>>(emptySet())
    fun unlock(folderId: String) { unlockedAt[folderId] = System.currentTimeMillis(); unlocked.value = unlockedAt.keys.toSet() }
    fun lockAgain() { unlockedAt.clear(); unlocked.value = emptySet() }
    /** Applies the auto-relock policy: folders unlocked longer ago than the limit lock again. */
    private fun expire() { val limit = relockAfterMs(); if (limit == Long.MAX_VALUE) return; val now = System.currentTimeMillis(); var changed = false; val it = unlockedAt.entries.iterator(); while (it.hasNext()) { if (now - it.next().value > limit) { it.remove(); changed = true } }; if (changed) unlocked.value = unlockedAt.keys.toSet() }
    fun isUnlocked(folderId: String): Boolean { expire(); return unlockedAt.containsKey(folderId) }

    /** Folders whose content must stay out of lists, search and banners right now: locked and not yet unlocked. */
    fun lockedIds(kind: ContentKind): Flow<Set<String>> = lockedFrom(db.browse().lockedFolders(scopeName(kind)), unlocked, expiryTicks())

    /** The auto-relock interval is applied by the clock too, not only when something asks: an open screen is told within a few seconds of a folder's time running out. */
    private fun expiryTicks(): Flow<Unit> = kotlinx.coroutines.flow.flow { while (true) { expire(); emit(Unit); kotlinx.coroutines.delay(EXPIRY_CHECK_MS) } }
    /**
     * The folder names and the person's arrangement of them for the open library, read once and shared: the folder list, the locked set and the restricted set all come from this one
     * subscription (they used to each read the same two tables again). No counts here: those are a separate, later read.
     */
    private val shells = HashMap<ContentKind, Flow<Pair<List<app.streamsetu.core.data.db.CategoryEntity>, List<FolderPrefEntity>>>>()
    private fun shell(kind: ContentKind): Flow<Pair<List<app.streamsetu.core.data.db.CategoryEntity>, List<FolderPrefEntity>>> = synchronized(shells) {
        shells.getOrPut(kind) {
            library.sourceIds.flatMapLatest { ids -> combine(db.catalog().categories(kind.name, ids), db.folders().observe(scopeName(kind))) { cats, prefs -> cats to prefs } }
                .shareIn(scope, SharingStarted.WhileSubscribed(5000), replay = 1)
        }
    }

    /** Folders whose titles must stay out of every list, rail, banner and badge: locked ones, and (while adult content is hidden, always for a kids profile) the adult categories. */
    fun restrictedIds(kind: ContentKind): Flow<Set<String>> =
        combine(lockedFrom(shell(kind).map { (_, prefs) -> prefs.filter { it.locked }.map { it.folderId } }, unlocked, expiryTicks()), parental.hideAdult, shell(kind).map { it.first }) { locked, hideAdult, cats ->
            if (!hideAdult) locked else locked + cats.filter { ParentalControls.isAdultName(it.name) }.map { it.id }
        }.distinctUntilChanged()
    suspend fun restrictedIdsNow(kind: ContentKind): Set<String> {
        val locked = lockedIdsNow()
        if (!parental.hideAdult.value) return locked
        return locked + db.catalog().categories(kind.name, library.sourceIds.value).first().filter { ParentalControls.isAdultName(it.name) }.map { it.id }
    }
    suspend fun lockedIdsNow(): Set<String> { expire(); return db.browse().lockedFoldersNow().toSet() - unlockedAt.keys }

    /** Every folder of [kind] in the open library, in the person's order (pinned first, then arranged order, then the provider's order). Hidden ones are included, flagged. */
    fun folders(kind: ContentKind, withCounts: Boolean = true): Flow<List<Folder>> = library.sourceIds.flatMapLatest { ids ->
        // The names and the person's arrangement come first; how many titles each holds (a grouped count over the whole catalog) is asked for separately and later.
        val counts = if (!withCounts) kotlinx.coroutines.flow.flowOf(emptyList()) else when (kind) {
            ContentKind.MOVIE -> db.catalog().movieFolderCounts(ids)
            ContentKind.SERIES -> db.catalog().seriesFolderCounts(ids)
            else -> db.catalog().channelFolderCounts(ids)
        }
        combine(shell(kind), counts, parental.hideAdult) { (cats, prefs), cnt, hideAdult ->
            val byId = prefs.associateBy { it.folderId }
            val n = cnt.associate { it.folderId to it.n }
            cats.filter { !hideAdult || !ParentalControls.isAdultName(it.name) }.mapIndexed { i, c ->
                Triple(i, Folder(c.id, c.sourceId, c.name, n[c.id] ?: 0, byId[c.id]?.toModel() ?: FolderPref()), c)
            }.sortedWith(compareByDescending<Triple<Int, Folder, *>> { it.second.pref.pinned }.thenBy { if (it.second.pref.sortIndex >= 0) it.second.pref.sortIndex else Int.MAX_VALUE }.thenBy { it.first })
                .map { it.second }
        }
    }

    private suspend fun update(kind: ContentKind, folderId: String, change: (FolderPrefEntity) -> FolderPrefEntity) {
        val cur = db.folders().get(scopeName(kind), folderId) ?: FolderPrefEntity(scopeName(kind), folderId)
        db.folders().put(change(cur))
    }

    suspend fun toggleFavorite(kind: ContentKind, f: Folder) = update(kind, f.id) { it.copy(favorite = !it.favorite) }
    suspend fun togglePinned(kind: ContentKind, f: Folder) = update(kind, f.id) { it.copy(pinned = !it.pinned) }
    suspend fun toggleHidden(kind: ContentKind, f: Folder) = update(kind, f.id) { it.copy(hidden = !it.hidden) }
    suspend fun toggleLocked(kind: ContentKind, f: Folder) = update(kind, f.id) { it.copy(locked = !it.locked) }
    suspend fun setAlias(kind: ContentKind, f: Folder, alias: String?) = update(kind, f.id) { it.copy(alias = alias?.trim()?.ifBlank { null }) }

    /** Moves [f] within the list as it is shown now (one place, or to either end) and saves that whole order in one transaction. Nothing else changes place. */
    suspend fun moveTo(kind: ContentKind, current: List<Folder>, f: Folder, to: MoveTo) {
        val order = FolderOrder.move(current.map { it.id }, f.id, to) ?: return
        val byId = current.associateBy { it.id }
        db.folders().putAll(order.mapIndexed { idx, id -> (byId[id]?.pref ?: FolderPref()).let { p -> FolderPrefEntity(scopeName(kind), id, p.favorite, p.pinned, p.hidden, p.locked, p.alias, idx) } })
    }
    suspend fun move(kind: ContentKind, current: List<Folder>, f: Folder, delta: Int) = moveTo(kind, current, f, if (delta < 0) MoveTo.UP else MoveTo.DOWN)

    /** One folder back to the provider's position (its other marks stay). */
    suspend fun resetPosition(kind: ContentKind, f: Folder) = update(kind, f.id) { it.copy(sortIndex = -1) }
    /** One folder back to plain: no label, not pinned, favorite, hidden or locked, in the provider's position. */
    suspend fun resetFolder(kind: ContentKind, f: Folder) = db.folders().delete(scopeName(kind), f.id)

    /** Counts for the settings screens. */
    suspend fun lockedCount(): Int = db.browse().lockedFoldersNow().size
    suspend fun unhideAll(kind: ContentKind) = db.folders().unhideAll(scopeName(kind))
    suspend fun clearAllLocks() { db.folders().all().filter { it.locked }.forEach { db.folders().put(it.copy(locked = false)) }; lockAgain() }

    suspend fun restoreDefaultOrder(kind: ContentKind) {
        // Keeps favourites, hidden, locked and renamed state; only the order goes back to the provider's.
        val kept = db.folders().observe(scopeName(kind)).first()
        db.folders().putAll(kept.map { it.copy(sortIndex = -1, pinned = false) })
    }
}

/** The locked folders from the saved list, what was unlocked, and a clock that makes the auto-relock noticed. */
internal fun lockedFrom(locked: Flow<List<String>>, unlocked: Flow<Set<String>>, ticks: Flow<Unit>): Flow<Set<String>> =
    combine(locked, unlocked, ticks) { l, open, _ -> l.toSet() - open }.distinctUntilChanged()          // the clock ticks every few seconds: only a change in what is locked may make a list read again
