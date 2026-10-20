package app.streamsetu.tv.lan

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.LanLog
import app.streamsetu.core.data.db.Profiles
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ProfilesTests {
    private lateinit var room: AppDatabase
    private val db get() = room.openHelper.writableDatabase

    @Before fun setUp() {
        room = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), AppDatabase::class.java).allowMainThreadQueries().build()
        LanLog.create(db); Profiles.create(db)
    }
    @After fun tearDown() { room.close() }

    private fun count(table: String) = db.query("SELECT COUNT(*) FROM $table").use { it.moveToFirst(); it.getInt(0) }

    @Test fun eachProfileKeepsItsOwnFavoritesAndProgress() {
        db.execSQL("INSERT INTO favorites(itemId, kind, listId, addedAt) VALUES('a:m:1', 'movie', 'favourites', 1)")
        db.execSQL("INSERT INTO progress(itemId, kind, seriesId, positionMs, durationMs, updatedAt, completed) VALUES('a:m:1', 'movie', NULL, 60000, 600000, 1, 0)")
        val other = Profiles.add(db, "Anya", false, null)!!
        Profiles.swap(db, Profiles.MAIN, other.id)
        assertEquals(0, count("favorites")); assertEquals(0, count("progress"))
        db.execSQL("INSERT INTO favorites(itemId, kind, listId, addedAt) VALUES('a:m:2', 'movie', 'favourites', 2)")
        Profiles.swap(db, other.id, Profiles.MAIN)
        assertEquals(1, count("favorites")); assertEquals(1, count("progress"))
        db.query("SELECT itemId FROM favorites").use { it.moveToFirst(); assertEquals("a:m:1", it.getString(0)) }
        Profiles.swap(db, Profiles.MAIN, other.id)
        assertEquals(1, count("favorites")); assertEquals(0, count("progress"))
    }

    @Test fun switchingIsNotLoggedAsDeletions() {
        db.execSQL("INSERT INTO favorites(itemId, kind, listId, addedAt) VALUES('a:m:1', 'movie', 'favourites', 1)")
        val before = db.query("SELECT COUNT(*) FROM lan_log WHERE deleted = 1").use { it.moveToFirst(); it.getInt(0) }
        val other = Profiles.add(db, "B", false, null)!!
        Profiles.swap(db, Profiles.MAIN, other.id)
        val after = db.query("SELECT COUNT(*) FROM lan_log WHERE deleted = 1").use { it.moveToFirst(); it.getInt(0) }
        assertEquals(before, after)
    }

    @Test fun pinsAndNames() {
        assertNull(Profiles.add(db, "Kid", true, null))
        assertNull(Profiles.add(db, "Kid", true, "12"))
        val kid = Profiles.add(db, "Kid", true, "1234")!!
        assertNull(Profiles.add(db, "kid", false, null))
        assertTrue(Profiles.checkPin(db, kid.id, "1234")); assertFalse(Profiles.checkPin(db, kid.id, "0000"))
        assertFalse(Profiles.remove(db, Profiles.MAIN))
        assertTrue(Profiles.remove(db, kid.id))
        assertNotNull(Profiles.list(db).firstOrNull { it.id == Profiles.MAIN })
    }
}
