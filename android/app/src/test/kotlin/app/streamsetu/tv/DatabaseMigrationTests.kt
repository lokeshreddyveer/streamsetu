package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.streamsetu.core.data.db.AppDatabase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The saved library must survive every upgrade: from each earlier layout, with a realistic amount of data, and a failed upgrade must leave the old database as it was. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
/** (The text index, search_fts, is a virtual table made outside Room, so dropped-table checking is off.) */
class DatabaseMigrationTests {
    @get:Rule val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), AppDatabase::class.java)
    private val current = 7

    private fun SupportSQLiteDatabase.count(table: String) = query("SELECT COUNT(*) FROM $table").use { it.moveToFirst(); it.getInt(0) }

    @Test fun everyEarlierVersionUpgradesToTheCurrentOne() {
        for (v in 1 until current) {
            helper.createDatabase("from$v", v).close()
            helper.runMigrationsAndValidate("from$v", current, false, *AppDatabase.MIGRATIONS).close()
        }
    }

    @Test fun aLargeLibraryUpgradesWithItsRowsAndGetsTheIndexes() {
        helper.createDatabase("big", 6).apply {
            beginTransaction()
            try {
                execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('s','S','XTREAM','x',1,0,'OK',0,0,0,0,0,0)")
                for (i in 0 until 100_000) execSQL("INSERT INTO movies (id, sourceId, categoryId, title, streamRef, addedAt) VALUES ('m$i','s','c${i % 200}','Title $i','r',$i)")
                for (i in 0 until 20_000) execSQL("INSERT INTO channels (id, sourceId, categoryId, name, streamRef, catchupDays, sortOrder, addedAt, isRadio) VALUES ('c$i','s','g${i % 100}','Ch $i','r',0,$i,$i,0)")
                for (i in 0 until 2_000) execSQL("INSERT INTO favorites (itemId, kind, listId, addedAt) VALUES ('m$i','MOVIE','favorites',$i)")
                setTransactionSuccessful()
            } finally { endTransaction() }
            close()
        }
        val t = System.currentTimeMillis()
        val db = helper.runMigrationsAndValidate("big", current, false, *AppDatabase.MIGRATIONS)
        val took = System.currentTimeMillis() - t
        println("upgrade of 100k movies + 20k channels took $took ms")
        assertEquals(100_000, db.count("movies")); assertEquals(20_000, db.count("channels")); assertEquals(2_000, db.count("favorites"))
        assertTrue("upgrade took $took ms", took < 20_000)
        db.query("SELECT COUNT(*) FROM sqlite_master WHERE name = 'catalog_fingerprints'").use { it.moveToFirst(); assertEquals(1, it.getInt(0)) }      // the new table exists, the old rows are untouched (counted above)
        // The browsing queries use the new indexes (EXPLAIN QUERY PLAN), not a scan of the whole table followed by a sort.
        fun plan(sql: String) = db.query("EXPLAIN QUERY PLAN $sql").use { c -> buildString { while (c.moveToNext()) append(c.getString(3)).append(" | ") } }
        val newest = plan("SELECT * FROM movies x WHERE x.sourceId IN ('s') ORDER BY x.addedAt DESC, x.rowid DESC LIMIT 30")
        assertTrue("newest movies: $newest", "index_movies_sourceId_addedAt" in newest)
        val folder = plan("SELECT * FROM channels x WHERE x.sourceId IN ('s') AND x.categoryId = 'g5' ORDER BY x.rowid LIMIT 150")
        assertTrue("a folder's channels: $folder", "index_channels_sourceId_categoryId" in folder)
        val list = plan("SELECT itemId FROM favorites WHERE listId = 'favorites' ORDER BY addedAt DESC")
        assertTrue("a list: $list", "index_favorites_listId_addedAt" in list)
        db.close()
    }

    @Test fun aFailedUpgradeLeavesTheOldDatabaseUntouched() {
        helper.createDatabase("fail", 6).apply {
            execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('s','S','XTREAM','x',1,0,'OK',0,0,0,0,0,0)")
            execSQL("INSERT INTO movies (id, sourceId, categoryId, title, streamRef, addedAt) VALUES ('m','s','c','T','r',1)")
            close()
        }
        val context = ApplicationProvider.getApplicationContext<Context>()
        val broken = object : androidx.room.migration.Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) { db.execSQL("CREATE TABLE catalog_fingerprints (x INTEGER)"); db.execSQL("THIS IS NOT SQL") }
        }
        val room = Room.databaseBuilder(context, AppDatabase::class.java, "fail").addMigrations(*AppDatabase.MIGRATIONS.take(5).toTypedArray(), broken).build()
        try { room.openHelper.writableDatabase; fail("the upgrade should have failed") } catch (_: Exception) {} finally { room.close() }
        val raw = android.database.sqlite.SQLiteDatabase.openDatabase(context.getDatabasePath("fail").path, null, android.database.sqlite.SQLiteDatabase.OPEN_READONLY)
        raw.use {
            assertEquals(6, it.version)                                                                              // still the old version
            it.rawQuery("SELECT COUNT(*) FROM movies", null).use { c -> c.moveToFirst(); assertEquals(1, c.getInt(0)) }       // the data is still there
            it.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE name = 'catalog_fingerprints'", null).use { c -> c.moveToFirst(); assertEquals(0, c.getInt(0)) }   // half an upgrade was rolled back
        }
    }

    @Test fun aDatabaseAlreadyAtTheCurrentVersionReopensNormally() {
        helper.createDatabase("now", current).apply { execSQL("INSERT INTO catalog_fingerprints (sourceId, fingerprint, rows, version) VALUES ('s', 1, 2, 1)"); close() }
        val context = ApplicationProvider.getApplicationContext<Context>()
        val room = Room.databaseBuilder(context, AppDatabase::class.java, "now").addMigrations(*AppDatabase.MIGRATIONS).build()
        try { assertEquals(1L, kotlinx.coroutines.runBlocking { room.catalog().fingerprint("s") }?.fingerprint) } finally { room.close() }
    }

    @Test fun noDestructiveFallbackIsEnabled() {
        val source = java.io.File("../core-database/src/main/kotlin/app/streamsetu/core/data/db/AppDatabase.kt").readText()
        assertTrue(!source.contains("fallbackToDestructiveMigration"))
    }
}
