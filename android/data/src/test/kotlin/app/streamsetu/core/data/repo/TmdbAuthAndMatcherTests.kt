package app.streamsetu.core.data.repo

import app.streamsetu.core.net.HttpStatusException
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TmdbAuthAndMatcherTests {
    @get:Rule val tmp = TemporaryFolder()
    private val token = "eyJhbGciOi.fake-payload_x.fake-signature_y"      // a made-up value with the shape of a token

    @Test fun theOwnKeyBeatsTheBuiltInTokenAndTheShapeDecidesHowItIsSent() {
        val v3 = TmdbAuth({ "0123456789abcdef0123456789abcdef" }, { "BUILTIN" })
        assertEquals(TmdbAuth.Source.OWN_KEY, v3.source)
        val seen = ArrayList<Pair<String, String?>>()
        v3.call("search/movie", "query=Heat") { u, b -> seen += u to b; "{}" }
        assertTrue(seen[0].first.endsWith("?query=Heat&api_key=0123456789abcdef0123456789abcdef")); assertNull("a v3 key never goes in a header", seen[0].second)
        val v4 = TmdbAuth({ token }, { "BUILTIN" })
        assertEquals(TmdbAuth.Source.OWN_TOKEN, v4.source)
        v4.call("configuration") { u, b -> seen += u to b; "{}" }
        assertEquals(token, seen[1].second); assertFalse("a token never goes in the address", "eyJ" in seen[1].first || "api_key" in seen[1].first)
    }

    @Test fun withoutAnOwnKeyTheBuiltInTokenGoesInTheHeaderAndWithoutEitherNothingIsAsked() {
        val b = TmdbAuth({ null }, { token })
        assertEquals(TmdbAuth.Source.BUILT_IN, b.source)
        var header: String? = null; var url = ""
        b.call("trending/movie/week") { u, h -> url = u; header = h; "{}" }
        assertEquals(token, header); assertEquals("https://api.themoviedb.org/3/trending/movie/week", url)
        var calls = 0
        val none = TmdbAuth({ " " }, { null })      // a build without a token
        assertFalse(none.available); assertNull(none.source)
        assertTrue(runCatching { none.call("configuration") { _, _ -> calls++; "{}" } }.isFailure); assertEquals(0, calls)
    }

    @Test fun aRefusedBuiltInTokenIsSetAsideAndRemembered() {
        val dir = tmp.newFolder(); var t = 1_000_000_000_000L
        val a = TmdbAuth({ null }, { token }, dir, { t })
        assertTrue(runCatching { a.call("configuration") { _, _ -> throw HttpStatusException(401) } }.isFailure)
        assertFalse(a.available); assertTrue(a.builtInRefused)
        var calls = 0
        assertTrue(runCatching { a.call("configuration") { _, _ -> calls++; "{}" } }.isFailure); assertEquals("not asked again", 0, calls)
        assertTrue("remembered by a new start", TmdbAuth({ null }, { token }, dir, { t }).builtInRefused)
        assertTrue("the person's own key still works", TmdbAuth({ "0123456789abcdef0123456789abcdef" }, { token }, dir, { t }).available)
        t += 8 * TmdbFiles.DAY_MS
        assertTrue("tried again after the pause", TmdbAuth({ null }, { token }, dir, { t }).available)
    }

    @Test fun anOwnKeyThatIsRefusedDoesNotDisableTheBuiltInToken() {
        val a = TmdbAuth({ "0123456789abcdef0123456789abcdef" }, { token }, tmp.newFolder())
        runCatching { a.call("configuration") { _, _ -> throw HttpStatusException(401) } }
        assertFalse(a.builtInRefused)
    }

    private fun results(vararg r: String) = """{"results":[${r.joinToString(",")}]}"""
    private fun movie(id: Int, title: String, year: Int, pop: Double = 10.0) = """{"id":$id,"title":"$title","release_date":"$year-01-01","popularity":$pop,"poster_path":"/$id.jpg","overview":"s$id"}"""

    private fun matcher(handler: (String) -> String) = TmdbMatcher(TmdbAuth({ "0123456789abcdef0123456789abcdef" }), { u, _ -> handler(u) })

    @Test fun theCleanedNameIsSearchedOnceWithoutTheYearAndThatIsUsuallyEnough() {
        val asked = ArrayList<String>()
        val m = matcher { u -> asked += java.net.URLDecoder.decode(u.substringAfter("query=").substringBefore("&"), "UTF-8"); results(movie(7, "Pushpa The Rise", 2021)) }
        val r = m.match("movie", "TELUGU | Pushpa The Rise (Telugu) FHD 2026", 2021)
        assertEquals(7L, r?.id); assertEquals(listOf("Pushpa The Rise"), asked)
    }

    @Test fun everyEpisodeOfASeriesInheritsOneSearchAndAMarkerOnlyNameBorrowsTheFolder() {
        val urls = ArrayList<String>()
        val m = matcher { u -> urls += u; """{"results":[{"id":77,"name":"The Silent Harbor","first_air_date":"2019-01-01","poster_path":"/p.jpg"}]}""" }
        for (n in listOf("The Silent Harbor S01E01 1080p", "The Silent Harbor S01E02", "The.Silent.Harbor.S02E10.WEB-DL", "The Silent Harbor - Episode 4")) assertEquals(77L, m.match("tv", n, null)?.id)
        assertEquals("one search for the whole series: $urls", 1, urls.size)
        assertEquals(77L, m.match("tv", "S01E04", null, folderName = "The Silent Harbor")?.id); assertEquals(1, urls.size)
        assertNull(m.match("tv", "S01E05", null)); assertEquals(1, urls.size)
    }

    @Test fun theAliasIndexIsConsultedByNameOnlyAndTheDetailsAreFetchedById() {
        val urls = ArrayList<String>()
        val m = matcher { u -> urls += u; if ("/search/" in u) """{"results":[]}""" else """{"id":256740,"title":"Baahubali: The Beginning","release_date":"2015-07-10","poster_path":"/p.jpg"}""" }
        m.aliasExactEnabled = true; m.aliasPhoneticEnabled = true   // off by default (measured: no net gain)
        m.aliasIndex = AliasIndex.parse("baahubali the beginning\tm\t256740\t90\n\u0c2c\u0c3e\u0c39\u0c41\u0c2c\u0c32\u0c3f\tm\t256740\t90\n".toByteArray())
        assertEquals(256740L, m.match("movie", "Baahubali: The Beginning", null)?.id)
        assertTrue(urls.any { it.contains("/movie/256740") })
        assertEquals(256740L, m.match("movie", "Bahubali The Beginning", null)?.id)
    }

    @Test fun oneSearchWithoutTheYearIsEnoughAndTheYearIsUsedLocally() {
        val urls = ArrayList<String>()
        val m = matcher { u -> urls += u; results(movie(1, "Distinctive Voyage Home", 1990), movie(2, "Distinctive Voyage Home", 2019, 3.0), movie(3, "Distinctive Voyage Home", 2021, 80.0)) }
        assertEquals("name only: the first same-name result in order", 1L, m.match("movie", "Distinctive Voyage Home", 2020)?.id)
        assertEquals(1, urls.size); assertTrue(urls[0].contains("language=en-US") && urls[0].contains("include_adult=false")); assertFalse("year=" in urls[0])
    }

    @Test fun whenNothingIsSureTheLastWordAndTheFirstWordAreTriedAndThenItStopsUnmatched() {
        val asked = ArrayList<String>()
        val m = matcher { u -> asked += java.net.URLDecoder.decode(u.substringAfter("query=").substringBefore("&"), "UTF-8"); results(movie(2, "Another Thing Entirely", 1990)) }
        assertNull(m.match("movie", "Distinctive Voyage Home", 2020))
        assertEquals(listOf("Distinctive Voyage Home", "Distinctive Voyage", "Voyage Home"), asked)
    }

    @Test fun theProviderOwnTmdbIdIsFetchedWithNoSearch() {
        val urls = ArrayList<String>()
        val m = matcher { u -> urls += u; """{"id":603,"title":"Anything At All","release_date":"1999-03-31","poster_path":"/p.jpg","overview":"s"}""" }
        val r = m.match("movie", "A name that matches nothing", 2001, providerTmdbId = 603)
        assertEquals(603L, r?.id); assertEquals(1, urls.size); assertTrue("/movie/603" in urls[0] && "search" !in urls[0])
        // an id TMDB does not know falls back to the search
        val gone = ArrayList<String>()
        val f = TmdbMatcher(TmdbAuth({ "0123456789abcdef0123456789abcdef" }), { u, _ -> gone += u; if ("/movie/9" in u) throw app.streamsetu.core.net.HttpStatusException(404) else results(movie(5, "Heat", 1995)) })
        assertEquals(5L, f.match("movie", "Heat (1995)", null, providerTmdbId = 9)?.id)
    }

    @Test fun aDifferentNameIsNeverTakenAndTheFirstSameNameResultWins() {
        assertNull(matcher { results(movie(1, "Heat 2", 1995), movie(2, "Closed Book", 1995)) }.match("movie", "Heat", 1995))
        assertEquals("year and popularity are not read", 1L, matcher { results(movie(1, "Heat", 1972, 1.0), movie(2, "Heat", 1995, 99.0)) }.match("movie", "Heat", 1995)?.id)
        assertEquals("no year is needed", 1L, matcher { results(movie(1, "Heat", 1995, 1.0)) }.match("movie", "Heat", null)?.id)
        assertEquals("a year far out does not matter", 1L, matcher { results(movie(1, "Heat", 1996, 50.0)) }.match("movie", "Heat", 2020)?.id)
    }

    @Test fun progressLinesReadWell() {
        val p = ArtworkMatchEngine.Progress(1204, 3218, 61, ArtworkMatchEngine.State.RUNNING)
        assertEquals("Matching artwork: 1,204 of 3,218 done · 61 not found", p.line(locale = java.util.Locale.US))
        assertEquals("All artwork matched · 61 not found", p.copy(done = 3218, state = ArtworkMatchEngine.State.COMPLETE).line(locale = java.util.Locale.US))
        assertEquals("All artwork matched", ArtworkMatchEngine.Progress(5, 5, 0, ArtworkMatchEngine.State.COMPLETE).line())
        assertTrue(ArtworkMatchEngine.Progress(state = ArtworkMatchEngine.State.NO_KEY).line(builtInRefused = true).startsWith("The built-in key is not working"))
    }
}
