package app.streamsetu.core.data.db

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Upsert

/**
 * The guide hub (database version 16; same shape as the Apple SchemaV25). A guide the person added is a row here; its programmes are stored in the existing `epg` table under the id scope
 * "<guide source id>\u0001<xmltv id>", so every reader of the guide keeps working. The address of a guide never sits in this table: [urlRef] names a secret held in encrypted preferences.
 */
@Entity(tableName = "guide_sources")
data class GuideSourceEntity(
    @PrimaryKey val id: String,
    val kind: String,
    val name: String,
    val urlRef: String? = null,
    @ColumnInfo(defaultValue = "1") val enabled: Boolean = true,
    @ColumnInfo(defaultValue = "20") val priority: Int = 20,
    @ColumnInfo(defaultValue = "6") val refreshHours: Int = 6,
    @ColumnInfo(defaultValue = "'auto'") val tzMode: String = "auto",
    val tzZone: String? = null,
    @ColumnInfo(defaultValue = "0") val offsetMinutes: Int = 0,
    val etag: String? = null,
    val lastModified: String? = null,
    @ColumnInfo(defaultValue = "0") val createdAt: Long = 0,
)

/** What the last fetch of a guide source found, including what it skipped and why: this is what explains an empty guide. */
@Entity(tableName = "guide_diagnostics")
data class GuideDiagnosticsEntity(
    @PrimaryKey val guideSourceId: String,
    val lastAttempt: Long,
    val lastSuccess: Long?,
    val outcome: String,
    val httpStatus: Int? = null,
    val bytes: Long? = null,
    @ColumnInfo(defaultValue = "0") val channels: Int = 0,
    @ColumnInfo(defaultValue = "0") val mapped: Int = 0,
    @ColumnInfo(defaultValue = "0") val programmesSeen: Int = 0,
    @ColumnInfo(defaultValue = "0") val programmesKept: Int = 0,
    @ColumnInfo(defaultValue = "0") val droppedPast: Int = 0,
    @ColumnInfo(defaultValue = "0") val droppedFuture: Int = 0,
    @ColumnInfo(defaultValue = "0") val droppedInvalid: Int = 0,
    val fileFirstStart: Long? = null,
    val fileLastStop: Long? = null,
    @ColumnInfo(defaultValue = "0") val truncated: Boolean = false,
    val error: String? = null,
    val windowEnd: Long? = null,
)

/** A channel tied to a guide channel: automatically (method and confidence) or by the person (method "user", locked, never recomputed). */
@Entity(tableName = "channel_guide_map", primaryKeys = ["channelId", "guideSourceId"], indices = [Index("guideSourceId", "xmltvId")])
data class ChannelGuideMapEntity(
    val channelId: String, val guideSourceId: String, val xmltvId: String, val method: String,
    @ColumnInfo(defaultValue = "1") val confidence: Double = 1.0,
    val reason: String? = null,
    @ColumnInfo(defaultValue = "0") val locked: Boolean = false,
    @ColumnInfo(defaultValue = "0") val updatedAt: Long = 0,
)

/** What the public channel database gave a channel (an overlay: the playlist's own fields are never changed). Derived, rebuildable, never synced. */
@Entity(tableName = "channel_enrichment")
data class ChannelEnrichmentEntity(
    @PrimaryKey val channelId: String,
    val dbId: String?, val logoUrl: String?, val categoryKey: String?, val country: String?, val language: String?, val matchedBy: String?,
    @ColumnInfo(defaultValue = "0") val confidence: Double = 0.0,
    @ColumnInfo(defaultValue = "0") val fetchedAt: Long = 0,
)

/** A channel as the guide hub needs it. [restricted]: hidden, or in a hidden or locked folder. Adult and kids names are checked by the caller. */
data class GuideChannelRow(val id: String, val sourceId: String, val name: String, val epgId: String?, val logoUrl: String?, val categoryName: String?, val restricted: Boolean)

@Dao
interface GuideHubDao {
    @Query("""SELECT c.id AS id, c.sourceId AS sourceId, c.name AS name, c.epgId AS epgId, c.logoUrl AS logoUrl, cat.name AS categoryName,
        (c.id IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) OR c.categoryId IN (SELECT folderId FROM folder_prefs WHERE locked = 1 OR hidden = 1)) AS restricted
        FROM channels c JOIN sources s ON s.id = c.sourceId LEFT JOIN categories cat ON cat.id = c.categoryId WHERE s.enabled = 1 AND s.draft = 0""")
    suspend fun channelRows(): List<GuideChannelRow>
    @Query("SELECT * FROM epg_channels WHERE epgId LIKE :scope || char(1) || '%'") suspend fun guideChannelsOf(scope: String): List<EpgChannelEntity>
    @Query("SELECT id FROM sources WHERE enabled = 1 AND draft = 0") suspend fun enabledSourceIds(): List<String>
    @Query("SELECT id, name FROM sources WHERE enabled = 1 AND draft = 0") suspend fun enabledSourceNames(): List<IdName>

    @Query("SELECT * FROM guide_sources ORDER BY priority, name") suspend fun sources(): List<GuideSourceEntity>
    @Query("SELECT * FROM guide_sources WHERE id = :id") suspend fun source(id: String): GuideSourceEntity?
    @Upsert suspend fun putSource(s: GuideSourceEntity)
    @Query("DELETE FROM guide_sources WHERE id = :id") suspend fun deleteSource(id: String)
    @Query("UPDATE guide_sources SET enabled = :on WHERE id = :id") suspend fun setEnabled(id: String, on: Boolean)
    @Query("UPDATE guide_sources SET etag = :etag, lastModified = :lastModified WHERE id = :id") suspend fun setValidators(id: String, etag: String?, lastModified: String?)

    @Query("SELECT * FROM guide_diagnostics") suspend fun diagnostics(): List<GuideDiagnosticsEntity>
    @Query("SELECT * FROM guide_diagnostics WHERE guideSourceId = :id") suspend fun diagnostic(id: String): GuideDiagnosticsEntity?
    @Upsert suspend fun putDiagnostic(d: GuideDiagnosticsEntity)
    @Query("DELETE FROM guide_diagnostics WHERE guideSourceId = :id") suspend fun deleteDiagnostic(id: String)

    @Query("SELECT * FROM channel_guide_map") suspend fun guideMap(): List<ChannelGuideMapEntity>
    @Query("SELECT * FROM channel_guide_map WHERE locked = 1") suspend fun userMappings(): List<ChannelGuideMapEntity>
    @Query("DELETE FROM channel_guide_map WHERE guideSourceId = :id AND locked = 0") suspend fun clearAutomatic(id: String)
    @Query("DELETE FROM channel_guide_map WHERE guideSourceId = :id") suspend fun clearAllOf(id: String)
    @Query("DELETE FROM channel_guide_map WHERE channelId = :channelId AND locked = 1") suspend fun clearUser(channelId: String)
    @Upsert suspend fun putMappings(rows: List<ChannelGuideMapEntity>)
    @Query("SELECT COUNT(*) FROM channel_guide_map WHERE guideSourceId = :id") suspend fun mappedCount(id: String): Int

    @Query("SELECT * FROM channel_enrichment") suspend fun enrichment(): List<ChannelEnrichmentEntity>
    @Query("SELECT * FROM channel_enrichment WHERE channelId IN (:ids)") suspend fun enrichmentFor(ids: List<String>): List<ChannelEnrichmentEntity>
    @Upsert suspend fun putEnrichment(rows: List<ChannelEnrichmentEntity>)
    @Query("DELETE FROM channel_enrichment WHERE channelId = :id") suspend fun deleteEnrichment(id: String)
    @Query("DELETE FROM channel_enrichment") suspend fun clearEnrichment()

    /** Programme count and last end of one guide scope in the shared `epg` table. */
    @Query("SELECT COUNT(*) FROM epg WHERE channelEpgId LIKE :scope || char(1) || '%'") suspend fun programmesOf(scope: String): Int
    @Query("SELECT MAX(endMs) FROM epg WHERE channelEpgId LIKE :scope || char(1) || '%'") suspend fun lastEndOf(scope: String): Long?
    @Query("DELETE FROM epg WHERE channelEpgId LIKE :scope || char(1) || '%'") suspend fun deleteProgrammesOf(scope: String)
    @Query("DELETE FROM epg WHERE channelEpgId LIKE :scope || char(1) || '%' AND endMs < :before") suspend fun pruneProgrammesOf(scope: String, before: Long)
    @Query("DELETE FROM epg_channels WHERE epgId LIKE :scope || char(1) || '%'") suspend fun deleteGuideChannelsOf(scope: String)
}

data class IdName(val id: String, val name: String)
