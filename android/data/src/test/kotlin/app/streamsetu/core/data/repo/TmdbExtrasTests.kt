package app.streamsetu.core.data.repo

import app.streamsetu.core.data.smartmix.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class TmdbExtrasTests {
    @get:Rule val tmp = TemporaryFolder()

    private val search = """{"results":[{"id":603,"title":"Heat","release_date":"1995-12-15","popularity":50.0}]}"""
    private val credits = """{"cast":[{"id":1,"name":"Ann Actor","character":"Neo","profile_path":"/a.jpg"},{"id":2,"name":"No Photo","character":null,"profile_path":null},{"name":"Bad"}]}"""
    private val details = """{"backdrop_path":"/bd.jpg","credits":$credits}"""

    @Test fun castIsParsedWithRoundPhotoAddressesAndRoles() {
        val m = TmdbCast.parseCredits(credits)
        assertEquals(2, m.size)
        assertEquals("Neo", m[0].role); assertEquals("https://image.tmdb.org/t/p/w185/a.jpg", m[0].photo); assertNull(m[1].photo)
        assertEquals(603L, TmdbCast.parseSearch(search))
    }

    @Test fun noKeyMeansNoRequestAndNoRow() {
        var calls = 0
        val c = TmdbCast({ null }, tmp.newFolder(), { _, _ -> calls++; "{}" })
        assertFalse(c.enabled); assertTrue(c.cast("Heat", 1995, false).isEmpty()); assertEquals(0, calls)
    }

    @Test fun castIsKeptAndNotAskedForAgainWithinThirtyDays() {
        val urls = ArrayList<String>()
        var t = 1_000_000_000_000L
        val c = TmdbCast({ "KEY" }, tmp.newFolder(), { u, _ -> urls += u; if ("/search/" in u) search else details }, { t })
        assertEquals(2, c.cast("Heat (1995)", null, false).size)
        assertEquals(2, urls.size)
        assertEquals(2, c.cast("Heat (1995)", null, false).size)
        assertEquals("served from the saved copy", 2, urls.size)
        assertEquals("https://image.tmdb.org/t/p/w780/bd.jpg", c.details("Heat (1995)", null, false).backdrop)
        assertTrue("only the title name and year go out", urls.none { "user" in it.lowercase() || "profile" in it.lowercase() })
    }

    @Test fun trendingListIsParsedRankedAndSaved() {
        val movies = """{"results":[{"title":"Alpha","original_title":"Alfa","release_date":"2026-05-01"},{"title":"Beta","original_title":"Beta","release_date":"2025-01-01"}]}"""
        val e = TmdbTrendingFetcher.parse(movies, "movie")
        assertEquals(listOf(1, 2), e.map { it.rank }); assertEquals("Alfa", e[0].original); assertNull(e[1].original); assertEquals(2026, e[0].year)
        val cache = FileTrendingCache(File(tmp.newFolder(), "t.json"))
        cache.save(TrendingSnapshot(123L, e))
        assertEquals(e, cache.load()!!.entries); assertEquals(123L, cache.load()!!.fetchedAtMillis)
        cache.clear(); assertNull(cache.load())
    }

    @Test fun fetcherSendsOnlyTheKeyAndAsksForThePublicLists() {
        val urls = ArrayList<String>()
        val f = TmdbTrendingFetcher(TmdbAuth({ "K" }), { u, _ -> urls += u; """{"results":[{"title":"X","name":"Y","release_date":"2026-01-01","first_air_date":"2026-01-01"}]}""" })
        assertNotNull(f.fetchWeekly("K"))
        assertEquals(2, urls.size)
        assertTrue(urls.all { it.startsWith("https://api.themoviedb.org/3/trending/") && it.endsWith("?api_key=K") })
    }

    @Test fun savedDataOlderThanOneHundredEightyDaysIsDeleted() {
        val d = tmp.newFolder(); val old = File(d, "old").apply { writeText("x"); setLastModified(1_000L) }; val fresh = File(d, "fresh").apply { writeText("y") }
        assertEquals(1, TmdbFiles.purge(d, System.currentTimeMillis()))
        assertFalse(old.exists()); assertTrue(fresh.exists())
        TmdbFiles.clear(d); assertFalse(fresh.exists())
    }

    @Test fun trendingIsActiveOnlyWithTheSwitchAndAKeyAndPurgedAtTheCap() {
        val cache = InMemoryTrendingCache()
        val fetcher = object : TrendingFetcher { var n = 0; override fun fetchWeekly(apiKey: String): TrendingSnapshot? { n++; return TrendingSnapshot(0, listOf(TrendingEntry(1, "movie", "A"))) } }
        val day = TrendingPolicy.DAY_MS
        assertEquals("off", TrendingProvider(FixedTmdbSettings(true, null), fetcher, cache).view(0).status); assertEquals(0, fetcher.n)
        assertEquals("off", TrendingProvider(FixedTmdbSettings(false, "K"), fetcher, cache).view(0).status); assertEquals(0, fetcher.n)
        val p = TrendingProvider(FixedTmdbSettings(true, "K"), fetcher, cache)
        assertEquals("active", p.view(10 * day).status)
        assertEquals("expired", TrendingProvider(FixedTmdbSettings(true, "K"), object : TrendingFetcher { override fun fetchWeekly(apiKey: String): TrendingSnapshot? = null }, cache).view(10 * day + 40 * day).status)
        assertEquals("the cache is gone past 180 days", "noCache", TrendingProvider(FixedTmdbSettings(true, "K"), object : TrendingFetcher { override fun fetchWeekly(apiKey: String): TrendingSnapshot? = null }, cache).view(10 * day + 200 * day).status)
    }
}
