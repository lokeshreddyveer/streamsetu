package app.streamsetu.core.data.hub

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** The shared hub cases (artwork/fixtures): the same answers as the Apple app. Fake keys only. */
class HubTests {
    private fun fixture(name: String): String {
        var d: File? = File("").absoluteFile; var f: File? = null
        while (d != null && f == null) { File(d, "artwork/fixtures/$name").takeIf { it.isFile }?.let { f = it }; d = d.parentFile }
        assumeTrue("the shared fixtures are not next to this checkout", f != null)
        return f!!.readText()
    }
    private fun json(name: String) = Json.parseToJsonElement(fixture(name))
    private fun JsonElement?.s() = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonElement?.i() = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.intOrNull
    private fun ctx(o: JsonObject) = ArtContext(o["preferredLang"].s() ?: "en", o["originalLang"].s())
    private fun cand(o: JsonObject, k: ArtKind) = ArtCandidate(k, o["url"].s()!!, HubSource.of(o["source"].s())!!, o["lang"].s(), o["width"].i()!!, o["height"].i()!!, o["likes"].i() ?: 0)
    private fun ids(o: JsonObject) = HubIdentity(o["tmdb"].i(), o["tvdb"].i(), o["imdb"].s(), o["tvmaze"].i())

    private fun picks(file: String, kind: ArtKind) {
        val cases = json(file).jsonObject["pick"]!!.jsonArray
        assertTrue(cases.size >= 5)
        for (e in cases) {
            val c = e.jsonObject
            val got = Arbiter.pick(kind, c["candidates"]!!.jsonArray.map { cand(it.jsonObject, kind) }, ctx(c["ctx"]!!.jsonObject))?.candidate?.url
            assertEquals(c["notes"].s(), c["expected"].s(), got)
        }
    }
    @Test fun posterFixtures() = picks("arbiter-poster.json", ArtKind.POSTER)
    @Test fun logoFixtures() = picks("arbiter-logo.json", ArtKind.LOGO)

    @Test fun replaceFixtures() {
        for (e in json("arbiter-poster.json").jsonObject["replace"]!!.jsonArray) {
            val c = e.jsonObject
            val stored = (c["stored"] as? JsonObject)?.let { s ->
                val q = if (s["quality"].s() == "pinned") Double.POSITIVE_INFINITY else s["quality"].s()!!.toDouble()
                StoredFact("x", HubSource.of(s["source"].s())!!, q, if (s["expired"]!!.jsonPrimitive.boolean) -1 else 1000, s["failCount"].i()!!)
            }
            val pick = Arbiter.Pick(ArtCandidate(ArtKind.POSTER, "n", HubSource.FANART, "en", 1000, 1500), c["candidateScore"].s()!!.toDouble())
            assertEquals(c["notes"].s(), c["expected"]!!.jsonPrimitive.boolean, Arbiter.shouldReplace(stored, pick, 0))
        }
    }

    @Test fun backdropNeedsTextless16by9AndWidth() {
        fun b(lang: String?, w: Int, h: Int) = ArtCandidate(ArtKind.BACKDROP, "u$w", HubSource.TMDB, lang, w, h)
        val c = ArtContext()
        assertNull(Arbiter.pick(ArtKind.BACKDROP, listOf(b("en", 1920, 1080)), c))
        assertNull(Arbiter.pick(ArtKind.BACKDROP, listOf(b(null, 1280, 720)), c))
        assertNull(Arbiter.pick(ArtKind.BACKDROP, listOf(b(null, 1920, 1200)), c))
        assertEquals(3840, Arbiter.pick(ArtKind.BACKDROP, listOf(b("", 1920, 1080), b(null, 3840, 2160)), c)!!.candidate.width)
        assertEquals(1920, Arbiter.pick(ArtKind.BACKDROP, listOf(b("", 1920, 1080), b(null, 3840, 2160)), ArtContext(largeScreen = false))!!.candidate.width)
    }

    @Test fun targetQualityStopsFanOut() {
        val good = StoredFact("u", HubSource.TMDB, 1100.0, 100)
        assertTrue(Arbiter.atTarget(ArtKind.POSTER, good, 0)); assertFalse(Arbiter.atTarget(ArtKind.POSTER, null, 0))
        assertFalse(Arbiter.atTarget(ArtKind.POSTER, good.copy(quality = 400.0), 0)); assertFalse(Arbiter.atTarget(ArtKind.POSTER, good.copy(expiresAt = -1), 0))
    }

    @Test fun identityFixtures() {
        val root = json("identity.json").jsonObject
        for (e in root["merge"]!!.jsonArray) {
            val c = e.jsonObject; val src = HubSource.of(c["incomingSource"].s())!!
            val got = HubIdentity.merge(ids(c["existing"]!!.jsonObject), ids(c["incoming"]!!.jsonObject), HubIdentity.rank(src), if (src == HubSource.PLAYLIST) 99 else 0)
            assertEquals(c["notes"].s(), ids(c["expected"]!!.jsonObject), got)
        }
        for (e in root["queryID"]!!.jsonArray) {
            val c = e.jsonObject
            assertEquals("$c", c["expected"].s(), ids(c["identity"]!!.jsonObject).queryId(HubSource.of(c["source"].s())!!, if (c["kind"].s() == "movie") HubTitleKind.MOVIE else HubTitleKind.SERIES))
        }
        for (e in root["imdb"]!!.jsonArray) assertEquals(e.jsonObject["expected"].s(), HubIdentity.imdbId(e.jsonObject["input"].s()))
    }

    @Test fun episodeTextFixtures() {
        for (e in json("arbiter-episode-text.json").jsonArray) {
            val c = e.jsonObject
            val got = EpisodeTextArbiter.choose(c["stored"].s(), HubSource.of(c["storedSource"].s()), c["candidates"]!!.jsonArray.map { EpisodeTextArbiter.Candidate(HubSource.of(it.jsonObject["source"].s())!!, it.jsonObject["text"].s()!!) })
            assertEquals(c["notes"].s(), c["expectedText"].s(), got?.text); assertEquals(c["notes"].s(), c["expectedSource"].s(), got?.source?.key)
        }
    }

    @Test fun ratingNeverBlends() {
        assertEquals(8.2, RatingArbiter.value(8.2, 1500, "5.5", 9.9)!!, 0.0)
        assertEquals(5.5, RatingArbiter.value(8.2, 9, "5.5", 9.9)!!, 0.0)
        assertEquals(8.9, RatingArbiter.value(null, null, null, 8.9)!!, 0.0)
        assertNull(RatingArbiter.value(10.0, 2, "0", null))
    }

    @Test fun tvdbFooterOnlyForTvdbProvenance() {
        for (e in json("attribution.json").jsonArray) {
            val c = e.jsonObject
            val prov = c["provenance"]!!.jsonArray.mapNotNull { HubSource.of(it.s()) }.toSet()
            assertEquals(c["expected"].s(), HubAttribution.footer(prov, c["onScreens"]!!.jsonPrimitive.boolean))
        }
        assertFalse(HubDefaults.TVDB_ATTRIBUTION_ON_SCREENS)
        assertNull(HubAttribution.footer(setOf(HubSource.TMDB, HubSource.FANART, HubSource.TVMAZE)))
        assertNull(HubAttribution.footer(setOf(HubSource.TVDB)))
    }

    @Test fun fanartParsesAndKeepsKeysOutOfTheUrl() {
        val movie = FanartProvider.parse(fixture("fanart-movie-603.json"), HubTitleKind.MOVIE)
        assertEquals(2, movie.count { it.kind == ArtKind.LOGO }); assertTrue(movie.all { it.url.startsWith("https://") })
        assertTrue(QualityScorer.isTextless(movie.first { it.kind == ArtKind.BACKDROP }.lang))
        val tv = FanartProvider.parse(fixture("fanart-tv-121361.json"), HubTitleKind.SERIES)
        assertEquals(1, tv.count { it.kind == ArtKind.SEASON_POSTER }); assertEquals(1, tv.first { it.kind == ArtKind.SEASON_POSTER }.season)
        assertTrue(FanartProvider.parse(fixture("fanart-tv-121361.json"), HubTitleKind.MOVIE).isEmpty())
        val req = FanartProvider.request(HubTitleKind.SERIES, "121361", FanartKeys("FAKE-PROJECT-KEY", "FAKE-PERSONAL-KEY"))
        assertFalse(req.url.contains("FAKE")); assertEquals("https://webservice.fanart.tv/v3.2/tv/121361", req.url)
        assertEquals("FAKE-PROJECT-KEY", req.headers["api-key"]); assertEquals("FAKE-PERSONAL-KEY", req.headers["client-key"])
        assertNull(FanartProvider.request(HubTitleKind.MOVIE, "603", FanartKeys("K", null)).headers["client-key"])
        assertFalse(req.toString().contains("FAKE")); assertFalse(FanartKeys("FAKE", null).toString().contains("FAKE"))
    }

    @Test fun tvdbParsesAndLogsInWithTheKeyOnlyInTheBody() {
        val a = TVDBProvider.parseArtworks(fixture("tvdb-artworks.json"), HubTitleKind.SERIES)
        assertEquals(3, a.size)
        assertEquals("en", a.first { it.kind == ArtKind.POSTER }.lang); assertEquals("", a.first { it.kind == ArtKind.BACKDROP }.lang); assertEquals("hi", a.first { it.kind == ArtKind.LOGO }.lang)
        val login = TVDBProvider.loginRequest("FAKE-TVDB-KEY", "1234")
        assertEquals("POST", login.method); assertTrue(login.body!!.contains("FAKE-TVDB-KEY")); assertFalse(login.url.contains("FAKE"))
        val req = TVDBProvider.authorized("/series/1/artworks", "TOKEN-1")
        assertEquals("Bearer TOKEN-1", req.headers["Authorization"]); assertFalse(req.url.contains("TOKEN"))
        assertEquals("T", TVDBProvider.parseToken("""{"data":{"token":"T"}}"""))
        assertEquals("tok:en" to 5L, TVDBProvider.decodeToken(TVDBProvider.encodeToken("tok:en", 5)))
    }

    @Test fun tvmazeParsesShowAndSchedule() {
        val s = TVmazeProvider.parseShow(fixture("tvmaze-show-82.json"))!!
        assertEquals(HubIdentity(null, 121361, "tt0944947", 82, HubTitleKind.SERIES), s.ids); assertEquals("Running", s.status); assertEquals(8.9, s.rating!!, 0.0)
        assertEquals(2, s.episodes.size); assertEquals(2, s.seasons.size); assertEquals(2, s.seasons[0].episodeCount)
        assertEquals("The first episode.", s.episodes[0].summary); assertEquals("https://static.tvmaze.com/o.jpg", s.episodes[0].imageUrl)
        assertEquals("2026-12-01T02:00:00+00:00", s.next!!.airstamp); assertEquals("Back again.", s.next!!.summary)
        val sch = TVmazeProvider.parseSchedule(fixture("tvmaze-schedule-web.json"))
        assertEquals(2, sch.size); assertEquals(121361, sch[0].tvdb); assertNull(sch[1].imdb); assertEquals(3, sch[0].season)
        assertTrue(TVmazeProvider.showRequest(HubIdentity(tvmaze = 82))!!.url.contains("embed[]=nextepisode"))
        assertEquals("https://api.tvmaze.com/lookup/shows?thetvdb=121361", TVmazeProvider.showRequest(HubIdentity(tvdb = 121361))!!.url)
        assertNull(TVmazeProvider.showRequest(HubIdentity(tmdb = 5)))
    }

    @Test fun tmdbImagesAndExtras() {
        val c = TMDBProvider.parseImages(fixture("tmdb-images.json"))
        assertEquals(3, c.size); assertNull(c.first { it.kind == ArtKind.BACKDROP }.lang)
        assertTrue(Arbiter.pick(ArtKind.BACKDROP, c, ArtContext())!!.candidate.url.endsWith("/b.jpg"))
        val root = json("tmdb-details-extras.json").jsonObject
        val s = TMDBExtras.parse(root["series"].toString(), true)!!; val es = root["expectedSeries"]!!.jsonObject
        assertEquals(ids(es["ids"]!!.jsonObject).copy(kind = HubTitleKind.SERIES), s.ids)
        assertEquals(es["translations"]!!.jsonObject.mapValues { it.value.s()!! }, s.translations)
        val m = TMDBExtras.parse(root["movie"].toString(), false)!!
        assertNull(m.ids.tvdb); assertEquals("tt0133093", m.ids.imdb); assertEquals(603, m.ids.tmdb)
    }

    @Test fun tvmazeNeverExceedsTenCallsPerTenSeconds() {
        val b = TokenBucket(HubPolicy.TVMAZE, 0); val times = mutableListOf<Long>()
        var t = 0L; while (t < 120_000) { if (b.take(t) == 0L) times += t; t += 100 }
        for (s in times) assertTrue("window at $s", times.count { it >= s && it < s + 10_000 } <= 10)
        assertTrue(times.size > 50)
    }

    @Test fun breakerOpensAfterFiveFailuresAndProbesOnce() {
        val b = CircuitBreaker(); repeat(4) { b.failure(0) }
        val a1 = b.allow(0); b.failure(0)
        val a2 = b.allow(899_000); val a3 = b.allow(901_000); val a4 = b.allow(902_000)
        b.failure(902_000); val a5 = b.allow(903_000); val a6 = b.allow(902_000 + 901_000); b.success(); val a7 = b.allow(2_000_000)
        assertTrue(a1 && !a2 && a3 && !a4 && !a5 && a6 && a7)
    }

    @Test fun negativeCacheDurations() {
        assertEquals(30L * 86_400_000, NegativeCache.missUntil(NegativeCache.Outcome.NotFound, 0))
        assertEquals(6L * 3_600_000, NegativeCache.missUntil(NegativeCache.Outcome.ServerError, 0))
        assertNull(NegativeCache.missUntil(NegativeCache.Outcome.Offline, 0))
        assertEquals(NegativeCache.Outcome.NotFound, NegativeCache.outcome(404, null))
        assertEquals(10.0, NegativeCache.backoffSeconds(null, 0), 0.0); assertEquals(900.0, NegativeCache.backoffSeconds(null, 20), 0.0); assertEquals(30.0, NegativeCache.backoffSeconds(30.0, 3), 0.0)
    }

    @Test fun queueExpressBeforeBulkDedupedAndCapped() {
        val q = HubQueue(HubPolicy.TVDB, 0)
        q.enqueue("a", HubLane.BULK); q.enqueue("b", HubLane.BULK); q.enqueue("b", HubLane.BULK); q.enqueue("c", HubLane.EXPRESS)
        val n1 = q.next(0)?.first; val n2 = q.next(0)?.first; val n3 = q.next(0)?.first
        q.enqueue("b", HubLane.EXPRESS); val n4 = q.next(0)?.first
        q.finish("c"); val n5 = q.next(0)?.first; val dup = q.enqueue("b", HubLane.EXPRESS)
        assertEquals(listOf("c", "a", null, null, "b"), listOf(n1, n2, n3, n4, n5)); assertFalse(dup)
    }

    @Test fun fanartRefusesBulkAndHasADailyCap() {
        val q = HubQueue(HubPolicy.FANART, 0)
        assertFalse(q.enqueue("x", HubLane.BULK)); assertNull(q.next(0))
        var served = 0
        for (i in 0 until 400) { q.enqueue("t$i", HubLane.EXPRESS); q.next(0)?.let { served++; q.finish(it.first) } }
        assertEquals(HubPolicy.FANART.perDayCap, served); assertNotNull(q.next(2 * HubPolicy.DAY))
        assertTrue(!HubPolicy.FANART.bulkAllowed && HubPolicy.FANART.refillPerSecond <= 2 && HubPolicy.TVDB.keepMs == 7 * HubPolicy.DAY && HubPolicy.TMDB.keepMs == 180 * HubPolicy.DAY)
    }

    @Test fun resolutionOrderDefaultsAndPause() {
        val st = MemoryHubStore(); var now = 1_000L
        val fan = HubAccess(HubSource.FANART, st, st, { "BUILTIN" }) { now }
        assertEquals(HubAccess.Origin.BUILT_IN, fan.origin); assertEquals(FanartKeys("BUILTIN", null), fan.fanartKeys())
        fan.setOwnKey("  MINE  ")
        assertEquals(HubAccess.Origin.OWN, fan.origin); assertEquals(FanartKeys("BUILTIN", "MINE"), fan.fanartKeys())            // the personal key is sent in addition
        assertEquals(HubAccess.Origin.NONE, HubAccess(HubSource.FANART, MemoryHubStore().let { it }, MemoryHubStore(), { null }).origin)
        val tvdb = HubAccess(HubSource.TVDB, st, st, { "BUILTIN" }) { now }
        // TheTVDB's built-in key is on by default now (owner's decision); the person's switch still turns it off.
        assertTrue(tvdb.enabled && tvdb.origin == HubAccess.Origin.BUILT_IN && HubDefaults.TVDB_BUILT_IN_DEFAULT_ON && tvdb.statusLine == "Using the built-in key")
        tvdb.enabled = false; assertTrue(tvdb.origin == HubAccess.Origin.NONE && tvdb.statusLine == "Off"); tvdb.enabled = true; assertEquals(HubAccess.Origin.BUILT_IN, tvdb.origin)
        assertEquals(HubAccess.Origin.BUILT_IN, HubAccess(HubSource.TVMAZE, st, st, { null }).origin)
        val s2 = MemoryHubStore(); val a = HubAccess(HubSource.FANART, s2, s2, { "BUILTIN" }) { now }
        a.markBuiltInRejected(); assertEquals(HubAccess.Origin.NONE, a.origin)
        now += 6 * 86_400_000L; assertEquals(HubAccess.Origin.NONE, a.origin)
        now += 86_400_000L + 1; assertEquals(HubAccess.Origin.BUILT_IN, a.origin)
        a.markBuiltInRejected(); a.setOwnKey("mine"); assertFalse(a.builtInRejected)
    }
}
