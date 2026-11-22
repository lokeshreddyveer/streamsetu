package app.streamsetu.core.data.smartmix

import org.junit.Assume
import org.junit.Test

/** JVM micro-benchmark, off by default: SMARTMIX_BENCH=1 ./gradlew :data:testDebugUnitTest --tests '*BenchmarkTest*' -i. Desktop JVM numbers only, never device timings. */
class BenchmarkTest {
    private fun ms(ns: Long) = "%.1f".format(ns / 1e6)
    private fun stats(samples: List<Long>): String { val s = samples.sorted(); return "p50 ${ms(s[s.size / 2])} ms, p95 ${ms(s[(s.size * 95 / 100).coerceAtMost(s.size - 1)])} ms, max ${ms(s.last())} ms" }
    private fun used(): Long { val r = Runtime.getRuntime(); System.gc(); System.gc(); return r.totalMemory() - r.freeMemory() }

    private fun bench(label: String, n: Int, folders: Int) {
        val m0 = used()
        val t0 = System.nanoTime()
        val lib = FixtureRunner.generate(label, 11, n, folders)
        val gen = System.nanoTime() - t0
        val m1 = used()
        println("BENCH [$label] n=$n generated in ${ms(gen)} ms, resident candidates ~${(m1 - m0) / 1_048_576} MB (JVM objects, not Android)")
        val aff = Affinity(listOf("Telugu", "Hindi", "English"), listOf("f1", "f2"), listOf("action", "drama"), listOf(2010, 2020))
        val now = 1_800_000_000_000L
        val view = TrendingViewSource { TrendingPolicy.view(true, true, 2, (0 until 40).map { TrendingEntry(it + 1, "movie", "t$it", null, 2024) }) }
        // A) whole library handed to the engine (worst case: no SQL pre-selection)
        val src = FakeCandidateSource(lib, Signals("Telugu", aff))
        var coldAll = 0L
        val all = ArrayList<Long>()
        for (i in 0 until 13) {
            val svc = SmartMixService(src, InMemorySmartMixStore(), view, { now })
            val t = System.nanoTime()
            for (sh in ShelfSpec.GLOBAL) svc.build("main", sh, "2026-11-21")
            val d = System.nanoTime() - t
            if (i == 0) coldAll = d else if (i >= 3) all.add(d)
        }
        println("BENCH [$label] A) 6 global shelves, WHOLE library in, identity grouping redone per shelf: first run ${ms(coldAll)} ms; warm ${stats(all)}")
        // B) what the app does: indexed pool of up to 2000 members per shelf (prepare once per shelf on 2000)
        val pool = lib.sortedWith(compareBy({ -it.qualityRank }, { it.addedDays ?: 9999 })).take(2000)
        val src2 = FakeCandidateSource(pool, Signals("Telugu", aff))
        val b = ArrayList<Long>()
        var coldB = 0L
        for (i in 0 until 23) {
            val svc = SmartMixService(src2, InMemorySmartMixStore(), view, { now })
            val t = System.nanoTime()
            for (sh in ShelfSpec.GLOBAL) svc.build("main", sh, "2026-11-21")
            val d = System.nanoTime() - t
            if (i == 0) coldB = d else if (i >= 3) b.add(d)
        }
        println("BENCH [$label] B) 6 global shelves from a 2000-member pool: first run ${ms(coldB)} ms; warm ${stats(b)} (per shelf ~${ms(b.sorted()[b.size / 2] / 6)} ms)")
        // C) engine core only on one prepared 66k/200k set (grouping once, then one shelf)
        val tp = System.nanoTime(); val prep = IdentityGrouping.prepare(lib, "Telugu"); val prepNs = System.nanoTime() - tp
        val c = ArrayList<Long>()
        for (i in 0 until 13) { val t = System.nanoTime(); SmartMixEngine.buildShelf(prep, "for-you", Context("main", "2026-11-21", 0, preferredLang = "Telugu", affinity = aff), false); if (i >= 3) c.add(System.nanoTime() - t) }
        println("BENCH [$label] C) identity grouping of all ${lib.size} members once: ${ms(prepNs)} ms (${prep.groups.size} groups); one shelf build on the prepared set (filter+score+pool cut+draw): ${stats(c)}")
        val f = ArrayList<Long>()
        for (i in 0 until 13) { val t = System.nanoTime(); SmartMixEngine.buildShelf(prep, "folder:f1", Context("main", "2026-11-21", 0, preferredLang = "Telugu"), false); if (i >= 3) f.add(System.nanoTime() - t) }
        println("BENCH [$label] D) one folder row (folder:f1): ${stats(f)}")
        val m2 = used()
        println("BENCH [$label] heap after all: ${(m2 - m0) / 1_048_576} MB over baseline (includes the candidate list)")
    }

    @Test fun bench() {
        Assume.assumeTrue(System.getenv("SMARTMIX_BENCH") == "1")
        println("BENCH JVM ${System.getProperty("java.vm.name")} ${System.getProperty("java.version")}, ${Runtime.getRuntime().availableProcessors()} cores, max heap ${Runtime.getRuntime().maxMemory() / 1_048_576} MB")
        bench("large-66k", 66540, 632)
        bench("stress-200k", 200000, 1500)
    }
}
