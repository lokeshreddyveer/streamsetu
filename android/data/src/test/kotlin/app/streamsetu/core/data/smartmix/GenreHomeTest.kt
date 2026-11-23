package app.streamsetu.core.data.smartmix

import org.junit.Assert.*
import org.junit.Test

class GenreHomeTest {
    private class Src(val lib: List<Candidate>, val counts: Map<String, Int>, val affinity: List<String> = emptyList()) : CandidateSource {
        override fun pool(request: PoolRequest) = lib
        override fun signals(profileId: String) = Signals()
        override fun matchCandidates(profileId: String) = lib
        override fun genreCounts(profileId: String) = counts
        override fun affinityGenreKeys(profileId: String) = affinity
    }
    private fun lib(genre: String, n: Int, prefix: String) = (0 until n).map { i -> Candidate("$prefix$i", Kind.MOVIE, "$prefix$i", 2020 - i % 3, 10 + i, "7.${i % 9}", 3, false, "English", genres = GenreShelves.tokens(genre)) }
    private fun entries(prefix: String, n: Int) = (0 until n).map { TrendingEntry(it + 1, "movie", "$prefix-key$it".replace("-", " ").let { s -> s }, null, null) }

    @Test fun kidsProfilesGetOnlyTheSevenSafeGenres() {
        assertEquals(7, GenreTable.all.count { it.kids }); assertEquals(setOf("comedy", "animation", "family", "fantasy", "adventure", "music", "kids"), GenreTable.all.filter { it.kids }.map { it.key }.toSet())
        val counts = GenreTable.all.associate { it.key to 20 }
        assertTrue(GenreShelves.select(counts, "p", "2026-11-02", 0, true, listOf("horror", "comedy")).all { GenreTable.of(it)!!.kids })
        assertEquals(7, GenreShelves.browse(counts, true).size); assertEquals(22, GenreShelves.browse(counts, false).size)
    }

    @Test fun fewerThanEightTitlesShowNoShelfAndTheBrowseRowSkipsThem() {
        val svc = SmartMixService(Src(lib("Thriller", 7, "a"), mapOf("thriller" to 7)), InMemorySmartMixStore(), null)
        val h = svc.buildGenres("p", "2026-11-02", false)
        assertTrue(h.shelves.isEmpty()); assertTrue(h.browse.isEmpty())
    }

    @Test fun aShelfAppearsWithTenTitlesAndTheOwnGenresComeFirst() {
        val l = lib("Thriller", 10, "a") + lib("Comedy", 10, "b")
        val svc = SmartMixService(Src(l, mapOf("thriller" to 10, "comedy" to 10), affinity = listOf("comedy")), InMemorySmartMixStore(), null)
        val h = svc.buildGenres("p", "2026-11-02", false)
        assertEquals(listOf("genre:comedy", "genre:thriller"), h.shelves.map { it.result.shelfId })
        assertEquals(listOf("comedy", "thriller"), h.browse.map { it.first.key }.sortedBy { listOf("comedy", "thriller").indexOf(it) })
        assertTrue(h.shelves.all { it.result.ids.size >= 8 })
    }

    @Test fun theChosenViewAndTheTmdbListOrderTheShelf() {
        val l = lib("Thriller", 12, "q")
        val top = (0 until 12).map { TrendingEntry(it + 1, "movie", "q$it", null, null) }
        val lists = RankedLists { name, _ -> if (name == "week:thriller") top else null }
        val svc = SmartMixService(Src(l, mapOf("thriller" to 12)), InMemorySmartMixStore(), null, lists)
        val weekly = svc.build("p", "genre:thriller", "2026-11-02", ShelfView.WEEKLY)
        assertEquals("trendingTMDB", weekly.result.diagnostics.caption); assertTrue(weekly.result.diagnostics.trendMode)
        val allTime = svc.build("p", "genre:thriller", "2026-11-02", ShelfView.ALL_TIME)
        assertEquals("no list for all time: the local ranking stands", "mostWatchedHere", allTime.result.diagnostics.caption)
        assertNotEquals(weekly.result.ids, allTime.result.ids)
    }

    @Test fun anOwnListWithNoMatchesFallsBackToTheWholeLibraryListOfTheSameView() {
        val l = lib("Thriller", 12, "q")
        val general = (0 until 12).map { TrendingEntry(it + 1, "movie", "q$it", null, null) }
        val lists = RankedLists { name, _ -> when (name) { "week:thriller" -> listOf(TrendingEntry(1, "movie", "nothing here", null, null)); "top" -> general; else -> null } }
        val svc = SmartMixService(Src(l, mapOf("thriller" to 12)), InMemorySmartMixStore(), null, lists)
        assertEquals("trendingTMDB", svc.build("p", "genre:thriller", "2026-11-02", ShelfView.ALL_TIME).result.diagnostics.caption)
    }

    @Test fun placementNeverPutsMoreThanTwoGenreShelvesInARow() {
        val out = GenreShelves.placement(emptySet(), listOf("a", "b", "c", "d", "e", "f"))
        assertEquals(listOf("a", "b"), out)
        val all = GenreShelves.placement(setOf("top-week", "trending", "for-you", "lang-pref", "rediscover"), listOf("g1", "g2", "g3", "g4", "g5", "g6"))
        assertEquals(listOf("top-week", "trending", "g1", "for-you", "g2", "g3", "lang-pref", "g4", "rediscover", "g5", "g6"), all)
    }

    @Test fun tmdbGenreIdsComeAsWordsAheadOfTheFolderText() {
        assertEquals(listOf("action", "science fiction"), GenreShelves.tokensForTmdb(listOf(28, 878), false))
        assertEquals("a series reads the TV ids: 10765 is Sci-Fi & Fantasy", listOf("science fiction", "fantasy"), GenreShelves.tokensForTmdb(listOf(10765), true))
        assertEquals(listOf("reality"), GenreShelves.tokensForTmdb(listOf(10764), true)); assertTrue("reality is series only", GenreShelves.tokensForTmdb(listOf(10764), false).isEmpty())
        val c = Candidate("m1", genres = GenreShelves.tokensForTmdb(listOf(53), false) + GenreShelves.tokens("Drama"))
        assertTrue(GenreShelves.matches(GenreTable.of("thriller")!!, c)); assertTrue(GenreShelves.matches(GenreTable.of("drama")!!, c)); assertFalse(GenreShelves.matches(GenreTable.of("comedy")!!, c))
    }
}
