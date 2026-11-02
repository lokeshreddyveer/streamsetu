package app.streamsetu.core.sync

import androidx.room.withTransaction
import kotlinx.coroutines.sync.withLock
import app.streamsetu.core.data.db.*

/**
 * Writes a source's catalog, with the text index and a fingerprint of everything shown or played (in order), so a provider that sends
 * exactly what is already saved writes nothing at all, even after a restart. Raise [fingerprintVersion] when a parser starts reading more (or other) fields: every saved fingerprint is
 * then out of date and the catalogs are written again once.
 */
class CatalogStore(private val db: AppDatabase, private val fingerprintVersion: Int = 2) {
    /** One refresh of a source at a time: two that overlapped would write and delete against different snapshots and leave rows that belong to neither. */
    private val locks = java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.sync.Mutex>()

    internal fun digest(cats: List<CategoryEntity>, ch: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>): Long {
        var h = 1125899906842597L
        fun mix(x: Int) { h = 31 * h + x }
        mix(cats.size); cats.forEach { mix(it.hashCode()) }
        mix(ch.size); ch.forEach { mix(it.hashCode()) }
        mix(mv.size); mv.forEach { mix(it.hashCode()) }
        mix(sr.size); sr.forEach { mix(it.hashCode()) }
        return h
    }

    suspend fun replace(sourceId: String, cats: List<CategoryEntity>, allChannels: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>) =
        locks.getOrPut(sourceId) { kotlinx.coroutines.sync.Mutex() }.withLock { replaceLocked(sourceId, cats, allChannels, mv, sr) }

    private suspend fun replaceLocked(sourceId: String, cats: List<CategoryEntity>, allChannels: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>) {
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
        suspend fun <T> step(rows: List<T>, write: suspend (List<T>) -> Unit) {
            rows.chunked(STEP).forEach { part -> db.withTransaction { write(part) }; kotlinx.coroutines.delay(PAUSE_MS) }
        }
        step(cats) { c.putCategories(it) }
        step(ch) { part ->
            c.putChannels(part)
            part.forEach { r -> prefs[r.id]?.let { p ->          // what the person set on channels (names, guide ids) is put back onto the fresh rows
                p.name?.let { db.extras().setChannelName(r.id, it) }
                p.epgId?.let { db.extras().setChannelEpg(r.id, it) }
            } }
            app.streamsetu.core.data.db.SearchIndex.upsert(raw, part.map { app.streamsetu.core.data.db.SearchHit("CHANNEL", it.id, sourceId, it.categoryId, it.name) })
        }
        step(mv) { part -> c.putMovies(part); app.streamsetu.core.data.db.SearchIndex.upsert(raw, part.map { app.streamsetu.core.data.db.SearchHit("MOVIE", it.id, sourceId, it.categoryId, it.title) }) }
        step(sr) { part -> c.putSeries(part); app.streamsetu.core.data.db.SearchIndex.upsert(raw, part.map { app.streamsetu.core.data.db.SearchHit("SERIES", it.id, sourceId, it.categoryId, it.title) }) }
        step(c.categoryIds(sourceId).toSet().minus(cats.map { it.id }.toSet()).toList()) { c.deleteCategories(it) }
        step(c.channelIds(sourceId).toSet().minus(ch.map { it.id }.toSet()).toList()) { gone -> c.deleteChannels(gone); app.streamsetu.core.data.db.SearchIndex.delete(raw, "CHANNEL", gone) }
        step(c.movieIds(sourceId).toSet().minus(mv.map { it.id }.toSet()).toList()) { gone -> c.deleteMovies(gone); app.streamsetu.core.data.db.SearchIndex.delete(raw, "MOVIE", gone) }
        step(c.seriesIds(sourceId).toSet().minus(sr.map { it.id }.toSet()).toList()) { gone -> c.deleteSeries(gone); app.streamsetu.core.data.db.SearchIndex.delete(raw, "SERIES", gone) }
        c.putFingerprint(app.streamsetu.core.data.db.CatalogFingerprintEntity(sourceId, d, expected, fingerprintVersion))
    }

    private companion object {
        const val STEP = 500          // rows per transaction
        const val PAUSE_MS = 8L       // a gap between steps in which a person's own write gets in
    }
}
