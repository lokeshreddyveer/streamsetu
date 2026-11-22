package app.streamsetu.core.data.smartmix

import org.junit.Assert.*
import org.junit.Test

class EngineTest {
    private fun ctx(n: Int = 0, day: String = "2026-11-21", profile: String = "main", lang: String? = null, poolCap: Int? = null) =
        Context(profile, day, n, preferredLang = lang, poolCap = poolCap)
    private fun run(l: List<Candidate>, shelf: String, c: Context = ctx(), ordered: Boolean = false) =
        SmartMixEngine.buildShelf(IdentityGrouping.prepare(l, c.preferredLang), shelf, c, ordered)
    private fun lib(n: Int) = (0 until n).map { cand(it, kind = if (it % 3 == 0) Kind.SERIES else Kind.MOVIE, lang = listOf("Telugu", "Hindi", "Tamil")[it % 3], year = 2010 + it % 17, q = 1 + it % 5, backdrop = it % 4 == 0) }

    @Test fun deterministicAndInputOrderIndependent() {
        val l = lib(500)
        val a = run(l, "for-you").ids
        assertEquals(a, run(l, "for-you").ids)
        assertEquals(a, run(l.reversed(), "for-you").ids)
        assertEquals(a, run(l.shuffled(java.util.Random(5)), "for-you").ids)
        assertEquals(14, a.size); assertEquals(14, a.toSet().size)
    }
    @Test fun differentSeedsDiffer() {
        val l = lib(500); val base = run(l, "for-you").ids
        assertNotEquals(base, run(l, "for-you", ctx(n = 1)).ids)
        assertNotEquals(base, run(l, "for-you", ctx(day = "2026-11-22")).ids)
        assertNotEquals(base, run(l, "for-you", ctx(profile = "kid")).ids)
        assertNotEquals(base, run(l, "hero").ids)
    }
    @Test fun restrictedNeverAppearsOnAnyShelfIncludingTwins() {
        // m1 is restricted; its twin m1b (other source, same identity) is clean but the whole group must go (R2)
        val l = lib(300).map { if (it.id == "m1") it.copy(restricted = true) else it } + cand(1, id = "m1b", key = "k1", year = 2011) + cand(2, id = "m2b", key = "k2", year = 2012).copy(restricted = true) + cand(2, id = "m2c", key = "k2", year = 2012)
        for (shelf in ShelfSpec.GLOBAL + "folder:x") for (n in 0..25) {
            val ids = run(l.map { it.copy(folderKey = "x") }, shelf, ctx(n = n, lang = "Telugu")).ids
            assertTrue("$shelf $n $ids", ids.none { it in setOf("m1", "m1b", "m2", "m2b", "m2c") })
        }
        assertEquals(2, run(l, "hero").diagnostics.restricted)
    }
    @Test fun dismissedOnRecommendationsNotFolders() {
        val l = lib(100).map { if (it.id == "m5") it.copy(dismissed = true, folderKey = "x") else it.copy(folderKey = "x") }
        assertTrue((0..30).flatMap { run(l, "for-you", ctx(n = it)).ids }.none { it == "m5" })
        assertTrue((0..60).flatMap { run(l, "folder:x", ctx(n = it)).ids }.any { it == "m5" })
    }
    @Test fun watchedExcludedExceptRediscover() {
        val l = lib(100).map { if (it.id in setOf("m10", "m11")) it.copy(watched = true, completed = true, lastWatchedDays = 90) else it }
        assertTrue((0..40).flatMap { run(l, "for-you", ctx(n = it)).ids }.none { it in setOf("m10", "m11") })
        assertTrue((0..80).flatMap { run(l, "rediscover", ctx(n = it)).ids }.any { it in setOf("m10", "m11") })
        val recent = l.map { if (it.id == "m10") it.copy(lastWatchedDays = 5) else it }
        assertTrue((0..80).flatMap { run(recent, "rediscover", ctx(n = it)).ids }.none { it == "m10" })
    }
    @Test fun camOnlyUntilRelaxationTier5() {
        val l = lib(50).map { if (it.id == "m7") it.copy(isCam = true) else it }
        assertTrue((0..30).flatMap { run(l, "for-you", ctx(n = it)).ids }.none { it == "m7" })
        val only = (1..6).map { cand(it, cam = true, q = 0) }
        val r = run(only, "for-you"); assertEquals(6, r.ids.size); assertEquals(Relax.CAM, r.diagnostics.tier)
    }
    @Test fun heroNeedsAnyArtworkRowsNeedPoster() {
        val none = lib(60).map { it.copy(hasPoster = false, hasBackdrop = false) }
        val h = run(none, "hero"); assertEquals(0, h.diagnostics.drawn); assertEquals("plainLibrary", h.diagnostics.fallback)   // hero never draws a poster-less title; the never-empty fallback lists by id
        assertEquals(14, run(none, "for-you").ids.size); assertEquals(Relax.ARTWORK, run(none, "for-you").diagnostics.tier)
        assertEquals(12, run(lib(60).map { it.copy(hasBackdrop = false) }, "hero").ids.size)
        assertTrue(run(lib(60).map { it.copy(hasBackdrop = false) }, "hero").art.all { it == "poster" })
    }
    @Test fun maxTwoConsecutive() {
        val l = (0 until 300).map { cand(it, franchise = if (it < 100) "F" else null, lang = if (it % 2 == 0) "Telugu" else "Hindi", kind = if (it % 3 == 0) Kind.SERIES else Kind.MOVIE) }
        val byId = l.associateBy { it.id }
        for (n in 0..30) for (shelf in listOf("for-you", "hero")) {
            val c = run(l, shelf, ctx(n = n)).ids.map { byId[it]!! }
            for (i in 2 until c.size) {
                assertFalse(c[i].franchiseKey != null && c[i].franchiseKey == c[i - 1].franchiseKey && c[i].franchiseKey == c[i - 2].franchiseKey)
                assertFalse(c[i].lang == c[i - 1].lang && c[i].lang == c[i - 2].lang)
                if (shelf == "hero") assertFalse(c[i].kind == c[i - 1].kind && c[i].kind == c[i - 2].kind)
            }
        }
    }
    @Test fun diversityRelaxedAndFilled() {
        val l = (0 until 20).map { cand(it, franchise = "F") }
        val r = run(l, "for-you"); assertEquals(14, r.ids.size)     // not left short by the franchise penalty
    }
    @Test fun langPrefHardFilter() {
        val l = lib(100)
        val r = run(l, "lang-pref", ctx(lang = "Telugu"))
        assertTrue(r.ids.all { id -> l.first { it.id == id }.lang == "Telugu" })
        assertTrue(run(l, "lang-pref", ctx(lang = "Korean")).hidden)
        assertTrue(run(l, "lang-pref", ctx(lang = null)).hidden); assertTrue(run(l, "lang-pref", ctx(lang = "")).hidden)
    }
    @Test fun neverEmptyFallsBackToRecentlyAdded() {
        val all = lib(40).map { it.copy(watched = true, completed = true, hasPoster = false, hasBackdrop = false) }
        // everything watched and poster-less: tiers 3/4 open them
        assertTrue(run(all, "for-you").ids.isNotEmpty())
        // dismissed or restricted ones never come back through the fallback
        val l = lib(10).map { it.copy(dismissed = it.id == "m0", restricted = it.id == "m1") }
        for (n in 0..10) assertTrue(run(l, "top-week", ctx(n = n)).ids.none { it == "m0" || it == "m1" })
        assertTrue(run(emptyList(), "hero").ids.isEmpty()); assertEquals("existingFeatured", run(emptyList(), "hero").diagnostics.fallback)
    }
    @Test fun tinyAndEmpty() {
        assertEquals(3, run(lib(3), "hero", ctx()).ids.size)
        assertEquals(setOf("m0", "m1", "m2"), run(lib(3), "for-you").ids.toSet())
        assertTrue(run(emptyList(), "for-you").ids.isEmpty())
    }
    @Test fun badRatingsAreNeutralAndOrderIsByIdOnTies() {
        val base = cand(1)
        val junk = listOf("", "0", "10", "10.0", "abc", "-1", null)
        assertTrue(junk.all { Features.rating(it) == 500 })
        val l = junk.mapIndexed { i, r -> base.copy(id = "r$i", identityKey = "rk$i", ratingText = r) }
        val s = SmartMixEngine.score(l[0], ShelfSpec.of("for-you"), ctx(), 0)
        assertTrue(l.all { SmartMixEngine.score(it, ShelfSpec.of("for-you"), ctx(), 0) == s })
    }
    @Test fun utf8ByteOrderNotUtf16() {
        assertTrue(SmartMixEngine.compareUtf8("～", "😀") < 0)
        assertTrue("～".compareTo("😀") > 0)
        assertTrue(SmartMixEngine.compareUtf8("a", "ab") < 0); assertEquals(0, SmartMixEngine.compareUtf8("é", "é"))
    }
    @Test fun weightOverflowBound() {
        assertEquals(12101L, SmartMixEngine.weight(1100, true))
        assertTrue(2000L * SmartMixEngine.weight(1100, true) < 25_000_000L)
    }
    @Test fun poolCapKeepsHighestScores() {
        val l = (0 until 3000).map { cand(it, key = "k$it", year = if (it < 10) 2026 else 1990, q = if (it < 10) 5 else 1, added = if (it < 10) 1 else 1000) }
        val r = run(l, "for-you", ctx(poolCap = 100))
        assertEquals(100, r.diagnostics.pool); assertEquals(14, r.ids.size)
        val top = (0 until 10).map { "m$it" }.toSet()
        assertTrue(r.ids.count { it in top } >= 1)
    }
    @Test fun trendingFirstOrdersByTmdbRank() {
        val l = lib(200).mapIndexed { i, c -> if (i in 50..57) c.copy(trendingRank = 60 - i) else c }
        val r = run(l, "top-week", ctx(), ordered = true)
        assertEquals((57 downTo 50).map { "m$it" }, r.ids.take(8)); assertEquals(14, r.ids.size)
        assertEquals("trendingTMDB", r.diagnostics.caption)
        assertEquals("mostWatchedHere", run(l, "top-week", ctx()).diagnostics.caption)
    }
    @Test fun identityGroupingKeepsRemakesApartAndMergesAdjacentYears() {
        val l = listOf(cand(1, key = "dune", year = 1984, id = "a"), cand(2, key = "dune", year = 2021, id = "b"), cand(3, key = "x", year = 2020, id = "c"), cand(4, key = "x", year = 2021, id = "d"), cand(5, key = "x", year = null, id = "e"))
        val p = IdentityGrouping.prepare(l, null)
        assertEquals(3, p.groups.size)            // dune twice (37 years apart), x once
        assertEquals(setOf("a", "b"), p.groups.filter { it.identityKey == "dune" }.map { it.id }.toSet())
    }
    @Test fun representativePrefersLanguageThenQualityThenSource() {
        val l = listOf(cand(1, key = "f", lang = "Hindi", q = 5, id = "hindi4k"), cand(2, key = "f", lang = "Telugu", q = 2, id = "telugusd"), cand(3, key = "f", lang = "Telugu", q = 0, cam = true, id = "cam"))
        assertEquals("telugusd", IdentityGrouping.prepare(l, "Telugu").groups.single().id)
        assertEquals("hindi4k", IdentityGrouping.prepare(l, null).groups.single().id)
    }
}
