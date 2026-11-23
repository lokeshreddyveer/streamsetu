package app.streamsetu.core.data.smartmix

import org.junit.Assert.*
import org.junit.Test

class ServiceTest {
    private val day = "2026-11-21"
    private val now = 1_800_000_000_000L
    private fun lib(n: Int) = (0 until n).map { cand(it, kind = if (it % 3 == 0) Kind.SERIES else Kind.MOVIE, lang = listOf("Telugu", "Hindi")[it % 2], year = 2015 + it % 12, q = 1 + it % 5, backdrop = true) }
    private fun svc(src: FakeCandidateSource, store: SmartMixStore = InMemorySmartMixStore(), tr: TrendingViewSource? = null) = SmartMixService(src, store, tr, clock = { now })
    private fun entries(range: IntRange) = range.map { TrendingEntry(60 - it, "movie", "Title $it long", null, 2024) }
    private fun trendLib() = lib(200).mapIndexed { i, c -> if (i in 50..57) c.copy(identityKey = "title $i long", year = 2024, kind = Kind.MOVIE) else c }

    @Test fun repeatSuppressionLowersOverlapAcrossLoads() {
        val s = svc(FakeCandidateSource(lib(300)))
        val shown = ArrayList<Set<String>>()
        repeat(5) {
            val b = s.build("main", "for-you", day); s.commitRendered("main", b); shown.add(b.result.ids.toSet()); s.reshuffle("main", listOf("for-you"))
        }
        for (i in 1..4) assertTrue("overlap ${shown[i].intersect(shown[i - 1]).size}", shown[i].intersect(shown[i - 1]).size <= 3)
    }
    @Test fun rebuildWithinSessionIsStable() {
        val s = svc(FakeCandidateSource(lib(300)))
        val a = s.build("main", "for-you", day); s.commitRendered("main", a)
        assertEquals(a.result.ids, s.build("main", "for-you", day).result.ids)
        s.commitRendered("main", s.build("main", "for-you", day))
        assertEquals(a.result.ids, s.build("main", "for-you", day).result.ids)
    }
    @Test fun reshuffleBumpsCounterWithoutAnythingElse() {
        val src = FakeCandidateSource(lib(300)); val s = svc(src)
        val a = s.build("main", "hero", day).result.ids
        s.reshuffle("main", listOf("hero"))
        assertNotEquals(a, s.build("main", "hero", day).result.ids)
    }
    @Test fun profilesAreIsolated() {
        val src = FakeCandidateSource(lib(300)); val store = InMemorySmartMixStore(); val s = svc(src, store)
        val a = s.build("A", "for-you", day); s.commitRendered("A", a); s.reshuffle("A", listOf("for-you"))
        assertEquals(svc(src).build("B", "for-you", day).result.ids, s.build("B", "for-you", day).result.ids)
        assertTrue(store.shown("B", "for-you").isEmpty())
        s.forgetProfile("A"); assertTrue(store.shown("A", "for-you").isEmpty()); assertEquals(0, store.state("A", "for-you").refreshCounter)
    }
    @Test fun shownHistoryNeverRecordsRestrictedItems() {
        val src = FakeCandidateSource(lib(100)); val store = InMemorySmartMixStore(); val s = svc(src, store)
        val b = s.build("main", "hero", day)
        val victim = b.result.ids.first()
        src.library = src.library.map { if (it.id == victim) it.copy(restricted = true) else it }   // locked between build and render
        s.commitRendered("main", svc(src, store).let { b })   // the built shelf is stale
        // the stale shelf still lists it, but a rebuild after the lock must not
        assertFalse(svc(src, store).build("main", "hero", day).result.ids.contains(victim))
        assertTrue(store.shown("main", "hero").isNotEmpty())
    }
    @Test fun rowsNeverWrittenForRestrictedBuiltItems() {
        val l = lib(100).map { it.copy(restricted = it.id in setOf("m1", "m2")) }
        val store = InMemorySmartMixStore(); val s = svc(FakeCandidateSource(l), store)
        for (n in 0..5) { val b = s.build("main", "for-you", day); s.commitRendered("main", b); s.reshuffle("main", listOf("for-you")) }
        assertTrue(store.shown("main", "for-you").none { it.itemId in setOf("m1", "m2") })
        assertTrue(store.shown("main", "for-you").size <= SmartMixService.MAX_ROWS)
    }
    @Test fun buildHomeNeverLeaksAndLangPrefHidesWithoutLanguage() {
        val l = lib(200).map { it.copy(restricted = it.id in setOf("m4", "m5", "m9")) }
        val src = FakeCandidateSource(l); val s = svc(src)
        for (n in 0..8) {
            s.reshuffle("main", ShelfSpec.GLOBAL)
            val home = s.buildHome("main", day)
            assertTrue(home.flatMap { it.result.ids }.none { it in setOf("m4", "m5", "m9") })
            assertTrue(home.none { it.result.shelfId == "lang-pref" })
        }
        src.signals = Signals(preferredLang = "Telugu")
        assertTrue(s.buildHome("main", day).any { it.result.shelfId == "lang-pref" })
        assertTrue(svc(FakeCandidateSource(emptyList())).buildHome("main", day).isEmpty())
    }
    @Test fun becauseYouWatchedPassesFourSeeds() {
        val src = FakeCandidateSource(lib(100), Signals(recentWatchedIdentityKeys = listOf("a", "b", "c", "d", "e", "f")))
        svc(src).build("main", "for-you", day)
        assertEquals(listOf("a", "b", "c", "d"), src.requests.first().seedIdentityKeys)
        svc(src).build("main", "hero", day); assertTrue(src.requests.last().seedIdentityKeys.isEmpty())
    }
    @Test fun continueWatchingIsNotATouchedConcept() {
        // the engine has no Continue Watching input or output: nothing to hide, nothing to remove
        val names = ShelfSpec.GLOBAL.toSet()
        assertFalse(names.any { it.contains("continue") })
    }

    // ---- TMDB
    private fun provider(key: String?, enabled: Boolean = true, f: FakeFetcher, c: TrendingCacheStore = InMemoryTrendingCache()) = TrendingProvider(FixedTmdbSettings(enabled, key), f, c)

    @Test fun noOwnKeyMeansNoRequestAndCachePurged() {
        val f = FakeFetcher(TrendingSnapshot(0, entries(50..57))); val c = InMemoryTrendingCache(); c.save(TrendingSnapshot(now - 1000, entries(50..57)))
        assertEquals("off", provider(null, true, f, c).view(now).status); assertNull(c.load())
        assertEquals("off", provider("  ", true, f, c).view(now).status)
        assertEquals("off", provider("k", false, f, c).view(now).status)
        assertEquals(0, f.calls)
    }
    @Test fun cachePolicy7_30_180() {
        val d = TrendingPolicy.DAY_MS
        val f = FakeFetcher(TrendingSnapshot(0, entries(50..57))); val c = InMemoryTrendingCache(); val p = provider("userkey", true, f, c)
        assertEquals("active", p.view(now).status); assertEquals(1, f.calls); assertEquals(listOf("userkey"), f.keysSeen)
        assertEquals("active", p.view(now + 2 * d).status); assertEquals(1, f.calls)                 // fresh: no refetch
        f.result = null
        assertEquals("active", p.view(now + 8 * d).status); assertEquals(2, f.calls)                 // refresh due, offline: cached list still shown
        p.view(now + 8 * d + 1000); assertEquals(2, f.calls)                                         // no hammering after a failure
        assertEquals("expired", p.view(now + 33 * d).status); assertNotNull(c.load())               // >30 days: not used, kept until 180
        val q = provider("userkey", true, FakeFetcher(null), c)
        assertEquals("noCache", q.view(now + 181 * d).status); assertNull(c.load())                 // >180 days: purged
    }
    @Test fun policyStatusTable() {
        val e = entries(1..2)
        assertEquals("off", TrendingPolicy.view(true, false, 1, e).status); assertEquals("off", TrendingPolicy.view(false, true, 1, e).status)
        assertEquals("noCache", TrendingPolicy.view(true, true, null, null).status)
        assertEquals("active", TrendingPolicy.view(true, true, 30, e).status); assertEquals("expired", TrendingPolicy.view(true, true, 31, e).status)
        assertEquals("expired", TrendingPolicy.view(true, true, 180, e).status); assertEquals("purged", TrendingPolicy.view(true, true, 181, e).status)
    }
    @Test fun foldMatchesReferenceCases() {
        assertEquals("shogun", TrendingMatcher.fold("Shōgun")); assertEquals("dune part two", TrendingMatcher.fold("Dune: Part Two"))
        assertEquals("bear", TrendingMatcher.fold("The Bear")); assertEquals("the", TrendingMatcher.fold("The"))
        assertEquals("కలకి", TrendingMatcher.fold("కల్కి"))   // virama has combining class 9: dropped, exactly like the reference
    }
    @Test fun matchedTitlesFeedTopWeekAndFallBackLocally() {
        val src = FakeCandidateSource(trendLib())
        val tr = TrendingViewSource { TrendingPolicy.view(true, true, 2, entries(50..57)) }
        val r = svc(src, tr = tr).build("main", "top-week", day).result
        assertEquals((57 downTo 50).map { "m$it" }, r.ids.take(8)); assertEquals("trendingTMDB", r.diagnostics.caption); assertEquals("active", r.diagnostics.tmdb)
        val local = svc(src, tr = TrendingViewSource { TrendingView.OFF }).build("main", "top-week", day).result
        assertEquals("mostWatchedHere", local.diagnostics.caption); assertEquals(14, local.ids.size)
        val few = svc(src, tr = TrendingViewSource { TrendingPolicy.view(true, true, 2, entries(50..53)) }).build("main", "top-week", day).result
        assertEquals("mostWatchedHere", few.diagnostics.caption)      // fewer than 6 matches: local order
    }
    @Test fun lockedTitleNeverMatchedOrRanked() {
        val l = trendLib().map { if (it.id in setOf("m56", "m57")) it.copy(restricted = true) else it }
        val tr = TrendingViewSource { TrendingPolicy.view(true, true, 2, entries(50..57)) }
        val s = svc(FakeCandidateSource(l), tr = tr)
        for (n in 0..5) { s.reshuffle("main", listOf("top-week", "hero", "trending-library")); for (sh in listOf("top-week", "hero", "trending-library")) assertTrue(s.build("main", sh, day).result.ids.none { it == "m56" || it == "m57" }) }
        assertEquals("trendingTMDB", s.build("main", "top-week", day).result.diagnostics.caption)   // 6 left: still >= 6
        val s5 = svc(FakeCandidateSource(l.map { if (it.id == "m55") it.copy(restricted = true) else it }), tr = tr)
        assertEquals("mostWatchedHere", s5.build("main", "top-week", day).result.diagnostics.caption)   // 5 left: below the minimum
    }
    @Test fun trendingLibraryOnlyMatchedWhenThreeMatches() {
        val src = FakeCandidateSource(trendLib())
        val r = svc(src, tr = TrendingViewSource { TrendingPolicy.view(true, true, 2, entries(50..57)) }).build("main", "trending-library", day).result
        assertEquals(8, r.ids.size); assertTrue(r.diagnostics.trendMode); assertTrue(r.ids.all { it in (50..57).map { n -> "m$n" } })
        assertFalse(svc(src).build("main", "trending-library", day).result.diagnostics.trendMode)
    }
}
