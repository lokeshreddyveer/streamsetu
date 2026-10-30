package app.streamsetu.tv.search

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.EpgIds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Guide results on a real database: each programme belongs to the channel of its own playlist, and carries what is needed to open that programme. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class GuideSearchTests {
    private lateinit var db: AppDatabase
    private lateinit var library: LibraryRepository
    private lateinit var search: GlobalSearch
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()
    private val now = System.currentTimeMillis(); private val h = 3_600_000L

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
        SearchIndex.create(db.openHelper.writableDatabase); PeopleIndex.create(db.openHelper.writableDatabase)
        library = LibraryRepository(db, ctx, CoroutineScope(Dispatchers.Unconfined))
        val folders = FolderRepository(db, library, ParentalControls(ctx))
        search = GlobalSearch(db, library, folders, CollectionRepository(db), SearchRepository(db, library, folders, ctx)) { it }
        runBlocking { db.sources().upsert(SourceEntity("A", "Playlist A", "M3U", "http://x/a", null, null, true, 1, "OK")); db.sources().upsert(SourceEntity("B", "Playlist B", "M3U", "http://x/b", null, null, true, 1, "OK")) }
    }
    @After fun close() { db.close() }

    private fun channel(id: String, source: String, name: String, epg: String) = runBlocking { db.catalog().putChannels(listOf(ChannelEntity(id, source, null, name, null, null, "ref", epg, 0, 0))) }
    private fun guide(source: String, epg: String, title: String, start: Long) = runBlocking { db.epg().put(listOf(EpgEntity(EpgIds.scope(source, epg), start, start + 2 * h, title, null))) }
    private suspend fun openLibrary(vararg ids: String) { val e = library.entries.first { l -> l.any { it.id == "src:${ids[0]}" } }.first { it.id == "src:${ids[0]}" }; library.open(e); kotlinx.coroutines.yield() }
    private fun results(q: String) = runBlocking { search.search(q).byKind[SearchKind.PROGRAMME].orEmpty() }

    @Test fun twoPlaylistsWithTheSameGuideIdNeverSwapProgrammes() = runBlocking {
        channel("A:1", "A", "News A", "bbc"); channel("B:1", "B", "News B", "bbc")                      // the same guide id in two playlists
        guide("A", "bbc", "Cricket Special from A", now + h); guide("B", "bbc", "Cricket Special from B", now + 2 * h)
        openLibrary("A")
        val r = results("cricket special")
        assertEquals("only the open library's guide", 1, r.size)
        val t = r.single().target as SearchTarget.PlayProgramme
        assertEquals("A:1", t.channel.id); assertEquals(now + h, t.startMs); assertEquals(now + 3 * h, t.endMs)
        openLibrary("B")
        val b = results("cricket special").single().target as SearchTarget.PlayProgramme
        assertEquals("B:1", b.channel.id); assertEquals(now + 2 * h, b.startMs)
    }

    @Test fun aProgrammeIsNeverGivenToAChannelOfAnotherPlaylist() = runBlocking {
        channel("B:1", "B", "News B", "bbc")                                                          // only playlist B has this channel; the guide is playlist A's
        guide("A", "bbc", "Cricket Special", now + h)
        openLibrary("B")
        assertTrue("A's programme must not appear on B's channel", results("cricket special").isEmpty())
    }

    @Test fun theResultCarriesTheProgrammeTimeAndItsIdentityIsUniquePerChannelAndStart() = runBlocking {
        channel("A:1", "A", "One", "x"); channel("A:2", "A", "Two", "y")
        guide("A", "x", "Derby Day", now + h); guide("A", "y", "Derby Day", now + h)
        openLibrary("A")
        val r = results("derby day"); assertEquals(2, r.size); assertEquals(2, r.map { it.id }.toSet().size)
        assertTrue(r.all { (it.target as SearchTarget.PlayProgramme).startMs == now + h })
    }

    @Test fun aGuideStoredBeforeIdsWereScopedStillFindsItsChannel() = runBlocking {
        channel("A:1", "A", "One", "legacy")
        runBlocking { db.epg().put(listOf(EpgEntity("legacy", now + h, now + 3 * h, "Old Style Guide Show", null))) }
        openLibrary("A")
        assertEquals("A:1", (results("old style guide").single().target as SearchTarget.PlayProgramme).channel.id)
    }

    @Test fun anEndedProgrammeIsNotListed() = runBlocking {
        channel("A:1", "A", "One", "x"); runBlocking { db.epg().put(listOf(EpgEntity(EpgIds.scope("A", "x"), now - 5 * h, now - 3 * h, "Yesterday Show", null))) }
        openLibrary("A"); assertTrue(results("yesterday show").isEmpty())
    }

    @Test fun titlesArriveFirstAndTheGuideIsAddedBelowWithoutMovingThem() = runBlocking {
        channel("A:1", "A", "Derby Live", "x"); guide("A", "x", "Derby Live Show", now + h)
        SearchIndex.insert(db.openHelper.writableDatabase, listOf(SearchHit("CHANNEL", "A:1", "A", null, "Derby Live")))
        openLibrary("A")
        val steps = search.searchProgressive("derby live").toList()
        assertTrue("more than one value: the titles, then the guide", steps.size >= 2)
        assertEquals("the first value has the titles and no guide yet", setOf(SearchKind.CHANNEL), steps.first().byKind.keys)
        assertEquals("the last is the complete result", setOf(SearchKind.CHANNEL, SearchKind.PROGRAMME), steps.last().byKind.keys)
        assertEquals("what was shown first is still first and unchanged", steps.first().byKind[SearchKind.CHANNEL]!!.map { it.id }, steps.last().byKind[SearchKind.CHANNEL]!!.map { it.id })
        for (i in 1 until steps.size) assertTrue("cumulative: nothing disappears", steps[i - 1].byKind.keys.all { it in steps[i].byKind.keys })
        assertEquals("the one-shot search gives the same final answer", steps.last().byKind.mapValues { e -> e.value.map { it.id } }, search.search("derby live").byKind.mapValues { e -> e.value.map { it.id } })
    }

    @Test fun cancellingTheCollectorStopsTheSearch() = runBlocking {
        channel("A:1", "A", "Derby Live", "x"); SearchIndex.insert(db.openHelper.writableDatabase, listOf(SearchHit("CHANNEL", "A:1", "A", null, "Derby Live"))); openLibrary("A")
        val first = search.searchProgressive("derby live").first()
        assertTrue(first.byKind.isNotEmpty())
    }
}
