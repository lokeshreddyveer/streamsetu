package app.streamsetu.tv

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.EpgEntity
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgIds
import app.streamsetu.core.sync.ChannelGuide
import app.streamsetu.core.sync.EpgService
import app.streamsetu.core.sync.channelGuide
import app.streamsetu.core.sync.programmesFor
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The Live TV screen's guide and the TV Guide read the same data through one operation; these keep that operation honest. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ChannelGuideTests {
    private lateinit var db: AppDatabase
    private lateinit var epg: EpgService
    private val now = 10_000_000_000L
    private fun ch(id: String, name: String, epgId: String?) = Channel(id, "A", null, name, null, null, "ref", epgId)

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        epg = EpgService(db)
    }
    @After fun close() { db.close() }

    @Test fun aMatchedChannelGetsItsProgrammesFromThirtyMinutesBackToThreeHoursAhead() = runBlocking {
        val min = 60_000L
        db.epg().put(listOf(
            EpgEntity(EpgIds.scope("A", "bbc1"), now - 90 * min, now - 40 * min, "too early", null),
            EpgEntity(EpgIds.scope("A", "bbc1"), now - 45 * min, now + 15 * min, "on now", null),
            EpgEntity(EpgIds.scope("A", "bbc1"), now + 15 * min, now + 75 * min, "next", null),
            EpgEntity(EpgIds.scope("A", "bbc1"), now + 5 * 60 * min, now + 6 * 60 * min, "too late", null),
        ))
        val g = epg.channelGuide(db, ch("A:1", "BBC One", "bbc1"), now, 0L)
        assertTrue(g is ChannelGuide.Matched)
        assertEquals(listOf("on now", "next"), (g as ChannelGuide.Matched).programmes.map { it.title })
    }

    @Test fun theTimeOffsetIsAppliedTheSameWayTheTvGuideAppliesIt() = runBlocking {
        val min = 60_000L; val shift = 120 * min
        db.epg().put(listOf(EpgEntity(EpgIds.scope("A", "bbc1"), now - 2 * 60 * min + 10 * min, now - 2 * 60 * min + 70 * min, "stored two hours early", null)))
        val c = ch("A:1", "BBC One", "bbc1")
        val g = epg.channelGuide(db, c, now, shift) as ChannelGuide.Matched
        assertEquals(1, g.programmes.size)
        assertEquals("shown at its real time", now - 2 * 60 * min + 10 * min + shift, g.programmes.single().startMs)
        // and the TV Guide's own call returns exactly the same thing
        val viaGuide = epg.programmesFor(db, listOf(c), mapOf(c.id to g.guideId), now - 30 * min, now + 3 * 60 * min, shift)[c.id]!!
        assertEquals(g.programmes.map { it.startMs }, viaGuide.map { it.startMs })
    }

    @Test fun aChannelWithNoMatchIsUnmatchedNotAnEmptyGuide() = runBlocking {
        db.epg().put(listOf(EpgEntity(EpgIds.scope("A", "bbc1"), now, now + 1000, "Show", null)))
        assertTrue(epg.channelGuide(db, ch("A:2", "Unknown Channel", "nope"), now, 0L) is ChannelGuide.Unmatched)
    }

    @Test fun aMatchedChannelWithNothingInTheWindowIsMatchedWithNoProgrammes() = runBlocking {
        db.epg().put(listOf(EpgEntity(EpgIds.scope("A", "bbc1"), now + 10 * 3_600_000L, now + 11 * 3_600_000L, "much later", null)))
        val g = epg.channelGuide(db, ch("A:1", "BBC One", "bbc1"), now, 0L)
        assertTrue(g is ChannelGuide.Matched); assertTrue((g as ChannelGuide.Matched).programmes.isEmpty())
    }

    @Test fun resolvingTheSameChannelsAgainReturnsTheSameAnswerAndAChangedGuideIsReadAgain() = runBlocking {
        db.epg().put(listOf(EpgEntity(EpgIds.scope("A", "bbc1"), now, now + 60_000L, "x", null)))
        val channels = listOf(ch("A:1", "BBC One", "bbc1"), ch("A:2", "Nothing", null))
        val first = epg.resolve(channels)
        assertEquals(mapOf("A:1" to EpgIds.scope("A", "bbc1")), first)
        assertSame("the second call reuses the first answer", first, epg.resolve(channels))
        assertNotSame("a different channel list is worked out again", first, epg.resolve(channels + ch("A:3", "Other", "zzz")))
    }
}
