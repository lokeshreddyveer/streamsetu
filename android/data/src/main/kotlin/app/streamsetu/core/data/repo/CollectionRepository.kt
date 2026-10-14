package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.UUID

/** The person's own lists, and local corrections to titles and pictures. Provider data is never changed. */
class CollectionRepository(private val db: AppDatabase) {
    private val dao get() = db.extras()

    fun collections(scope: ContentKind): Flow<List<UserCollection>> = dao.collections(scope.name).map { l -> l.map { UserCollection(it.id, it.name, scope) } }
    suspend fun create(name: String, scope: ContentKind): String { val id = UUID.randomUUID().toString(); dao.putCollection(CollectionEntity(id, name.trim().ifBlank { "My list" }, scope.name, System.currentTimeMillis())); return id }
    suspend fun rename(c: UserCollection, name: String) = dao.putCollection(CollectionEntity(c.id, name.trim().ifBlank { c.name }, c.scope.name, System.currentTimeMillis()))
    suspend fun delete(c: UserCollection) { dao.clearCollection(c.id); dao.deleteCollection(c.id) }
    suspend fun add(collectionId: String, itemId: String) = dao.putItem(CollectionItemEntity(collectionId, itemId, System.currentTimeMillis()))
    suspend fun remove(collectionId: String, itemId: String) = dao.removeItem(collectionId, itemId)
    suspend fun containing(itemId: String): Set<String> = dao.collectionsOf(itemId).toSet()

    // ---- Local corrections ----
    val overrides: Flow<Map<String, ItemOverride>> = dao.overrides().map { l -> l.associate { it.itemId to ItemOverride(it.title, it.posterUrl, it.plot) } }
    suspend fun setOverride(itemId: String, title: String?, posterUrl: String?) {
        if (title.isNullOrBlank() && posterUrl.isNullOrBlank()) dao.clearOverride(itemId) else dao.putOverride(OverrideEntity(itemId, title?.trim()?.ifBlank { null }, posterUrl?.trim()?.ifBlank { null }))
    }
    suspend fun clearOverride(itemId: String) = dao.clearOverride(itemId)
}
