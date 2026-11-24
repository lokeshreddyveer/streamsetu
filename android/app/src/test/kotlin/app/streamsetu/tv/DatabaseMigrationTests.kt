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
    private val current = 18          // 18 makes the insert trigger run only for a row saved without a sort key (same schema as 17); 17 gives the title sort key its accents (the schema is the same as 16); 16 adds the guide hub tables; 15 makes the two TMDB tables Room tables; 14 adds the rating checks; 13 adds the metadata hub tables; 12 adds the lower-case title and year indexes (11 added the canonical identity and Smart Mix tables)

    private fun SupportSQLiteDatabase.count(table: String) = query("SELECT COUNT(*) FROM $table").use { it.moveToFirst(); it.getInt(0) }

    @Test fun everyEarlierVersionUpgradesToTheCurrentOne() {
        for (v in 1 until current) {
            helper.createDatabase("from$v", v).close()
            helper.runMigrationsAndValidate("from$v", current, false, *AppDatabase.MIGRATIONS).close()
        }
    }

    @Test fun versionSixteenToSeventeenFoldsAccentsInTheSortKeyAndKeepsAsciiKeysAndEveryRow() {
        helper.createDatabase("v16", 16).apply {
            execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('s','S','XTREAM','x',1,0,'OK',0,0,0,0,0,0)")
            for ((i, t) in listOf("Zebra", "Émile", "Ørsted", "Apple", "Straße", "తెలుగు").withIndex()) execSQL("INSERT INTO movies (id, sourceId, categoryId, title, titleSort, streamRef, addedAt) VALUES ('m$i','s','c','$t',lower('$t'),'r',$i)")          // a real version 16 file holds lower(title) (set by the 11 to 12 step and its triggers); the test helper creates no triggers, so it is written here
            close()
        }
        val db = helper.runMigrationsAndValidate("v16", 17, true, *AppDatabase.MIGRATIONS)
        fun key(id: String) = db.query("SELECT titleSort FROM movies WHERE id = '$id'").use { it.moveToFirst(); it.getString(0) }
        assertEquals("zebra", key("m0")); assertEquals("emile", key("m1")); assertEquals("orsted", key("m2")); assertEquals("apple", key("m3")); assertEquals("strasse", key("m4")); assertEquals("తెలుగు", key("m5"))
        assertEquals(6, db.count("movies"))
        // The triggers use the new key for rows written afterwards.
        db.execSQL("INSERT INTO movies (id, sourceId, categoryId, title, streamRef, addedAt) VALUES ('n1','s','c','Ünal','r',9)")
        assertEquals("unal", key("n1"))
        db.execSQL("UPDATE movies SET title = 'Éclair' WHERE id = 'n1'")
        assertEquals("eclair", key("n1"))
        // Every key the SQL gives is the key Kotlin gives (so a page cursor equals the stored column).
        for (t in listOf("Zebra", "Émile", "Ørsted", "Apple", "Straße", "తెలుగు")) assertEquals(app.streamsetu.core.model.SortKey.of(t), key("m${listOf("Zebra", "Émile", "Ørsted", "Apple", "Straße", "తెలుగు").indexOf(t)}"))
        db.close()
    }

    @Test fun versionSeventeenToEighteenKeepsEveryRowAndKeyAndMakesTheInsertTriggerRunOnlyWithoutAKey() {
        val titles = listOf("Zebra", "Émile", "Ørsted", "Straße", "తెలుగు")
        helper.createDatabase("v17", 17).apply {
            execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('s','S','XTREAM','x',1,0,'OK',0,0,0,0,0,0)")
            for ((i, t) in titles.withIndex()) execSQL("INSERT INTO movies (id, sourceId, categoryId, title, titleSort, streamRef, addedAt) VALUES ('m$i','s','c','$t','${app.streamsetu.core.model.SortKey.of(t)}','r',$i)")
            close()
        }
        val db = helper.runMigrationsAndValidate("v17", 18, true, *AppDatabase.MIGRATIONS)
        fun key(id: String) = db.query("SELECT titleSort FROM movies WHERE id = '$id'").use { it.moveToFirst(); it.getString(0) }
        for ((i, t) in titles.withIndex()) assertEquals(app.streamsetu.core.model.SortKey.of(t), key("m$i"))          // the saved keys are untouched
        assertEquals(titles.size, db.count("movies"))
        db.execSQL("INSERT INTO movies (id, sourceId, categoryId, title, streamRef, addedAt) VALUES ('n1','s','c','Ünal','r',9)")
        assertEquals("unal", key("n1"))          // no key given: the trigger makes it
        db.execSQL("INSERT INTO movies (id, sourceId, categoryId, title, titleSort, streamRef, addedAt) VALUES ('n2','s','c','Ünal','given','r',9)")
        assertEquals("given", key("n2"))          // a key given with the row is kept
        db.close()
    }

    @Test fun versionFourteenToFifteenKeepsTheRowsOfTheTwoTmdbTablesThatWereMadeOutsideRoom() {
        helper.createDatabase("tmdb", 14).apply {
            // What the older code made on first use (its own index name), with rows in it.
            execSQL("CREATE TABLE IF NOT EXISTS tmdb_ids(itemId TEXT PRIMARY KEY NOT NULL, tmdbId INTEGER NOT NULL, tv INTEGER NOT NULL, at INTEGER NOT NULL)")
            execSQL("CREATE INDEX IF NOT EXISTS tmdb_ids_by_id ON tmdb_ids(tmdbId, tv)")
            execSQL("CREATE TABLE IF NOT EXISTS tmdb_genres(itemId TEXT PRIMARY KEY NOT NULL, ids TEXT NOT NULL, at INTEGER NOT NULL)")
            execSQL("INSERT INTO tmdb_ids VALUES ('m1', 603, 0, 5), ('s1', 1396, 1, 6)"); execSQL("INSERT INTO tmdb_genres VALUES ('m1', ',28,878,', 5)")
            close()
        }
        val db = helper.runMigrationsAndValidate("tmdb", 15, true, *AppDatabase.MIGRATIONS)
        assertEquals(2, db.count("tmdb_ids")); assertEquals(1, db.count("tmdb_genres"))
        db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='tmdb_ids' AND name NOT LIKE 'sqlite_%'").use { c -> val names = buildList { while (c.moveToNext()) add(c.getString(0)) }; assertEquals(listOf("index_tmdb_ids_tmdbId_tv"), names) }
        // A database that never had them (a fresh version 14) gets them empty.
        helper.createDatabase("tmdb-none", 14).close()
        val none = helper.runMigrationsAndValidate("tmdb-none", 15, true, *AppDatabase.MIGRATIONS)
        assertEquals(0, none.count("tmdb_ids")); assertEquals(0, none.count("tmdb_genres"))
    }

    @Test fun versionNineToTenRemovesPlexTokensFromEveryPictureColumnAndTheDividerChannels() {
        helper.createDatabase("plex", 9).apply {
            execSQL("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, streamRef, addedAt) VALUES ('m1','s','c','A','http://plex:32400/library/metadata/1/thumb/9?X-Plex-Token=SECRET','r',1), ('m2','s','c','B','http://img.example/heat.jpg?size=big','r',2), ('m3','s','c','C',NULL,'r',3)")
            execSQL("INSERT INTO series (id, sourceId, categoryId, title, posterUrl, backdropUrl, providerId, addedAt) VALUES ('s1','s','c','S','http://plex:32400/a?X-Plex-Token=SECRET','http://plex:32400/b?X-Plex-Token=SECRET','p',1), ('s2','s','c','T','http://img.example/s.jpg','http://img.example/b.jpg','p',2)")
            execSQL("INSERT INTO episodes (id, seriesId, season, number, title, imageUrl, streamRef) VALUES ('e1','s1',1,1,'E','http://plex:32400/c?X-Plex-Token=SECRET','r'), ('e2','s1',1,2,'F','http://img.example/e.jpg','r')")
            execSQL("INSERT INTO channels (id, sourceId, categoryId, name, streamRef, catchupDays, sortOrder, addedAt, isRadio) VALUES ('c1','s','g','BBC One','r',0,1,1,0), ('c2','s','g','#### SPORTS ####','r',0,2,1,0), ('c3','s','g','  ','r',0,3,1,0), ('c4','s','g','-----','r',0,4,1,0)")
            close()
        }
        val db = helper.runMigrationsAndValidate("plex", 10, false, *AppDatabase.MIGRATIONS)
        fun one(sql: String) = db.query(sql).use { it.moveToFirst(); it.getString(0) }
        assertEquals("http://plex:32400/library/metadata/1/thumb/9", one("SELECT posterUrl FROM movies WHERE id='m1'"))
        assertEquals("http://img.example/heat.jpg?size=big", one("SELECT posterUrl FROM movies WHERE id='m2'"))                  // an address without the token is left as it was
        assertEquals("http://plex:32400/a", one("SELECT posterUrl FROM series WHERE id='s1'"))
        assertEquals("http://plex:32400/b", one("SELECT backdropUrl FROM series WHERE id='s1'"))
        assertEquals("http://img.example/s.jpg", one("SELECT posterUrl FROM series WHERE id='s2'"))
        assertEquals("http://plex:32400/c", one("SELECT imageUrl FROM episodes WHERE id='e1'"))
        assertEquals("http://img.example/e.jpg", one("SELECT imageUrl FROM episodes WHERE id='e2'"))
        assertEquals("1", one("SELECT COUNT(*) FROM channels"))                                                                  // the three dividers are gone, the real channel stays
        assertEquals("BBC One", one("SELECT name FROM channels"))
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


    /** Every table of the database, row by row, as text (blobs as hex), in row order: for "byte for byte the same after an upgrade". */
    private fun SupportSQLiteDatabase.dump(tables: List<String>): Map<String, List<String>> = tables.associateWith { t ->
        query("SELECT * FROM `$t` ORDER BY rowid").use { c ->
            buildList { while (c.moveToNext()) add((0 until c.columnCount).joinToString("|") { i -> when (c.getType(i)) { android.database.Cursor.FIELD_TYPE_NULL -> "NULL"; android.database.Cursor.FIELD_TYPE_BLOB -> c.getBlob(i).joinToString("") { b -> "%02x".format(b) }; else -> c.getString(i) } }) }
        }
    }
    private fun SupportSQLiteDatabase.userTables(): List<String> = query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%' AND name != 'room_master_table' AND name NOT LIKE 'search_fts%' ORDER BY name").use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }

    @Test fun versionTenToElevenKeepsEveryOldRowIdenticalAndAddsTheNewTablesEmpty() {
        var oldTables: List<String> = emptyList(); var oldDump: Map<String, List<String>> = emptyMap()
        helper.createDatabase("ten", 10).apply {
            execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('s1','One','XTREAM','x',1,5,'OK',0,0,1,2,1,0), ('s2','Two','XTREAM','y',1,6,'OK',1,0,0,2,0,0)")
            execSQL("INSERT INTO categories (id, sourceId, kind, name, sortOrder) VALUES ('c1','s1','MOVIE','HINDI | NEW',0), ('c2','s2','MOVIE','HINDI | NEW',0)")
            execSQL("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES ('m1','s1','c1','Leo (2023) (Tamil) FHD','http://img/1.jpg',2023,'7.1','a plot','ref:1',100), ('m2','s2','c2','Leo 2023 Hindi','http://img/2.jpg',2023,'7.1',NULL,'ref:2',200)")
            execSQL("INSERT INTO series (id, sourceId, categoryId, title, posterUrl, backdropUrl, year, rating, plot, providerId, addedAt) VALUES ('t1','s1','c1','Show','http://img/s.jpg',NULL,2020,NULL,NULL,'p1',50)")
            execSQL("INSERT INTO channels (id, sourceId, categoryId, name, streamRef, catchupDays, sortOrder, addedAt, isRadio) VALUES ('ch1','s1','g','BBC One','r',0,1,1,0)")
            execSQL("INSERT INTO favorites (itemId, kind, listId, addedAt) VALUES ('m1','MOVIE','favorites',9)")
            execSQL("INSERT INTO progress (itemId, kind, seriesId, positionMs, durationMs, updatedAt, completed) VALUES ('m1','MOVIE',NULL,600000,6000000,1000,0), ('m2','MOVIE',NULL,0,6000000,2000,1)")
            execSQL("INSERT INTO watch_log (itemId, kind, title, playedAt) VALUES ('m1','MOVIE','Leo',1000)")
            execSQL("INSERT INTO folder_prefs (scope, folderId, favorite, pinned, hidden, locked, alias, sortIndex) VALUES ('MOVIE','c1',0,0,0,1,NULL,-1)")
            execSQL("INSERT INTO catalog_fingerprints (sourceId, fingerprint, rows, version) VALUES ('s1', 7, 4, 2)")
            oldTables = userTables(); oldDump = dump(oldTables)
            close()
        }
        val db = helper.runMigrationsAndValidate("ten", 11, true, *AppDatabase.MIGRATIONS)
        val after = db.dump(oldTables)
        for (t in oldTables) assertEquals("table $t is identical after the upgrade", oldDump[t], after[t])
        assertTrue("rows were really compared", oldDump.getValue("movies").size == 2 && oldDump.getValue("progress").size == 2)
        for (t in listOf("content_identity", "source_twin", "rec_dismissed", "smartmix_shown", "smartmix_state", "folder_recent")) assertEquals("new table $t starts empty", 0, db.count(t))
        fun hasIndex(name: String) = db.query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = '$name'").use { it.moveToFirst(); it.getInt(0) == 1 }
        for (i in listOf("index_movies_sourceId_categoryId_addedAt", "index_series_sourceId_categoryId_addedAt", "index_content_identity_kind_identityKey_year", "index_content_identity_sourceId_kind", "index_content_identity_folderKey")) assertTrue(i, hasIndex(i))
        // the browse path of a folder, newest first, now reads one index and sorts nothing
        val plan = db.query("EXPLAIN QUERY PLAN SELECT * FROM movies WHERE sourceId = 's1' AND categoryId = 'c1' ORDER BY addedAt DESC LIMIT 20").use { c -> buildString { while (c.moveToNext()) append(c.getString(3)).append(" | ") } }
        assertTrue(plan, "index_movies_sourceId_categoryId_addedAt" in plan && "TEMP B-TREE" !in plan)
        db.close()
    }

    @Test fun theNewTablesWorkAfterTheUpgradeAndAnOlderFileKeepsOpeningNormally() {
        helper.createDatabase("ten2", 10).close()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val room = Room.databaseBuilder(context, AppDatabase::class.java, "ten2").addMigrations(*AppDatabase.MIGRATIONS).build()
        try {
            kotlinx.coroutines.runBlocking {
                room.identity().putAll(listOf(app.streamsetu.core.data.db.ContentIdentityEntity("m1", "MOVIE", "s", "leo", 2023, "Tamil", 4, false, "MOVIE|hindi new", 1L, 1)))
                assertEquals("leo", room.identity().byItemIds(listOf("m1")).single().identityKey)
            }
        } finally { room.close() }
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
