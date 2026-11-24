package app.streamsetu.core.sync

import androidx.room.withTransaction
import app.streamsetu.core.data.repo.SourceLocks
import app.streamsetu.core.data.repo.SourceRemovedException
import kotlinx.coroutines.sync.withLock
import app.streamsetu.core.data.db.*

/**
 * Writes a source's catalog, with the text index and a fingerprint of everything shown or played (in order), so a provider that sends
 * exactly what is already saved writes nothing at all, even after a restart. Raise [fingerprintVersion] when a parser starts reading more (or other) fields: every saved fingerprint is
 * then out of date and the catalogs are written again once.
 */
class CatalogStore(private val db: AppDatabase, private val fingerprintVersion: Int = 2, private val deferFirstIdentity: Boolean = false) {
    /** The derived identity of every movie and series (see IdentityStore): written in the same steps as the rows, only for rows that are new or changed. IdentityStore.changes tells what a read changed. */
    val identity = app.streamsetu.core.data.repo.smartmix.IdentityStore(db)

    internal fun digest(cats: List<CategoryEntity>, ch: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>): Long {
        var h = 1125899906842597L
        fun mix(x: Int) { h = 31 * h + x }
        mix(cats.size); cats.forEach { mix(it.hashCode()) }
        mix(ch.size); ch.forEach { mix(it.hashCode()) }
        mix(mv.size); mv.forEach { mix(it.hashCode()) }
        mix(sr.size); sr.forEach { mix(it.hashCode()) }
        return h
    }

    suspend fun replace(sourceId: String, cats: List<CategoryEntity>, allChannels: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>, onProgress: (SyncProgress) -> Unit = {}) =
        // One writer of a source's catalog at a time (a refresh, removing it, clearing an add-on): two that overlapped would write and delete against different snapshots and leave rows that belong to neither.
        SourceLocks.of(sourceId).withLock { replaceLocked(sourceId, cats, allChannels, mv, sr, onProgress) }

    private suspend fun replaceLocked(sourceId: String, cats: List<CategoryEntity>, allChannels: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>, onProgress: (SyncProgress) -> Unit) {
        val ch = allChannels.filter { !ChannelFilter.isDivider(it.name) }          // a heading in the provider's list is not a channel and is never stored (the one definition, shared with the import)
        // The screens already show what is saved. If the provider sent exactly the same catalog, nothing is deleted, nothing is inserted and nothing is announced: no list
        // is rebuilt and no row is handed to the screens as new.
        val d = digest(cats, ch, mv, sr); val expected = cats.size + ch.size + mv.size + sr.size
        db.catalog().fingerprint(sourceId)?.let { was -> if (was.version == fingerprintVersion && was.fingerprint == d && was.rows == expected && db.catalog().rowsFor(sourceId) == expected) return }
        // The catalog is written in small steps, each its own short transaction, with a pause between them: a favourite or a resume point a person saves meanwhile waits for one step (tens of
        // milliseconds), never for the whole catalog. New and changed rows go in first and rows the provider no longer lists are removed last, so a refresh that stops half way leaves
        // the old catalog plus some of the new rows (never less than before), and the fingerprint is written only once everything is in, so an interrupted refresh is simply done again.
        val c = db.catalog(); val raw = db.openHelper.writableDatabase
        val was = c.fingerprint(sourceId)
        // From here the catalog is being changed. The saved fingerprint is removed first, so a refresh that is cut short can never leave an old fingerprint standing over a half-written catalog
        // (a provider that then went back to its old content would otherwise be "unchanged" and the damage never repaired); it is written again only when everything is in.
        db.catalog().clearFingerprint(sourceId)
        if (was == null || was.version != fingerprintVersion) db.withTransaction { app.streamsetu.core.data.db.SearchIndex.clear(raw, sourceId) }          // an index from before rows had fixed numbers is rebuilt, once
        val prefs = db.extras().channelPrefsNow().associateBy { it.channelId }
        // [stage] names what the person is told; [size] is the rows per transaction (the large kinds go in bigger steps: fewer commits, the same short wait for a person's own write).
        suspend fun <T> step(rows: List<T>, stage: SyncProgress.Stage? = null, size: Int = STEP, write: suspend (List<T>) -> Unit) {
            val t0 = System.nanoTime(); var done = 0
            if (stage != null && rows.isNotEmpty()) onProgress(SyncProgress(stage, 0, rows.size))
            rows.chunked(size).forEach { part ->
                if (SourceLocks.isRemoving(sourceId)) throw SourceRemovedException(sourceId)          // the connection is being removed: stop writing rows for it
                db.withTransaction { write(part) }; done += part.size
                if (stage != null) onProgress(SyncProgress(stage, done, rows.size))
                kotlinx.coroutines.delay(PAUSE_MS)
            }
            if (stage != null && rows.isNotEmpty()) SyncLog.stage(stage.name, rows.size, (System.nanoTime() - t0) / 1_000_000)
        }
        val names = cats.associate { it.id to it.name }
        val movieIdentity = safely { identity.begin(sourceId, "MOVIE", names) }.getOrNull()
        val seriesIdentity = safely { identity.begin(sourceId, "SERIES", names) }.getOrNull()
        // A first read (nothing derived yet for this playlist) writes no identity rows here: deriving 80,000 titles inside the read is what kept a TV stick busy for many minutes. The background fill makes them
        // soon after (see IdentityStore.backfillStep), and readers use their slower path until enough of the catalog is covered. A refresh of a playlist that has identities derives only what is new or changed, as before.
        val inlineMovies = movieIdentity?.takeIf { !deferFirstIdentity || it.knownCount > 0 || mv.isEmpty() }
        val inlineSeries = seriesIdentity?.takeIf { !deferFirstIdentity || it.knownCount > 0 || sr.isEmpty() }
        fun movieRows(p: List<MovieEntity>) = p.map { UnderivedRow(it.id, it.sourceId, it.categoryId, it.title, it.year) }
        fun seriesRows(p: List<SeriesEntity>) = p.map { UnderivedRow(it.id, it.sourceId, it.categoryId, it.title, it.year) }
        step(cats) { c.putCategories(it) }
        step(ch, SyncProgress.Stage.SAVING_CHANNELS, BULK_STEP) { part ->
            c.putChannels(part)
            part.forEach { r -> prefs[r.id]?.let { p ->          // what the person set on channels (names, guide ids) is put back onto the fresh rows
                p.name?.let { db.extras().setChannelName(r.id, it) }
                p.epgId?.let { db.extras().setChannelEpg(r.id, it) }
            } }
            app.streamsetu.core.data.db.SearchIndex.upsert(raw, part.map { app.streamsetu.core.data.db.SearchHit("CHANNEL", it.id, sourceId, it.categoryId, it.name) })
        }
        // The sort key is written with the row (the same SortKey the database triggers use), so the trigger that would otherwise rewrite every new row about fifteen times has nothing to do (it runs only for a row saved without a key).
        step(mv, SyncProgress.Stage.SAVING_MOVIES, BULK_STEP) { part -> c.putMovies(part.map { if (it.titleSort.isEmpty()) it.copy(titleSort = app.streamsetu.core.model.SortKey.of(it.title)) else it }); app.streamsetu.core.data.db.SearchIndex.upsert(raw, part.map { app.streamsetu.core.data.db.SearchHit("MOVIE", it.id, sourceId, it.categoryId, it.title) }); safely { inlineMovies?.apply(movieRows(part)) } }          // an identity that could not be written is made by the background fill later, never a failed read
        step(sr, SyncProgress.Stage.SAVING_SERIES, BULK_STEP) { part -> c.putSeries(part.map { if (it.titleSort.isEmpty()) it.copy(titleSort = app.streamsetu.core.model.SortKey.of(it.title)) else it }); app.streamsetu.core.data.db.SearchIndex.upsert(raw, part.map { app.streamsetu.core.data.db.SearchHit("SERIES", it.id, sourceId, it.categoryId, it.title) }); safely { inlineSeries?.apply(seriesRows(part)) } }
        val tidy0 = System.nanoTime()
        step(c.categoryIds(sourceId).toSet().minus(cats.map { it.id }.toSet()).toList()) { c.deleteCategories(it) }
        step(c.channelIds(sourceId).toSet().minus(ch.map { it.id }.toSet()).toList()) { gone -> c.deleteChannels(gone); app.streamsetu.core.data.db.SearchIndex.delete(raw, "CHANNEL", gone) }
        step(c.movieIds(sourceId).toSet().minus(mv.map { it.id }.toSet()).toList()) { gone -> c.deleteMovies(gone); app.streamsetu.core.data.db.SearchIndex.delete(raw, "MOVIE", gone); safely { movieIdentity?.removed(gone) } }
        step(c.seriesIds(sourceId).toSet().minus(sr.map { it.id }.toSet()).toList()) { gone -> c.deleteSeries(gone); app.streamsetu.core.data.db.SearchIndex.delete(raw, "SERIES", gone); safely { seriesIdentity?.removed(gone) } }
        SyncLog.stage("TIDYING", 0, (System.nanoTime() - tidy0) / 1_000_000)
        c.putFingerprint(app.streamsetu.core.data.db.CatalogFingerprintEntity(sourceId, d, expected, fingerprintVersion))
        // Announced only once everything is in, and only when something changed; whether this playlist is now a twin of another is looked at again.
        val changed = listOfNotNull(movieIdentity?.finish(), seriesIdentity?.finish()).any { !it.isEmpty }
        if (changed) safely { app.streamsetu.core.data.repo.smartmix.SourceTwins.recompute(db) }
    }

    private companion object {
        const val STEP = 500          // rows per transaction (folders, rows to remove)
        const val BULK_STEP = 1000    // rows per transaction for channels, movies and series: with no per-row trigger a step of this size is still tens of milliseconds to a few hundred on a TV stick
        const val PAUSE_MS = 8L       // a gap between steps in which a person's own write gets in
    }
}

/** Like runCatching, but a cancelled read stays cancelled (the cancellation is passed on, not swallowed as a failure of the identity step). */
private inline fun <T> safely(block: () -> T): Result<T> = try { Result.success(block()) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Throwable) { Result.failure(e) }
