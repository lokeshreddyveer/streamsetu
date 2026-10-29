package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.ui.screens.sports.SportsLoad
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.TimeZone

/** Measurements, with checks on what must not happen. The numbers go to the test output (PERF lines). A development machine's figures are a floor for a TV. */
class SportsDiscoveryPerformanceTests {
    private val n = 1800
    private val events = D.large(n)
    private val rows = (0 until 300).map { D.recording("r$it", events[it * 5], listOf("SCHEDULED", "COMPLETED", "CANCELLED", "FAILED", "RECORDING")[it % 5], updated = D.NOW - it) }

    private fun ms(n: Long) = n / 1_000_000.0
    private fun stats(label: String, nanos: List<Long>, size: String) {
        val s = nanos.sorted(); fun p(q: Double) = s[minOf(s.size - 1, (s.size * q).toInt())]
        println(String.format(java.util.Locale.US, "PERF %-46s n=%-4d median=%8.2f ms  p95=%8.2f ms  worst=%8.2f ms  [%s]", label, s.size, ms(p(0.5)), ms(p(0.95)), ms(s.last()), size))
    }
    private fun time(times: Int, op: (Int) -> Unit): List<Long> = (0 until times).map { i -> val t = System.nanoTime(); op(i); System.nanoTime() - t }
    private fun usedMb(): Long { repeat(3) { System.gc(); Thread.sleep(40) }; val r = Runtime.getRuntime(); return (r.totalMemory() - r.freeMemory()) / (1024 * 1024) }
    private val size get() = "$n events, ${events.sumOf { it.feeds.size }} feeds, ${events.flatMap { it.participants }.toSet().size} names"

    private class Src(val events: List<SportsEvent>, val follows: FollowSet, val rows: List<app.streamsetu.core.data.db.SportsRecordingEntity>) : SportsSearch.Source {
        var loads = 0; var gate: CompletableDeferred<Unit>? = null
        override fun now() = D.NOW; override val zone: TimeZone = D.UTC
        override suspend fun contextKey() = "c"
        override suspend fun load(): SportsLoad { loads++; gate?.await(); return SportsLoad(events, "r", true) }
        override suspend fun follows() = follows; override suspend fun recordings() = rows
    }

    @Test fun searchColdAndWarm() = runBlocking(Dispatchers.Default) {
        val followed = FollowSet(listOf(D.team(Sport.CRICKET, "Team 7 CRI"), D.comp(Sport.FOOTBALL, "Comp 3 FOO")), IdentityIndex.build(events))
        val diag = ArrayList<DiscoveryReport>()
        val cold = ArrayList<Long>()
        repeat(5) { val s = SportsSearch(Src(events, followed, rows)) { diag.add(it) }; val t = System.nanoTime(); s.search("team 7"); cold.add(System.nanoTime() - t) }
        stats("Sports Search, cold (index built)", cold, size)
        val s = SportsSearch(Src(events, followed, rows)) { diag.add(it) }; s.search("warm up")
        val queries = listOf("team 1", "comp", "team 12 foo", "tea", "team 1 cri", "zzzz", "comp 3", "team 99 bas")
        val warm = time(200) { i -> runBlocking { s.search(queries[i % queries.size]) } }
        stats("Sports Search, warm", warm, size + ", 8 different queries")
        assertEquals("one index for all of them", 1, s.builds)
        assertTrue("no name or text in what was recorded", diag.joinToString { it.line() }.let { t -> listOf("Team", "Comp", "team").none { t.contains(it) } })
    }

    @Test fun searchCancellationIsPrompt() = runBlocking(Dispatchers.Default) {
        val src = Src(events, FollowSet.NONE, rows).also { it.gate = CompletableDeferred() }
        val s = SportsSearch(src) { }
        val t = ArrayList<Long>()
        repeat(40) {
            val job = async { runCatching { s.search("team $it") } }
            while (src.loads <= it) kotlinx.coroutines.delay(1)
            val started = System.nanoTime(); job.cancel(); job.join(); t.add(System.nanoTime() - started)
        }
        stats("Search cancellation (stale query dropped)", t, "40 queries held at the load, then cancelled")
        assertTrue(t.sorted()[t.size / 2] < 50_000_000L)
    }

    @Test fun pageAndBoardBuilds() {
        val index = IdentityIndex.build(events)
        stats("Identity index build", time(15) { IdentityIndex.build(events) }, size)
        val env = D.env(events, follows = listOf(D.team(Sport.CRICKET, "Team 7 CRI"), D.team(Sport.FOOTBALL, "Team 14 FOO"), D.comp(Sport.RUGBY, "Comp 5 RUG")), history = D.large(600, now = D.NOW - 40 * D.H).map { it.copy(id = "h-" + it.id) }, rows = rows,
            reminded = events.filterIndexed { i, _ -> i % 40 == 0 }.map { SportsPages.eventKey(it) }.toSet())
        val teamRefs = events.take(80).flatMap { e -> index.participants(e).map { PageRef(PageKind.TEAM, e.sport, it, index.displayName(it) ?: "") } }.distinct()
        val compRefs = events.take(80).mapNotNull { e -> index.competition(e)?.let { PageRef(PageKind.COMPETITION, e.sport, it, "") } }.distinct()
        stats("Team page build", time(teamRefs.size) { SportsPages.page(teamRefs[it], env, false) }, "$size, ${teamRefs.size} different teams, 600 history events")
        stats("Competition page build", time(compRefs.size) { SportsPages.page(compRefs[it], env, false) }, "$size, ${compRefs.size} different competitions")
        stats("My Sports board build", time(40) { SportsPages.board(env) }, "$size, 3 follows, ${rows.size} recordings, ${env.remindedEventKeys.size} reminders")
        val board = SportsPages.board(env)
        assertTrue(board.sections.isNotEmpty())
        println("PERF my sports board: ${board.sections.joinToString { it.id + "=" + it.cards.size }}; orphan recordings=${board.recordings.size}")
        // every event once
        val all = board.sections.flatMap { s -> s.cards.map { SportsPages.eventKey(events.first { e -> e.id == it.id }.let { e -> e }) } }
        assertEquals(all.size, all.toSet().size)
    }

    @Test fun repeatedPageBuildsDoNotGrowMemory() {
        val env = D.env(events, rows = rows); val index = env.index
        val refs = events.take(60).flatMap { e -> index.participants(e).map { PageRef(PageKind.TEAM, e.sport, it, "") } }.distinct()
        repeat(200) { SportsPages.page(refs[it % refs.size], env, false) }
        val before = usedMb()
        repeat(1500) { SportsPages.page(refs[it % refs.size], env, false); if (it % 3 == 0) SportsPages.board(env) }
        val after = usedMb()
        println("PERF memory heap used before=$before MB after=$after MB across 1500 page builds and 500 board builds ($size)")
        assertTrue("no steady growth ($before -> $after MB)", after - before < 25)
    }

    @Test fun searchIndexIsBounded() = runBlocking(Dispatchers.Default) {
        var ctx = 0
        val src = object : SportsSearch.Source by Src(events, FollowSet.NONE, rows) { override suspend fun contextKey() = "c${ctx}" }
        val s = SportsSearch(src) { }
        val before = usedMb()
        repeat(60) { ctx = it; s.search("team") }
        val after = usedMb()
        assertEquals("a new context replaces the index, never adds to it", 60, s.builds)
        println("PERF memory heap used before=$before MB after=$after MB across 60 contexts rebuilt")
        assertTrue("one index is held at a time ($before -> $after MB)", after - before < 40)
    }
}
