package app.streamsetu.core.data.hub

import app.streamsetu.core.net.HttpStatusException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class MetadataHubTests {
    private class MemFacts : HubFactStore {
        val facts = HashMap<String, Triple<StoredFact, Long?, Boolean>>(); val ids = HashMap<String, HubIdentity>()
        override suspend fun fact(item: String, field: String) = facts["$item|$field"]?.let { it.first to it.second }
        override suspend fun put(item: String, field: String, value: String, source: HubSource, quality: Double, now: Long, keepMs: Long): Boolean {
            val s = facts["$item|$field"]?.first
            if (s != null && s.value.isNotEmpty() && s.expiresAt > now && quality <= s.quality + Arbiter.MARGIN && value != s.value) return false
            facts["$item|$field"] = Triple(StoredFact(value, source, quality, now + keepMs), null, true); return true
        }
        override suspend fun putMiss(item: String, field: String, source: HubSource, until: Long, now: Long) { facts["$item|$field"] = Triple(StoredFact("", source, 0.0, until), until, false) }
        override suspend fun saveIdentity(item: String, incoming: HubIdentity, from: HubSource, now: Long) { ids[item] = HubIdentity.merge(ids[item] ?: HubIdentity(), incoming, HubIdentity.rank(from), 0) }
        override suspend fun identity(item: String) = ids[item]
        override suspend fun provenance(item: String) = facts.filter { it.key.startsWith("$item|") && it.value.third }.map { it.value.first.source }.toSet()
    }
    private fun access(s: HubSource, st: MemoryHubStore = MemoryHubStore(), builtIn: String? = "BUILTIN") = HubAccess(s, st, st, { builtIn })

    private val fanartJson = """{"hdmovielogo":[{"url":"http://assets.fanart.tv/l.png","lang":"en","likes":"5"}],"moviebackground":[{"url":"http://assets.fanart.tv/b.jpg","lang":"","likes":"5"}]}"""

    @Test fun asksFanartOncePerTitleAndStoresTheBestLogo() = runBlocking {
        val calls = ArrayList<HubRequest>(); val facts = MemFacts()
        val hub = MetadataHub(facts, mapOf(HubSource.FANART to access(HubSource.FANART)), { calls += it; fanartJson })
        val id = HubIdentity(tmdb = 603)
        val r1 = hub.refresh("m1", id, HubTitleKind.MOVIE)
        assertEquals(listOf(HubSource.FANART), r1.asked); assertEquals(setOf("logo", "backdrop"), r1.stored.toSet())
        assertEquals("https://assets.fanart.tv/l.png", hub.image("m1", ArtKind.LOGO))
        val r2 = hub.refresh("m1", id, HubTitleKind.MOVIE)
        assertEquals(1, calls.size); assertTrue(r2.asked.isEmpty())
        assertNull(hub.attributionFooter("m1")); assertFalse(calls[0].url.contains("BUILTIN"))
    }

    @Test fun skipsLockedTitlesMissingIdsAndOffSources() = runBlocking {
        val calls = ArrayList<HubRequest>()
        val hub = MetadataHub(MemFacts(), mapOf(HubSource.FANART to access(HubSource.FANART), HubSource.TVDB to access(HubSource.TVDB)), { calls += it; "{}" }, null, { it != "locked" })
        hub.refresh("locked", HubIdentity(tmdb = 1), HubTitleKind.MOVIE); hub.refresh("noid", HubIdentity(), HubTitleKind.SERIES); hub.refresh("ok", HubIdentity(tmdb = 1, tvdb = 2), HubTitleKind.MOVIE)
        assertEquals("only the allowed title with an id is asked (no TheTVDB session here)", 1, calls.size)
    }

    @Test fun anEmptyAnswerIsRemembered() = runBlocking {
        var n = 0; val hub = MetadataHub(MemFacts(), mapOf(HubSource.FANART to access(HubSource.FANART)), { n++; "{}" })
        hub.refresh("m", HubIdentity(tmdb = 9), HubTitleKind.MOVIE); hub.refresh("m", HubIdentity(tmdb = 9), HubTitleKind.MOVIE)
        assertEquals(1, n)
    }

    @Test fun aRefusedBuiltInKeyIsPausedAndTheMissRemembered() = runBlocking {
        val st = MemoryHubStore(); val a = access(HubSource.FANART, st)
        val hub = MetadataHub(MemFacts(), mapOf(HubSource.FANART to a), { throw HttpStatusException(401) })
        hub.refresh("m", HubIdentity(tmdb = 9), HubTitleKind.MOVIE)
        assertTrue(a.builtInRejected); assertEquals(HubAccess.Origin.NONE, a.origin)
    }

    @Test fun seriesGetTheNextEpisodeFromTvmazeAndTheCrosswalk() = runBlocking {
        val show = """{"id":82,"externals":{"thetvdb":121361,"imdb":"tt0944947"},"_embedded":{"nextepisode":{"season":2,"number":1,"airstamp":"2026-12-01T02:00:00+00:00"}}}"""
        val calls = ArrayList<String>(); val facts = MemFacts()
        val hub = MetadataHub(facts, mapOf(HubSource.TVMAZE to access(HubSource.TVMAZE, builtIn = null)), { calls += it.url; show })
        hub.refresh("s1", HubIdentity(tvdb = 121361), HubTitleKind.SERIES)
        assertEquals(2, calls.size); assertTrue(calls[0].contains("lookup/shows?thetvdb=121361")); assertTrue(calls[1].contains("/shows/82?embed"))
        assertEquals("2026-12-01T02:00:00+00:00", hub.text("s1", "nextepisode")); assertEquals(82, facts.ids["s1"]!!.tvmaze)
    }

    @Test fun tvdbLogsInOnceKeepsTheTokenAndRefreshesOn401() {
        val st = MemoryHubStore(); val a = access(HubSource.TVDB, st); a.enabled = true
        var logins = 0; var failNext = false; val seen = ArrayList<HubRequest>()
        val fetch = HubFetch { r -> seen += r; if (r.url.endsWith("/login")) { logins++; """{"data":{"token":"TOKEN-$logins"}}""" } else if (failNext) { failNext = false; throw HttpStatusException(401) } else "{}" }
        val s = TVDBSession(a, st, fetch)
        s.get("/series/1/artworks"); s.get("/series/2/artworks")
        assertEquals(1, logins); assertTrue(seen[0].body!!.contains("BUILTIN")); assertFalse(seen[0].url.contains("BUILTIN"))
        assertTrue(seen.drop(1).all { it.headers["Authorization"]!!.startsWith("Bearer TOKEN-") && !it.url.contains("TOKEN") })
        assertTrue(st.get(HubAccess.TVDB_TOKEN_ACCOUNT)!!.endsWith("TOKEN-1"))
        failNext = true; s.get("/series/3/artworks"); assertEquals(2, logins)
        TVDBSession(a, st, fetch).get("/x"); assertEquals(2, logins)                         // a new launch reads the saved token
        val rej = access(HubSource.TVDB, MemoryHubStore()).also { it.enabled = true }
        try { TVDBSession(rej, MemoryHubStore(), HubFetch { throw HttpStatusException(403) }).get("/x"); fail() } catch (e: HttpStatusException) { assertTrue(rej.builtInRejected) }
    }

    @Test fun theTestButtonReportsOnlyOkRefusedOrNoAnswer() {
        for (s in listOf(HubSource.FANART, HubSource.TVDB, HubSource.TVMAZE)) {
            fun acc() = access(s).also { it.enabled = true }
            fun check(f: HubFetch) = HubTester.check(s, acc(), MemoryHubStore(), f)
            assertTrue("$s", check(HubFetch { """{"data":{"token":"T"}}""" }).first)
            if (s != HubSource.TVMAZE) assertEquals(HubTester.REFUSED, check(HubFetch { throw HttpStatusException(403) }).second)
            assertEquals(HubTester.NO_ANSWER, check(HubFetch { throw java.io.IOException("down") }).second)
        }
        assertFalse(HubTester.check(HubSource.FANART, access(HubSource.FANART, builtIn = null), MemoryHubStore(), HubFetch { "{}" }).first)
    }

    @Test fun statusLinesAndCredits() {
        val st = MemoryHubStore()
        assertEquals("Using the built-in key", access(HubSource.FANART, st).statusLine); assertEquals("Using the built-in key", access(HubSource.TVDB, st).statusLine); assertEquals("Working", access(HubSource.TVMAZE, st, null).statusLine)
        assertEquals("No key available", access(HubSource.FANART, MemoryHubStore(), null).statusLine)
        assertEquals("https://fanart.tv", HubAttribution.FANART_LINK); assertEquals("Data from TheTVDB.com", HubAttribution.TVDB_FOOTER)
    }
}
