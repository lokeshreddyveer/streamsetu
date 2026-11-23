package app.streamsetu.tv

import app.streamsetu.core.data.db.OverrideEntity
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.net.HttpStatusException
import kotlinx.coroutines.Dispatchers
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
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** The automatic artwork run: queue order, resuming, pacing and back-off with a fake clock and a fake network, the switch and the key, and that restricted titles are never queued or sent. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ArtworkEngineTests {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PrivacyFixture
    @Before fun open() {
        fx = PrivacyFixture().build()
        fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET posterUrl = NULL"); fx.db.openHelper.writableDatabase.execSQL("UPDATE series SET posterUrl = NULL")
    }
    @After fun close() = fx.close()

    private var t = 1_000_000_000_000L
    private val sent = java.util.Collections.synchronizedList(ArrayList<String>())      // the title of every search that went out
    private val times = java.util.Collections.synchronizedList(ArrayList<Long>())
    private var key: String? = "0123456789abcdef0123456789abcdef"
    private var on = true
    private var net: (String) -> String = { u -> found(u) }
    private fun titleOf(u: String) = java.net.URLDecoder.decode(u.substringAfter("query=").substringBefore("&"), "UTF-8")
    private fun found(u: String): String { val q = titleOf(u); return """{"results":[{"id":1,"title":"$q","release_date":"2020-01-01","first_air_date":"2020-01-01","popularity":5,"poster_path":"/p.jpg","overview":"story"}]}""" }
    private val pacer = RequestPacer(4, { t }, { t += it })

    private var lastSvc: TmdbService? = null
    private fun engine(dir: java.io.File, concurrency: Int = 1, page: Int = 4, dispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Unconfined, builtIn: String? = null, allowed: () -> Boolean = { true }): ArtworkMatchEngine {
        val svc = TmdbService(fx.db, { key }, fx.folders.visibility, dir, { t }, TmdbAuth({ key }, { builtIn }, dir, { t })) { u, _ ->
            pacer.acquire(); times += t; sent += titleOf(u); net(u)
        }
        lastSvc = svc
        return ArtworkMatchEngine(fx.db, svc, fx.folders.visibility, dir, { "p1" }, { on }, allowed, ArtworkMatchEngine.Config(concurrency = concurrency, page = page, includeSummaryOnly = false), { t }, dispatcher)
    }
    private fun overrideIds() = fx.db.openHelper.readableDatabase.query("SELECT itemId FROM overrides").use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }.toSet()
    private val restrictedTitles = listOf("Secret", "Hidden", "Adult", "Split", "Lone")

    @Test fun oneContinuousRunMatchesEveryOpenTitleAndNothingRestricted() = runBlocking {
        val e = engine(tmp.newFolder())
        assertEquals(ArtworkMatchEngine.Result.Complete, e.runOnce())
        val ids = overrideIds()
        assertTrue(F.OPEN_FILM_A in ids && F.OPEN_FILM_B in ids && F.SERIES_OPEN in ids)
        assertTrue("restricted: ${ids intersect F.restrictedMovies}", (ids intersect F.restrictedMovies).isEmpty()); assertFalse(F.SERIES_SECRET in ids)
        assertTrue(sent.none { s -> restrictedTitles.any { it in s } })
        val p = e.progress.value
        assertEquals(ArtworkMatchEngine.State.COMPLETE, p.state); assertEquals(p.done, p.total); assertEquals(0, p.notFound)
        assertTrue(p.line().startsWith("All artwork matched"))
    }

    @Test fun titlesOnScreenGoToTheFrontOfTheQueue() = runBlocking {
        val e = engine(tmp.newFolder())
        e.prioritize(listOf(F.SERIES_OPEN, "m-other-b"))
        e.runOnce()
        assertTrue("first asked: ${sent.take(2)}", sent.take(2).toSet() == setOf("Open Show", "Other Voyage"))
    }

    @Test fun aRestrictedTitleOnScreenIsNeverQueued() = runBlocking {
        val e = engine(tmp.newFolder())
        e.prioritize(listOf(F.SECRET_A, F.SERIES_SECRET, F.HIDDEN_FILM_A, F.ADULT_FILM_A, F.SPLIT_A, F.LONE_B))
        e.runOnce()
        assertTrue(sent.none { s -> restrictedTitles.any { it in s } })
    }

    @Test fun aLockMadeWhileTheQueueIsFullPurgesItAtOnce() = runBlocking {
        val e = engine(tmp.newFolder())
        e.prioritize(listOf(F.OPEN_FILM_A, F.OPEN_FILM_B, "m-plain-a", "m-plain-b", "m-other-a"))
        // the person locks the folder of "Plain Story" while the queue is waiting
        fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_B, "B", F.names["open"]!!))
        e.onRestrictionsChanged()
        e.runOnce()
        assertTrue("the locked folder's titles were not sent: $sent", sent.none { it == "Plain Story" || it == "Open Film" || it == "Other Voyage" })
        assertFalse(F.OPEN_FILM_B in overrideIds())
    }

    @Test fun aLockMadeInTheMiddleOfARunStopsTheRestOfThePage() = runBlocking {
        val dir = tmp.newFolder(); var calls = 0
        lateinit var e: ArtworkMatchEngine
        net = { u -> if (++calls == 1) { runBlocking { fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_A, "A", F.names["open"]!!)) }; e.onRestrictionsChanged() }; found(u) }
        e = engine(dir, page = 12)
        e.runOnce()
        // once the lock was made (after the first request) nothing from that folder family went out
        assertTrue("sent: $sent", sent.drop(1).none { it in setOf("Open Film", "Plain Story", "Other Voyage", "Split Title", "Lone Copy") })
    }

    @Test fun aRunStoppedByTheProcessDyingCarriesOnWhereItStoppedAndAsksNothingTwice() = runBlocking {
        val dir = tmp.newFolder()
        net = { u -> t += 1_000; found(u) }
        val first = engine(dir, page = 1).runOnce(t + 3_500)
        assertEquals(ArtworkMatchEngine.Result.TimeUp, first)
        val asked1 = sent.size; assertTrue(asked1 in 1..6)
        // a new engine (a new process) with the same files
        val second = engine(dir, page = 4)
        assertEquals(ArtworkMatchEngine.Result.Complete, second.runOnce())
        // name-only policy: copies with the same cleaned name share one search (the run cache), so there can be fewer requests than titles, never a repeat
        assertEquals("no title was asked about twice: $sent", sent.size, sent.distinct().size); assertTrue(sent.size <= overrideIds().size)
        assertEquals("progress ${second.progress.value} sent=$sent overrides=${overrideIds()}", second.progress.value.total, second.progress.value.done)
    }

    @Test fun requestsArePacedAndConcurrencyIsBounded() = runBlocking {
        val active = AtomicInteger(); val most = AtomicInteger()
        val t0 = t
        net = { u -> val n = active.incrementAndGet(); most.updateAndGet { maxOf(it, n) }; Thread.sleep(8); active.decrementAndGet(); found(u) }
        engine(tmp.newFolder(), concurrency = 2, page = 6, dispatcher = Dispatchers.IO).runOnce()
        assertTrue("at most 2 at a time, saw ${most.get()}", most.get() <= 2)
        val elapsed = t - t0          // the fake clock only moves when the pacer makes a request wait
        assertTrue("never faster than 4 a second: ${sent.size} requests in $elapsed ms", sent.size <= elapsed / 250 + 3)
    }

    @Test fun aTooManyRequestsAnswerBacksOffForRetryAfterAndTheWaitSurvivesARestart() = runBlocking {
        val dir = tmp.newFolder()
        net = { throw HttpStatusException(429, 120) }
        val e = engine(dir)
        val r = e.runOnce() as ArtworkMatchEngine.Result.Backoff
        assertTrue("waits at least the Retry-After: ${r.until - t}", r.until - t >= 120_000)
        val asked = sent.size
        assertTrue(engine(dir).runOnce() is ArtworkMatchEngine.Result.Backoff); assertEquals("a restarted app does not ask again at once", asked, sent.size)
        assertEquals(0, overrideIds().size)
        t = r.until + 1; net = { u -> found(u) }
        assertEquals(ArtworkMatchEngine.Result.Complete, engine(dir).runOnce())
    }

    @Test fun beingOfflineBacksOffWithGrowingWaitsAndStoresNothingAsNotFound() = runBlocking {
        val dir = tmp.newFolder(); net = { throw IOException("offline") }
        val waits = ArrayList<Long>()
        repeat(3) { val r = engine(dir).runOnce() as ArtworkMatchEngine.Result.Backoff; waits += r.until - t; t = r.until + 1 }
        assertTrue("each wait is longer: $waits", waits[0] < waits[1] && waits[1] < waits[2])
        assertEquals(0, overrideIds().size)
    }

    @Test fun theSwitchOffAndAMissingKeyStopTheRun() = runBlocking {
        on = false
        assertEquals(ArtworkMatchEngine.Result.Paused, engine(tmp.newFolder()).runOnce()); assertEquals(0, sent.size)
        on = true; key = null
        val e = engine(tmp.newFolder())
        assertEquals(ArtworkMatchEngine.Result.Paused, e.runOnce()); assertEquals(0, sent.size); assertEquals(ArtworkMatchEngine.State.NO_KEY, e.progress.value.state)
        key = "0123456789abcdef0123456789abcdef"
        val dir = tmp.newFolder(); val e2 = engine(dir)
        net = { u -> if (sent.size >= 2) on = false; found(u) }
        e2.runOnce()
        assertTrue("stopped soon after the switch went off: ${sent.size}", sent.size <= 3)
    }

    @Test fun theBuiltInTokenIsUsedWhenThereIsNoOwnKeyAndNothingGoesOutWhenItIsRefused() = runBlocking {
        key = null
        val e = engine(tmp.newFolder(), builtIn = "eyJhbGciOi.fake.fake")
        net = { throw HttpStatusException(401) }
        assertEquals(ArtworkMatchEngine.Result.Paused, e.runOnce())
        val asked = sent.size
        assertEquals(ArtworkMatchEngine.Result.Paused, e.runOnce()); assertEquals("no hammering", asked, sent.size)
    }

    @Test fun waitingForTheNetworkRulesAsksNothing() = runBlocking {
        assertEquals(ArtworkMatchEngine.Result.Waiting, engine(tmp.newFolder(), allowed = { false }).runOnce()); assertEquals(0, sent.size)
    }

    @Test fun progressCountsDoneAndNotFoundAndNoMatchIsRemembered() = runBlocking {
        val dir = tmp.newFolder()
        net = { u -> if (titleOf(u).startsWith("Other")) """{"results":[]}""" else found(u) }
        val e = engine(dir)
        e.runOnce()
        val p = e.progress.value
        assertEquals(2, p.notFound); assertTrue(p.done >= 5 && p.done == p.total)
        assertTrue(p.line().endsWith("· 2 not found"))
        val before = sent.size
        engine(dir).runOnce(); assertEquals("a title with no match is not asked about again", before, sent.size)
    }

    @Test fun aNoMatchTitleGetsASecondTryWithTheCleanedNameFirst() = runBlocking {
        fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET title = 'TELUGU | Open Film (Telugu) FHD' WHERE id = '${F.OPEN_FILM_A}'")
        net = { u -> if (titleOf(u) == "Open Film") found(u) else if (titleOf(u).contains("TELUGU")) """{"results":[]}""" else found(u) }
        engine(tmp.newFolder()).runOnce()
        assertTrue("the cleaned name is what is asked", sent.none { it.contains("TELUGU") } && sent.contains("Open Film"))
        val o = fx.db.openHelper.readableDatabase.query("SELECT posterUrl FROM overrides WHERE itemId = ?", arrayOf(F.OPEN_FILM_A)).use { c -> if (c.moveToFirst()) c.getString(0) else null }
        assertNotNull("matched on the second try", o)
    }

    @Test fun purgedFillsLeaveTheCountsRight() = runBlocking {
        val dir = tmp.newFolder(); val e = engine(dir)
        e.runOnce()
        fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_B, "B", F.names["open"]!!))
        e.onRestrictionsChanged()
        val svc = TmdbService(fx.db, { key }, fx.folders.visibility, dir, { t }, TmdbAuth({ key })) { _, _ -> "{}" }
        assertTrue(svc.purge() > 0); e.resync()
        assertEquals(ArtworkMatchEngine.Result.Complete, e.runOnce())
        assertTrue(e.progress.value.done >= 1)
    }

    @Test fun requestsPerMatchedTitleStayNearOne() = runBlocking {
        val raw = fx.db.openHelper.writableDatabase
        raw.beginTransaction()
        for (i in 0 until 400) raw.execSQL("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES ('syn-$i','A','${F.OPEN_A}','${if (i % 10 == 0) "TELUGU | " else ""}Synthetic Voyage $i${if (i % 10 == 0) " (Telugu) FHD" else ""}',NULL,2020,NULL,NULL,'r$i',1)")
        raw.setTransactionSuccessful(); raw.endTransaction()
        // the answer is a list with the title in it; the "TELUGU | ..." names find nothing until they are cleaned
        net = { u -> val q = titleOf(u); if (q.startsWith("TELUGU")) """{"results":[]}""" else """{"results":[{"id":1,"title":"$q","release_date":"2020-05-05","popularity":5,"poster_path":"/p.jpg","overview":"s"},{"id":2,"title":"$q 2","release_date":"2020-05-05","popularity":9,"poster_path":"/q.jpg"}]}""" }
        val e = engine(tmp.newFolder(), concurrency = 8, page = 200, dispatcher = Dispatchers.IO)
        e.runOnce()
        val matched = overrideIds().count { it.startsWith("syn-") }
        assertEquals(400, matched)
        val perTitle = sent.count { it.contains("Synthetic") } / matched.toDouble()
        assertTrue("requests per matched title: $perTitle", perTitle <= 1.3)
    }

    @Test fun theFastRunStaysUnderTheRateAndShowsARateAndTimeLeftAfterOneHundredTitles() = runBlocking {
        val raw = fx.db.openHelper.writableDatabase
        raw.beginTransaction()
        for (i in 0 until 600) raw.execSQL("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES ('syn-$i','A','${F.OPEN_A}','Rate Test $i',NULL,2020,NULL,NULL,'r$i',1)")
        raw.setTransactionSuccessful(); raw.endTransaction()
        val fast = RequestPacer(22, { t }, { t += it })
        net = { u -> fast.acquire(); found(u) }
        val e = engine(tmp.newFolder(), concurrency = 8, page = 200, dispatcher = Dispatchers.IO)
        var mid: ArtworkMatchEngine.Progress? = null
        val watcher = Thread { while (!Thread.interrupted()) { val p = e.progress.value; if (p.done in 150..500 && p.perSecond > 0) { mid = p; break }; Thread.sleep(2) } }.also { it.isDaemon = true; it.start() }
        e.runOnce(); watcher.interrupt()
        val span = (times.max() - times.min()) / 1000.0
        assertTrue("about 22 a second at most: ${sent.size / span}", sent.size / span <= 25)
        assertNotNull("a rate and time left appear after 100 titles", mid)
        assertTrue(mid!!.line().contains("left"))
        assertFalse("no rate before 100 titles", ArtworkMatchEngine.Progress(50, 500, 0, ArtworkMatchEngine.State.RUNNING).line().contains("left"))
    }

    @Test fun mobileDataIsOnByDefaultAndTheBulkRuleIsPlain() {
        val ui = app.streamsetu.core.settings.UiPrefs(fx.ctx)
        assertTrue("use mobile data defaults on", ui.artworkMatchingCellular.value); assertTrue(ui.artworkMatching.value)
        assertTrue(ArtworkPolicy.decide(connected = true, metered = true, mobileDataOk = ui.artworkMatchingCellular.value, batteryLow = false))
        assertFalse("mobile data switched off", ArtworkPolicy.decide(true, true, false, false))
        assertTrue("Wi-Fi always", ArtworkPolicy.decide(true, false, false, false))
        assertFalse("offline", ArtworkPolicy.decide(false, false, true, false)); assertFalse("battery low", ArtworkPolicy.decide(true, false, true, true))
    }

    // ---- the express lane ----
    private fun express(e: ArtworkMatchEngine, dir: java.io.File, debounce: Long = 25): ArtworkExpress {
        val svc = lastSvc!!
        val call: TmdbCall = { u, b -> pacer.acquire(); times += t; sent += titleOf(u).let { q -> if ("/search/" in u) q else "DETAILS" }; net(u) }
        val cast = TmdbCast({ key }, dir, call, { t }, TmdbAuth({ key }, { null }, dir, { t }), svc.matcher)
        return ArtworkExpress(fx.db, svc, cast, e, fx.folders.visibility, { on }, ArtworkExpress.Config(concurrency = 3, debounceMs = debounce), { t }, Dispatchers.IO, kotlinx.coroutines.CoroutineScope(Dispatchers.Default))
    }
    private fun addSynthetic(n: Int) {
        val raw = fx.db.openHelper.writableDatabase
        raw.beginTransaction(); for (i in 0 until n) raw.execSQL("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES ('syn-${"%04d".format(i)}','A','${F.OPEN_A}','Synthetic Voyage $i',NULL,2020,NULL,NULL,'r$i',1)"); raw.setTransactionSuccessful(); raw.endTransaction()
    }
    private fun waitFor(ms: Long = 5000, cond: () -> Boolean): Boolean { val end = System.currentTimeMillis() + ms; while (System.currentTimeMillis() < end) { if (cond()) return true; Thread.sleep(10) }; return cond() }

    @Test fun aTileOnScreenIsMatchedBeforeTheBulkQueueReachesItAndBulkThenSkipsIt() {
        addSynthetic(300)
        net = { u -> Thread.sleep(2); found(u) }
        val dir = tmp.newFolder(); val e = engine(dir, concurrency = 1, page = 50, dispatcher = Dispatchers.IO); val x = express(e, dir)
        val bulk = Thread { runBlocking { e.runOnce() } }.also { it.start() }
        waitFor { sent.size >= 5 }
        var stored = 0; x.onStored = { stored++ }
        x.tileVisible("syn-0290", true)
        assertTrue("matched within about a second, long before the bulk line gets there", waitFor(1500) { "syn-0290" in overrideIds() })
        assertTrue("the bulk run was nowhere near it: ${sent.size}", sent.size < 200); assertTrue("the screen is told", stored >= 1)
        bulk.join(60_000)
        assertEquals("asked about once only", 1, sent.count { it == "Synthetic Voyage 290" })
    }

    @Test fun scrollingPausesAndOnlyTheNewestTwelveStillOnScreenAreMatched() {
        addSynthetic(60)
        val dir = tmp.newFolder(); val e = engine(dir); val x = express(e, dir, debounce = 150)
        for (i in 0 until 30) x.tileVisible("syn-%04d".format(i), true)
        for (i in 0 until 20) x.tileVisible("syn-%04d".format(i), false)          // scrolled away before the pause
        assertTrue(waitFor { sent.isNotEmpty() }); Thread.sleep(400)
        val titles = sent.toList()
        assertTrue("only what is still visible: $titles", titles.all { q -> (20..29).any { q == "Synthetic Voyage $it" } }); assertEquals(10, titles.size)
        // thirty at once: no more than twelve, the newest
        sent.clear(); for (i in 30 until 60) x.tileVisible("syn-%04d".format(i), true)
        waitFor { sent.size >= 12 }; Thread.sleep(400)
        assertEquals(12, sent.size); assertTrue(sent.all { q -> q.removePrefix("Synthetic Voyage ").toInt() >= 48 })
    }

    @Test fun restrictedTitlesNeverGoThroughTheExpressLaneEvenAfterALock() {
        val dir = tmp.newFolder(); val e = engine(dir); val x = express(e, dir, debounce = 100)
        for (id in listOf(F.SECRET_A, F.HIDDEN_FILM_A, F.ADULT_FILM_A, F.SPLIT_A, F.LONE_B, F.SERIES_SECRET)) x.tileVisible(id, true)
        x.tileVisible(F.OPEN_FILM_B, true)
        runBlocking { fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_B, "B", F.names["open"]!!)) }; e.onRestrictionsChanged()          // locked while waiting
        Thread.sleep(500)
        assertTrue("sent: $sent", sent.none { s -> restrictedTitles.any { it in s } || s == "Open Film" })
    }

    @Test fun theExpressLaneIsSilentWithoutACredentialTheSwitchOrAllowedNetwork() {
        key = null
        val dir = tmp.newFolder(); val e = engine(dir); val x = express(e, dir)
        x.tileVisible(F.OPEN_FILM_A, true); Thread.sleep(300)
        assertEquals(0, sent.size); assertSame(TmdbCast.Details.NONE, runBlocking { x.open(F.OPEN_FILM_A, "Open Film", 2020, false, F.OPEN_A) })
        key = "0123456789abcdef0123456789abcdef"; on = false
        x.tileVisible("m-plain-a", true); Thread.sleep(300); assertEquals(0, sent.size)
    }

    @Test fun openingATitleMatchesAndFetchesDetailsTogetherAndKeepsThePictureForTheBulkRun() {
        val dir = tmp.newFolder(); val e = engine(dir); val x = express(e, dir)
        net = { u -> if ("/search/" in u) found(u) else """{"id":1,"backdrop_path":"/bd.jpg","poster_path":"/pp.jpg","overview":"A story.","vote_average":7.5,"vote_count":500,"credits":{"cast":[{"id":5,"name":"Ann Actor","character":"Neo","profile_path":"/a.jpg"}]},"videos":{"results":[{"site":"YouTube","type":"Trailer","key":"abc123"}]}}""" }
        val d = runBlocking { x.open(F.OPEN_FILM_A, "Open Film", 2020, false, F.OPEN_A) }
        assertEquals(2, sent.size); assertEquals("DETAILS", sent[1])
        assertEquals("https://image.tmdb.org/t/p/w780/bd.jpg", d.backdrop); assertEquals(1, d.cast.size); assertEquals("abc123", d.trailerKey); assertEquals(7.5, d.rating!!, 0.0)
        assertTrue(F.OPEN_FILM_A in overrideIds()); assertTrue(e.isHandled(F.OPEN_FILM_A))
        val before = sent.size; runBlocking { e.runOnce() }
        // name-only policy: the twin copy has the same cleaned name, so the express answer is shared and the bulk run asks nothing for it
        assertEquals("the bulk run did not ask again for this title or its twin", 0, sent.drop(before).count { it == "Open Film" })
        assertEquals(1, runBlocking { fx.db.extras().overrideIdsAmong(listOf(F.OPEN_FILM_A)) }.size)
    }

    @Test fun theExpressLaneKeepsItsOwnReservedShareOfTheRate() {
        val clock = 1_000_000L          // time never moves: the waits are read from the slots
        val waits = ArrayList<Long>()
        val q = RequestPacer(22, 6, { clock }, { waits += it })
        repeat(200) { q.acquire() }          // a long bulk line
        waits.clear()
        ArtworkLane.express { q.acquire(); q.acquire(); q.acquire() }
        assertEquals("express is not queued behind 200 bulk requests: $waits", 2, waits.size)
        assertTrue("then one every 166 ms (6 a second): $waits", waits[0] in 160L..170L && waits[1] in 325L..340L)
        val bulk = ArrayList<Long>(); val r = RequestPacer(22, 6, { clock }, { bulk += it }); repeat(11) { r.acquire() }
        assertEquals("bulk keeps the other 16 a second: one every 62 ms", 62L, bulk[1] - bulk[0])
    }

    @Test fun whatThePersonOpensIsNeverHeldBackByTheBulkRulesAndFailuresAreReportedHonestly() {
        // the bulk run's network rule says no (mobile data off on a metered network), and the matching switch is off
        val dir = tmp.newFolder(); val e = engine(dir, allowed = { false }); val x = express(e, dir)
        assertEquals(ArtworkMatchEngine.Result.Waiting, runBlocking { e.runOnce() })
        on = false
        net = { u -> if ("/search/" in u) found(u) else """{"id":1,"backdrop_path":"/bd.jpg","credits":{"cast":[]}}""" }
        val (d, failure) = runBlocking { x.openChecked(F.OPEN_FILM_A, "Open Film", 2020, false, F.OPEN_A) }
        assertNull(failure); assertEquals("https://image.tmdb.org/t/p/w780/bd.jpg", d.backdrop)
        // a failure comes back as the error, so the screen can say why (and offer Retry); a 429 cools the lane down
        net = { throw IOException("no answer") }
        val bad = runBlocking { x.openChecked("m-plain-b", "Plain Story", 2020, false, F.OPEN_B) }
        assertTrue(bad.second is IOException)
        assertEquals("The details service did not answer. Try again.", TmdbProblem.message(bad.second!!, online = true, builtIn = false))
        assertEquals("You are offline", TmdbProblem.message(bad.second!!, online = false, builtIn = false))
        // Match now overrides the bulk rule for the session
        on = true; net = { u -> found(u) }
        e.matchAnyway(); assertEquals(ArtworkMatchEngine.Result.Complete, runBlocking { e.runOnce() })
    }

    @Test fun theBulkPauseLineSaysWhyInTrueWords() {
        assertEquals("Paused: waiting for Wi-Fi (mobile data is off in Settings). Opening titles still works.", ArtworkMatchEngine.Progress(state = ArtworkMatchEngine.State.WAITING, cause = ArtworkMatchEngine.PauseCause.METERED).line())
        assertTrue(ArtworkMatchEngine.Progress(state = ArtworkMatchEngine.State.WAITING, cause = ArtworkMatchEngine.PauseCause.OFFLINE).line().startsWith("Paused: no connection"))
        assertFalse(ArtworkMatchEngine.PauseCause.entries.any { it.name.contains("SAVER") })
    }
}
