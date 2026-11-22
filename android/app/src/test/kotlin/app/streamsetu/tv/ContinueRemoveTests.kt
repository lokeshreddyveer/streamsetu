package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.LanLog
import app.streamsetu.core.data.db.ProgressEntity
import app.streamsetu.core.data.repo.UserRepository
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Removing titles from Continue Watching only writes a marker of its own: every resume point, watched mark and the order stay intact, Undo takes the marker away. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ContinueRemoveTests {
    private lateinit var db: AppDatabase
    private lateinit var user: UserRepository

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), AppDatabase::class.java).allowMainThreadQueries()
            .addCallback(object : androidx.room.RoomDatabase.Callback() { override fun onCreate(db: SupportSQLiteDatabase) { LanLog.create(db) } }).build()
        user = UserRepository(db)
        runBlocking {
            db.user().putProgress(ProgressEntity("m1", "MOVIE", null, 600_000, 6_000_000, 1_000, false))
            db.user().putProgress(ProgressEntity("e1", "EPISODE", "s1", 900_000, 2_400_000, 2_000, false))
            db.user().putProgress(ProgressEntity("done", "MOVIE", null, 0, 5_000_000, 3_000, true))          // watched: not in Continue Watching
        }
    }
    @After fun tearDown() = db.close()

    private fun row() = runBlocking { user.continueWatching(50).first().map { it.itemId } }
    private fun deletedInLanLog(id: String) = db.openHelper.readableDatabase.query("SELECT deleted FROM lan_log WHERE kind = 'prog' AND key = ?", arrayOf(id)).use { c -> c.moveToFirst() && c.getInt(0) == 1 }

    @Test fun removingOnlyWritesAMarkerAndKeepsTheResumePointIntact() = runBlocking {
        val before = db.user().progress("m1")!!
        val prev = user.hideFromContinue(listOf("m1"), at = 1_500)
        assertEquals(listOf("e1"), row())
        assertEquals("progress, position and watched mark are untouched", before, db.user().progress("m1"))
        assertEquals(listOf("m1" to null), prev)
        assertEquals(mapOf("m1" to 1_500L), user.continueHidden())
    }

    @Test fun undoTakesTheMarkerAwayAndTheTitleIsBackInTheSamePlace() = runBlocking {
        val order = row()
        val prev = user.hideFromContinue(listOf("m1"))
        user.restoreContinueMarkers(prev)
        assertEquals(order, row())
        assertTrue(user.continueHidden().isEmpty())
    }

    @Test fun clearAllHidesEverythingKeepsEveryRecordAndCanBeUndone() = runBlocking {
        val before = listOf(db.user().progress("m1"), db.user().progress("e1"), db.user().progress("done"))
        val prev = user.hideAllFromContinue()
        assertEquals(setOf("m1", "e1"), prev.map { it.first }.toSet())
        assertTrue(row().isEmpty())
        assertEquals("nothing deleted or changed", before, listOf(db.user().progress("m1"), db.user().progress("e1"), db.user().progress("done")))
        user.restoreContinueMarkers(prev)
        assertEquals(setOf("m1", "e1"), row().toSet())
    }

    @Test fun removalIsNotADeletionForSyncOnTheHomeNetwork() = runBlocking {
        user.hideFromContinue(listOf("e1"))
        assertTrue("no deletion is logged", !deletedInLanLog("e1"))
    }

    @Test fun playingItAgainBringsItBack() = runBlocking {
        user.hideFromContinue(listOf("m1"), at = 1_500)
        assertEquals(listOf("e1"), row())
        db.user().putProgress(ProgressEntity("m1", "MOVIE", null, 700_000, 6_000_000, 4_000, false))
        assertEquals(listOf("m1", "e1"), row())
    }

    @Test fun undoOfASecondRemovalKeepsTheEarlierMarker() = runBlocking {
        user.hideFromContinue(listOf("m1"), at = 1_500)
        val prev = user.hideFromContinue(listOf("m1"), at = 1_800)
        user.restoreContinueMarkers(prev)
        assertEquals(mapOf("m1" to 1_500L), user.continueHidden())
    }
}
