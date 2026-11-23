package app.streamsetu.core.data.hub

import app.streamsetu.core.data.repo.ArtworkLane
import app.streamsetu.core.data.repo.RequestPacer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

/** Many threads, one shared pacer, a virtual clock that never moves and a sleep that only records: the slots it hands out are the schedule. No real waiting. */
class SharedLimiterLoadTests {
    private fun hammer(p: RequestPacer, threads: Int, each: Int, express: Boolean): List<Long> {
        val waits = java.util.Collections.synchronizedList(ArrayList<Long>())
        val q = RequestPacer(p.rps, 6, { 0L }, { waits += it })
        val go = CountDownLatch(1)
        val ts = (1..threads).map { thread { go.await(); repeat(each) { if (express) ArtworkLane.express { q.acquire() } else q.acquire() } } }
        go.countDown(); ts.forEach { it.join() }
        return waits.sorted()
    }
    @Test fun sixteenThreadsNeverShareASlotAndNeverBeatTheRate() {
        val w = hammer(RequestPacer(22), 16, 30, express = false)
        assertEquals("the first of the 480 starts at once and records no wait", 479, w.size)
        val gaps = w.zipWithNext { a, b -> b - a }
        assertTrue("two requests shared a slot: ${gaps.min()}", gaps.all { it >= 62 })       // 22 - 6 reserved = 16 a second for bulk: 62 ms
        assertTrue("the whole queue of 480 takes at least 29 s of schedule at 16/s: ${w.last()}", w.last() >= 29_000)
    }
    @Test fun theExpressLaneIsNotDelayedByAHugeBulkQueueEvenUnderLoad() {
        val bulk = RequestPacer(22, 6, { 0L }, { })
        repeat(2000) { bulk.acquire() }
        val waits = java.util.Collections.synchronizedList(ArrayList<Long>()); val q = RequestPacer(22, 6, { 0L }, { waits += it })
        repeat(1000) { q.acquire() }; waits.clear()
        val ts = (1..8).map { thread { ArtworkLane.express { repeat(5) { q.acquire() } } } }; ts.forEach { it.join() }
        assertTrue("express waited behind bulk: ${waits.max()}", waits.max() <= 40 * 1000L / 6)
    }
    @Test fun tvmazeAndFanartBucketsHoldUnderParallelCallersOnVirtualTime() {
        for (policy in listOf(HubPolicy.TVMAZE, HubPolicy.FANART, HubPolicy.TVDB)) {
            val b = TokenBucket(policy, 0); val clock = AtomicLong(0); var granted = 0
            val lock = Any()
            val ts = (1..8).map { thread { repeat(400) { synchronized(lock) { if (b.take(clock.get()) == 0L) granted++; clock.addAndGet(25) } } } }; ts.forEach { it.join() }
            val seconds = clock.get() / 1000.0
            assertTrue("$policy granted $granted in $seconds s", granted <= policy.burst + policy.refillPerSecond * seconds + 1)
            assertTrue("$policy starved: $granted", granted >= policy.burst)
        }
    }
    @Test fun anIdleBucketNeverSavesUpMoreThanItsBurst() {
        for (policy in listOf(HubPolicy.TVMAZE, HubPolicy.FANART, HubPolicy.TVDB)) {
            val b = TokenBucket(policy, 0); val granted = (1..50).count { b.take(3_600_000) == 0L }          // an hour of silence, then 50 calls in the same instant
            assertEquals("$policy", policy.burst, granted)
        }
    }
    @Test fun aBreakerThatOpensStaysOpenForEveryCallerUntilItsProbe() {
        val b = CircuitBreaker(); repeat(CircuitBreaker.THRESHOLD) { b.failure(1_000) }
        assertTrue((0..50).none { b.allow(1_000 + it * 10_000L) && 1_000 + it * 10_000L < 1_000 + CircuitBreaker.OPEN_MS })
        assertTrue(b.allow(1_000 + CircuitBreaker.OPEN_MS)); assertFalse("only one probe", b.allow(1_000 + CircuitBreaker.OPEN_MS + 1))
    }
}
