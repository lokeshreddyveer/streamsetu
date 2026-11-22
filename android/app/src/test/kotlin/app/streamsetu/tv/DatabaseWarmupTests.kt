package app.streamsetu.tv

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.DatabaseOpener
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The database opens on its own thread at start; callers only wait on a signal, and everyone gets the one instance. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class DatabaseWarmupTests {
    @Test fun theFirstOpenRunsOnItsOwnThreadAndSignalsWhenReady() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        var createdOn: String? = null
        val opener = DatabaseOpener { createdOn = Thread.currentThread().name; Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).build() }
        opener.start(); opener.start()
        runBlocking { withTimeout(30_000) { opener.ready.await() } }
        assertEquals("db-warmup", createdOn)
        assertTrue("opened (took ${opener.openedAtMs} ms here)", opener.openedAtMs >= 0)
        assertSame(opener.instance(), opener.instance())
        assertTrue(opener.instance().isOpen)
        opener.instance().close()
    }
}
