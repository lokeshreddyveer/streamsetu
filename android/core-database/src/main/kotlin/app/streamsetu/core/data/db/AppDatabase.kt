package app.streamsetu.core.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [SourceEntity::class, CategoryEntity::class, ChannelEntity::class, MovieEntity::class, SeriesEntity::class,
        EpisodeEntity::class, EpgEntity::class, FavoriteEntity::class, ProgressEntity::class, WatchLogEntity::class,
        LibraryEntity::class, LibraryMemberEntity::class, FolderPrefEntity::class,
        NewEpisodeEntity::class, CollectionEntity::class, CollectionItemEntity::class, OverrideEntity::class, EpgChannelEntity::class,
        WatchTimeEntity::class, ChannelPrefEntity::class, ReminderEntity::class],
    version = 6,
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

    companion object {
        /** Adds drafts and cached counts to playlists, combined libraries, and folder arrangements. Nothing existing is touched. */
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

        fun open(context: Context): AppDatabase =
            Room.databaseBuilder(context, AppDatabase::class.java, "streamsetu.db").addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6)
                .addCallback(object : RoomDatabase.Callback() {
                    override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) { SearchIndex.create(db); PeopleIndex.create(db) }
                    override fun onOpen(db: androidx.sqlite.db.SupportSQLiteDatabase) { SearchIndex.create(db); PeopleIndex.create(db) }
                })
                .build()
    }
}
