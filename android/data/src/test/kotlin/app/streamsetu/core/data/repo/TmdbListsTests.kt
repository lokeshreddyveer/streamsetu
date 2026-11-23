package app.streamsetu.core.data.repo

import app.streamsetu.core.data.smartmix.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException

class TmdbListsTests {
    @get:Rule val tmp = TemporaryFolder()
    private fun page(vararg titles: String, tv: Boolean = false) = """{"results":[""" + titles.joinToString(",") { """{"id":1,"${if (tv) "name" else "title"}":"$it","${if (tv) "first_air_date" else "release_date"}":"2020-01-01"}""" } + "]}"
    private fun lists(urls: MutableList<String> = ArrayList(), key: String? = "KEY", on: Boolean = true, fail: Boolean = false, now: () -> Long = { 1_000_000_000_000L }) = TmdbLists(TmdbAuth({ key }, { null }, tmp.root, now), tmp.root, { on }, { u, _ -> urls += u; if (fail) throw IOException("x"); if ("/tv/" in u || "discover/tv" in u) page("S1", "S2", tv = true) else page("M1", "M2") }, now)

    @Test fun genreListsAskTheRightQuestionAndNothingElse() {
        val urls = ArrayList<String>(); val l = lists(urls)
        assertTrue(l.refresh("week:thriller"))
        assertEquals("thriller has no TV genre id: only movies are asked", 1, urls.size)
        assertTrue(urls.any { "discover/movie" in it && "with_genres=53" in it && "sort_by=popularity.desc" in it && "include_adult=false" in it && "page=1" in it })
                assertTrue(l.refresh("top:action"))
        assertTrue(urls.any { "discover/movie" in it && "with_genres=28" in it && "sort_by=vote_average.desc" in it && "vote_count.gte=300" in it })
        assertTrue(urls.any { "discover/tv" in it && "with_genres=10759" in it && "vote_count.gte=150" in it })
        assertTrue(l.refresh("week:anime")); assertTrue(urls.any { "with_original_language=ja" in it })
        assertTrue("nothing about the person or library", urls.none { listOf("profile", "library", "user", "device", "title").any { w -> w in it.lowercase().substringAfter("?") } })
        assertFalse("a genre without TMDB ids has no list", l.refresh("week:biography"))
    }

    @Test fun topListsInterleaveAndRenumber() {
        val urls = ArrayList<String>(); val l = lists(urls)
        assertTrue(l.refresh("top")); tmp.root.listFiles()!!.forEach { it.setLastModified(1_000_000_000_000L) }
        assertEquals(4, urls.size); assertTrue(urls.any { "movie/top_rated" in it && "page=2" in it }); assertTrue(urls.any { "tv/top_rated" in it && "page=1" in it })
        val e = l.entries("top", 0)!!
        assertEquals(listOf("M1", "S1", "M2", "S2", "M1", "S1", "M2", "S2"), e.map { it.title }); assertEquals((1..8).toList(), e.map { it.rank })
        assertEquals(listOf("movie", "tv", "movie", "tv"), e.take(4).map { it.type })
    }

    @Test fun cacheIsUsedFor30DaysDeletedAt180AndRefetchedByAge() {
        var t = 1_000_000_000_000L; val urls = ArrayList<String>(); val l = lists(urls, now = { t })
        l.refresh("week:drama"); tmp.root.listFiles()!!.forEach { it.setLastModified(t) }
        assertNotNull(l.entries("week:drama", t)); assertFalse(l.isStale("week:drama"))
        t += 25 * 3_600_000L; assertTrue("week lists are refetched after 24 hours", l.isStale("week:drama")); assertNotNull("but still used", l.entries("week:drama", t))
        l.refresh("top:drama"); tmp.root.listFiles()!!.forEach { it.setLastModified(t) }
        t += 100 * 3_600_000L; assertFalse("others wait a week", l.isStale("top:drama"))
        t += 70 * 3_600_000L; assertTrue(l.isStale("top:drama"))
        tmp.root.listFiles()!!.forEach { it.setLastModified(1_000_000_000_000L) }; t = 1_000_000_000_000L + 31 * TmdbFiles.DAY_MS; assertNull("past 30 days it is not used", l.entries("week:drama", t))
        t = 1_000_000_000_000L + 181 * TmdbFiles.DAY_MS; assertNull(l.entries("week:drama", t)); assertEquals("and deleted", 0, tmp.root.listFiles { f -> f.name.contains("week_drama") }!!.size)
    }

    @Test fun failuresKeepTheOldCopyAndNoCredentialOrSwitchOffAsksNothing() {
        val t = 1_000_000_000_000L
        lists(now = { t }).refresh("week:comedy"); tmp.root.listFiles()!!.forEach { it.setLastModified(t - 2 * TmdbFiles.DAY_MS) }
        assertFalse(lists(fail = true, now = { t }).refresh("week:comedy")); assertNotNull("old copy kept", lists(now = { t }).entries("week:comedy", t))
        val urls = ArrayList<String>()
        assertFalse(lists(urls, key = null).refresh("week:horror")); assertFalse(lists(urls, on = false).refresh("week:horror")); assertTrue(urls.isEmpty())
        assertNull(lists(on = false, now = { t }).entries("week:comedy", t)); assertNull(lists(key = null, now = { t }).entries("week:comedy", t))
        TmdbFiles.clear(tmp.root); assertEquals(0, tmp.root.listFiles { f -> f.name.startsWith(TmdbLists.PREFIX) }!!.size)
    }
}
