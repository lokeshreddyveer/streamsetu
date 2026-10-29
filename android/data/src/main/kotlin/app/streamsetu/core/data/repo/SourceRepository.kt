package app.streamsetu.core.data.repo

import androidx.room.withTransaction
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.Source
import app.streamsetu.core.model.SyncStatus
import app.streamsetu.core.security.CredentialStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.UUID

class SourceRepository(private val db: AppDatabase, private val credentials: CredentialStore) {
    val sources: Flow<List<Source>> = db.sources().observe().map { l -> l.map { it.toModel() } }

    suspend fun get(id: String): Source? = db.sources().get(id)?.toModel()
    suspend fun all(): List<Source> = db.sources().all().map { it.toModel() }

    /** Saves a playlist. The password goes to the credential store, never the database. */
    suspend fun add(source: Source, password: String?): Source {
        val s = source.copy(id = source.id.ifBlank { UUID.randomUUID().toString() })
        db.sources().upsert(s.toEntity())
        if (!password.isNullOrEmpty()) credentials.save(credentialRef(s.id), password)
        return s
    }

    /** Removes a connection and everything read from it, as one step: all of it goes or none of it does. Its saved login is deleted only after that has happened. */
    suspend fun remove(id: String) {
        db.withTransaction {
            val c = db.catalog()
            c.clearChannels(id); c.clearMovies(id); c.clearSeries(id); c.clearCategories(id); c.clearFingerprint(id)
            db.sources().delete(id)
            db.libraries().removeSource(id)
            val raw = db.openHelper.writableDatabase          // on this transaction's own thread, so these are part of it
            app.streamsetu.core.data.db.SearchIndex.clear(raw, id); app.streamsetu.core.data.db.PeopleIndex.clear(raw, id)
        }
        credentials.delete(credentialRef(id))
    }

    suspend fun setStatus(id: String, status: SyncStatus, at: Long = System.currentTimeMillis()) = db.sources().setStatus(id, status.name, at)

    suspend fun setCounts(id: String, channels: Int, movies: Int, series: Int) = db.sources().setCounts(id, channels, movies, series)
    suspend fun setError(id: String, message: String?) = db.sources().setError(id, message)
    suspend fun setEnabled(id: String, enabled: Boolean) = db.sources().setEnabled(id, enabled)
    suspend fun rename(id: String, name: String) = db.sources().rename(id, name)
    /** The guide (XMLTV) address chosen by the person; empty goes back to the one the provider gives. */
    suspend fun setGuide(id: String, url: String?) = db.sources().setGuide(id, url?.trim()?.takeIf { it.isNotEmpty() })
    suspend fun markOpened(id: String) = db.sources().touch(id, System.currentTimeMillis())

    /** The saved password, for a connection being edited or tested again (never logged or shown). */
    suspend fun password(id: String): String? = credentials.load(credentialRef(id))

    companion object { fun credentialRef(sourceId: String) = "source.$sourceId" }
}
