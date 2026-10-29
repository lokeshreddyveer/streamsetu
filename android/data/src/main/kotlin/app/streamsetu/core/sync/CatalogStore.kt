package app.streamsetu.core.sync

import androidx.room.withTransaction
import app.streamsetu.core.data.db.*

/**
 * Writes a source's catalog. Rows are written in one transaction together with the text index and a fingerprint of everything shown or played (in order), so a provider that sends
 * exactly what is already saved writes nothing at all, even after a restart. Raise [fingerprintVersion] when a parser starts reading more (or other) fields: every saved fingerprint is
 * then out of date and the catalogs are written again once.
 */
class CatalogStore(private val db: AppDatabase, private val fingerprintVersion: Int = 1) {
    internal fun digest(cats: List<CategoryEntity>, ch: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>): Long {
        var h = 1125899906842597L
        fun mix(x: Int) { h = 31 * h + x }
        mix(cats.size); cats.forEach { mix(it.hashCode()) }
        mix(ch.size); ch.forEach { mix(it.hashCode()) }
        mix(mv.size); mv.forEach { mix(it.hashCode()) }
        mix(sr.size); sr.forEach { mix(it.hashCode()) }
        return h
    }

    suspend fun replace(sourceId: String, cats: List<CategoryEntity>, ch: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>) {
        // The screens already show what is saved. If the provider sent exactly the same catalog, nothing is deleted, nothing is inserted and nothing is announced: no list
        // is rebuilt and no row is handed to the screens as new.
        val d = digest(cats, ch, mv, sr); val expected = cats.size + ch.size + mv.size + sr.size
        db.catalog().fingerprint(sourceId)?.let { was -> if (was.version == fingerprintVersion && was.fingerprint == d && was.rows == expected && db.catalog().rowsFor(sourceId) == expected) return }
        db.withTransaction {
            val c = db.catalog()
            c.clearCategories(sourceId); c.clearChannels(sourceId); c.clearMovies(sourceId); c.clearSeries(sourceId)
            cats.chunked(500).forEach { c.putCategories(it) }
            ch.chunked(500).forEach { c.putChannels(it) }
            mv.chunked(500).forEach { c.putMovies(it) }
            sr.chunked(500).forEach { c.putSeries(it) }
            // The text index changes in the same transaction, so a refresh that fails keeps the old catalog and the old index together.
            val raw = db.openHelper.writableDatabase
            app.streamsetu.core.data.db.SearchIndex.clear(raw, sourceId)
            val hits = ArrayList<app.streamsetu.core.data.db.SearchHit>(ch.size + mv.size + sr.size)
            ch.forEach { hits += app.streamsetu.core.data.db.SearchHit("CHANNEL", it.id, sourceId, it.categoryId, it.name) }
            mv.forEach { hits += app.streamsetu.core.data.db.SearchHit("MOVIE", it.id, sourceId, it.categoryId, it.title) }
            sr.forEach { hits += app.streamsetu.core.data.db.SearchHit("SERIES", it.id, sourceId, it.categoryId, it.title) }
            hits.chunked(2000).forEach { app.streamsetu.core.data.db.SearchIndex.insert(raw, it) }
            // Saved in the same transaction as the rows, so the fingerprint only ever describes a catalog that was written completely.
            c.putFingerprint(app.streamsetu.core.data.db.CatalogFingerprintEntity(sourceId, d, expected, fingerprintVersion))
            // What the person set on channels (names, guide ids) is put back onto the fresh rows.
            db.extras().channelPrefsNow().forEach { p ->
                p.name?.let { db.extras().setChannelName(p.channelId, it) }
                p.epgId?.let { db.extras().setChannelEpg(p.channelId, it) }
            }
        }
    }
}
