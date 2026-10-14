package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.*

fun SourceEntity.toModel() = Source(id, name, SourceType.valueOf(type), address, username, epgUrl, enabled, lastSyncAt, SyncStatus.valueOf(status), draft, channelCount, movieCount, seriesCount, lastError, lastOpenedAt, userAgent)
fun Source.toEntity(sortOrder: Int = 0) = SourceEntity(id, name, type.name, address, username, epgUrl, enabled, lastSyncAt, status.name, sortOrder, draft, channelCount, movieCount, seriesCount, lastError, lastOpenedAt, userAgent)
fun CategoryEntity.toModel() = Category(id, sourceId, ContentKind.valueOf(kind), name, sortOrder)
fun ChannelEntity.toModel() = Channel(id, sourceId, categoryId, name, number, logoUrl, streamRef, epgId, catchupDays, isRadio)
fun MovieEntity.toModel() = Movie(id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt)
fun SeriesEntity.toModel() = Series(id, sourceId, categoryId, title, posterUrl, backdropUrl, year, rating, plot, providerId)
fun EpisodeEntity.toModel() = Episode(id, seriesId, season, number, title, plot, imageUrl, durationSec, streamRef)
fun EpgEntity.toModel() = EpgProgram(channelEpgId, startMs, endMs, title, description)
fun ProgressEntity.toModel() = WatchProgress(itemId, ContentKind.valueOf(kind), seriesId, positionMs, durationMs, updatedAt, completed)
fun FolderPrefEntity.toModel() = FolderPref(favorite, pinned, hidden, locked, alias, sortIndex)
