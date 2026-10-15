package app.streamsetu.tv

import androidx.test.core.app.ApplicationProvider
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PlexTokenCleanupTest {
    private fun database(): androidx.sqlite.db.SupportSQLiteDatabase {
        val config = SupportSQLiteOpenHelper.Configuration.builder(ApplicationProvider.getApplicationContext()).name(null)
            .callback(object : SupportSQLiteOpenHelper.Callback(1) {
                override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                    db.execSQL("CREATE TABLE movies(id TEXT, posterUrl TEXT)")
                    db.execSQL("CREATE TABLE series(id TEXT, posterUrl TEXT, backdropUrl TEXT)")
                    db.execSQL("CREATE TABLE episodes(id TEXT, imageUrl TEXT)")
                }
                override fun onUpgrade(db: androidx.sqlite.db.SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {}
            }).build()
        return FrameworkSQLiteOpenHelperFactory().create(config).writableDatabase
    }

    private fun value(db: androidx.sqlite.db.SupportSQLiteDatabase, sql: String) = db.query(sql).use { it.moveToFirst(); it.getString(0) }

    @Test fun aStoredPictureAddressLosesItsTokenAndOthersAreLeftAlone() {
        val db = database()
        db.execSQL("INSERT INTO movies VALUES('1', 'http://plex:32400/library/metadata/1/thumb/9?X-Plex-Token=SECRET'), ('2', 'http://img.example/heat.jpg')")
        db.execSQL("INSERT INTO series VALUES('s', 'http://plex:32400/a?X-Plex-Token=SECRET', 'http://plex:32400/b?X-Plex-Token=SECRET')")
        db.execSQL("INSERT INTO episodes VALUES('e', 'http://plex:32400/c?X-Plex-Token=SECRET')")
        PlexTokenCleanup.run(db)
        assertEquals("http://plex:32400/library/metadata/1/thumb/9", value(db, "SELECT posterUrl FROM movies WHERE id='1'"))
        assertEquals("http://img.example/heat.jpg", value(db, "SELECT posterUrl FROM movies WHERE id='2'"))
        assertEquals("http://plex:32400/a", value(db, "SELECT posterUrl FROM series"))
        assertEquals("http://plex:32400/b", value(db, "SELECT backdropUrl FROM series"))
        assertEquals("http://plex:32400/c", value(db, "SELECT imageUrl FROM episodes"))
        PlexTokenCleanup.run(db)                       // a second run changes nothing
        assertEquals("http://plex:32400/library/metadata/1/thumb/9", value(db, "SELECT posterUrl FROM movies WHERE id='1'"))
    }
}
