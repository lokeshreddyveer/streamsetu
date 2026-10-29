package app.streamsetu.tv.sports.personal

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.Profiles
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The Sports tables arrive by an explicit upgrade from the schema people have now, and are separate from everything else. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
class SportsMigrationTests {
    @get:Rule val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), AppDatabase::class.java)

    private fun SupportSQLiteDatabase.count(table: String) = query("SELECT COUNT(*) FROM $table").use { it.moveToFirst(); it.getInt(0) }
    private fun SupportSQLiteDatabase.follow(profile: String, kind: String = "SPORT", key: String = "cricket", verb: String = "INSERT") =
        execSQL("$verb INTO sports_follows (profileId, kind, sport, normKey, displayName, createdAt) VALUES ('$profile', '$kind', 'CRICKET', '$key', 'Cricket', 1)")
    private fun SupportSQLiteDatabase.reminder(id: String, profile: String = "main", slot: Int = 1, verb: String = "INSERT") =
        execSQL("$verb INTO sports_reminders (id, profileId, sport, identity, competitionKey, participantsKey, startMs, endMs, leadMs, slot, occurrence, siblings, matchedEventId, candidateChannelIds, status, notifiedAt, bannerAt, kept, createdAt, updatedAt) VALUES ('$id', '$profile', 'CRICKET', 'cricket|head_to_head|australia|india|', NULL, 'australia|india', 10, 20, 900000, $slot, 0, 1, NULL, '', 'SCHEDULED', 0, 0, 0, 1, 1)")

    @Test fun theCurrentProductionSchemaUpgradesAndTheSportsTablesStartEmpty() {
        helper.createDatabase("prod", 7).apply {
            execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('s','Home','XTREAM','x',1,0,'OK',0,0,5,0,0,0)")
            execSQL("INSERT INTO favorites (itemId, kind, listId, addedAt) VALUES ('m1','MOVIE','favorites',1)")
            close()
        }
        val db = helper.runMigrationsAndValidate("prod", 8, false, *AppDatabase.MIGRATIONS)
        assertEquals(0, db.count("sports_follows")); assertEquals(0, db.count("sports_reminders"))
        assertEquals("what was there is untouched", 1, db.count("sources")); assertEquals(1, db.count("favorites"))
        db.close()
    }

    @Test fun everyEarlierVersionStillReachesTheSportsSchema() {
        for (v in 1 until 8) { helper.createDatabase("v$v", v).close(); helper.runMigrationsAndValidate("v$v", 8, false, *AppDatabase.MIGRATIONS).close() }
    }

    @Test fun duplicateFollowsAndRemindersAreRefusedByTheDatabase() {
        val db = helper.createDatabase("dup", 8)
        db.follow("main"); db.follow("main", verb = "INSERT OR IGNORE"); assertEquals(1, db.count("sports_follows"))
        try { db.follow("main"); fail("a second identical follow must be refused") } catch (e: android.database.sqlite.SQLiteConstraintException) { }
        db.follow("kid"); assertEquals("another profile may follow the same thing", 2, db.count("sports_follows"))
        db.reminder("a"); try { db.reminder("b"); fail("the same event and slot twice must be refused") } catch (e: android.database.sqlite.SQLiteConstraintException) { }
        db.reminder("c", slot = 2); assertEquals("the same sides at another time are another reminder", 2, db.count("sports_reminders"))
        db.close()
    }

    @Test fun theIndexesExistAndTheProfileQueriesUseThem() {
        val db = helper.createDatabase("idx", 8)
        for (i in 0 until 500) db.reminder("r$i", slot = i, profile = if (i % 2 == 0) "main" else "kid")
        val names = db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name IN ('sports_follows', 'sports_reminders')").use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }
        for (n in listOf("index_sports_follows_profileId", "index_sports_follows_profileId_kind_sport_normKey", "index_sports_reminders_profileId", "index_sports_reminders_identity", "index_sports_reminders_startMs", "index_sports_reminders_status", "index_sports_reminders_profileId_sport_identity_slot")) assertTrue("$n in $names", n in names)
        fun plan(sql: String) = db.query("EXPLAIN QUERY PLAN $sql").use { c -> buildString { while (c.moveToNext()) append(c.getString(3)).append(" | ") } }
        assertTrue(plan("SELECT * FROM sports_reminders WHERE profileId = 'main' ORDER BY startMs"), "USING INDEX" in plan("SELECT * FROM sports_reminders WHERE profileId = 'main' ORDER BY startMs").uppercase() || "INDEX" in plan("SELECT * FROM sports_reminders WHERE profileId = 'main'").uppercase())
        assertTrue("INDEX" in plan("SELECT * FROM sports_reminders WHERE status IN ('SCHEDULED') AND endMs > 5").uppercase())
        db.close()
    }

    @Test fun removingAProfileRemovesItsSportsRowsAndNoOnesElse() {
        val db = helper.createDatabase("prof", 8)
        Profiles.create(db)
        val kid = Profiles.add(db, "Kid", false, null)!!
        db.follow("main"); db.follow(kid.id); db.reminder("m", "main"); db.reminder("k", kid.id, slot = 2)
        assertTrue(Profiles.remove(db, kid.id))
        assertEquals(1, db.count("sports_follows")); assertEquals(1, db.count("sports_reminders"))
        db.query("SELECT profileId FROM sports_reminders").use { it.moveToFirst(); assertEquals("main", it.getString(0)) }
        db.close()
    }

    @Test fun deletingAPlaylistOrItsGuideLeavesTheRemindersAsTheyWere() {
        val db = helper.createDatabase("guide", 8)
        db.execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('s','Home','XTREAM','x',1,0,'OK',0,0,5,0,0,0)")
        db.reminder("a"); db.follow("main")
        db.execSQL("DELETE FROM sources"); db.execSQL("DELETE FROM epg"); db.execSQL("DELETE FROM epg_channels")
        assertEquals(1, db.count("sports_reminders")); assertEquals(1, db.count("sports_follows"))
        db.close()
    }

    @Test fun thereIsNoDestructiveFallback() {
        val src = java.io.File("../core-database/src/main/kotlin/app/streamsetu/core/data/db/AppDatabase.kt").readText()
        assertFalse(src.contains("fallbackToDestructiveMigration")); assertTrue(src.contains("MIGRATION_7_8"))
    }
}
