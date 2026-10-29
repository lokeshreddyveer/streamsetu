package app.streamsetu.tv.sports

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.CategoryEntity
import app.streamsetu.core.data.db.ChannelEntity
import app.streamsetu.core.data.db.ChannelPrefEntity
import app.streamsetu.core.data.db.EpgEntity
import app.streamsetu.core.data.db.SourceEntity
import app.streamsetu.core.data.repo.ParentalControls
import app.streamsetu.core.model.EpgIds
import app.streamsetu.core.sports.SportsContext
import app.streamsetu.core.sports.SportsEventService
import app.streamsetu.core.sync.EpgService
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The Sports service against the real Room database, the real guide matching and the real restriction sources. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SportsAdapterTests {
    private lateinit var db: AppDatabase
    private lateinit var epg: EpgService
    private var offset = 0L
    private lateinit var svc: SportsEventService
    private val t0 = 1_800_000_000_000L; private val h = 3_600_000L; private val min = 60_000L
    private val parent get() = runBlocking { SportsGuideInputs.context(db, "main", false, ParentalControls::isAdultName) }
    private val kid get() = runBlocking { SportsGuideInputs.context(db, "kid", true, ParentalControls::isAdultName) }

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        epg = EpgService(db)
        svc = SportsGuideInputs.service(db, epg) { offset }
        runBlocking { source("A"); source("B") }
    }
    @After fun close() { db.close() }

    private suspend fun source(id: String, enabled: Boolean = true) = db.sources().upsert(SourceEntity(id, "Playlist $id", "M3U", "http://x/$id", null, null, enabled, 1, "OK"))
    private suspend fun category(id: String, source: String, name: String) = db.catalog().putCategories(listOf(CategoryEntity(id, source, "LIVE", name, 0)))
    private suspend fun channel(id: String, source: String, name: String, epgId: String?, category: String? = null) =
        db.catalog().putChannels(listOf(ChannelEntity(id, source, category, name, null, null, "ref", epgId, 0, 0)))
    private suspend fun guide(scopeSource: String, id: String, title: String, start: Long = t0, minutes: Long = 120) =
        db.epg().put(listOf(EpgEntity(EpgIds.scope(scopeSource, id), start, start + minutes * min, title, null)))
    private suspend fun events(ctx: SportsContext = parent) = svc.events(t0 - h, t0 + 12 * h, ctx)
    private fun refreshed() = epg.guideChanged()          // what a guide refresh does after it has written the table

    @Test fun eventsAreBuiltFromTheRealChannelsAndGuide() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("B:1", "B", "Premier Sports", "epl"); guide("B", "epl", "Premier League: Arsenal v Chelsea")
        val evs = events()
        assertEquals(2, evs.size)
        assertEquals(listOf("A:1"), evs.first { it.title.contains("Lakers") }.feeds.map { it.channelId })
        assertEquals(setOf("B"), evs.first { it.title.contains("Arsenal") }.sourceIds)
        assertNull("the Android channel model has no language", evs.first().feeds.first().language)
    }

    @Test fun aGuideRefreshOfOnePlaylistInvalidatesOnlyThatPlaylist() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("B:1", "B", "Premier Sports", "epl"); guide("B", "epl", "Premier League: Arsenal v Chelsea")
        events(); assertEquals(2, svc.classifiedSources)
        events(); assertEquals("answered from the cache", 2, svc.classifiedSources)
        guide("B", "epl", "NBA: Heat vs Bulls", start = t0 + 20 * min); refreshed()                      // B's guide was refreshed
        val evs = events()
        assertEquals("only B was classified again", 3, svc.classifiedSources)
        assertTrue(evs.any { it.title.contains("Heat") } && evs.any { it.title.contains("Lakers") })
    }

    @Test fun aPlaylistThatTakesItsProgrammesFromAnotherPlaylistsGuideFollowsThatGuide() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("B:1", "B", "Other NBA", "nba")                                                           // B has no guide of its own: it reads A's
        events(); assertEquals(2, svc.classifiedSources)
        guide("A", "nba", "NBA: Heat vs Bulls", start = t0 + 3 * h); refreshed()
        events(); assertEquals("A's guide changed, and B reads from it, so both are redone", 4, svc.classifiedSources)
    }

    @Test fun aPlaylistChangeInvalidatesThePlaylistThatChanged() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("B:1", "B", "Premier Sports", "epl"); guide("B", "epl", "Premier League: Arsenal v Chelsea")
        events(); assertEquals(2, svc.classifiedSources)
        channel("A:2", "A", "Sky Sports NBA 2", "nba")                                                    // a channel was added to A
        val evs = events()
        assertEquals("only A was classified again", 3, svc.classifiedSources)
        assertEquals(2, evs.first { it.title.contains("Lakers") }.feeds.size)
        source("B", enabled = false)                                                                      // B was switched off
        val after = events()
        assertEquals("B's events are gone and A was not redone", 3, svc.classifiedSources)
        assertTrue(after.none { it.sourceIds.contains("B") })
    }

    @Test fun aGuideTimeOffsetChangeInvalidatesEverything() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        val first = events().single(); assertEquals(1, svc.classifiedSources)
        offset = 30 * min
        val shifted = events().single()
        assertEquals(2, svc.classifiedSources); assertEquals(first.startMs + 30 * min, shifted.startMs); assertEquals("the event is the same event", first.id, shifted.id)
    }

    @Test fun aProfileChangeUsesItsOwnCacheEntriesAndNeverTheOtherProfilesResults() = runBlocking {
        category("cat-ok", "A", "Sports"); category("cat-adult", "A", "Adult XXX")
        channel("A:ok", "A", "Sky Sports NBA", "nba", "cat-ok"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("A:adult", "A", "Night Sports", "night", "cat-adult"); guide("A", "night", "NFL: Chiefs vs Eagles")
        assertEquals(2, events(parent).size); assertEquals(1, svc.classifiedSources)
        val kidEvents = events(kid)
        assertEquals("the kids profile does not get the parent's cached events", 1, kidEvents.size); assertEquals(2, svc.classifiedSources)
        assertTrue(kidEvents.flatMap { it.feeds }.none { it.channelId == "A:adult" })
        assertEquals(2, events(parent).size); assertEquals("switching back is answered from the parent's own entry", 2, svc.classifiedSources)
    }

    @Test fun hiddenAndAdultFilteredChannelsNeverLeakThroughAnEvent() = runBlocking {
        category("cat-adult", "A", "Adult XXX")
        channel("A:open", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("A:hidden", "A", "Sky Sports NBA 2", "nba")
        channel("A:adult", "A", "Night NBA", "nba", "cat-adult")
        assertEquals(3, events(parent).single().feeds.size)
        db.extras().putChannelPref(ChannelPrefEntity("A:hidden", hidden = true))
        assertEquals("a hidden channel is gone for everyone", listOf("A:adult", "A:open").sorted(), events(parent).single().feeds.map { it.channelId }.sorted())
        assertEquals("and the adult-filtered folder is gone while the filter is on", listOf("A:open"), events(kid).single().feeds.map { it.channelId })
    }

    @Test fun theCacheStaysBoundedAcrossRealRefreshesAndProfiles() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        var peak = 0
        for (i in 0 until 40) {
            guide("A", "nba", "NBA: Team$i vs Other$i", start = t0 + i * 15 * min); refreshed()
            events(parent); events(kid); peak = maxOf(peak, svc.cachedEntries)
        }
        assertTrue("peak $peak", peak <= SportsEventService.CACHE_LIMIT)
    }
}
