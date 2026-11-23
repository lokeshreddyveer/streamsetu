package app.streamsetu.tv

import app.streamsetu.core.data.hub.*
import app.streamsetu.core.data.repo.TmdbAuth
import app.streamsetu.core.data.repo.TmdbIdStore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.time.LocalDate
import java.time.ZoneId
import app.streamsetu.tv.PrivacyFixture.Companion as F

/**
 * The metadata hub as the app wires it: a title the person opens gets its ids from TMDB through the shared TMDB call (one rhythm), its logo, wide picture and next episode from the extra
 * sources through the express lane, nothing for a restricted title, nothing for a source that is off, and what TMDB gave is taken back with the rest. Shared artwork fixtures, fake keys.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class HubWiringTests {
    private lateinit var fx: PrivacyFixture
    private val tmdbCalls = java.util.Collections.synchronizedList(ArrayList<String>())
    private val hubCalls = java.util.Collections.synchronizedList(ArrayList<String>())

    private fun fixture(name: String): String {
        var d: File? = File("").absoluteFile; var f: File? = null
        while (d != null && f == null) { File(d, "artwork/fixtures/$name").takeIf { it.isFile }?.let { f = it }; d = d.parentFile }
        assumeTrue("the shared fixtures are not next to this checkout", f != null)
        return f!!.readText()
    }

    @Before fun open() { fx = PrivacyFixture().build() }
    @After fun close() = fx.close()

    private val fetch = HubFetch { req ->
        hubCalls += req.url
        when {
            "webservice.fanart.tv" in req.url -> fixture("fanart-tv-121361.json")
            "api.tvmaze.com" in req.url -> fixture("tvmaze-show-82.json")
            else -> throw IllegalStateException("unexpected host ${req.url}")
        }
    }

    private fun titles(tvdbOn: Boolean = false, fanartKey: String? = "FAKE-FANART-KEY", tmdbKey: String? = "0123456789abcdef0123456789abcdef"): HubTitles {
        val store = RoomHubStore(fx.db.hub())
        val mem = MemoryHubStore()
        fun access(s: HubSource) = HubAccess(s, mem, mem, { if (s == HubSource.FANART) fanartKey else null })
        val all = listOf(HubSource.FANART, HubSource.TVDB, HubSource.TVMAZE).associateWith(::access)
        all.getValue(HubSource.TVDB).enabled = tvdbOn
        val sendable = HubSendable(fx.db, fx.folders.visibility)
        val hub = MetadataHub(store, all, fetch, TVDBSession(all.getValue(HubSource.TVDB), mem, fetch), sendable::invoke)
        // The same single TMDB call the whole app shares: counted here.
        return HubTitles(fx.db, hub, store, TmdbIdStore(fx.db), TmdbAuth({ tmdbKey }), { url, _ -> tmdbCalls += url; """{"id":1399,"imdb_id":"tt0944947","tvdb_id":121361}""" }, sendable::invoke)
    }

    @Test fun anOpenedSeriesGetsItsIdsFromTmdbThroughTheSharedCallThenLogoBackdropAndNextEpisodeFromTheOtherSources() = runBlocking {
        val t = titles(); TmdbIdStore(fx.db).put(F.SERIES_OPEN, 1399, true)
        val saved = t.open(F.SERIES_OPEN, true)
        assertEquals("one TMDB request, for the ids", 1, tmdbCalls.size); assertTrue(tmdbCalls.single().contains("tv/1399/external_ids"))
        val id = fx.db.hub().identity(F.SERIES_OPEN)!!
        assertEquals(121361, id.tvdbId); assertEquals("tt0944947", id.imdbId); assertEquals(1399, id.tmdbId); assertEquals("tvmaze id came back from the show", 82, id.tvmazeId)
        assertTrue("logo", saved.logo!!.endsWith("a.png")); assertTrue("wide picture", saved.backdrop!!.endsWith("b.jpg")); assertEquals("2026-12-01T02:00:00+00:00", saved.nextEpisode)
        assertTrue("no TheTVDB key in this test, so it is never asked", hubCalls.none { "api4.thetvdb.com" in it })
        assertFalse("no TheTVDB credit when nothing came from it", saved.provenance.contains(HubSource.TVDB))
        // A second open asks nobody again: one request per title until it expires.
        val before = hubCalls.size; t.open(F.SERIES_OPEN, true); assertEquals(before, hubCalls.size); assertEquals(1, tmdbCalls.size)
    }

    @Test fun aRestrictedTitleAsksNobodyAtAll() = runBlocking {
        val t = titles(); TmdbIdStore(fx.db).put(F.SERIES_SECRET, 1399, true)
        val saved = t.open(F.SERIES_SECRET, true)
        assertEquals(HubTitles.Saved.NONE.logo, saved.logo); assertNull(saved.nextEpisode)
        assertTrue(hubCalls.isEmpty()); assertTrue("not even TMDB is asked for its ids", tmdbCalls.isEmpty())
        assertNull(fx.db.hub().identity(F.SECRET_A))
    }

    @Test fun withoutAFanartKeyOrWithTheSwitchOffNothingIsAskedOfIt() = runBlocking {
        val t = titles(fanartKey = null); TmdbIdStore(fx.db).put(F.SERIES_OPEN, 1399, true)
        t.open(F.SERIES_OPEN, true)
        assertTrue(hubCalls.none { "fanart" in it }); assertTrue("the next episode still comes (no key needed)", hubCalls.any { "tvmaze" in it })
    }

    @Test fun theKeyedDetailsReplyFiledUnderTheItemIdFeedsTheCrosswalk() = runBlocking {
        val t = titles()
        t.ingestTmdbDetails(F.SERIES_OPEN, true, """{"id":1399,"external_ids":{"imdb_id":"tt0944947","tvdb_id":121361}}""")
        val id = fx.db.hub().identity(F.SERIES_OPEN)!!
        assertEquals(1399, id.tmdbId); assertEquals(121361, id.tvdbId)
        t.identity(F.SERIES_OPEN, true); assertEquals("with the ids known no TMDB request is needed", 0, tmdbCalls.size)
    }

    @Test fun whatTmdbGaveIsTakenBackAndTheOtherServicesIdsStay() = runBlocking {
        val t = titles(); t.ingestTmdbDetails(F.SERIES_OPEN, true, """{"id":1399,"external_ids":{"imdb_id":"tt0944947","tvdb_id":121361}}""")
        val hub = fx.db.hub()
        hub.putFact(app.streamsetu.core.data.db.MetadataFactEntity(F.SERIES_OPEN, "x", "v", "tmdb", 1.0, 1, 2)); hub.putFact(app.streamsetu.core.data.db.MetadataFactEntity(F.SERIES_OPEN, "y", "v", "fanart", 1.0, 1, 2))
        hub.purgeSource(HubSource.TMDB.key); hub.forgetTmdbIds()
        assertNull(hub.fact(F.SERIES_OPEN, "x")); assertNotNull(hub.fact(F.SERIES_OPEN, "y"))
        val id = hub.identity(F.SERIES_OPEN)!!; assertNull(id.tmdbId); assertEquals(121361, id.tvdbId)
    }

    @Test fun tmdbHasNoLimiterOfItsOwnInTheHubAndTheHubNeverAsksIt() = runBlocking {
        assertEquals("no second TMDB bucket", 0.0, HubPolicy.TMDB.refillPerSecond, 0.0); assertEquals(0, HubPolicy.TMDB.burst)
        assertEquals(app.streamsetu.core.data.repo.TmdbFiles.MAX_DAYS * 86_400_000L, HubPolicy.TMDB.keepMs)
        val t = titles(); TmdbIdStore(fx.db).put(F.SERIES_OPEN, 1399, true)
        val r = t.hub.refresh(F.SERIES_OPEN, t.identity(F.SERIES_OPEN, true), HubTitleKind.SERIES)
        assertFalse(HubSource.TMDB in r.asked); assertTrue(HubSource.FANART in r.asked && HubSource.TVMAZE in r.asked)
        assertTrue("fanart.tv is express lane only", !HubPolicy.FANART.bulkAllowed)
    }

    @Test fun nextEpisodeWordsFollowTheStamp() {
        val today = LocalDate.of(2026, 11, 28); val z = ZoneId.of("UTC")
        fun w(s: String?) = NextEpisode.from(s, today, z, java.util.Locale.ENGLISH)
        assertEquals(NextEpisode.Today, w("2026-11-28T18:00:00+00:00")); assertEquals(NextEpisode.Tomorrow, w("2026-11-29T02:00:00+00:00"))
        assertEquals(NextEpisode.InDays(3), w("2026-12-01T02:00:00+00:00")); assertEquals("Next episode on {}", NextEpisode.On("20 Dec").key().first)
        assertEquals(NextEpisode.On("20 Dec"), w("2026-12-20T02:00:00+00:00")); assertNull(w("2026-11-20T02:00:00+00:00")); assertNull(w("")); assertNull(w("soon"))
        assertEquals(NextEpisode.InDays(3) to "3", NextEpisode.InDays(3).let { it to it.key().second })
    }
}
