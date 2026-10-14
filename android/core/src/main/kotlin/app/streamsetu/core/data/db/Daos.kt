package app.streamsetu.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface SourceDao {
    @Query("SELECT * FROM sources ORDER BY sortOrder, name") fun observe(): Flow<List<SourceEntity>>
    @Query("SELECT * FROM sources WHERE id = :id") suspend fun get(id: String): SourceEntity?
    @Query("SELECT * FROM sources ORDER BY sortOrder, name") suspend fun all(): List<SourceEntity>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsert(s: SourceEntity)
    @Query("DELETE FROM sources WHERE id = :id") suspend fun delete(id: String)
    @Query("UPDATE sources SET status = :status, lastSyncAt = :at WHERE id = :id") suspend fun setStatus(id: String, status: String, at: Long)
}

@Dao
interface CatalogDao {
    // Categories
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putCategories(list: List<CategoryEntity>)
    @Query("SELECT * FROM categories WHERE kind = :kind ORDER BY sortOrder, name") fun categories(kind: String): Flow<List<CategoryEntity>>
    @Query("SELECT * FROM categories WHERE sourceId = :sourceId AND kind = :kind ORDER BY sortOrder, name") fun categories(sourceId: String, kind: String): Flow<List<CategoryEntity>>
    @Query("DELETE FROM categories WHERE sourceId = :sourceId") suspend fun clearCategories(sourceId: String)

    // Channels
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putChannels(list: List<ChannelEntity>)
    @Query("DELETE FROM channels WHERE sourceId = :sourceId") suspend fun clearChannels(sourceId: String)
    @Query("SELECT * FROM channels WHERE categoryId = :categoryId ORDER BY sortOrder, name") fun channelsIn(categoryId: String): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels ORDER BY sortOrder, name LIMIT :limit") fun allChannels(limit: Int): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels WHERE id = :id") suspend fun channel(id: String): ChannelEntity?
    @Query("SELECT * FROM channels WHERE name LIKE '%' || :q || '%' ORDER BY name LIMIT :limit") suspend fun searchChannels(q: String, limit: Int): List<ChannelEntity>
    @Query("SELECT COUNT(*) FROM channels") fun channelCount(): Flow<Int>

    // Movies
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putMovies(list: List<MovieEntity>)
    @Query("DELETE FROM movies WHERE sourceId = :sourceId") suspend fun clearMovies(sourceId: String)
    @Query("SELECT * FROM movies WHERE categoryId = :categoryId ORDER BY title LIMIT :limit") fun moviesIn(categoryId: String, limit: Int): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies ORDER BY addedAt DESC LIMIT :limit") fun latestMovies(limit: Int): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies WHERE id = :id") suspend fun movie(id: String): MovieEntity?
    @Query("SELECT * FROM movies WHERE posterUrl IS NOT NULL AND posterUrl != '' ORDER BY RANDOM() LIMIT :n") suspend fun randomMovies(n: Int): List<MovieEntity>
    @Query("SELECT * FROM series WHERE posterUrl IS NOT NULL AND posterUrl != '' ORDER BY RANDOM() LIMIT :n") suspend fun randomSeries(n: Int): List<SeriesEntity>
    @Query("SELECT * FROM movies WHERE title LIKE '%' || :q || '%' ORDER BY title LIMIT :limit") suspend fun searchMovies(q: String, limit: Int): List<MovieEntity>

    // Series
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putSeries(list: List<SeriesEntity>)
    @Query("DELETE FROM series WHERE sourceId = :sourceId") suspend fun clearSeries(sourceId: String)
    @Query("SELECT * FROM series WHERE categoryId = :categoryId ORDER BY title LIMIT :limit") fun seriesIn(categoryId: String, limit: Int): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series ORDER BY title LIMIT :limit") fun allSeries(limit: Int): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series WHERE id = :id") suspend fun series(id: String): SeriesEntity?
    @Query("SELECT * FROM series WHERE title LIKE '%' || :q || '%' ORDER BY title LIMIT :limit") suspend fun searchSeries(q: String, limit: Int): List<SeriesEntity>

    // Episodes
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putEpisodes(list: List<EpisodeEntity>)
    @Query("SELECT * FROM episodes WHERE seriesId = :seriesId ORDER BY season, number") fun episodes(seriesId: String): Flow<List<EpisodeEntity>>
    @Query("SELECT * FROM episodes WHERE seriesId = :seriesId ORDER BY season, number") suspend fun episodesOnce(seriesId: String): List<EpisodeEntity>
    @Query("SELECT * FROM episodes WHERE id = :id") suspend fun episode(id: String): EpisodeEntity?
}

@Dao
interface EpgDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun put(list: List<EpgEntity>)
    @Query("DELETE FROM epg WHERE endMs < :before") suspend fun prune(before: Long)
    @Query("DELETE FROM epg") suspend fun clear()
    @Query("SELECT * FROM epg WHERE channelEpgId = :id AND endMs > :now ORDER BY startMs LIMIT :limit") suspend fun upcoming(id: String, now: Long, limit: Int): List<EpgEntity>
    @Query("SELECT * FROM epg WHERE channelEpgId IN (:ids) AND startMs <= :now AND endMs > :now") suspend fun nowFor(ids: List<String>, now: Long): List<EpgEntity>
}

@Dao
interface UserDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putFavorite(f: FavoriteEntity)
    @Query("DELETE FROM favorites WHERE itemId = :itemId AND listId = :listId") suspend fun removeFavorite(itemId: String, listId: String)
    @Query("SELECT itemId FROM favorites WHERE listId = :listId ORDER BY addedAt DESC") fun favoriteIds(listId: String): Flow<List<String>>

    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putProgress(p: ProgressEntity)
    @Query("SELECT * FROM progress WHERE itemId = :id") suspend fun progress(id: String): ProgressEntity?
    @Query("SELECT * FROM progress WHERE completed = 0 AND positionMs > 30000 AND kind IN ('MOVIE','EPISODE') ORDER BY updatedAt DESC LIMIT :limit") fun continueWatching(limit: Int): Flow<List<ProgressEntity>>
    @Query("SELECT * FROM progress WHERE seriesId = :seriesId") suspend fun progressForSeries(seriesId: String): List<ProgressEntity>

    @Insert suspend fun log(e: WatchLogEntity)
    @Query("SELECT * FROM watch_log WHERE kind = 'CHANNEL' ORDER BY playedAt DESC LIMIT :limit") fun recentChannelLog(limit: Int): Flow<List<WatchLogEntity>>
    @Query("DELETE FROM watch_log WHERE id NOT IN (SELECT id FROM watch_log ORDER BY playedAt DESC LIMIT 500)") suspend fun trimLog()
    @Query("SELECT itemId, COUNT(*) AS plays FROM watch_log WHERE kind = 'CHANNEL' AND playedAt > :since GROUP BY itemId HAVING plays >= 2 ORDER BY plays DESC LIMIT :limit")
    fun mostWatched(since: Long, limit: Int): Flow<List<PlayCount>>
}

data class PlayCount(val itemId: String, val plays: Int)
