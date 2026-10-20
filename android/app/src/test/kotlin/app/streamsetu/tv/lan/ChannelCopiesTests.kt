package app.streamsetu.tv.lan

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.ChannelEntity
import app.streamsetu.core.data.db.SourceEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ChannelCopiesTests {
    private lateinit var db: AppDatabase

    @Before fun setUp() { db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), AppDatabase::class.java).allowMainThreadQueries().build() }
    @After fun tearDown() { db.close() }

    private fun source(id: String, enabled: Boolean = true, draft: Boolean = false) = SourceEntity(id, id, "XTREAM", "http://x", "u", null, enabled, 0, "OK", 0, draft)
    private fun channel(id: String, source: String, name: String, epg: String? = null) = ChannelEntity(id, source, null, name, null, null, "ref", epg, 0, 0)

    @Test fun theSameChannelInAnotherEnabledConnectionIsFound() = runBlocking {
        listOf(source("a"), source("b"), source("off", enabled = false), source("draft", draft = true)).forEach { db.sources().upsert(it) }
        db.catalog().putChannels(listOf(channel("1", "a", "Star Sports 1"), channel("2", "b", "star sports 1"), channel("3", "b", "Zee News"), channel("4", "off", "Star Sports 1"), channel("5", "draft", "Star Sports 1")))
        assertEquals(listOf("2"), db.catalog().channelCopiesElsewhere("a", "Star Sports 1", "").map { it.id })
    }

    @Test fun aGuideIdMatchesWhenTheNamesDiffer() = runBlocking {
        listOf(source("a"), source("b")).forEach { db.sources().upsert(it) }
        db.catalog().putChannels(listOf(channel("1", "a", "BBC One HD", "bbc1.uk"), channel("2", "b", "BBC 1 London", "bbc1.uk")))
        assertEquals(listOf("2"), db.catalog().channelCopiesElsewhere("a", "BBC One HD", "bbc1.uk").map { it.id })
    }
}
