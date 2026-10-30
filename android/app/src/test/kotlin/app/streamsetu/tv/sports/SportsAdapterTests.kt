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
import kotlinx.coroutines.flow.first
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
    private var locked: Set<String> = emptySet()
    private lateinit var svc: SportsEventService
    private val t0 = 1_800_000_000_000L; private val h = 3_600_000L; private val min = 60_000L
    private val parent get() = runBlocking { SportsGuideInputs.context(db, "main", false, locked, ParentalControls::isAdultName) }
    private val kid get() = runBlocking { SportsGuideInputs.context(db, "kid", true, locked, ParentalControls::isAdultName) }

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        epg = EpgService(db)
        svc = SportsGuideInputs.service(db, epg, offsetMs = { offset })
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

    // ---- the active library, and the PIN lock, exactly as the rest of the app reads them

    private fun serviceFor(active: () -> List<String>) = SportsGuideInputs.service(db, epg, { offset }, active)

    @Test fun onlyTheActiveLibrarysSourcesAppearAndAnotherLibrarysEventsNeverLeak() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("B:1", "B", "Premier Sports", "epl"); guide("B", "epl", "Premier League: Arsenal v Chelsea")
        val onlyA = serviceFor { listOf("A") }.events(t0 - h, t0 + 12 * h, parent)
        assertEquals(1, onlyA.size); assertEquals(setOf("A"), onlyA.single().sourceIds); assertTrue(onlyA.none { it.title.contains("Arsenal") })
        val both = serviceFor { listOf("A", "B") }.events(t0 - h, t0 + 12 * h, parent)
        assertEquals(2, both.size)
        val onlyB = serviceFor { listOf("B") }.events(t0 - h, t0 + 12 * h, parent)
        assertEquals(setOf("B"), onlyB.single().sourceIds); assertTrue("A's event does not leak into B's library", onlyB.none { it.title.contains("Lakers") })
    }

    @Test fun anEmptyActiveLibraryShowsNothingLikeMoviesSeriesAndLiveTv() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        assertTrue("no library open: nothing is shown, not everything", serviceFor { emptyList() }.events(t0 - h, t0 + 12 * h, parent).isEmpty())
    }

    @Test fun theRealLibraryRepositoryDecidesTheSources() = runBlocking {
        channel("A:1", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("B:1", "B", "Premier Sports", "epl"); guide("B", "epl", "Premier League: Arsenal v Chelsea")
        val ctxApp = ApplicationProvider.getApplicationContext<android.content.Context>()
        val library = app.streamsetu.core.data.repo.LibraryRepository(db, ctxApp, kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined))
        val s = serviceFor { library.sourceIds.value }
        assertTrue("nothing is open yet", s.events(t0 - h, t0 + 12 * h, parent).isEmpty())
        library.open(library.entries.first { l -> l.any { e -> e.id == "src:A" } }.first { e -> e.id == "src:A" }); kotlinx.coroutines.yield()
        assertEquals(setOf("A"), s.events(t0 - h, t0 + 12 * h, parent).single().sourceIds)
        library.open(library.entries.first { l -> l.any { e -> e.id == "src:B" } }.first { e -> e.id == "src:B" }); kotlinx.coroutines.yield()
        assertEquals(setOf("B"), s.events(t0 - h, t0 + 12 * h, parent).single().sourceIds)
        library.close(); kotlinx.coroutines.yield()
        assertTrue(s.events(t0 - h, t0 + 12 * h, parent).isEmpty())
    }

    private fun folderRepo(): app.streamsetu.core.data.repo.FolderRepository {
        val ctxApp = ApplicationProvider.getApplicationContext<android.content.Context>()
        val library = app.streamsetu.core.data.repo.LibraryRepository(db, ctxApp, kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined))
        return app.streamsetu.core.data.repo.FolderRepository(db, library, ParentalControls(ctxApp))
    }
    private suspend fun lockFolder(id: String) = db.folders().put(app.streamsetu.core.data.db.FolderPrefEntity("CHANNEL", id, locked = true))
    private suspend fun contextNow(folders: app.streamsetu.core.data.repo.FolderRepository) = SportsGuideInputs.context(db, "main", false, folders.lockedIdsNow(), ParentalControls::isAdultName)

    @Test fun pinLockedFoldersAreExcludedSessionUnlockedFoldersAppearAndRelockingRemovesThemAtOnce() = runBlocking {
        category("cat-locked", "A", "Premium")
        channel("A:open", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("A:locked", "A", "Premium NBA", "prem", "cat-locked"); guide("A", "prem", "NFL: Chiefs vs Eagles")
        lockFolder("cat-locked")
        val folders = folderRepo(); val s = serviceFor { listOf("A") }
        assertEquals("the locked folder's event is excluded", 1, s.events(t0 - h, t0 + 12 * h, contextNow(folders)).size)
        folders.unlock("cat-locked")
        assertEquals("unlocked with the PIN this session: it appears", 2, s.events(t0 - h, t0 + 12 * h, contextNow(folders)).size)
        folders.lockAgain()
        val after = s.events(t0 - h, t0 + 12 * h, contextNow(folders))
        assertEquals("relocked: gone immediately", 1, after.size); assertTrue(after.flatMap { it.feeds }.none { it.channelId == "A:locked" })
    }

    @Test fun aProfileSwitchRelocksFoldersAccordingToTheAppsOwnRule() = runBlocking {
        category("cat-locked", "A", "Premium")
        channel("A:open", "A", "Sky Sports NBA", "nba"); guide("A", "nba", "NBA: Lakers vs Celtics")
        channel("A:locked", "A", "Premium NBA", "prem", "cat-locked"); guide("A", "prem", "NFL: Chiefs vs Eagles")
        lockFolder("cat-locked")
        val folders = folderRepo(); val s = serviceFor { listOf("A") }
        // the app's ProfileService relocks folders before the tables change hands (see AppContainer.profiles)
        val profiles = app.streamsetu.tv.sync.ProfileService(db, null, beforeSwitch = { folders.lockAgain() }) { }
        app.streamsetu.core.data.db.LanLog.create(db.openHelper.writableDatabase)           // what the real app creates at start; a profile switch swaps these tables too
        profiles.reload()
        val other = profiles.add("Guest", kids = false, pin = null)!!
        folders.unlock("cat-locked")
        assertEquals(2, s.events(t0 - h, t0 + 12 * h, contextNow(folders)).size)
        assertEquals(app.streamsetu.tv.sync.SwitchResult.Switched, profiles.switchTo(other.id))
        val afterSwitch = s.events(t0 - h, t0 + 12 * h, SportsGuideInputs.context(db, other.id, false, folders.lockedIdsNow(), ParentalControls::isAdultName))
        assertEquals("the switch locked the folder again, so its event is gone", 1, afterSwitch.size)
        assertTrue(afterSwitch.flatMap { it.feeds }.none { it.channelId == "A:locked" })
    }

    // ---- timing through the real database path, as the Sports Hub uses it

    @Test fun firstLoadCachedReturnAndFilterChangeThroughTheRealDatabase() = runBlocking {
        val titles = listOf("NBA: Lakers vs Celtics", "Premier League: Arsenal v Chelsea", "IPL: Mumbai Indians vs Chennai Super Kings", "Evening News", "Cooking Today", "Weather", "Quiz Night", "Kids Hour")
        val channels = ArrayList<ChannelEntity>(); val rows = ArrayList<EpgEntity>()
        for (i in 0 until 3_000) {
            channels.add(ChannelEntity("A:$i", "A", null, "Channel $i", null, null, "ref", "g$i", 0, i))
            for (j in 0 until 6) rows.add(EpgEntity(EpgIds.scope("A", "g$i"), t0 + j * h, t0 + (j + 1) * h, if (i % 40 == 0 && j == 2) titles[(i / 40) % 3] else titles[3 + (i + j) % 5], null))
        }
        db.catalog().putChannels(channels); db.epg().put(rows)
        val svc = serviceFor { listOf("A") }
        val t1 = System.nanoTime(); val first = svc.events(t0 - h, t0 + 12 * h, parent); val firstMs = (System.nanoTime() - t1) / 1e6
        val t2 = System.nanoTime(); svc.events(t0 - h, t0 + 12 * h, parent); val cachedMs = (System.nanoTime() - t2) / 1e6
        val t3 = System.nanoTime(); val r = app.streamsetu.tv.ui.screens.sports.SportsSections.build(first, t0 + h, java.util.TimeZone.getTimeZone("UTC"), app.streamsetu.core.sports.Sport.CRICKET, null, mapOf("A" to "A")); val filterMs = (System.nanoTime() - t3) / 1e6
        println("SPORTS PHASE 2 TIMING (3000 channels, 18000 guide rows, real Room database): first load ${"%.0f".format(firstMs)} ms, cached return ${"%.0f".format(cachedMs)} ms, filter change (state rebuild) ${"%.1f".format(filterMs)} ms")
        assertEquals(3, first.size); assertTrue(r.live.size + r.soon.size + r.today.size + r.upcoming.size > 0)
        assertTrue("the cached return is much quicker than the first load ($cachedMs vs $firstMs ms)", cachedMs < firstMs)
    }
}
