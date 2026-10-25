package app.streamsetu.core

import app.streamsetu.core.parse.Xtream
import org.junit.Assert.*
import org.junit.Test

/** Providers lay out the episodes of a series in different ways; every one of them must give the same episodes (the Apple apps read all of them). */
class XtreamEpisodesTests {
    private fun ep(id: Int, n: Int, season: Int? = null) =
        """{"id":"$id","episode_num":$n,"title":"E$n","container_extension":"mkv"${season?.let { ""","season":$it""" } ?: ""},"info":{"plot":"p$n","movie_image":"http://x/$id.jpg","duration_secs":2700}}"""
    private fun parse(json: String) = Xtream.episodes(Xtream.parseObject(json)!!)

    @Test fun anObjectKeyedBySeasonIsRead() {
        val rows = parse("""{"episodes":{"9":[${ep(1, 1)},${ep(2, 2)}],"10":[${ep(3, 1)},${ep(4, 2)},${ep(5, 3)}]}}""")
        assertEquals(5, rows.size); assertEquals(setOf(9, 10), rows.map { it.season }.toSet())
        assertEquals(3, rows.count { it.season == 10 })
    }

    @Test fun anArrayWithOneListPerSeasonIsReadAndCountedFromOne() {
        val rows = parse("""{"episodes":[[${ep(1, 1)}],[${ep(2, 1)},${ep(3, 2)}]]}""")
        assertEquals(3, rows.size); assertEquals(listOf(1, 2, 2), rows.map { it.season })
    }

    @Test fun anEpisodesOwnSeasonFieldWinsOverTheKeyItSitsUnder() {
        val rows = parse("""{"episodes":{"1":[${ep(1, 1, season = 10)},${ep(2, 2, season = 10)}]}}""")
        assertEquals(listOf(10, 10), rows.map { it.season })
    }

    @Test fun aSeasonWhoseEpisodesAreAnObjectKeyedByPositionIsRead() {
        val rows = parse("""{"episodes":{"10":{"0":${ep(1, 1)},"2":${ep(2, 3)},"5":${ep(3, 6)}}}}""")
        assertEquals(3, rows.size); assertTrue(rows.all { it.season == 10 })
    }

    @Test fun aFlatListOfEpisodesIsRead() {
        val rows = parse("""{"episodes":[${ep(1, 1, season = 2)},${ep(2, 2, season = 2)}]}""")
        assertEquals(2, rows.size); assertTrue(rows.all { it.season == 2 })
    }

    @Test fun anEpisodeWithoutANumberGetsItsPositionAndOneWithoutAnIdIsSkipped() {
        val rows = parse("""{"episodes":{"3":[{"id":"7","title":"First"},{"title":"No id"},{"id":"8"}]}}""")
        assertEquals(2, rows.size); assertEquals(listOf(1, 3), rows.map { it.number }); assertEquals("Episode 3", rows[1].title)
    }

    @Test fun missingOrEmptyEpisodesGiveNothingNotAnError() {
        assertTrue(parse("""{"info":{}}""").isEmpty()); assertTrue(parse("""{"episodes":[]}""").isEmpty()); assertTrue(parse("""{"episodes":{}}""").isEmpty()); assertTrue(parse("""{"episodes":false}""").isEmpty())
    }

    @Test fun detailsAndTheStreamExtensionAreKept() {
        val r = parse("""{"episodes":{"1":[${ep(11, 4)}]}}""").single()
        assertEquals("11", r.id); assertEquals(4, r.number); assertEquals("p4", r.plot); assertEquals("http://x/11.jpg", r.image); assertEquals(2700, r.durationSecs); assertEquals("mkv", r.extension)
    }
}
