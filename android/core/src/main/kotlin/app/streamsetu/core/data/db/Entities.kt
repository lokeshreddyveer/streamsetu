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
