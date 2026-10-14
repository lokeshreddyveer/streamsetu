package app.streamsetu.core.data.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(tableName = "sources")
data class SourceEntity(
    @PrimaryKey val id: String,
    val name: String,
    val type: String,
    val address: String,
    val username: String?,
    val epgUrl: String?,
    val enabled: Boolean,
    val lastSyncAt: Long,
    val status: String,
    val sortOrder: Int = 0,
    /** Set aside before it was tested: not a working library yet. */
    val draft: Boolean = false,
    /** What the last good read found, so the library chooser can preview it without a network request. */
    val channelCount: Int = 0,
    val movieCount: Int = 0,
    val seriesCount: Int = 0,
    val lastError: String? = null,
    val lastOpenedAt: Long = 0,
    val userAgent: String? = null,
)

@Entity(tableName = "categories", primaryKeys = ["id"], indices = [Index("sourceId", "kind")])
data class CategoryEntity(val id: String, val sourceId: String, val kind: String, val name: String, val sortOrder: Int)

@Entity(tableName = "channels", indices = [Index("sourceId", "categoryId"), Index("name"), Index("epgId")])
data class ChannelEntity(
    @PrimaryKey val id: String,
    val sourceId: String,
    val categoryId: String?,
    val name: String,
    val number: Int?,
    val logoUrl: String?,
    val streamRef: String,
    val epgId: String?,
    val catchupDays: Int,
    val sortOrder: Int,
    val addedAt: Long = 0,
    val isRadio: Boolean = false,
)

@Entity(tableName = "movies", indices = [Index("sourceId", "categoryId"), Index("title")])
data class MovieEntity(
    @PrimaryKey val id: String,
    val sourceId: String,
    val categoryId: String?,
    val title: String,
    val posterUrl: String?,
    val year: Int?,
    val rating: String?,
    val plot: String?,
    val streamRef: String,
    val addedAt: Long,
)

@Entity(tableName = "series", indices = [Index("sourceId", "categoryId"), Index("title")])
data class SeriesEntity(
    @PrimaryKey val id: String,
    val sourceId: String,
    val categoryId: String?,
    val title: String,
    val posterUrl: String?,
    val backdropUrl: String?,
    val year: Int?,
    val rating: String?,
    val plot: String?,
    val providerId: String,
    val addedAt: Long = 0,
)

@Entity(tableName = "episodes", indices = [Index("seriesId", "season", "number")])
data class EpisodeEntity(
    @PrimaryKey val id: String,
    val seriesId: String,
    val season: Int,
    val number: Int,
    val title: String,
    val plot: String?,
    val imageUrl: String?,
    val durationSec: Int?,
    val streamRef: String,
)

@Entity(tableName = "epg", primaryKeys = ["channelEpgId", "startMs"], indices = [Index("channelEpgId", "endMs")])
data class EpgEntity(val channelEpgId: String, val startMs: Long, val endMs: Long, val title: String, val description: String?)

@Entity(tableName = "favorites", primaryKeys = ["itemId", "listId"])
data class FavoriteEntity(val itemId: String, val kind: String, val listId: String, val addedAt: Long)

@Entity(tableName = "progress")
data class ProgressEntity(
    @PrimaryKey val itemId: String,
    val kind: String,
    val seriesId: String?,
    val positionMs: Long,
    val durationMs: Long,
    val updatedAt: Long,
    val completed: Boolean,
)

@Entity(tableName = "watch_log", indices = [Index("playedAt")])
data class WatchLogEntity(@PrimaryKey(autoGenerate = true) val id: Long = 0, val itemId: String, val kind: String, val title: String, val playedAt: Long)

/** A group of connections shown as one library. It holds no copy of their catalogs; screens read the members' records together. */
@Entity(tableName = "libraries")
data class LibraryEntity(@PrimaryKey val id: String, val name: String, val createdAt: Long, val lastOpenedAt: Long = 0)

@Entity(tableName = "library_members", primaryKeys = ["libraryId", "sourceId"], indices = [Index("sourceId")])
data class LibraryMemberEntity(val libraryId: String, val sourceId: String)

/** The person's own arrangement of a provider folder. The provider's playlist is never changed. [scope] is CHANNEL, MOVIE or SERIES. */
@Entity(tableName = "folder_prefs", primaryKeys = ["scope", "folderId"])
data class FolderPrefEntity(
    val scope: String,
    val folderId: String,
    val favorite: Boolean = false,
    val pinned: Boolean = false,
    val hidden: Boolean = false,
    val locked: Boolean = false,
    val alias: String? = null,
    /** -1 = provider order. */
    val sortIndex: Int = -1,
)

/** An episode that appeared after the person had already seen the series' earlier ones. Cleared when it is played or marked watched. */
@Entity(tableName = "new_episodes", indices = [Index("seriesId")])
data class NewEpisodeEntity(@PrimaryKey val episodeId: String, val seriesId: String, val discoveredAt: Long)

/** A list the person made ("Weekend movies"). [scope] is MOVIE, SERIES or CHANNEL. */
@Entity(tableName = "collections")
data class CollectionEntity(@PrimaryKey val id: String, val name: String, val scope: String, val createdAt: Long)

@Entity(tableName = "collection_items", primaryKeys = ["collectionId", "itemId"], indices = [Index("itemId")])
data class CollectionItemEntity(val collectionId: String, val itemId: String, val addedAt: Long)

/** A local correction to what the provider calls something. The provider's own data is never changed. */
@Entity(tableName = "overrides")
data class OverrideEntity(@PrimaryKey val itemId: String, val title: String?, val posterUrl: String?)

/** Guide channel names, so a channel without a usable guide id can be matched to its programmes by name. */
@Entity(tableName = "epg_channels")
data class EpgChannelEntity(@PrimaryKey val epgId: String, val nameNorm: String)
