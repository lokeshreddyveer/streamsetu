package app.streamsetu.core.data.db

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Upsert

/** The metadata hub's crosswalk: one title's ids across the services (the older ContentIdentityEntity is derived data and stays untouched). Same shape as the Apple hub_identity. */
@Entity(tableName = "hub_identity")
data class HubIdentityEntity(
    @PrimaryKey val itemId: String,
    val tmdbId: Int?, val tvdbId: Int?, val imdbId: String?, val tvmazeId: Int?, val kind: String?,
    @ColumnInfo(defaultValue = "0") val resolvedAt: Long = 0,
    val missUntil: Long? = null,
)

/** One saved fact (an address, a text, a date) with its source, quality and expiry. Misses are rows with no value and a missUntil. */
@Entity(tableName = "metadata_facts", primaryKeys = ["itemId", "field"], indices = [Index("expiresAt")])
data class MetadataFactEntity(
    val itemId: String, val field: String, val value: String?, val source: String,
    @ColumnInfo(defaultValue = "0") val quality: Double, val fetchedAt: Long, val expiresAt: Long, val missUntil: Long? = null,
    @ColumnInfo(defaultValue = "0") val failCount: Int = 0,
)

/** Which TMDB title a library item was matched to (was a raw-SQL table made on first use; a Room table since database version 15). Removed with everything else TMDB gave. */
@Entity(tableName = "tmdb_ids", indices = [Index("tmdbId", "tv")])
data class TmdbIdEntity(@PrimaryKey val itemId: String, val tmdbId: Long, val tv: Int, val at: Long)

/** The TMDB genre ids of a library item (",28,12,"), kept where its TMDB details were fetched. A Room table since database version 15. */
@Entity(tableName = "tmdb_genres")
data class TmdbGenreEntity(@PrimaryKey val itemId: String, val ids: String, val at: Long)

@Dao
interface HubDao {
    @Query("SELECT * FROM hub_identity WHERE itemId = :id") suspend fun identity(id: String): HubIdentityEntity?
    @Upsert suspend fun putIdentity(e: HubIdentityEntity)
    @Query("SELECT * FROM metadata_facts WHERE itemId = :id AND field = :field") suspend fun fact(id: String, field: String): MetadataFactEntity?
    @Upsert suspend fun putFact(e: MetadataFactEntity)
    @Query("SELECT DISTINCT source FROM metadata_facts WHERE itemId = :id AND value IS NOT NULL") suspend fun provenance(id: String): List<String>
    @Query("DELETE FROM metadata_facts WHERE expiresAt <= :now") suspend fun purgeExpired(now: Long): Int
    @Query("DELETE FROM metadata_facts WHERE itemId IN (:ids)") suspend fun purgeFacts(ids: List<String>): Int
    @Query("DELETE FROM hub_identity WHERE itemId IN (:ids)") suspend fun purgeIdentity(ids: List<String>): Int
    /** Turning one service off deletes what it saved. */
    @Query("DELETE FROM metadata_facts WHERE source = :source") suspend fun purgeSource(source: String): Int
    /** Turning TMDB matching off or removing the key takes back what the hub saved from TMDB: its facts, and the TMDB id in the crosswalk (the other services' ids stay). */
    @Query("UPDATE hub_identity SET tmdbId = NULL") suspend fun forgetTmdbIds()
    /** Locked or hidden folders (their titles) and a folder removed from the library. */
    @Query("DELETE FROM metadata_facts WHERE itemId IN (SELECT id FROM movies WHERE categoryId IN (:folders) UNION SELECT id FROM series WHERE categoryId IN (:folders))")
    suspend fun purgeFactsInFolders(folders: List<String>): Int
    @Query("DELETE FROM hub_identity WHERE itemId IN (SELECT id FROM movies WHERE categoryId IN (:folders) UNION SELECT id FROM series WHERE categoryId IN (:folders))")
    suspend fun purgeIdentityInFolders(folders: List<String>): Int
}
