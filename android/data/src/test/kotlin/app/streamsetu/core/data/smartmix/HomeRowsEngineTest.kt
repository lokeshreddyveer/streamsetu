package app.streamsetu.core.data.smartmix

import org.junit.Assert.*
import org.junit.Test

/** The engine rows of Home v2 (docs/SMART-MIX.md section 10.2): eligibility, hidden rules, oversampling. Small hand-made libraries. */
class HomeRowsEngineTest {
    private fun movie(i: Int, added: Int? = 100, rating: String? = "7.5", genres: List<String> = listOf("drama"), q: Int = 3, series: Boolean = false) =
        Candidate(id = "${if (series) "s" else "m"}$i", kind = if (series) Kind.SERIES else Kind.MOVIE, identityKey = "title $i", year = 2020, addedDays = added, ratingText = rating, qualityRank = q, genres = genres)

    private fun build(lib: List<Candidate>, shelf: String, ctx: Context = Context("p", "2026-11-22")) = SmartMixEngine.buildShelf(IdentityGrouping.prepare(lib, null), shelf, ctx, false)

    @Test fun freshNeedsSixTitlesFromTheLastTwoWeeks() {
        assertTrue(build((0 until 5).map { movie(it, added = 3) } + (5 until 40).map { movie(it, added = 90) }, ShelfSpec.FRESH).hidden)
        val ok = build((0 until 8).map { movie(it, added = 3) } + (8 until 40).map { movie(it, added = 90) }, ShelfSpec.FRESH)
        assertFalse(ok.hidden); assertTrue(ok.ids.all { it.removePrefix("m").toInt() < 8 }); assertTrue(ok.ids.size >= 6)
    }

    @Test fun movieNightTakesGoodFilmsAndBingeTakesGoodSeries() {
        val lib = (0 until 20).map { movie(it) } + (0 until 20).map { movie(it, series = true) } + (20 until 30).map { movie(it, rating = "4.0") } + (30 until 40).map { movie(it, q = 1) }
        val night = build(lib, ShelfSpec.MOVIE_NIGHT); val binge = build(lib, ShelfSpec.BINGE)
        assertFalse(night.hidden); assertTrue(night.ids.all { it.startsWith("m") && it.removePrefix("m").toInt() < 20 })
        assertFalse(binge.hidden); assertTrue(binge.ids.all { it.startsWith("s") })
    }

    @Test fun aRowWithoutPostersIsHiddenNotFilledIn() {
        val lib = (0 until 30).map { movie(it).copy(hasPoster = false) }
        assertTrue(build(lib, ShelfSpec.MOVIE_NIGHT).hidden)
    }

    @Test fun aMoodNeedsItsFloorAndOnlyItsGenres() {
        val lib = (0 until 20).map { movie(it, genres = listOf("thriller")) } + (20 until 40).map { movie(it, genres = listOf("comedy")) }
        val edge = build(lib, "mood:edge", Context("p", "2026-11-22", libraryTotal = 40))
        assertFalse(edge.hidden); assertTrue(edge.ids.all { it.removePrefix("m").toInt() < 20 })
        assertTrue(build(lib, "mood:edge", Context("p", "2026-11-22", libraryTotal = 20_000)).hidden)          // 1.5% of 20,000 is 300 titles
        assertTrue(build(lib, "mood:withKids", Context("p", "2026-11-22")).hidden)
    }

    @Test fun oversamplingOnlyAddsPicksAfterTheNormalOnes() {
        val lib = (0 until 60).map { movie(it, added = (it * 3) % 90, rating = "${5 + it % 5}.0") }
        val plain = build(lib, ShelfSpec.TOP_WEEK); val more = build(lib, ShelfSpec.TOP_WEEK, Context("p", "2026-11-22", oversample = 10))
        assertEquals(14, plain.ids.size); assertEquals(24, more.ids.size)
        assertEquals(plain.ids, more.ids.take(14))
    }
}
