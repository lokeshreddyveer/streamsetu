package app.streamsetu.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.RawQuery
import androidx.room.Transaction
import androidx.room.Update
import androidx.sqlite.db.SupportSQLiteQuery
import kotlinx.coroutines.flow.Flow

data class PartialRow(val id: String, val fraction: Double)

/** What a recommendation needs about a title and no more (never the plot or the stream address): one row of a candidate pool. */
data class CandidateRow(val id: String, val sourceId: String, val categoryId: String?, val title: String, val year: Int?, val rating: String?, val addedAt: Long, val posterUrl: String?)

/** A title and its year, nothing else (for building the set of titles a restriction covers without reading whole rows). */
data class TitleYear(val title: String, val year: Int?)

/** One playlist's share of the guide table (see EpgDao.guideStamps). */
data class GuideStamp(val scope: String, val n: Int, val lastEnd: Long?)

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
    @Query("SELECT id FROM categories WHERE sourceId = :sourceId") suspend fun categoryIds(sourceId: String): List<String>
    @Query("DELETE FROM categories WHERE id IN (:ids)") suspend fun deleteCategories(ids: List<String>)
    @Query("SELECT name FROM categories WHERE id = :id") suspend fun categoryName(id: String): String?
    /** Every folder of one kind in every connection (not only the open library): what a lock or hide has to be applied to by name. */
    @Query("SELECT * FROM categories WHERE kind = :kind") suspend fun categoriesOfKind(kind: String): List<CategoryEntity>
    @Query("SELECT title, year FROM movies WHERE categoryId IN (:folders)") suspend fun movieTitlesIn(folders: List<String>): List<TitleYear>
    @Query("SELECT title, year FROM series WHERE categoryId IN (:folders)") suspend fun seriesTitlesIn(folders: List<String>): List<TitleYear>
    /** The picture addresses of what sits in these folders (to take them out of the picture cache when the folder is locked or hidden). */
    @Query("SELECT posterUrl FROM movies WHERE categoryId IN (:folders) AND posterUrl IS NOT NULL") suspend fun moviePicturesIn(folders: List<String>): List<String>
    @Query("SELECT posterUrl FROM series WHERE categoryId IN (:folders) AND posterUrl IS NOT NULL UNION SELECT backdropUrl FROM series WHERE categoryId IN (:folders) AND backdropUrl IS NOT NULL") suspend fun seriesPicturesIn(folders: List<String>): List<String>
    @Query("SELECT logoUrl FROM channels WHERE categoryId IN (:folders) AND logoUrl IS NOT NULL") suspend fun channelPicturesIn(folders: List<String>): List<String>
    @Query("SELECT imageUrl FROM episodes WHERE seriesId IN (SELECT id FROM series WHERE categoryId IN (:folders)) AND imageUrl IS NOT NULL AND imageUrl != ''") suspend fun episodePicturesIn(folders: List<String>): List<String>

    // Channels
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putChannels(list: List<ChannelEntity>)
    @Query("DELETE FROM channels WHERE sourceId = :sourceId") suspend fun clearChannels(sourceId: String)
    @Query("SELECT id FROM channels WHERE sourceId = :sourceId") suspend fun channelIds(sourceId: String): List<String>
    @Query("DELETE FROM channels WHERE id IN (:ids)") suspend fun deleteChannels(ids: List<String>)
    @Query("SELECT * FROM catalog_fingerprints WHERE sourceId = :id") suspend fun fingerprint(id: String): CatalogFingerprintEntity?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putFingerprint(f: CatalogFingerprintEntity)
    @Query("DELETE FROM catalog_fingerprints WHERE sourceId = :id") suspend fun clearFingerprint(id: String)
    @Query("SELECT COALESCE(group_concat(sourceId || ':' || fingerprint || ':' || rows), '') FROM catalog_fingerprints") suspend fun fingerprintRevisionNow(): String
    /** Changes when a source's catalog is written (and only then): what a saved page of titles is checked against. */
    @Query("SELECT COALESCE(group_concat(sourceId || ':' || fingerprint || ':' || rows), '') FROM catalog_fingerprints") fun catalogRevision(): Flow<String>
    @Query("SELECT (SELECT COUNT(*) FROM channels WHERE sourceId = :id) + (SELECT COUNT(*) FROM movies WHERE sourceId = :id) + (SELECT COUNT(*) FROM series WHERE sourceId = :id) + (SELECT COUNT(*) FROM categories WHERE sourceId = :id)") suspend fun rowsFor(id: String): Int
    @Query("SELECT * FROM channels WHERE categoryId = :categoryId AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) ORDER BY sortOrder, name") fun channelsIn(categoryId: String): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels WHERE sourceId IN (:sources) AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1) ORDER BY sortOrder, name LIMIT :limit") fun allChannels(limit: Int, sources: List<String>): Flow<List<ChannelEntity>>
    @Query("SELECT * FROM channels WHERE id = :id") suspend fun channel(id: String): ChannelEntity?
    /** Every channel of these playlists the person has not hidden, in one read (Sports builds its events from this). */
    @Query("SELECT * FROM channels WHERE sourceId IN (:sources) AND id NOT IN (SELECT channelId FROM channel_prefs WHERE hidden = 1)") suspend fun visibleChannelsOf(sources: List<String>): List<ChannelEntity>
    @Query("SELECT channelId FROM channel_prefs WHERE hidden = 1") suspend fun hiddenChannelIds(): List<String>
    @Query("SELECT * FROM categories") suspend fun allCategories(): List<CategoryEntity>
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

    // Candidate pools (narrow rows; one playlist per query so the index (sourceId, addedAt) gives the order and no sort is needed; the caller merges playlists).
    @Query("SELECT id, sourceId, categoryId, title, year, rating, addedAt, posterUrl FROM movies WHERE sourceId = :source AND posterUrl IS NOT NULL AND posterUrl != '' ORDER BY addedAt DESC LIMIT :limit")
    suspend fun recentMovieCandidates(source: String, limit: Int): List<CandidateRow>
    @Query("SELECT id, sourceId, categoryId, title, year, rating, addedAt, posterUrl FROM series WHERE sourceId = :source AND posterUrl IS NOT NULL AND posterUrl != '' ORDER BY addedAt DESC LIMIT :limit")
    suspend fun recentSeriesCandidates(source: String, limit: Int): List<CandidateRow>
    /** The first titles of one folder, newest first (a folder row's tiles): uses (sourceId, categoryId, addedAt). */
    @Query("SELECT id, sourceId, categoryId, title, year, rating, addedAt, posterUrl FROM movies WHERE sourceId = :source AND categoryId = :folder ORDER BY addedAt DESC LIMIT :limit")
    suspend fun movieFolderHead(source: String, folder: String, limit: Int): List<CandidateRow>

    // Movies
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putMovies(list: List<MovieEntity>)
    @Query("DELETE FROM movies WHERE sourceId = :sourceId") suspend fun clearMovies(sourceId: String)
    @Query("SELECT id FROM movies WHERE sourceId = :sourceId") suspend fun movieIds(sourceId: String): List<String>
    @Query("DELETE FROM movies WHERE id IN (:ids)") suspend fun deleteMovies(ids: List<String>)
    @Query("SELECT * FROM movies WHERE categoryId = :categoryId ORDER BY title LIMIT :limit") fun moviesIn(categoryId: String, limit: Int): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) ORDER BY addedAt DESC LIMIT :limit") fun latestMovies(limit: Int, sources: List<String>): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) ORDER BY title LIMIT :limit") fun allMovies(limit: Int, sources: List<String>): Flow<List<MovieEntity>>
    @Query("SELECT * FROM movies WHERE id IN (:ids)") suspend fun moviesByIds(ids: List<String>): List<MovieEntity>
    @Query("SELECT * FROM series WHERE id IN (:ids)") suspend fun seriesByIds(ids: List<String>): List<SeriesEntity>
    @Query("SELECT * FROM movies WHERE id = :id") suspend fun movie(id: String): MovieEntity?
    @Query("UPDATE movies SET posterUrl = :url WHERE id = :id") suspend fun setMoviePoster(id: String, url: String)
    @Query("UPDATE series SET posterUrl = :url WHERE id = :id") suspend fun setSeriesPoster(id: String, url: String)
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) AND posterUrl IS NOT NULL AND posterUrl != '' ORDER BY RANDOM() LIMIT :n") suspend fun randomMovies(n: Int, sources: List<String>): List<MovieEntity>
    @Query("SELECT * FROM series WHERE sourceId IN (:sources) AND posterUrl IS NOT NULL AND posterUrl != '' ORDER BY RANDOM() LIMIT :n") suspend fun randomSeries(n: Int, sources: List<String>): List<SeriesEntity>
    @Query("SELECT * FROM movies WHERE sourceId IN (:sources) AND title LIKE '%' || :q || '%' ORDER BY title LIMIT :limit") suspend fun searchMovies(q: String, limit: Int, sources: List<String>): List<MovieEntity>

    // Series
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putSeries(list: List<SeriesEntity>)
    @Query("DELETE FROM series WHERE sourceId = :sourceId") suspend fun clearSeries(sourceId: String)
    @Query("SELECT id FROM series WHERE sourceId = :sourceId") suspend fun seriesIds(sourceId: String): List<String>
    @Query("DELETE FROM series WHERE id IN (:ids)") suspend fun deleteSeries(ids: List<String>)
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
    @Query("SELECT * FROM episodes WHERE id IN (:ids)") suspend fun episodesByIds(ids: List<String>): List<EpisodeEntity>
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
    /** What the guide holds for each playlist (the part of the stored id before the separator; "" for a guide stored before ids were scoped): how many programmes and when the last one ends. */
    @Query("SELECT CASE WHEN instr(channelEpgId, char(1)) > 0 THEN substr(channelEpgId, 1, instr(channelEpgId, char(1)) - 1) ELSE '' END AS scope, COUNT(*) AS n, MAX(endMs) AS lastEnd FROM epg GROUP BY scope") suspend fun guideStamps(): List<GuideStamp>
    /**
     * A signal, not data: it emits whenever the guide table is written (a refresh writes it in bursts) and costs one row to read. Callers debounce it and then read what they need once.
     */
    @Query("SELECT 1 FROM epg LIMIT 1") fun guideTouched(): Flow<List<Int>>
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
    @Query("SELECT * FROM progress") fun allProgress(): Flow<List<ProgressEntity>>
    /** Movies watched to the end, and series whose episodes were all watched (the Watched tick on a poster). Only series with some progress are looked at: this runs again at every progress save (every 10 s while playing), and a series nothing was watched in can never qualify, so a library of tens of thousands of series is not scanned each time. */
    @Query("SELECT itemId FROM progress WHERE completed = 1 AND kind = 'MOVIE' UNION SELECT e.seriesId FROM episodes e LEFT JOIN progress p ON p.itemId = e.id AND p.completed = 1 WHERE e.seriesId IN (SELECT e2.seriesId FROM episodes e2 JOIN progress p2 ON p2.itemId = e2.id) GROUP BY e.seriesId HAVING COUNT(p.itemId) = COUNT(*)")
    fun watchedTitles(): Flow<List<String>>
    /** Started but not finished: a movie by its position, a series by its episodes watched (the bar along the bottom of a poster). */
    @Query("SELECT itemId AS id, CAST(positionMs AS REAL) / durationMs AS fraction FROM progress WHERE kind = 'MOVIE' AND completed = 0 AND positionMs > 30000 AND durationMs > 0 UNION ALL SELECT e.seriesId AS id, SUM(CASE WHEN p.completed = 1 THEN 1.0 WHEN p.durationMs > 0 THEN CAST(p.positionMs AS REAL) / p.durationMs ELSE 0 END) / COUNT(*) AS fraction FROM episodes e LEFT JOIN progress p ON p.itemId = e.id WHERE e.seriesId IN (SELECT e2.seriesId FROM episodes e2 JOIN progress p2 ON p2.itemId = e2.id) GROUP BY e.seriesId HAVING fraction > 0 AND fraction < 1")
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
}

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
    /** The same lists when nothing about the order or the members depends on what the person has watched or saved: only the catalog table is watched, so a progress or favourite change does not read the page again. */
    /** One read, no watching: the page is asked for explicitly (with the library and restrictions it was asked for), and again only when the catalog changes. */
    @RawQuery suspend fun moviesOnce(q: SupportSQLiteQuery): List<MovieEntity>
    @RawQuery suspend fun seriesOnce(q: SupportSQLiteQuery): List<SeriesEntity>
    @Query("SELECT folderId FROM folder_prefs WHERE scope = :scope AND favorite = 1") suspend fun favoriteFoldersNow(scope: String): List<String>
    @RawQuery(observedEntities = [MovieEntity::class])
    fun moviesPlain(q: SupportSQLiteQuery): Flow<List<MovieEntity>>
    @RawQuery(observedEntities = [SeriesEntity::class])
    fun seriesPlain(q: SupportSQLiteQuery): Flow<List<SeriesEntity>>
    @RawQuery(observedEntities = [ChannelEntity::class, FavoriteEntity::class, WatchLogEntity::class, FolderPrefEntity::class])
    fun channels(q: SupportSQLiteQuery): Flow<List<ChannelEntity>>
    @RawQuery(observedEntities = [ChannelEntity::class, FavoriteEntity::class, WatchLogEntity::class, FolderPrefEntity::class])
    fun channelCount(q: SupportSQLiteQuery): Flow<Int>

    @Query("SELECT folderId FROM folder_prefs WHERE scope = :scope AND locked = 1") fun lockedFolders(scope: String): Flow<List<String>>
    @Query("SELECT folderId FROM folder_prefs WHERE locked = 1") suspend fun lockedFoldersNow(): List<String>
    @Query("SELECT folderId FROM folder_prefs WHERE scope = :scope AND favorite = 1") fun favoriteFolders(scope: String): Flow<List<String>>
    @Query("SELECT EXISTS(SELECT 1 FROM movies WHERE sourceId IN (:s) AND year IS NOT NULL)") suspend fun moviesWithYear(s: List<String>): Int
    @Query("SELECT EXISTS(SELECT 1 FROM movies WHERE sourceId IN (:s) AND rating IS NOT NULL AND rating != '' AND rating != '0')") suspend fun moviesWithRating(s: List<String>): Int
    @Query("SELECT EXISTS(SELECT 1 FROM series WHERE sourceId IN (:s) AND year IS NOT NULL)") suspend fun seriesWithYear(s: List<String>): Int
    @Query("SELECT EXISTS(SELECT 1 FROM series WHERE sourceId IN (:s) AND rating IS NOT NULL AND rating != '' AND rating != '0')") suspend fun seriesWithRating(s: List<String>): Int
    @Query("SELECT EXISTS(SELECT 1 FROM watch_log)") suspend fun watchedCount(): Int
    @Query("SELECT EXISTS(SELECT 1 FROM series WHERE sourceId IN (:s) AND addedAt > 0)") suspend fun seriesWithUpdateDate(s: List<String>): Int
    @Query("SELECT EXISTS(SELECT 1 FROM new_episodes)") suspend fun newEpisodeCount(): Int
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
    @Query("SELECT id FROM episodes WHERE seriesId = :seriesId") suspend fun episodeIds(seriesId: String): List<String>
    @Query("SELECT DISTINCT seriesId FROM progress WHERE seriesId IS NOT NULL") suspend fun seriesWithProgress(): List<String>

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

    // The background matching queue: read in pages by id (a cursor), so nothing but one page is ever in memory and restricted titles never block the pages behind them.
    // "No poster" comes first; "has a poster but no summary" is a second pass. A title with a correction row (found or remembered as not found) is never listed again.
    @Query("SELECT * FROM movies WHERE id > :after AND (posterUrl IS NULL OR posterUrl = '') AND id NOT IN (SELECT itemId FROM overrides) ORDER BY id LIMIT :n") suspend fun moviesNoPosterAfter(after: String, n: Int): List<MovieEntity>
    @Query("SELECT * FROM series WHERE id > :after AND (posterUrl IS NULL OR posterUrl = '') AND id NOT IN (SELECT itemId FROM overrides) ORDER BY id LIMIT :n") suspend fun seriesNoPosterAfter(after: String, n: Int): List<SeriesEntity>
    @Query("SELECT * FROM movies WHERE id > :after AND posterUrl IS NOT NULL AND posterUrl <> '' AND (plot IS NULL OR plot = '') AND id NOT IN (SELECT itemId FROM overrides) ORDER BY id LIMIT :n") suspend fun moviesNoPlotAfter(after: String, n: Int): List<MovieEntity>
    @Query("SELECT * FROM series WHERE id > :after AND posterUrl IS NOT NULL AND posterUrl <> '' AND (plot IS NULL OR plot = '') AND id NOT IN (SELECT itemId FROM overrides) ORDER BY id LIMIT :n") suspend fun seriesNoPlotAfter(after: String, n: Int): List<SeriesEntity>
    @Query("SELECT COUNT(*) FROM movies WHERE (posterUrl IS NULL OR posterUrl = '' OR plot IS NULL OR plot = '') AND id NOT IN (SELECT itemId FROM overrides)") suspend fun countMoviesToMatch(): Int
    @Query("SELECT COUNT(*) FROM series WHERE (posterUrl IS NULL OR posterUrl = '' OR plot IS NULL OR plot = '') AND id NOT IN (SELECT itemId FROM overrides)") suspend fun countSeriesToMatch(): Int
    @Query("SELECT COUNT(*) FROM movies WHERE (posterUrl IS NULL OR posterUrl = '') AND id NOT IN (SELECT itemId FROM overrides)") suspend fun countMoviesNoPoster(): Int
    @Query("SELECT COUNT(*) FROM series WHERE (posterUrl IS NULL OR posterUrl = '') AND id NOT IN (SELECT itemId FROM overrides)") suspend fun countSeriesNoPoster(): Int
    @Query("SELECT itemId FROM overrides WHERE itemId IN (:ids)") suspend fun overrideIdsAmong(ids: List<String>): List<String>

    // Ratings: what a tile shows is read for many titles at once (never one query per tile)
    @Query("SELECT id, rating FROM movies WHERE id IN (:ids)") suspend fun movieRatings(ids: List<String>): List<RatingRow>
    @Query("SELECT id, rating FROM series WHERE id IN (:ids)") suspend fun seriesRatings(ids: List<String>): List<RatingRow>
    @Query("SELECT * FROM rating_checks WHERE itemId IN (:ids)") suspend fun ratingChecks(ids: List<String>): List<RatingCheckEntity>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putRatingCheck(r: RatingCheckEntity)
    @Query("DELETE FROM rating_checks WHERE checkedAt < :cutoff") suspend fun clearRatingChecksBefore(cutoff: Long)
    @Query("DELETE FROM rating_checks WHERE itemId IN (:ids)") suspend fun clearRatingChecks(ids: List<String>)
    @Query("DELETE FROM rating_checks") suspend fun clearAllRatingChecks()

    // Overrides
    @Query("SELECT * FROM overrides") fun overrides(): Flow<List<OverrideEntity>>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putOverride(o: OverrideEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putOverrides(list: List<OverrideEntity>)
    @Query("DELETE FROM overrides WHERE itemId = :id") suspend fun clearOverride(id: String)
    /** Takes back what TMDB filled in: only a correction that holds no title of the person's own (their hand-made ones always have a title or a picture they chose). */
    @Query("DELETE FROM overrides WHERE itemId = :id AND title IS NULL AND (posterUrl IS NULL OR posterUrl = '' OR posterUrl LIKE 'https://image.tmdb.org/%')") suspend fun clearTmdbOverride(id: String)
    @Query("SELECT * FROM movies WHERE id IN (:ids)") suspend fun moviesByIds(ids: List<String>): List<MovieEntity>
    @Query("SELECT * FROM series WHERE id IN (:ids)") suspend fun seriesByIds(ids: List<String>): List<SeriesEntity>

    // Watch time
    // One statement, no upsert (ON CONFLICT ... DO UPDATE needs SQLite 3.24; the oldest supported Android and Fire OS have less): the new row carries the old total plus this time.
    @Query("INSERT OR REPLACE INTO watch_time(day, hour, itemId, kind, title, ms) VALUES(:day, :hour, :itemId, :kind, :title, :ms + COALESCE((SELECT ms FROM watch_time WHERE day = :day AND hour = :hour AND itemId = :itemId), 0))")
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
    @Query("SELECT DISTINCT channelEpgId FROM epg") suspend fun epgIdsWithProgrammes(): List<String>
}


@Dao
abstract class SportsDao {
    // Follows
    @Query("SELECT * FROM sports_follows WHERE profileId = :profile ORDER BY createdAt, id") abstract suspend fun follows(profile: String): List<SportsFollowEntity>
    @Query("SELECT * FROM sports_follows WHERE profileId = :profile ORDER BY createdAt, id") abstract fun followsFlow(profile: String): Flow<List<SportsFollowEntity>>
    @Insert(onConflict = OnConflictStrategy.IGNORE) abstract suspend fun insertFollow(f: SportsFollowEntity): Long
    @Query("DELETE FROM sports_follows WHERE profileId = :profile AND kind = :kind AND sport = :sport AND normKey = :key") abstract suspend fun deleteFollow(profile: String, kind: String, sport: String, key: String): Int
    @Query("DELETE FROM sports_follows WHERE profileId = :profile") abstract suspend fun clearFollows(profile: String): Int
    /** Moves one follow to another key in one transaction. False if the old follow is gone (another caller already moved or removed it), so repeating or racing the call changes nothing more. */
    @Transaction open suspend fun replaceFollowKey(profile: String, kind: String, sport: String, oldKey: String, newKey: String, displayName: String, now: Long): Boolean {
        if (deleteFollow(profile, kind, sport, oldKey) == 0) return false
        insertFollow(SportsFollowEntity(profileId = profile, kind = kind, sport = sport, normKey = newKey, displayName = displayName, createdAt = now))
        return true
    }

    // Reminders
    @Query("SELECT * FROM sports_reminders WHERE profileId = :profile ORDER BY startMs, id") abstract suspend fun reminders(profile: String): List<SportsReminderEntity>
    @Query("SELECT * FROM sports_reminders WHERE profileId = :profile ORDER BY startMs, id") abstract fun remindersFlow(profile: String): Flow<List<SportsReminderEntity>>
    @Query("SELECT * FROM sports_reminders WHERE id = :id") abstract suspend fun reminder(id: String): SportsReminderEntity?
    @Query("SELECT * FROM sports_reminders WHERE status IN ('SCHEDULED', 'UNMATCHED', 'AMBIGUOUS') AND endMs > :now ORDER BY startMs, id") abstract suspend fun activeReminders(now: Long): List<SportsReminderEntity>
    @Insert(onConflict = OnConflictStrategy.IGNORE) abstract suspend fun insertReminder(r: SportsReminderEntity): Long
    @Update abstract suspend fun updateReminders(list: List<SportsReminderEntity>)
    @Query("DELETE FROM sports_reminders WHERE id = :id") abstract suspend fun deleteReminder(id: String): Int
    @Query("SELECT COUNT(*) FROM sports_reminders") abstract suspend fun reminderCount(): Int

    // Recordings (the Sports side: identity, matching, state; the executor is the scheduled-recording service)
    @Query("SELECT * FROM sports_recordings WHERE profileId = :profile ORDER BY startMs, id") abstract suspend fun recordings(profile: String): List<SportsRecordingEntity>
    @Query("SELECT * FROM sports_recordings WHERE profileId = :profile ORDER BY startMs, id") abstract fun recordingsFlow(profile: String): Flow<List<SportsRecordingEntity>>
    /** What the screens need: every open request, and the most recent ended ones. The long history is never read to draw a card. */
    @Query("SELECT * FROM sports_recordings WHERE profileId = :profile AND (status IN ('SCHEDULED', 'RECORDING', 'REVIEW_REQUIRED') OR id IN (SELECT id FROM sports_recordings WHERE profileId = :profile AND status NOT IN ('SCHEDULED', 'RECORDING', 'REVIEW_REQUIRED') ORDER BY updatedAt DESC, id LIMIT :closed)) ORDER BY startMs, id")
    abstract fun recentRecordingsFlow(profile: String, closed: Int): Flow<List<SportsRecordingEntity>>
    @Query("SELECT * FROM sports_recordings WHERE id = :id") abstract suspend fun recording(id: String): SportsRecordingEntity?
    @Query("SELECT * FROM sports_recordings WHERE scheduleId = :scheduleId") abstract suspend fun recordingBySchedule(scheduleId: String): SportsRecordingEntity?
    @Query("SELECT * FROM sports_recordings WHERE status IN ('SCHEDULED', 'RECORDING', 'REVIEW_REQUIRED') ORDER BY startMs, id") abstract suspend fun openRecordings(): List<SportsRecordingEntity>
    /** A request that ended (cancelled, finished, failed) frees its place, so the same event can be asked for again; the unique index covers every row, open or not. */
    @Query("DELETE FROM sports_recordings WHERE profileId = :profileId AND sport = :sport AND identity = :identity AND slot = :slot AND status NOT IN ('SCHEDULED', 'RECORDING', 'REVIEW_REQUIRED')")
    abstract suspend fun deleteClosedRecordings(profileId: String, sport: String, identity: String, slot: Long): Int
    @Insert(onConflict = OnConflictStrategy.IGNORE) abstract suspend fun insertRecording(r: SportsRecordingEntity): Long
    /** Frees the place of an ended request and inserts the new one as one transaction: two callers cannot both delete and both insert, and an open request is never replaced. -1 if an open one holds the place. */
    @Transaction open suspend fun replaceClosedRecording(r: SportsRecordingEntity): Long { deleteClosedRecordings(r.profileId, r.sport, r.identity, r.slot); return insertRecording(r) }
    @Update abstract suspend fun updateRecordings(list: List<SportsRecordingEntity>)
    @Query("DELETE FROM sports_recordings WHERE id = :id") abstract suspend fun deleteRecording(id: String): Int

    /** Moves a recording from one of [from] to [to] in one statement: it applies only if it is still in one of those states, so a repeated or late call changes nothing. Returns how many rows changed. */
    @Query("UPDATE sports_recordings SET status = :to, failure = :failure, updatedAt = :now WHERE id = :id AND status IN (:from)")
    abstract suspend fun transition(id: String, from: List<String>, to: String, failure: String?, now: Long): Int
}

data class IdentityHash(val itemId: String, val inHash: Long)

/** A catalog row that has no identity yet (or one derived by an older rule): only what the rule reads. */
data class UnderivedRow(val id: String, val sourceId: String, val categoryId: String?, val title: String, val year: Int?)

/** The derived identity table and the Smart Mix state. Nothing here reads or changes a playlist row. */
@Dao
interface IdentityDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putAll(rows: List<ContentIdentityEntity>)
    @Query("DELETE FROM content_identity WHERE itemId IN (:ids)") suspend fun delete(ids: List<String>)
    @Query("DELETE FROM content_identity WHERE sourceId = :sourceId") suspend fun clearSource(sourceId: String)
    @Query("DELETE FROM source_twin WHERE sourceA = :sourceId OR sourceB = :sourceId") suspend fun clearTwinsOf(sourceId: String)
    @Query("SELECT itemId, inHash FROM content_identity WHERE sourceId = :sourceId AND kind = :kind") suspend fun hashes(sourceId: String, kind: String): List<IdentityHash>
    @Query("SELECT * FROM content_identity WHERE itemId IN (:ids)") suspend fun byItemIds(ids: List<String>): List<ContentIdentityEntity>
    /** The rows of one kind with one of these identity keys, in these playlists (the person page matches a filmography against the library with it). */
    @Query("SELECT * FROM content_identity WHERE kind = :kind AND identityKey IN (:keys) AND sourceId IN (:sources)") suspend fun byKeys(kind: String, keys: List<String>, sources: List<String>): List<ContentIdentityEntity>
    @Query("SELECT COUNT(*) FROM content_identity WHERE identVer = :ver") suspend fun derivedCount(ver: Int): Int
    @Query("SELECT COUNT(*) FROM content_identity") suspend fun identityTotal(): Int
    /** Movies with no identity row, or one made by an older rule: the work of the background fill (a small batch at a time). */
    @Query("SELECT m.id AS id, m.sourceId AS sourceId, m.categoryId AS categoryId, m.title AS title, m.year AS year FROM movies m LEFT JOIN content_identity ci ON ci.itemId = m.id WHERE m.id > :after AND (ci.itemId IS NULL OR ci.identVer != :ver) ORDER BY m.id LIMIT :limit")
    suspend fun underivedMovies(ver: Int, limit: Int, after: String): List<UnderivedRow>
    @Query("SELECT s.id AS id, s.sourceId AS sourceId, s.categoryId AS categoryId, s.title AS title, s.year AS year FROM series s LEFT JOIN content_identity ci ON ci.itemId = s.id WHERE s.id > :after AND (ci.itemId IS NULL OR ci.identVer != :ver) ORDER BY s.id LIMIT :limit")
    suspend fun underivedSeries(ver: Int, limit: Int, after: String): List<UnderivedRow>

    // Twin playlists
    @Query("SELECT COUNT(*) FROM content_identity WHERE sourceId = :source AND kind = :kind") suspend fun countOf(source: String, kind: String): Int
    @Query("SELECT COUNT(*) FROM content_identity a WHERE a.sourceId = :a AND a.kind = :kind AND EXISTS (SELECT 1 FROM content_identity b WHERE b.sourceId = :b AND b.kind = :kind AND b.identityKey = a.identityKey AND b.year IS a.year)")
    suspend fun matched(a: String, b: String, kind: String): Int
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putTwins(rows: List<SourceTwinEntity>)
    @Query("DELETE FROM source_twin") suspend fun clearTwins()
    @Query("SELECT * FROM source_twin") suspend fun twins(): List<SourceTwinEntity>

    // Recommendations only: "removed from Continue Watching" markers (never read for restricted titles)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putDismissed(row: RecDismissedEntity)
    @Query("DELETE FROM rec_dismissed WHERE profileId = :profile AND itemId = :itemId") suspend fun undismiss(profile: String, itemId: String)
    @Query("SELECT * FROM rec_dismissed WHERE profileId = :profile") suspend fun dismissed(profile: String): List<RecDismissedEntity>

    // What shelves showed
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putShown(rows: List<SmartMixShownEntity>)
    @Query("SELECT * FROM smartmix_shown WHERE profileId = :profile") suspend fun shown(profile: String): List<SmartMixShownEntity>
    @Query("DELETE FROM smartmix_shown WHERE itemId IN (:ids)") suspend fun deleteShownItems(ids: List<String>)
    @Query("DELETE FROM smartmix_shown WHERE identityKey IN (:keys)") suspend fun deleteShownKeys(keys: List<String>)

    @Query("SELECT * FROM smartmix_state WHERE profileId = :profile AND shelfId = :shelf") suspend fun state(profile: String, shelf: String): SmartMixStateEntity?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putState(row: SmartMixStateEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putRecent(row: FolderRecentEntity)
    @Query("SELECT * FROM folder_recent WHERE profileId = :profile") suspend fun recent(profile: String): List<FolderRecentEntity>
}

/** An item's id and the rating its own row holds (the provider's, or the one TMDB filled). */
data class RatingRow(val id: String, val rating: String?)
