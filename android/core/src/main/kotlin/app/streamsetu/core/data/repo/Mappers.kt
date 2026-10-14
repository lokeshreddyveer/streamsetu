package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.*

internal fun SourceEntity.toModel() = Source(id, name, SourceType.valueOf(type), address, username, epgUrl, enabled, lastSyncAt, SyncStatus.valueOf(status))
internal fun Source.toEntity(sortOrder: Int = 0) = SourceEntity(id, name, type.name, address, username, epgUrl, enabled, lastSyncAt, status.name, sortOrder)
internal fun CategoryEntity.toModel() = Category(id, sourceId, ContentKind.valueOf(kind), name, sortOrder)
internal fun ChannelEntity.toModel() = Channel(id, sourceId, categoryId, name, number, logoUrl, streamRef, epgId, catchupDays)
internal fun MovieEntity.toModel() = Movie(id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt)
internal fun SeriesEntity.toModel() = Series(id, sourceId, categoryId, title, posterUrl, backdropUrl, year, rating, plot, providerId)
internal fun EpisodeEntity.toModel() = Episode(id, seriesId, season, number, title, plot, imageUrl, durationSec, streamRef)
internal fun EpgEntity.toModel() = EpgProgram(channelEpgId, startMs, endMs, title, description)
internal fun ProgressEntity.toModel() = WatchProgress(itemId, ContentKind.valueOf(kind), seriesId, positionMs, durationMs, updatedAt, completed)
