package app.streamsetu.tv

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.EpgChannelEntity
import app.streamsetu.core.data.db.EpgEntity
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgIds
import app.streamsetu.core.sync.EpgService
import app.streamsetu.core.sync.window
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Two playlists that give different channels the same guide id must each keep their own programmes. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class GuideIsolationTests {
    private lateinit var db: AppDatabase
    private lateinit var epg: EpgService
    private fun ch(id: String, source: String, name: String, epgId: String?) = Channel(id, source, null, name, null, null, "ref", epgId)

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        epg = EpgService(db)
    }
    @After fun close() { db.close() }

    @Test fun theSameGuideIdInTwoPlaylistsKeepsEachPlaylistsOwnProgrammes() = runBlocking {
        db.epg().put(listOf(
            EpgEntity(EpgIds.scope("A", "bbc1"), 1000, 2000, "News from A", null),
            EpgEntity(EpgIds.scope("B", "bbc1"), 1000, 2000, "Film from B", null),
        ))
        val a = ch("A:ch:1", "A", "One", "bbc1"); val b = ch("B:ch:1", "B", "One", "bbc1")
        val resolved = epg.resolve(listOf(a, b))
        assertEquals(EpgIds.scope("A", "bbc1"), resolved[a.id]); assertEquals(EpgIds.scope("B", "bbc1"), resolved[b.id])
        val rows = epg.window(db, resolved.values.toList(), 0, 5000)
        assertEquals("News from A", rows[resolved[a.id]]!!.single().title)
        assertEquals("Film from B", rows[resolved[b.id]]!!.single().title)
    }

    @Test fun aChannelWithoutItsOwnPlaylistsGuideStillUsesAnotherPlaylistsGuideForTheSameId() = runBlocking {
        db.epg().put(listOf(EpgEntity(EpgIds.scope("A", "itv"), 1000, 2000, "Show", null)))
        val b = ch("B:ch:7", "B", "ITV", "itv")
        assertEquals(EpgIds.scope("A", "itv"), epg.resolve(listOf(b))[b.id])
    }

    @Test fun aGuideStoredBeforeIdsWereScopedStillMatches() = runBlocking {
        db.epg().put(listOf(EpgEntity("old1", 1000, 2000, "Old", null)))
        val c = ch("A:ch:2", "A", "Anything", "old1")
        assertEquals("old1", epg.resolve(listOf(c))[c.id])
    }

    @Test fun nameMatchPrefersTheChannelsOwnPlaylist() = runBlocking {
        db.epg().put(listOf(EpgEntity(EpgIds.scope("A", "x"), 1000, 2000, "A show", null), EpgEntity(EpgIds.scope("B", "y"), 1000, 2000, "B show", null)))
        db.extras().putEpgChannels(listOf(EpgChannelEntity(EpgIds.scope("A", "x"), "sky sports"), EpgChannelEntity(EpgIds.scope("B", "y"), "sky sports")))
        val b = ch("B:ch:3", "B", "Sky Sports HD", null)
        assertEquals(EpgIds.scope("B", "y"), epg.resolve(listOf(b))[b.id])
    }

    @Test fun theIdHelpersRoundTrip() {
        assertEquals("bbc1", EpgIds.raw(EpgIds.scope("A", "bbc1"))); assertEquals("A", EpgIds.source(EpgIds.scope("A", "bbc1")))
        assertEquals("plain", EpgIds.raw("plain")); assertNull(EpgIds.source("plain"))
    }
}
