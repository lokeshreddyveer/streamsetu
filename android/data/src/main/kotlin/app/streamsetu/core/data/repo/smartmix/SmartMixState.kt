package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.Visibility

/**
 * The person's own Smart Mix state, written only for titles that may be recommended: nothing that names a locked, hidden or adult-blocked title is saved, and what was saved for a folder
 * that has just been restricted is removed at once. Continue Watching's own data (progress, resume points, history) is never read or written here.
 */
class SmartMixState(private val db: AppDatabase, private val visibility: Visibility) {
    private val dao get() = db.identity()

    /**
     * "Remove from recommendations" (the person took a title out of Continue Watching). Returns false and writes nothing when the title is restricted. The progress row is not touched;
     * this is a marker of its own, kept per profile and by identity (so another copy of the title is covered too).
     */
    suspend fun dismiss(profileId: String, kind: String, itemId: String, title: String, categoryId: String?, year: Int?, at: Long = System.currentTimeMillis()): Boolean {
        val ck = if (kind == "SERIES" || kind == "EPISODE") app.streamsetu.core.model.ContentKind.SERIES else app.streamsetu.core.model.ContentKind.MOVIE
        val snap = visibility.snapshot(Visibility.Surface.RECOMMEND)
        if (!snap.folderOk(ck, categoryId)) return false
        dao.putDismissed(RecDismissedEntity(profileId, itemId, kind, IdentityKey.ofOrFallback(title), IdentityKey.yearOf(title, year), at))
        return true
    }
    suspend fun undismiss(profileId: String, itemId: String) = dao.undismiss(profileId, itemId)
    suspend fun dismissed(profileId: String) = dao.dismissed(profileId)

    /** What a shelf showed; restricted titles are never recorded. */
    suspend fun recordShown(profileId: String, shelfId: String, loadSeq: Int, shown: List<CanonicalPick.Copy>, at: Long = System.currentTimeMillis()): Int {
        val snap = visibility.snapshot(Visibility.Surface.RECOMMEND)
        val ok = shown.filter { c -> snap.folderOk(if (c.kind == "SERIES") app.streamsetu.core.model.ContentKind.SERIES else app.streamsetu.core.model.ContentKind.MOVIE, c.folderId) }
        dao.putShown(ok.map { SmartMixShownEntity(profileId, shelfId, it.identityKey, it.year, it.itemId, loadSeq, at) })
        return ok.size
    }

    /**
     * Called when a folder becomes restricted: removes what was saved for titles in it, and for any title whose identity matches one in it (another copy). Dismissals stay (they are the
     * person's own choice and are never read for a restricted title).
     */
    suspend fun purgeShown(folderIds: Set<String>) {
        if (folderIds.isEmpty()) return
        val ids = ArrayList<String>(); val keys = ArrayList<String>()
        val raw = db.openHelper.readableDatabase
        for (chunk in folderIds.toList().chunked(400)) for (table in listOf("movies", "series")) {
            raw.query("SELECT id, title FROM $table WHERE categoryId IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray()).use { c -> while (c.moveToNext()) { ids += c.getString(0); keys += IdentityKey.ofOrFallback(c.getString(1)) } }
        }
        for (c in ids.chunked(500)) dao.deleteShownItems(c)
        for (c in keys.distinct().chunked(500)) dao.deleteShownKeys(c)
    }
}
