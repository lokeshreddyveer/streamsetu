package app.streamsetu.core.data.repo

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

    suspend fun remove(id: String) {
        val c = db.catalog()
        c.clearChannels(id); c.clearMovies(id); c.clearSeries(id); c.clearCategories(id)
        db.sources().delete(id)
        db.libraries().removeSource(id)
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { app.streamsetu.core.data.db.SearchIndex.clear(db.openHelper.writableDatabase, id) }
        credentials.delete(credentialRef(id))
    }

    suspend fun setStatus(id: String, status: SyncStatus, at: Long = System.currentTimeMillis()) = db.sources().setStatus(id, status.name, at)

    suspend fun setCounts(id: String, channels: Int, movies: Int, series: Int) = db.sources().setCounts(id, channels, movies, series)
    suspend fun setError(id: String, message: String?) = db.sources().setError(id, message)
    suspend fun rename(id: String, name: String) = db.sources().rename(id, name)
    suspend fun markOpened(id: String) = db.sources().touch(id, System.currentTimeMillis())

    /** The saved password, for a connection being edited or tested again (never logged or shown). */
    suspend fun password(id: String): String? = credentials.load(credentialRef(id))

    companion object { fun credentialRef(sourceId: String) = "source.$sourceId" }
}
