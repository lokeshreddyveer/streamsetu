package app.streamsetu.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.RawQuery
import androidx.sqlite.db.SupportSQLiteQuery
import kotlinx.coroutines.flow.Flow

@Dao
interface SourceDao {
    @Query("SELECT * FROM sources ORDER BY sortOrder, name") fun observe(): Flow<List<SourceEntity>>
    @Query("SELECT * FROM sources WHERE id = :id") suspend fun get(id: String): SourceEntity?
    @Query("SELECT * FROM sources ORDER BY sortOrder, name") suspend fun all(): List<SourceEntity>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsert(s: SourceEntity)
    @Query("DELETE FROM sources WHERE id = :id") suspend fun delete(id: String)
    @Query("UPDATE sources SET status = :status, lastSyncAt = :at WHERE id = :id") suspend fun setStatus(id: String, status: String, at: Long)
    @Query("UPDATE sources SET draft = CASE WHEN :ch + :mv + :sr = 0 THEN 1 ELSE 0 END, channelCount = :ch, movieCount = :mv, seriesCount = :sr, lastError = NULL WHERE id = :id") suspend fun setCounts(id: String, ch: Int, mv: Int, sr: Int)
    @Query("UPDATE sources SET lastError = :error WHERE id = :id") suspend fun setError(id: String, error: String?)
    @Query("UPDATE sources SET lastOpenedAt = :at WHERE id = :id") suspend fun touch(id: String, at: Long)
    @Query("UPDATE sources SET name = :name WHERE id = :id") suspend fun rename(id: String, name: String)
}

@Dao
interface CatalogDao {
    // Categories
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putCategories(list: List<CategoryEntity>)
    @Query("SELECT * FROM categories WHERE kind = :kind AND sourceId IN (:sources) ORDER BY sortOrder, name") fun categories(kind: String, sources: List<String>): Flow<List<CategoryEntity>>
    @Query("SELECT * FROM categories WHERE sourceId = :sourceId AND kind = :kind ORDER BY sortOrder, name") fun categories(sourceId: String, kind: String): Flow<List<CategoryEntity>>
    @Query("DELETE FROM categories WHERE sourceId = :sourceId") suspend fun clearCategories(sourceId: String)

    // Channels
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putChannels(list: List<ChannelEntity>)
    @Query("DELETE FROM channels WHERE sourceId = :sourceId") suspend fun clearChannels(sourceId: String)
    @Query("DELETE FROM channels WHERE name LIKE '%####%' OR name LIKE '%====%' OR name LIKE '%----%' OR name LIKE '%****%' OR TRIM(name) = ''") suspend fun deleteDividers(): Int
    @Query("SELECT * FROM channels WHERE categoryId = :categoryId ORDER BY sortOrder, name") fun channelsIn(categoryId: String): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels WHERE sourceId IN (:sources) ORDER BY sortOrder, name LIMIT :limit") fun allChannels(limit: Int, sources: List<String>): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels WHERE id = :id") suspend fun channel(id: String): ChannelEntity?
    @Query("SELECT * FROM channels WHERE id IN (:ids)") suspend fun channelsByIds(ids: List<String>): List<ChannelEntity>
    @Query("SELECT * FROM channels WHERE sourceId IN (:sources) AND name LIKE '%' || :q || '%' ORDER BY name LIMIT :limit") suspend fun searchChannels(q: String, limit: Int, sources: List<String>): List<ChannelEntity>
    @Query("SELECT COUNT(*) FROM channels WHERE sourceId IN (:sources)") fun channelCount(sources: List<String>): Flow<Int>

    // Movies
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putMovies(list: List<MovieEntity>)
    @Query("DELETE FROM movies WHERE sourceId = :sourceId") suspend fun clearMovies(sourceId: String)
    @Query("SELECT * FROM movies WHERE categoryId = :categoryId ORDER BY title LIMIT :limit") fun moviesIn(categoryId: String, limit: Int): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) ORDER BY addedAt DESC LIMIT :limit") fun latestMovies(limit: Int, sources: List<String>): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) ORDER BY title LIMIT :limit") fun allMovies(limit: Int, sources: List<String>): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies WHERE id IN (:ids)") suspend fun moviesByIds(ids: List<String>): List<MovieEntity>
    @Query("SELECT * FROM series WHERE id IN (:ids)") suspend fun seriesByIds(ids: List<String>): List<SeriesEntity>
    @Query("SELECT * FROM movies WHERE id = :id") suspend fun movie(id: String): MovieEntity?
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) AND posterUrl IS NOT NULL AND posterUrl != '' ORDER BY RANDOM() LIMIT :n") suspend fun randomMovies(n: Int, sources: List<String>): List<MovieEntity>
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) AND posterUrl IS NOT NULL AND posterUrl != '' ORDER BY RANDOM() LIMIT :n") suspend fun randomSeries(n: Int, sources: List<String>): List<SeriesEntity>
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) AND title LIKE '%' || :q || '%' ORDER BY title LIMIT :limit") suspend fun searchMovies(q: String, limit: Int, sources: List<String>): List<MovieEntity>

    // Series
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putSeries(list: List<SeriesEntity>)
    @Query("DELETE FROM series WHERE sourceId = :sourceId") suspend fun clearSeries(sourceId: String)
    @Query("SELECT * FROM series WHERE categoryId = :categoryId ORDER BY title LIMIT :limit") fun seriesIn(categoryId: String, limit: Int): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) ORDER BY title LIMIT :limit") fun allSeries(limit: Int, sources: List<String>): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) ORDER BY id DESC LIMIT :limit") fun latestSeries(limit: Int, sources: List<String>): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series WHERE id = :id") suspend fun series(id: String): SeriesEntity?
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) AND title LIKE '%' || :q || '%' ORDER BY title LIMIT :limit") suspend fun searchSeries(q: String, limit: Int, sources: List<String>): List<SeriesEntity>
    @Query("SELECT categoryId AS folderId, COUNT(*) AS n FROM movies WHERE sourceId IN (:sources) GROUP BY categoryId") fun movieFolderCounts(sources: List<String>): Flow<List<FolderCount>>
    @Query("SELECT categoryId AS folderId, COUNT(*) AS n FROM series WHERE sourceId IN (:sources) GROUP BY categoryId") fun seriesFolderCounts(sources: List<String>): Flow<List<FolderCount>>
    @Query("SELECT categoryId AS folderId, COUNT(*) AS n FROM channels WHERE sourceId IN (:sources) GROUP BY categoryId") fun channelFolderCounts(sources: List<String>): Flow<List<FolderCount>>

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
    @Query("SELECT * FROM progress") fun allProgress(): Flow<List<ProgressEntity>>
    @Query("DELETE FROM progress WHERE itemId = :id") suspend fun clearProgress(id: String)
    @Query("DELETE FROM progress") suspend fun clearAllProgress()

    @Insert suspend fun log(e: WatchLogEntity)
    @Query("SELECT * FROM watch_log WHERE kind = 'CHANNEL' ORDER BY playedAt DESC LIMIT :limit") fun recentChannelLog(limit: Int): Flow<List<WatchLogEntity>>
    @Query("SELECT * FROM watch_log ORDER BY playedAt DESC LIMIT :limit") fun history(limit: Int): Flow<List<WatchLogEntity>>
    @Query("DELETE FROM watch_log") suspend fun clearLog()
    @Query("DELETE FROM watch_log WHERE id NOT IN (SELECT id FROM watch_log ORDER BY playedAt DESC LIMIT 500)") suspend fun trimLog()
    @Query("SELECT itemId, COUNT(*) AS plays FROM watch_log WHERE kind = 'CHANNEL' AND playedAt > :since GROUP BY itemId HAVING plays >= 2 ORDER BY plays DESC LIMIT :limit")
    fun mostWatched(since: Long, limit: Int): Flow<List<PlayCount>>
}

data class PlayCount(val itemId: String, val plays: Int)

data class FolderCount(val folderId: String?, val n: Int)

@Dao
interface LibraryDao {
    @Query("SELECT * FROM libraries ORDER BY name") fun observe(): Flow<List<LibraryEntity>>
    @Query("SELECT * FROM libraries WHERE id = :id") suspend fun get(id: String): LibraryEntity?
    @Query("SELECT * FROM library_members") fun members(): Flow<List<LibraryMemberEntity>>
    @Query("SELECT sourceId FROM library_members WHERE libraryId = :id") suspend fun memberIds(id: String): List<String>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun put(l: LibraryEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putMembers(m: List<LibraryMemberEntity>)
    @Query("DELETE FROM library_members WHERE libraryId = :id") suspend fun clearMembers(id: String)
    @Query("DELETE FROM libraries WHERE id = :id") suspend fun delete(id: String)
    @Query("DELETE FROM library_members WHERE sourceId = :sourceId") suspend fun removeSource(sourceId: String)
    @Query("UPDATE libraries SET lastOpenedAt = :at WHERE id = :id") suspend fun touch(id: String, at: Long)
}

@Dao
interface FolderDao {
    @Query("SELECT * FROM folder_prefs WHERE scope = :scope") fun observe(scope: String): Flow<List<FolderPrefEntity>>
    @Query("SELECT * FROM folder_prefs WHERE scope = :scope AND folderId = :id") suspend fun get(scope: String, id: String): FolderPrefEntity?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun put(p: FolderPrefEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putAll(p: List<FolderPrefEntity>)
    @Query("DELETE FROM folder_prefs WHERE scope = :scope") suspend fun reset(scope: String)
}

/** Lists whose order and filter are chosen at run time (see BrowseRepository, which builds the SQL from fixed pieces, never from typed text). */
@Dao
interface BrowseDao {
    @RawQuery(observedEntities = [MovieEntity::class, FavoriteEntity::class, ProgressEntity::class, WatchLogEntity::class, FolderPrefEntity::class])
    fun movies(q: SupportSQLiteQuery): Flow<List<MovieEntity>>
    @RawQuery(observedEntities = [SeriesEntity::class, FavoriteEntity::class, ProgressEntity::class, WatchLogEntity::class, FolderPrefEntity::class])
    fun series(q: SupportSQLiteQuery): Flow<List<SeriesEntity>>
    @RawQuery(observedEntities = [ChannelEntity::class, FavoriteEntity::class, WatchLogEntity::class, FolderPrefEntity::class])
    fun channels(q: SupportSQLiteQuery): Flow<List<ChannelEntity>>

    @Query("SELECT folderId FROM folder_prefs WHERE scope = :scope AND locked = 1") fun lockedFolders(scope: String): Flow<List<String>>
    @Query("SELECT folderId FROM folder_prefs WHERE locked = 1") suspend fun lockedFoldersNow(): List<String>
    @Query("SELECT folderId FROM folder_prefs WHERE scope = :scope AND favorite = 1") fun favoriteFolders(scope: String): Flow<List<String>>
    @Query("SELECT COUNT(*) FROM movies WHERE sourceId IN (:s) AND year IS NOT NULL") suspend fun moviesWithYear(s: List<String>): Int
    @Query("SELECT COUNT(*) FROM movies WHERE sourceId IN (:s) AND rating IS NOT NULL AND rating != '' AND rating != '0'") suspend fun moviesWithRating(s: List<String>): Int
    @Query("SELECT COUNT(*) FROM series WHERE sourceId IN (:s) AND year IS NOT NULL") suspend fun seriesWithYear(s: List<String>): Int
    @Query("SELECT COUNT(*) FROM series WHERE sourceId IN (:s) AND rating IS NOT NULL AND rating != '' AND rating != '0'") suspend fun seriesWithRating(s: List<String>): Int
    @Query("SELECT COUNT(*) FROM watch_log") suspend fun watchedCount(): Int
}
