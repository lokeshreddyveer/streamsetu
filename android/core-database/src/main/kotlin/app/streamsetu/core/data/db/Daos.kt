package app.streamsetu.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.RawQuery
import androidx.sqlite.db.SupportSQLiteQuery
import kotlinx.coroutines.flow.Flow

data class PartialRow(val id: String, val fraction: Double)

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
    @Query("UPDATE sources SET epgUrl = :url WHERE id = :id") suspend fun setGuide(id: String, url: String?)
    @Query("UPDATE sources SET enabled = :enabled WHERE id = :id") suspend fun setEnabled(id: String, enabled: Boolean)
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
    @Query("SELECT * FROM channels WHERE categoryId = :categoryId AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) ORDER BY sortOrder, name") fun channelsIn(categoryId: String): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels WHERE sourceId IN (:sources) AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) ORDER BY sortOrder, name LIMIT :limit") fun allChannels(limit: Int, sources: List<String>): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels WHERE id = :id") suspend fun channel(id: String): ChannelEntity?
    /** A visible channel that carries this guide id, for turning a guide entry into something that can be played. */
    @Query("SELECT c.* FROM channels c JOIN sources s ON s.id = c.sourceId WHERE s.enabled = 1 AND s.draft = 0 AND c.epgId = :epgId AND c.id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) ORDER BY c.sortOrder LIMIT 1") suspend fun channelForGuideId(epgId: String): ChannelEntity?
    /** The same channel (same name, or same guide id) in the person's other enabled connections: what to try when it stops working in its own. */
    @Query("SELECT c.* FROM channels c JOIN sources s ON s.id = c.sourceId WHERE s.enabled = 1 AND s.draft = 0 AND c.sourceId != :sourceId AND (LOWER(c.name) = LOWER(:name) OR (:epgId != '' AND c.epgId = :epgId)) AND c.id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) ORDER BY (LOWER(c.name) = LOWER(:name)) DESC, c.sortOrder LIMIT 6") suspend fun channelCopiesElsewhere(sourceId: String, name: String, epgId: String): List<ChannelEntity>
    /** Every channel of one connection, hidden ones too, for the Channel Manager. */
    @Query("SELECT * FROM channels WHERE sourceId = :sourceId AND name LIKE '%' || :q || '%' ORDER BY sortOrder, name LIMIT :limit") suspend fun managerChannels(sourceId: String, q: String, limit: Int): List<ChannelEntity>
    @Query("SELECT * FROM channels WHERE sourceId = :sourceId AND name = :name LIMIT 1") suspend fun channelByName(sourceId: String, name: String): ChannelEntity?
    /** Films for a typed sentence ("telugu 2024 unwatched"): every filter is optional (an empty text, a zero or an empty word means no filter). A title, or somebody in it, matches [text]. */
    @Query("""
        SELECT m.* FROM movies m JOIN sources s ON s.id = m.sourceId
        WHERE s.enabled = 1 AND s.draft = 0 AND m.sourceId IN (:sources)
          AND (:text = '' OR LOWER(m.title) LIKE '%' || :text || '%' OR m.id IN (:personIds))
          AND (:year = 0 OR m.year = :year) AND (:decade = 0 OR (m.year >= :decade AND m.year < :decade + 10))
          AND (:language = '' OR m.title LIKE '%(' || :language || '%' OR m.title LIKE '%[' || :language || '%' OR m.categoryId IN (SELECT id FROM categories WHERE name LIKE '%' || :language || '%'))
          AND (:q1 = '' OR m.title LIKE '%' || :q1 || '%' OR m.title LIKE '%' || :q2 || '%' OR m.title LIKE '%' || :q3 || '%' OR m.categoryId IN (SELECT id FROM categories WHERE name LIKE '%' || :q1 || '%' OR name LIKE '%' || :q2 || '%' OR name LIKE '%' || :q3 || '%'))
          AND (:minRating = 0 OR CAST(m.rating AS REAL) >= :minRating)
          AND (:unwatched = 0 OR (m.id NOT IN (SELECT itemId FROM progress) AND m.id NOT IN (SELECT itemId FROM watch_log)))
          AND (:favorites = 0 OR m.id IN (SELECT itemId FROM favorites))
          AND (:addedSince = 0 OR m.addedAt >= :addedSince)
        ORDER BY m.addedAt DESC LIMIT :limit
    """)
    suspend fun moviesForSentence(sources: List<String>, text: String, personIds: List<String>, year: Int, decade: Int, language: String, q1: String, q2: String, q3: String, minRating: Double, unwatched: Int, favorites: Int, addedSince: Long, limit: Int): List<MovieEntity>

    /** The same for series. */
    @Query("""
        SELECT m.* FROM series m JOIN sources s ON s.id = m.sourceId
        WHERE s.enabled = 1 AND s.draft = 0 AND m.sourceId IN (:sources)
          AND (:text = '' OR LOWER(m.title) LIKE '%' || :text || '%' OR m.id IN (:personIds))
          AND (:year = 0 OR m.year = :year) AND (:decade = 0 OR (m.year >= :decade AND m.year < :decade + 10))
          AND (:language = '' OR m.title LIKE '%(' || :language || '%' OR m.title LIKE '%[' || :language || '%' OR m.categoryId IN (SELECT id FROM categories WHERE name LIKE '%' || :language || '%'))
          AND (:q1 = '' OR m.title LIKE '%' || :q1 || '%' OR m.title LIKE '%' || :q2 || '%' OR m.title LIKE '%' || :q3 || '%' OR m.categoryId IN (SELECT id FROM categories WHERE name LIKE '%' || :q1 || '%' OR name LIKE '%' || :q2 || '%' OR name LIKE '%' || :q3 || '%'))
          AND (:minRating = 0 OR CAST(m.rating AS REAL) >= :minRating)
          AND (:unwatched = 0 OR m.id NOT IN (SELECT seriesId FROM progress WHERE seriesId IS NOT NULL))
          AND (:favorites = 0 OR m.id IN (SELECT itemId FROM favorites))
          AND (:addedSince = 0 OR m.addedAt >= :addedSince)
        ORDER BY m.addedAt DESC LIMIT :limit
    """)
    suspend fun seriesForSentence(sources: List<String>, text: String, personIds: List<String>, year: Int, decade: Int, language: String, q1: String, q2: String, q3: String, minRating: Double, unwatched: Int, favorites: Int, addedSince: Long, limit: Int): List<SeriesEntity>
    @Query("SELECT * FROM movies WHERE sourceId = :sourceId AND title = :title LIMIT 1") suspend fun movieByTitle(sourceId: String, title: String): MovieEntity?
    @Query("SELECT * FROM channels WHERE id IN (:ids)") suspend fun channelsByIds(ids: List<String>): List<ChannelEntity>
    /** Like [channelsByIds], without the channels the person hid (for search results). */
    @Query("SELECT * FROM channels WHERE id IN (:ids) AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1)") suspend fun visibleChannelsByIds(ids: List<String>): List<ChannelEntity>
    @Query("SELECT * FROM channels WHERE sourceId IN (:sources) AND name LIKE '%' || :q || '%' AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) ORDER BY name LIMIT :limit") suspend fun searchChannels(q: String, limit: Int, sources: List<String>): List<ChannelEntity>
    @Query("SELECT COUNT(*) FROM channels WHERE sourceId IN (:sources) AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1)") fun channelCount(sources: List<String>): Flow<Int>

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
    @Query("DELETE FROM episodes WHERE seriesId NOT IN (SELECT id FROM series)") suspend fun deleteOrphanEpisodes(): Int
    @Query("SELECT COUNT(*) FROM channels") suspend fun channelTotal(): Int
    @Query("SELECT COUNT(*) FROM movies") suspend fun movieTotal(): Int
    @Query("SELECT COUNT(*) FROM series") suspend fun seriesTotal(): Int
    @Query("SELECT * FROM series WHERE categoryId = :categoryId ORDER BY title LIMIT :limit") fun seriesIn(categoryId: String, limit: Int): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) ORDER BY title LIMIT :limit") fun allSeries(limit: Int, sources: List<String>): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) ORDER BY id DESC LIMIT :limit") fun latestSeries(limit: Int, sources: List<String>): Flow<List<SeriesEntity>>
    @Query("SELECT * FROM series WHERE id = :id") suspend fun series(id: String): SeriesEntity?
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) AND title LIKE '%' || :q || '%' ORDER BY title LIMIT :limit") suspend fun searchSeries(q: String, limit: Int, sources: List<String>): List<SeriesEntity>
    @Query("SELECT categoryId AS folderId, COUNT(*) AS n FROM movies WHERE sourceId IN (:sources) GROUP BY categoryId") fun movieFolderCounts(sources: List<String>): Flow<List<FolderCount>>
    @Query("SELECT categoryId AS folderId, COUNT(*) AS n FROM series WHERE sourceId IN (:sources) GROUP BY categoryId") fun seriesFolderCounts(sources: List<String>): Flow<List<FolderCount>>
    @Query("SELECT categoryId AS folderId, COUNT(*) AS n FROM channels WHERE sourceId IN (:sources) AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) GROUP BY categoryId") fun channelFolderCounts(sources: List<String>): Flow<List<FolderCount>>

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
    @Query("SELECT * FROM epg WHERE channelEpgId IN (:ids) AND endMs > :from AND startMs < :to ORDER BY channelEpgId, startMs") suspend fun window(ids: List<String>, from: Long, to: Long): List<EpgEntity>
    @Query("SELECT COUNT(*) FROM epg") suspend fun count(): Int
    /** Programmes whose title has the word and that start between the two times, soonest first. */
    @Query("SELECT * FROM epg WHERE LOWER(title) LIKE '%' || LOWER(:term) || '%' AND startMs > :from AND startMs < :to ORDER BY startMs LIMIT 40") suspend fun matching(term: String, from: Long, to: Long): List<EpgEntity>
    @Query("SELECT MAX(endMs) FROM epg") suspend fun lastEnd(): Long?
}

@Dao
interface UserDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putFavorite(f: FavoriteEntity)
    @Query("SELECT * FROM favorites") suspend fun allFavorites(): List<FavoriteEntity>
    @Query("SELECT * FROM progress") suspend fun allProgressNow(): List<ProgressEntity>
    @Query("SELECT * FROM watch_log ORDER BY playedAt DESC LIMIT 500") suspend fun logNow(): List<WatchLogEntity>
    @Query("DELETE FROM favorites WHERE listId = :listId") suspend fun clearList(listId: String)
    @Query("DELETE FROM favorites WHERE itemId = :itemId AND listId = :listId") suspend fun removeFavorite(itemId: String, listId: String)
    @Query("SELECT itemId FROM favorites WHERE listId = :listId ORDER BY addedAt DESC") fun favoriteIds(listId: String): Flow<List<String>>
    /** The lists show the newest first, so "first" is the largest time and "last" the smallest. */
    @Query("UPDATE favorites SET addedAt = (SELECT COALESCE(MAX(addedAt), 0) + 1 FROM favorites WHERE listId = :listId) WHERE itemId = :itemId AND listId = :listId") suspend fun moveFavoriteFirst(itemId: String, listId: String)
    @Query("UPDATE favorites SET addedAt = (SELECT COALESCE(MIN(addedAt), 0) - 1 FROM favorites WHERE listId = :listId) WHERE itemId = :itemId AND listId = :listId") suspend fun moveFavoriteLast(itemId: String, listId: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putProgress(p: ProgressEntity)
    @Query("SELECT * FROM progress WHERE itemId = :id") suspend fun progress(id: String): ProgressEntity?
    @Query("SELECT * FROM progress WHERE completed = 0 AND positionMs > 30000 AND kind IN ('MOVIE','EPISODE') ORDER BY updatedAt DESC LIMIT :limit") fun continueWatching(limit: Int): Flow<List<ProgressEntity>>
    @Query("SELECT * FROM progress WHERE seriesId = :seriesId") suspend fun progressForSeries(seriesId: String): List<ProgressEntity>
    @Query("SELECT * FROM progress") fun allProgress(): Flow<List<ProgressEntity>>
    /** Movies watched to the end, and series whose episodes were all watched (the Watched tick on a poster). */
    @Query("SELECT itemId FROM progress WHERE completed = 1 AND kind = 'MOVIE' UNION SELECT e.seriesId FROM episodes e LEFT JOIN progress p ON p.itemId = e.id AND p.completed = 1 GROUP BY e.seriesId HAVING COUNT(p.itemId) = COUNT(*)")
    fun watchedTitles(): Flow<List<String>>
    /** Started but not finished: a movie by its position, a series by its episodes watched (the bar along the bottom of a poster). */
    @Query("SELECT itemId AS id, CAST(positionMs AS REAL) / durationMs AS fraction FROM progress WHERE kind = 'MOVIE' AND completed = 0 AND positionMs > 30000 AND durationMs > 0 UNION ALL SELECT e.seriesId AS id, SUM(CASE WHEN p.completed = 1 THEN 1.0 WHEN p.durationMs > 0 THEN CAST(p.positionMs AS REAL) / p.durationMs ELSE 0 END) / COUNT(*) AS fraction FROM episodes e LEFT JOIN progress p ON p.itemId = e.id GROUP BY e.seriesId HAVING fraction > 0 AND fraction < 1")
    fun partialTitles(): Flow<List<PartialRow>>
    @Query("DELETE FROM progress WHERE itemId = :id") suspend fun clearProgress(id: String)
    @Query("DELETE FROM progress") suspend fun clearAllProgress()

    @Insert suspend fun log(e: WatchLogEntity)
    @Query("SELECT * FROM watch_log WHERE kind = 'CHANNEL' ORDER BY playedAt DESC LIMIT :limit") fun recentChannelLog(limit: Int): Flow<List<WatchLogEntity>>
    @Query("SELECT * FROM watch_log ORDER BY playedAt DESC LIMIT :limit") fun history(limit: Int): Flow<List<WatchLogEntity>>
    @Query("DELETE FROM watch_log") suspend fun clearLog()
    @Query("DELETE FROM watch_log WHERE itemId = :id") suspend fun deleteLogFor(id: String)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putLog(l: List<WatchLogEntity>)
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
    @Query("SELECT * FROM folder_prefs") suspend fun all(): List<FolderPrefEntity>
    @Query("UPDATE folder_prefs SET hidden = 0 WHERE scope = :scope") suspend fun unhideAll(scope: String)
    @Query("SELECT * FROM folder_prefs WHERE scope = :scope AND folderId = :id") suspend fun get(scope: String, id: String): FolderPrefEntity?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun put(p: FolderPrefEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putAll(p: List<FolderPrefEntity>)
    @Query("DELETE FROM folder_prefs WHERE scope = :scope") suspend fun reset(scope: String)
    @Query("DELETE FROM folder_prefs WHERE scope = :scope AND folderId = :id") suspend fun delete(scope: String, id: String)
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
    @Query("SELECT COUNT(*) FROM series WHERE sourceId IN (:s) AND addedAt > 0") suspend fun seriesWithUpdateDate(s: List<String>): Int
    @Query("SELECT COUNT(*) FROM new_episodes") suspend fun newEpisodeCount(): Int
    @Query("SELECT COUNT(*) FROM channels WHERE sourceId = :id AND epgId IS NOT NULL AND epgId != ''") suspend fun channelsWithGuideId(id: String): Int
    @Query("SELECT COUNT(*) FROM channels WHERE sourceId = :id AND catchupDays > 0") suspend fun channelsWithCatchUp(id: String): Int
    @Query("SELECT COUNT(*) FROM epg WHERE channelEpgId IN (SELECT epgId FROM channels WHERE sourceId = :id AND epgId IS NOT NULL)") suspend fun programmesFor(id: String): Int
}

@Dao
interface ExtrasDao {
    // New episodes
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun putNewEpisodes(list: List<NewEpisodeEntity>)
    @Query("SELECT * FROM new_episodes ORDER BY discoveredAt DESC") fun newEpisodes(): Flow<List<NewEpisodeEntity>>
    @Query("DELETE FROM new_episodes WHERE episodeId = :id") suspend fun clearNewEpisode(id: String)
    @Query("DELETE FROM new_episodes WHERE seriesId = :id") suspend fun clearNewForSeries(id: String)
    @Query("SELECT id FROM episodes WHERE seriesId = :seriesId") suspend fun episodeIds(seriesId: String): List<String>
    @Query("SELECT DISTINCT seriesId FROM progress WHERE seriesId IS NOT NULL") suspend fun seriesWithProgress(): List<String>
    @Query("DELETE FROM episodes WHERE seriesId = :seriesId AND id NOT IN (:keep)") suspend fun dropOtherEpisodes(seriesId: String, keep: List<String>)

    // Collections
    @Query("SELECT * FROM collections WHERE scope = :scope ORDER BY name") fun collections(scope: String): Flow<List<CollectionEntity>>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putCollection(c: CollectionEntity)
    @Query("DELETE FROM collections WHERE id = :id") suspend fun deleteCollection(id: String)
    @Query("DELETE FROM collection_items WHERE collectionId = :id") suspend fun clearCollection(id: String)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putItem(i: CollectionItemEntity)
    @Query("DELETE FROM collection_items WHERE collectionId = :c AND itemId = :i") suspend fun removeItem(c: String, i: String)
    @Query("SELECT collectionId FROM collection_items WHERE itemId = :i") suspend fun collectionsOf(i: String): List<String>
    @Query("SELECT * FROM collection_items") suspend fun allCollectionItems(): List<CollectionItemEntity>
    @Query("SELECT * FROM collections") suspend fun allCollections(): List<CollectionEntity>

    // Titles with no picture that no correction covers yet (for TMDB)
    @Query("SELECT * FROM movies WHERE (posterUrl IS NULL OR posterUrl = '') AND id NOT IN (SELECT itemId FROM overrides) LIMIT :n") suspend fun moviesWithoutPoster(n: Int): List<MovieEntity>
    @Query("SELECT * FROM series WHERE (posterUrl IS NULL OR posterUrl = '') AND id NOT IN (SELECT itemId FROM overrides) LIMIT :n") suspend fun seriesWithoutPoster(n: Int): List<SeriesEntity>

    // Overrides
    @Query("SELECT * FROM overrides") fun overrides(): Flow<List<OverrideEntity>>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putOverride(o: OverrideEntity)
    @Query("DELETE FROM overrides WHERE itemId = :id") suspend fun clearOverride(id: String)

    // Watch time
    @Query("INSERT INTO watch_time(day, hour, itemId, kind, title, ms) VALUES(:day, :hour, :itemId, :kind, :title, :ms) ON CONFLICT(day, hour, itemId) DO UPDATE SET ms = ms + :ms")
    suspend fun addWatchTime(day: Long, hour: Int, itemId: String, kind: String, title: String, ms: Long)
    @Query("SELECT * FROM watch_time WHERE day >= :fromDay") suspend fun watchTimeSince(fromDay: Long): List<WatchTimeEntity>
    @Query("DELETE FROM watch_time") suspend fun clearWatchTime()

    // What the person changed about channels
    @Query("SELECT * FROM channel_prefs") fun channelPrefs(): Flow<List<ChannelPrefEntity>>
    @Query("SELECT * FROM channel_prefs") suspend fun channelPrefsNow(): List<ChannelPrefEntity>
    @Query("SELECT * FROM channel_prefs WHERE channelId = :id") suspend fun channelPref(id: String): ChannelPrefEntity?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putChannelPref(p: ChannelPrefEntity)
    @Query("DELETE FROM channel_prefs WHERE channelId = :id") suspend fun clearChannelPref(id: String)
    @Query("SELECT channelId FROM channel_prefs WHERE hidden = 1") suspend fun hiddenChannelIds(): List<String>
    @Query("UPDATE channels SET name = :name WHERE id = :id") suspend fun setChannelName(id: String, name: String)
    @Query("UPDATE channels SET epgId = :epgId WHERE id = :id") suspend fun setChannelEpg(id: String, epgId: String?)

    // Reminders
    @Query("SELECT * FROM reminders ORDER BY startMs") fun reminders(): Flow<List<ReminderEntity>>
    @Query("SELECT * FROM reminders ORDER BY startMs") suspend fun remindersNow(): List<ReminderEntity>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putReminder(r: ReminderEntity)
    @Query("DELETE FROM reminders WHERE id = :id") suspend fun deleteReminder(id: String)
    @Query("DELETE FROM reminders WHERE startMs < :before") suspend fun pruneReminders(before: Long)

    // Guide channel names
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putEpgChannels(list: List<EpgChannelEntity>)
    @Query("SELECT * FROM epg_channels") suspend fun epgChannels(): List<EpgChannelEntity>
    @Query("DELETE FROM epg_channels") suspend fun clearEpgChannels()
    @Query("SELECT DISTINCT channelEpgId FROM epg") suspend fun epgIdsWithProgrammes(): List<String>
}
