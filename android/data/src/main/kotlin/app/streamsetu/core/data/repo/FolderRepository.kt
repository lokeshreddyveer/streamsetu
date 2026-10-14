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
class FolderRepository(private val db: AppDatabase, private val library: LibraryRepository, private val parental: ParentalControls) {
    private fun scopeName(kind: ContentKind) = kind.name

    /** Every folder of [kind] in the open library, in the person's order (pinned first, then arranged order, then the provider's order). Hidden ones are included, flagged. */
    fun folders(kind: ContentKind): Flow<List<Folder>> = library.sourceIds.flatMapLatest { ids ->
        val counts = when (kind) {
            ContentKind.MOVIE -> db.catalog().movieFolderCounts(ids)
            ContentKind.SERIES -> db.catalog().seriesFolderCounts(ids)
            else -> db.catalog().channelFolderCounts(ids)
        }
        combine(db.catalog().categories(kind.name, ids), db.folders().observe(scopeName(kind)), counts, parental.hideAdult) { cats, prefs, cnt, hideAdult ->
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

    /** Moves [f] one place up or down within the list as it is shown now, and saves that whole order. */
    suspend fun move(kind: ContentKind, current: List<Folder>, f: Folder, delta: Int) {
        val order = current.map { it.id }.toMutableList()
        val i = order.indexOf(f.id); val j = i + delta
        if (i < 0 || j !in order.indices) return
        order.removeAt(i); order.add(j, f.id)
        val byId = current.associateBy { it.id }
        db.folders().putAll(order.mapIndexed { idx, id -> (byId[id]?.pref ?: FolderPref()).let { p -> FolderPrefEntity(scopeName(kind), id, p.favorite, p.pinned, p.hidden, p.locked, p.alias, idx) } })
    }

    suspend fun restoreDefaultOrder(kind: ContentKind) {
        // Keeps favourites, hidden, locked and renamed state; only the order goes back to the provider's.
        val kept = db.folders().observe(scopeName(kind)).first()
        db.folders().putAll(kept.map { it.copy(sortIndex = -1, pinned = false) })
    }
}
