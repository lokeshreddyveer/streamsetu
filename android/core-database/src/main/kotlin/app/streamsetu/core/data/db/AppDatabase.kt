package app.streamsetu.core.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [SourceEntity::class, CategoryEntity::class, ChannelEntity::class, MovieEntity::class, SeriesEntity::class,
        EpisodeEntity::class, EpgEntity::class, FavoriteEntity::class, ProgressEntity::class, WatchLogEntity::class,
        LibraryEntity::class, LibraryMemberEntity::class, FolderPrefEntity::class,
        NewEpisodeEntity::class, CatalogFingerprintEntity::class, CollectionEntity::class, CollectionItemEntity::class, OverrideEntity::class, EpgChannelEntity::class,
        WatchTimeEntity::class, ChannelPrefEntity::class, ReminderEntity::class, SportsFollowEntity::class, SportsReminderEntity::class, SportsRecordingEntity::class,
        RatingCheckEntity::class, ContentIdentityEntity::class, SourceTwinEntity::class, RecDismissedEntity::class, SmartMixShownEntity::class, SmartMixStateEntity::class, FolderRecentEntity::class, HubIdentityEntity::class, MetadataFactEntity::class, TmdbIdEntity::class, TmdbGenreEntity::class,
        GuideSourceEntity::class, GuideDiagnosticsEntity::class, ChannelGuideMapEntity::class, ChannelEnrichmentEntity::class],
    version = 18,
    exportSchema = true,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun sources(): SourceDao
    abstract fun catalog(): CatalogDao
    abstract fun epg(): EpgDao
    abstract fun user(): UserDao
    abstract fun libraries(): LibraryDao
    abstract fun folders(): FolderDao
    abstract fun browse(): BrowseDao
    abstract fun extras(): ExtrasDao
    abstract fun sports(): SportsDao
    abstract fun identity(): IdentityDao
    abstract fun hub(): HubDao
    abstract fun guideHub(): GuideHubDao

    companion object {
        /** Every step from the first version to the current one, in order. There is no destructive fallback: a database that cannot be upgraded is never emptied. */
        val MIGRATIONS: Array<androidx.room.migration.Migration> get() = arrayOf(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10, MIGRATION_10_11, MIGRATION_11_12, MIGRATION_12_13, MIGRATION_13_14, MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18)

        /**
         * "A to Z" and "Newest year" over the whole library read straight from an index: a lower-case copy of the title (kept by two triggers, so no write path has to know about it) with an
         * index on it, and an index on the year, for movies and series. Additive: nothing existing is changed. The copy is filled in here with one statement per table, and the triggers keep it right.
         */
        val MIGRATION_11_12 = object : androidx.room.migration.Migration(11, 12) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                for (t in listOf("movies", "series")) {
                    db.execSQL("ALTER TABLE $t ADD COLUMN titleSort TEXT NOT NULL DEFAULT ''")
                    db.execSQL("UPDATE $t SET titleSort = lower(title)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS index_${t}_titleSort_id ON $t (titleSort, id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS index_${t}_year_id ON $t (year DESC, id ASC)")
                }
                ensureSortTriggers(db)
            }
        }

        /** The metadata hub: two new, empty tables (the crosswalk of ids across services, and the saved facts with source, quality and expiry). Additive; nothing existing is touched. */
        val MIGRATION_12_13 = object : androidx.room.migration.Migration(12, 13) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS hub_identity (itemId TEXT NOT NULL, tmdbId INTEGER, tvdbId INTEGER, imdbId TEXT, tvmazeId INTEGER, kind TEXT, resolvedAt INTEGER NOT NULL DEFAULT 0, missUntil INTEGER, PRIMARY KEY(itemId))")
                db.execSQL("CREATE TABLE IF NOT EXISTS metadata_facts (itemId TEXT NOT NULL, field TEXT NOT NULL, value TEXT, source TEXT NOT NULL, quality REAL NOT NULL DEFAULT 0, fetchedAt INTEGER NOT NULL, expiresAt INTEGER NOT NULL, missUntil INTEGER, failCount INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(itemId, field))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_metadata_facts_expiresAt ON metadata_facts (expiresAt)")
            }
        }

        /** What TMDB said a matched title is rated, and when it was asked (once: a title with nothing credible is not asked again). One new, empty table; nothing existing is touched. */
        val MIGRATION_13_14 = object : androidx.room.migration.Migration(13, 14) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS rating_checks (itemId TEXT NOT NULL, tmdbRating TEXT, checkedAt INTEGER NOT NULL, PRIMARY KEY(itemId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_rating_checks_checkedAt ON rating_checks (checkedAt)")
            }
        }

        /**
         * The two TMDB tables (which TMDB title an item is, and its TMDB genres) were made on first use with CREATE TABLE IF NOT EXISTS, outside Room. They are Room tables now, with the same columns, so a
         * database that has them keeps its rows; only the index gets its Room name. Additive. (Version 16 is reserved for the Live TV guide work on Android.)
         */
        val MIGRATION_14_15 = object : androidx.room.migration.Migration(14, 15) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS tmdb_ids (itemId TEXT NOT NULL, tmdbId INTEGER NOT NULL, tv INTEGER NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(itemId))")
                db.execSQL("DROP INDEX IF EXISTS tmdb_ids_by_id")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_tmdb_ids_tmdbId_tv ON tmdb_ids (tmdbId, tv)")
                db.execSQL("CREATE TABLE IF NOT EXISTS tmdb_genres (itemId TEXT NOT NULL, ids TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(itemId))")
            }
        }

        /** The guide hub (Live TV guide sources, per-source diagnostics, the channel-to-guide map and the public channel database overlay): four new, empty tables. Additive; nothing existing is touched. */
        val MIGRATION_15_16 = object : androidx.room.migration.Migration(15, 16) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS guide_sources (id TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL, urlRef TEXT, enabled INTEGER NOT NULL DEFAULT 1, priority INTEGER NOT NULL DEFAULT 20, refreshHours INTEGER NOT NULL DEFAULT 6, tzMode TEXT NOT NULL DEFAULT 'auto', tzZone TEXT, offsetMinutes INTEGER NOT NULL DEFAULT 0, etag TEXT, lastModified TEXT, createdAt INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(id))")
                db.execSQL("CREATE TABLE IF NOT EXISTS guide_diagnostics (guideSourceId TEXT NOT NULL, lastAttempt INTEGER NOT NULL, lastSuccess INTEGER, outcome TEXT NOT NULL, httpStatus INTEGER, bytes INTEGER, channels INTEGER NOT NULL DEFAULT 0, mapped INTEGER NOT NULL DEFAULT 0, programmesSeen INTEGER NOT NULL DEFAULT 0, programmesKept INTEGER NOT NULL DEFAULT 0, droppedPast INTEGER NOT NULL DEFAULT 0, droppedFuture INTEGER NOT NULL DEFAULT 0, droppedInvalid INTEGER NOT NULL DEFAULT 0, fileFirstStart INTEGER, fileLastStop INTEGER, truncated INTEGER NOT NULL DEFAULT 0, error TEXT, windowEnd INTEGER, PRIMARY KEY(guideSourceId))")
                db.execSQL("CREATE TABLE IF NOT EXISTS channel_guide_map (channelId TEXT NOT NULL, guideSourceId TEXT NOT NULL, xmltvId TEXT NOT NULL, method TEXT NOT NULL, confidence REAL NOT NULL DEFAULT 1, reason TEXT, locked INTEGER NOT NULL DEFAULT 0, updatedAt INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(channelId, guideSourceId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_channel_guide_map_guideSourceId_xmltvId ON channel_guide_map (guideSourceId, xmltvId)")
                db.execSQL("CREATE TABLE IF NOT EXISTS channel_enrichment (channelId TEXT NOT NULL, dbId TEXT, logoUrl TEXT, categoryKey TEXT, country TEXT, language TEXT, matchedBy TEXT, confidence REAL NOT NULL DEFAULT 0, fetchedAt INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(channelId))")
            }
        }

        /**
         * The sort key learns accents: titleSort was lower(title), and SQLite's lower() changes only A to Z, so "Émile" sorted after "Z". The two triggers are made again with the key of [app.streamsetu.core.model.SortKey]
         * (lower-case, Latin accents folded) and only the rows that have a non-ASCII character are updated (one statement per table; ASCII titles keep the very same key, so nothing else changes). Additive: no column,
         * table or index changes, so the Room schema is the same as version 16.
         */
        val MIGRATION_16_17 = object : androidx.room.migration.Migration(16, 17) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                ensureSortTriggers(db)
                for (t in listOf("movies", "series")) for (q in app.streamsetu.core.model.SortKey.updateStatements(t, "title", "title GLOB '${app.streamsetu.core.model.SortKey.NON_ASCII_GLOB}'")) db.execSQL(q)
            }
        }

        /**
         * The insert trigger now runs only for a row saved WITHOUT a sort key (titleSort is empty): the catalog write computes the key in Kotlin (SortKey.of, the same table) and saves it with the row, so
         * a bulk read no longer fires about fifteen UPDATE statements per new row. Any other way of inserting a row (no key given) is still covered. The two triggers are made again; no table, column or index
         * changes, so the Room schema is the same as version 17.
         */
        val MIGRATION_17_18 = object : androidx.room.migration.Migration(17, 18) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) { ensureSortTriggers(db) }
        }

        /** The triggers that keep titleSort equal to the sort key of the title (see [app.streamsetu.core.model.SortKey]). Safe to run again; made with a new database and by the 11 to 12 step. */
        fun ensureSortTriggers(db: androidx.sqlite.db.SupportSQLiteDatabase) {
            for (t in listOf("movies", "series")) {
                val body = app.streamsetu.core.model.SortKey.updateStatements(t, "NEW.title", "rowid = NEW.rowid").joinToString("; ")
                db.execSQL("DROP TRIGGER IF EXISTS ${t}_titlesort_ai"); db.execSQL("DROP TRIGGER IF EXISTS ${t}_titlesort_au")
                db.execSQL("CREATE TRIGGER IF NOT EXISTS ${t}_titlesort_ai AFTER INSERT ON $t WHEN NEW.titleSort = '' BEGIN $body; END")
                db.execSQL("CREATE TRIGGER IF NOT EXISTS ${t}_titlesort_au AFTER UPDATE OF title ON $t BEGIN $body; END")
            }
        }

        /**
         * Canonical content identity and the Smart Mix state: six new, empty tables and two indexes for the folder queries. Nothing existing is touched and nothing is filled in here (a pass over
         * 66,000 titles must not hold up opening the database on a TV stick): the identity rows are made as playlists are read and by a background fill (see IdentityStore). Room has no
         * downgrade, so an older build cannot open a version 11 file.
         */
        val MIGRATION_10_11 = object : androidx.room.migration.Migration(10, 11) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS content_identity (itemId TEXT NOT NULL, kind TEXT NOT NULL, sourceId TEXT NOT NULL, identityKey TEXT NOT NULL, year INTEGER, lang TEXT, qualityRank INTEGER NOT NULL, isCam INTEGER NOT NULL, folderKey TEXT, inHash INTEGER NOT NULL, identVer INTEGER NOT NULL, PRIMARY KEY(itemId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_content_identity_kind_identityKey_year ON content_identity (kind, identityKey, year)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_content_identity_sourceId_kind ON content_identity (sourceId, kind)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_content_identity_folderKey ON content_identity (folderKey)")
                db.execSQL("CREATE TABLE IF NOT EXISTS source_twin (kind TEXT NOT NULL, sourceA TEXT NOT NULL, sourceB TEXT NOT NULL, matched INTEGER NOT NULL, totalA INTEGER NOT NULL, totalB INTEGER NOT NULL, checkedAt INTEGER NOT NULL, PRIMARY KEY(kind, sourceA, sourceB))")
                db.execSQL("CREATE TABLE IF NOT EXISTS rec_dismissed (profileId TEXT NOT NULL, itemId TEXT NOT NULL, kind TEXT NOT NULL, identityKey TEXT NOT NULL, year INTEGER, dismissedAt INTEGER NOT NULL, PRIMARY KEY(profileId, itemId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_rec_dismissed_profileId_identityKey ON rec_dismissed (profileId, identityKey)")
                db.execSQL("CREATE TABLE IF NOT EXISTS smartmix_shown (profileId TEXT NOT NULL, shelfId TEXT NOT NULL, identityKey TEXT NOT NULL, year INTEGER, itemId TEXT NOT NULL, loadSeq INTEGER NOT NULL, shownAt INTEGER NOT NULL, PRIMARY KEY(profileId, shelfId, identityKey, loadSeq))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_smartmix_shown_profileId_shelfId_loadSeq ON smartmix_shown (profileId, shelfId, loadSeq)")
                db.execSQL("CREATE TABLE IF NOT EXISTS smartmix_state (profileId TEXT NOT NULL, shelfId TEXT NOT NULL, refreshCounter INTEGER NOT NULL, loadKey TEXT NOT NULL, loadSeq INTEGER NOT NULL, PRIMARY KEY(profileId, shelfId))")
                db.execSQL("CREATE TABLE IF NOT EXISTS folder_recent (profileId TEXT NOT NULL, categoryId TEXT NOT NULL, lastOpenedAt INTEGER NOT NULL, opens INTEGER NOT NULL, PRIMARY KEY(profileId, categoryId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_movies_sourceId_categoryId_addedAt ON movies (sourceId, categoryId, addedAt)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_series_sourceId_categoryId_addedAt ON series (sourceId, categoryId, addedAt)")
            }
        }

        /**
         * Plex pictures used to be saved with the access token in their address, always in the form `...?X-Plex-Token=...` (the `&X-Plex-Token` form only ever existed in playback addresses, which are
         * never stored). The token is taken out of what an earlier version stored, once, here, so nothing has to scan every address at each start. Addresses without it are not touched; no structure changes.
         */
        val MIGRATION_9_10 = object : androidx.room.migration.Migration(9, 10) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                SearchIndex.create(db); PeopleIndex.create(db); LanLog.create(db); Profiles.create(db)          // the tables that used to be made at every open (all "if not exists": a database that has them keeps them)
                for ((table, column) in listOf("movies" to "posterUrl", "series" to "posterUrl", "series" to "backdropUrl", "episodes" to "imageUrl"))
                    db.execSQL("UPDATE $table SET $column = substr($column, 1, instr($column, '?X-Plex-Token=') - 1) WHERE $column LIKE '%?X-Plex-Token=%'")
                // Divider rows ("#### SPORTS ####") that older imports kept as channels are removed once here (the common marks only); new imports never store them (see CatalogStore and ChannelFilter).
                db.execSQL("DELETE FROM channels WHERE name LIKE '%####%' OR name LIKE '%====%' OR name LIKE '%----%' OR name LIKE '%****%' OR TRIM(name) = ''")
            }
        }

        /** Recordings asked for from Sports events: one new, empty table. Nothing existing is touched. */
        val MIGRATION_8_9 = object : androidx.room.migration.Migration(8, 9) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS sports_recordings (id TEXT NOT NULL, profileId TEXT NOT NULL, libraryKey TEXT NOT NULL, sport TEXT NOT NULL, identity TEXT NOT NULL, competitionKey TEXT, participantsKey TEXT NOT NULL, sourceId TEXT NOT NULL, channelId TEXT NOT NULL, startMs INTEGER NOT NULL, endMs INTEGER NOT NULL, preMs INTEGER NOT NULL, postMs INTEGER NOT NULL, slot INTEGER NOT NULL, siblings INTEGER NOT NULL, distinguishing TEXT NOT NULL, programmeId TEXT, scheduleId TEXT NOT NULL, matchedEventId TEXT, status TEXT NOT NULL, failure TEXT, authStamp TEXT NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, PRIMARY KEY(id))")
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_sports_recordings_profileId_sport_identity_slot ON sports_recordings (profileId, sport, identity, slot)")
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_sports_recordings_scheduleId ON sports_recordings (scheduleId)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_recordings_profileId ON sports_recordings (profileId)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_recordings_identity ON sports_recordings (identity)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_recordings_startMs ON sports_recordings (startMs)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_recordings_status ON sports_recordings (status)")
            }
        }

        /** What a person follows in Sports, and the reminders they asked for. Two new, empty tables: nothing existing is touched. */
        val MIGRATION_7_8 = object : androidx.room.migration.Migration(7, 8) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS sports_follows (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, profileId TEXT NOT NULL, kind TEXT NOT NULL, sport TEXT NOT NULL, normKey TEXT NOT NULL, displayName TEXT NOT NULL, createdAt INTEGER NOT NULL)")
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_sports_follows_profileId_kind_sport_normKey ON sports_follows (profileId, kind, sport, normKey)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_follows_profileId ON sports_follows (profileId)")
                db.execSQL("CREATE TABLE IF NOT EXISTS sports_reminders (id TEXT NOT NULL, profileId TEXT NOT NULL, sport TEXT NOT NULL, identity TEXT NOT NULL, competitionKey TEXT, participantsKey TEXT NOT NULL, startMs INTEGER NOT NULL, endMs INTEGER NOT NULL, leadMs INTEGER NOT NULL, slot INTEGER NOT NULL, siblings INTEGER NOT NULL, distinguishing TEXT NOT NULL, matchedEventId TEXT, candidateChannelIds TEXT NOT NULL, status TEXT NOT NULL, notifiedAt INTEGER NOT NULL, bannerAt INTEGER NOT NULL, kept INTEGER NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, PRIMARY KEY(id))")
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_sports_reminders_profileId_sport_identity_slot ON sports_reminders (profileId, sport, identity, slot)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_reminders_profileId ON sports_reminders (profileId)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_reminders_identity ON sports_reminders (identity)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_reminders_startMs ON sports_reminders (startMs)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_sports_reminders_status ON sports_reminders (status)")
            }
        }

        /** Indexes for the paths the screens browse by: newest first per library, a list in the order it was filled, what is partly watched, and the viewing history of one title. */
        val MIGRATION_6_7 = object : androidx.room.migration.Migration(6, 7) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS catalog_fingerprints (sourceId TEXT NOT NULL, fingerprint INTEGER NOT NULL, rows INTEGER NOT NULL, version INTEGER NOT NULL, PRIMARY KEY(sourceId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_channels_sourceId_addedAt ON channels (sourceId, addedAt)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_movies_sourceId_addedAt ON movies (sourceId, addedAt)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_series_sourceId_addedAt ON series (sourceId, addedAt)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_favorites_listId_addedAt ON favorites (listId, addedAt)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_progress_seriesId ON progress (seriesId)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_progress_updatedAt ON progress (updatedAt)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_watch_log_itemId ON watch_log (itemId)")
            }
        }

        /** Watch time for the Statistics page, what the person changed about channels, and programme reminders. */
        val MIGRATION_5_6 = object : androidx.room.migration.Migration(5, 6) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS watch_time (day INTEGER NOT NULL, hour INTEGER NOT NULL, itemId TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, hour, itemId))")
                db.execSQL("CREATE TABLE IF NOT EXISTS channel_prefs (channelId TEXT NOT NULL, hidden INTEGER NOT NULL, name TEXT, epgId TEXT, PRIMARY KEY(channelId))")
                db.execSQL("ALTER TABLE overrides ADD COLUMN plot TEXT")
                db.execSQL("CREATE TABLE IF NOT EXISTS reminders (id TEXT NOT NULL, channelId TEXT NOT NULL, channelName TEXT NOT NULL, title TEXT NOT NULL, startMs INTEGER NOT NULL, PRIMARY KEY(id))")
            }
        }

        /** A custom User-Agent per connection, and a radio flag on channels. */
        val MIGRATION_4_5 = object : androidx.room.migration.Migration(4, 5) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE sources ADD COLUMN userAgent TEXT")
                db.execSQL("ALTER TABLE channels ADD COLUMN isRadio INTEGER NOT NULL DEFAULT 0")
            }
        }

        /** New-episode flags, collections, local overrides and guide channel names. Nothing existing is touched. */
        val MIGRATION_3_4 = object : androidx.room.migration.Migration(3, 4) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS new_episodes (episodeId TEXT NOT NULL, seriesId TEXT NOT NULL, discoveredAt INTEGER NOT NULL, PRIMARY KEY(episodeId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_new_episodes_seriesId ON new_episodes (seriesId)")
                db.execSQL("CREATE TABLE IF NOT EXISTS collections (id TEXT NOT NULL, name TEXT NOT NULL, scope TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY(id))")
                db.execSQL("CREATE TABLE IF NOT EXISTS collection_items (collectionId TEXT NOT NULL, itemId TEXT NOT NULL, addedAt INTEGER NOT NULL, PRIMARY KEY(collectionId, itemId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_collection_items_itemId ON collection_items (itemId)")
                db.execSQL("CREATE TABLE IF NOT EXISTS overrides (itemId TEXT NOT NULL, title TEXT, posterUrl TEXT, PRIMARY KEY(itemId))")
                db.execSQL("CREATE TABLE IF NOT EXISTS epg_channels (epgId TEXT NOT NULL, nameNorm TEXT NOT NULL, PRIMARY KEY(epgId))")
            }
        }

        /** Adds the text search index and fills it from the catalog already on the device. */
        val MIGRATION_2_3 = object : androidx.room.migration.Migration(2, 3) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE channels ADD COLUMN addedAt INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE series ADD COLUMN addedAt INTEGER NOT NULL DEFAULT 0")
                SearchIndex.create(db); SearchIndex.backfill(db)
            }
        }

        val MIGRATION_1_2 = object : androidx.room.migration.Migration(1, 2) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE sources ADD COLUMN draft INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE sources ADD COLUMN channelCount INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE sources ADD COLUMN movieCount INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE sources ADD COLUMN seriesCount INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE sources ADD COLUMN lastError TEXT")
                db.execSQL("ALTER TABLE sources ADD COLUMN lastOpenedAt INTEGER NOT NULL DEFAULT 0")
                // Counts for playlists that were already read.
                db.execSQL("UPDATE sources SET channelCount = (SELECT COUNT(*) FROM channels WHERE channels.sourceId = sources.id), movieCount = (SELECT COUNT(*) FROM movies WHERE movies.sourceId = sources.id), seriesCount = (SELECT COUNT(*) FROM series WHERE series.sourceId = sources.id)")
                db.execSQL("CREATE TABLE IF NOT EXISTS libraries (id TEXT NOT NULL, name TEXT NOT NULL, createdAt INTEGER NOT NULL, lastOpenedAt INTEGER NOT NULL, PRIMARY KEY(id))")
                db.execSQL("CREATE TABLE IF NOT EXISTS library_members (libraryId TEXT NOT NULL, sourceId TEXT NOT NULL, PRIMARY KEY(libraryId, sourceId))")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_library_members_sourceId ON library_members (sourceId)")
                db.execSQL("CREATE TABLE IF NOT EXISTS folder_prefs (scope TEXT NOT NULL, folderId TEXT NOT NULL, favorite INTEGER NOT NULL, pinned INTEGER NOT NULL, hidden INTEGER NOT NULL, locked INTEGER NOT NULL, alias TEXT, sortIndex INTEGER NOT NULL, PRIMARY KEY(scope, folderId))")
            }
        }

        /** [queryThreads]: how many reads may run at once (two on a small TV box); every write transaction goes through one thread, so catalog writes and reads do not fight each other for four. */
        fun open(context: Context, logQueries: Boolean = false, queryThreads: Int = 4): AppDatabase =
            Room.databaseBuilder(context, AppDatabase::class.java, "streamsetu.db").addMigrations(*MIGRATIONS)
                .setQueryExecutor(java.util.concurrent.Executors.newFixedThreadPool(queryThreads) { r -> Thread(r, "room-query").apply { isDaemon = true } })
                .setTransactionExecutor(java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "room-tx").apply { isDaemon = true } })
                .apply { if (logQueries) setQueryCallback({ sql, _ -> android.util.Log.i("SQL", sql.replace('\n', ' ').take(110)) }, java.util.concurrent.Executors.newSingleThreadExecutor()) }
                .addCallback(object : RoomDatabase.Callback() {
                    override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) { SearchIndex.create(db); PeopleIndex.create(db); LanLog.create(db); Profiles.create(db); ensureSortTriggers(db) }
                    // Opening a database runs no schema statements: the text index, people index, LAN log and profile tables are made when the database is created, and by the 9 to 10 step for one that already exists.
                })
                .build()
    }
}
