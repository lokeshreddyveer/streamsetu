package app.streamsetu.tv

import app.streamsetu.core.data.db.OverrideEntity
import app.streamsetu.core.data.repo.TmdbService
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** TMDB artwork matching: restricted titles are never listed or sent, and what TMDB filled is taken back on a lock and after 180 days. Synthetic titles; the network is a stub. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class TmdbPrivacyTests {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PrivacyFixture
    @Before fun open() {
        fx = PrivacyFixture().build()
        // every movie loses its picture so all are candidates
        fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET posterUrl = NULL"); fx.db.openHelper.writableDatabase.execSQL("UPDATE series SET posterUrl = NULL")
    }
    @After fun close() = fx.close()

    val urls = java.util.Collections.synchronizedList(ArrayList<String>())
    private fun service(dir: java.io.File, clock: () -> Long = System::currentTimeMillis) = TmdbService(fx.db, { "KEY" }, fx.folders.visibility, dir, clock) { u, _ -> urls += u; """{"results":[]}""" }

    @Test fun restrictedTitlesAreNeverSentToTmdb() {
        val sent = java.util.Collections.synchronizedList(ArrayList<String>())
        // The service's own network call is replaced by watching what would be looked up: every override row it writes names the title that was asked for.
        val dir = tmp.newFolder()
        runBlocking { runCatching { service(dir).fillMissing(500) } }          // no network in the test: lookups fail, but each asked title still gets its blank correction row
        val asked = fx.db.openHelper.readableDatabase.query("SELECT itemId FROM overrides").use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }.toSet()
        sent += asked
        assertTrue("nothing named a restricted title in a request", urls.none { u -> listOf("Secret", "Hidden", "Adult", "Split", "Lone").any { it in u } })
        assertTrue(urls.isNotEmpty())
        assertTrue("restricted titles were sent: ${asked intersect F.restrictedMovies}", (asked intersect F.restrictedMovies).isEmpty())
        assertFalse(F.SERIES_SECRET in asked)
        assertTrue("open titles are still matched", F.OPEN_FILM_A in asked)
    }

    @Test fun whatTmdbFilledIsTakenBackWhenTheTitleBecomesRestrictedAndAfter180Days() = runBlocking {
        val dir = tmp.newFolder(); val t0 = System.currentTimeMillis()
        var clock = t0
        val svc = service(dir) { clock }
        // two fills as the service writes them, one for a title that is open now and one for a title in the locked folder; one hand-made correction
        val extras = fx.db.extras()
        extras.putOverride(OverrideEntity(F.OPEN_FILM_A, null, "https://image.tmdb.org/t/p/w342/a.jpg", "story"))
        extras.putOverride(OverrideEntity(F.SECRET_A, null, "https://image.tmdb.org/t/p/w342/b.jpg", "secret story"))
        extras.putOverride(OverrideEntity("m-plain-a", "My own name", null, null))
        java.io.File(dir, "filled.log").writeText("${F.OPEN_FILM_A}\t$t0\n${F.SECRET_A}\t$t0\nm-plain-a\t$t0\n")
        assertEquals("the locked title's fill is removed, the others stay", 1, svc.purge())
        assertNull(overrideOf(F.SECRET_A)); assertNotNull(overrideOf(F.OPEN_FILM_A)); assertNotNull(overrideOf("m-plain-a"))
        clock = t0 + 181L * 86_400_000L
        svc.purge()
        assertNull("gone after 180 days", overrideOf(F.OPEN_FILM_A))
        assertEquals("a correction the person made by hand is never touched", "My own name", overrideOf("m-plain-a")?.title)
    }

    private fun overrideOf(id: String) = fx.db.openHelper.readableDatabase.query("SELECT itemId, title, posterUrl, plot FROM overrides WHERE itemId = ?", arrayOf(id)).use { c -> if (c.moveToFirst()) OverrideEntity(c.getString(0), c.getString(1), c.getString(2), c.getString(3)) else null }

    @Test fun aRunStoppedHalfWayStillHasEveryWrittenFillOnTheRecord() {
        val dir = tmp.newFolder(); var n = 0
        val svc = TmdbService(fx.db, { "KEY" }, fx.folders.visibility, dir) { u, _ -> if (++n == 3) throw kotlinx.coroutines.CancellationException("left the screen"); """{"results":[{"title":"${java.net.URLDecoder.decode(u.substringAfter("query=").substringBefore("&"), "UTF-8")}","poster_path":"/p.jpg","overview":"s"}]}""" }
        assertTrue(runCatching { runBlocking { svc.fillMissing(50) } }.isFailure)
        val written = fx.db.openHelper.readableDatabase.query("SELECT itemId FROM overrides").use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }.toSet()
        val logged = java.io.File(dir, "filled.log").readLines().map { it.substringBefore('\t') }.toSet()
        assertTrue(written.isNotEmpty()); assertTrue("every correction written is on the record: $written vs $logged", logged.containsAll(written))
    }

    @Test fun aNetworkFailureIsNotStoredAsNoMatchAndTheRunBacksOff() {
        val dir = tmp.newFolder(); var clock = 1_000_000_000_000L; var online = false; var calls = 0
        val svc = TmdbService(fx.db, { "KEY" }, fx.folders.visibility, dir, { clock }) { _, _ -> calls++; if (!online) throw java.io.IOException("offline"); """{"results":[]}""" }
        assertTrue(runCatching { runBlocking { svc.fillMissing(50) } }.isFailure)
        assertEquals("nothing was stored as unmatched", 0, fx.db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM overrides").use { it.moveToFirst(); it.getInt(0) })
        val after = calls
        assertTrue("a second run right away does not ask again", runCatching { runBlocking { svc.fillMissing(50) } }.isFailure); assertEquals(after, calls)
        clock += 2 * 3_600_000L; online = true
        assertTrue("later it works and now stores the answers", runBlocking { svc.fillMissing(50) } >= 0)
        assertTrue(fx.db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM overrides").use { it.moveToFirst(); it.getInt(0) } > 0)
    }

    @Test fun withoutAKeyNothingIsRequestedAndWhatWasFilledStaysUntilTheLimit() = runBlocking {
        val dir = tmp.newFolder(); var calls = 0
        val noKey = TmdbService(fx.db, { null }, fx.folders.visibility, dir) { _, _ -> calls++; "{}" }
        assertTrue(runCatching { noKey.fillMissing(10) }.isFailure); assertEquals(0, calls)
        fx.db.extras().putOverride(OverrideEntity(F.OPEN_FILM_A, null, "https://image.tmdb.org/t/p/w342/a.jpg", "story"))
        java.io.File(dir, "filled.log").writeText("${F.OPEN_FILM_A}\t${System.currentTimeMillis()}\n")
        noKey.purge()
        assertNotNull("kept until the 180-day limit", overrideOf(F.OPEN_FILM_A))
    }

}
