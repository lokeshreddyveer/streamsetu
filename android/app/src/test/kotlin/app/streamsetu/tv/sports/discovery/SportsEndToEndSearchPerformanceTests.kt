package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.core.sports.SportsContext
import app.streamsetu.core.sports.SportsEventService
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.ui.screens.sports.SportsLoad
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.TimeZone

/**
 * Cold Search from guide data to merged results: the real classifier and event service over a synthetic guide, then the Search index and the query. The guide itself is supplied from memory, so the
 * time to READ it from the database on a device is NOT in these numbers and stays a final-hardware measurement.
 */
class SportsEndToEndSearchPerformanceTests {
    private val now = D.NOW; private val h = D.H
    private val channelCount = 3000

    private class Guide(val channels: List<Channel>, val programmes: Map<String, List<EpgProgram>>) : SportsEventService.Inputs {
        override suspend fun channels() = channels
        override suspend fun programmes(channels: List<Channel>, fromMs: Long, toMs: Long) = channels.mapNotNull { c -> programmes[c.id]?.let { c.id to it } }.toMap()
        override suspend fun revisions() = mapOf("A" to "r1", "B" to "r1")
    }

    private fun guide(): Guide {
        val chans = (0 until channelCount).map { Channel("c$it", if (it % 2 == 0) "A" else "B", "cat", "Channel $it ${if (it % 4 == 0) "HD" else "SD"}", null, null, "x", "g$it", catchupDays = if (it % 3 == 0) 3 else 0) }
        val sports = listOf("Premier League", "La Liga", "NBA", "IPL", "Formula 1 Grand Prix", "UFC", "ATP Tennis", "NFL")
        val progs = chans.associate { c ->
            val i = c.id.drop(1).toInt()
            c.id to (0 until 14).map { k ->
                val start = now - 4 * h + k * 5 * h + (i % 7) * 600_000L
                val title = if ((i + k) % 3 == 0) "${sports[(i + k) % sports.size]}: Team ${(i + k * 3) % 120} v Team ${(i * 5 + k) % 120 + 1}" else listOf("Evening News", "Morning Show", "Movie of the Week", "Cooking Hour", "Documentary $k")[(i + k) % 5]
                EpgProgram(c.id, start, start + 2 * h, title, null)
            }
        }
        return Guide(chans, progs)
    }

    private fun ms(n: Long) = n / 1_000_000.0
    private fun stats(label: String, nanos: List<Long>, size: String) {
        val s = nanos.sorted(); fun p(q: Double) = s[minOf(s.size - 1, (s.size * q).toInt())]
        println(String.format(java.util.Locale.US, "PERF %-52s n=%-4d median=%8.2f ms  p95=%8.2f ms  worst=%8.2f ms  [%s]", label, s.size, ms(p(0.5)), ms(p(0.95)), ms(s.last()), size))
    }

    private class Src(val service: SportsEventService, val ctx: SportsContext) : SportsSearch.Source {
        override fun now() = D.NOW; override val zone: TimeZone = D.UTC
        override suspend fun contextKey() = ctx.fingerprint
        override suspend fun load(): SportsLoad { val (f, t) = SportsWindow.hub(now()); return SportsLoad(service.events(f, t, ctx), "r", false) }
        override suspend fun follows() = FollowSet.NONE
        override suspend fun recordings() = emptyList<app.streamsetu.core.data.db.SportsRecordingEntity>()
    }

    @Test fun coldSearchFromGuideDataToMergedResults() = runBlocking {
        val g = guide(); val ctx = SportsContext("main", false, emptySet(), emptySet())
        val programmeCount = g.programmes.values.sumOf { it.size }
        val size = "$channelCount channels, $programmeCount programmes in the guide, in memory"
        val cold = ArrayList<Long>(); val classify = ArrayList<Long>(); var events = 0
        repeat(5) {
            val service = SportsEventService(g); val search = SportsSearch(Src(service, ctx)) { }
            val t = System.nanoTime(); val r = search.search("team 7"); cold.add(System.nanoTime() - t); events = r.size
        }
        repeat(5) { val service = SportsEventService(g); val (f, t) = SportsWindow.hub(now); val t0 = System.nanoTime(); events = service.events(f, t, ctx).size; classify.add(System.nanoTime() - t0) }
        stats("COLD end to end: classify + group + index + query", cold, size)
        stats("  of which classify + group alone (the Sports hub's own load)", classify, size + ", $events events")
        val service = SportsEventService(g); val hot = ArrayList<Long>()
        val s1 = SportsSearch(Src(service, ctx)) { }; s1.search("warm")
        repeat(5) { val search = SportsSearch(Src(service, ctx)) { }; val t = System.nanoTime(); search.search("team 7"); hot.add(System.nanoTime() - t) }
        stats("Classified events cached, index cold (22 ms case)", hot, size)
        val warm = ArrayList<Long>(); repeat(60) { val t = System.nanoTime(); s1.search("team $it"); warm.add(System.nanoTime() - t) }
        stats("Warm (index held)", warm, size)
        assertTrue(events > 0)
    }
}
