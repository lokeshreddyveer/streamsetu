package app.streamsetu.core.sports

import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgProgram
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.concurrent.atomic.AtomicInteger

/** A scripted guide: channels, their programmes and each playlist's revision, with no database. */
class FakeGuide : SportsEventService.Inputs {
    val channels = ArrayList<Channel>()
    private val known = HashSet<String>()
    val programmes = HashMap<String, MutableList<EpgProgram>>()
    var revisions = HashMap<String, String>()
    val calls = AtomicInteger()
    val asked = ArrayList<Pair<Long, Long>>()
    /** Called at the start of each guide read; may suspend to hold a read up. */
    var onProgrammes: (suspend () -> Unit)? = null

    override suspend fun channels(): List<Channel> = synchronized(this) { channels.toList() }
    override suspend fun programmes(channels: List<Channel>, fromMs: Long, toMs: Long): Map<String, List<EpgProgram>> {
        calls.incrementAndGet(); synchronized(this) { asked.add(fromMs to toMs) }
        onProgrammes?.invoke()
        return synchronized(this) { channels.mapNotNull { c -> programmes[c.id]?.let { c.id to it.toList() } }.toMap() }
    }
    override suspend fun revisions(): Map<String, String> = synchronized(this) { revisions.toMap() }

    fun channel(id: String, source: String, name: String, category: String? = "Sports", archive: Int = 0) =
        Channel(id = id, sourceId = source, categoryId = category, name = name, number = null, logoUrl = null, streamRef = "x", epgId = id, catchupDays = archive)

    fun add(channel: Channel, title: String, startMs: Long, minutes: Double = 120.0) = synchronized(this) {
        if (known.add(channel.id)) channels.add(channel)
        programmes.getOrPut(channel.id) { ArrayList() }.add(EpgProgram(channel.id, startMs, startMs + (minutes * 60_000).toLong(), title, null))
    }
}

class SportsEventServiceTests {
    private val a = "srcA"; private val b = "srcB"
    private val t0 = 1_800_000_000_000L
    private val h = 3_600_000L; private val min = 60_000L
    private val ctx = SportsContext("main", false, emptySet(), emptySet())
    private fun service(g: FakeGuide, tolerance: Long = 45 * min) = SportsEventService(g, tolerance)
    private suspend fun SportsEventService.run(ctx: SportsContext = this@SportsEventServiceTests.ctx, from: Long = t0 - h, to: Long = t0 + 12 * h) = events(from, to, ctx)

    @Test fun duplicateFeedsOfOneEventBecomeOneEventSortedByQuality() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "Sports 1 SD"), "Premier League: Arsenal v Chelsea (SD)", t0)
        g.add(g.channel("c2", a, "Sports 1 4K"), "Premier League: Arsenal vs Chelsea 4K", t0 + 5 * min)
        g.add(g.channel("c3", a, "Sports 2 Hindi", archive = 3), "Premier League: Arsenal v Chelsea - Hindi", t0)
        val events = service(g).run()
        assertEquals(1, events.size); val e = events[0]
        assertEquals(Sport.FOOTBALL, e.sport); assertEquals(SportsEventKind.HEAD_TO_HEAD, e.kind); assertEquals(listOf("Arsenal", "Chelsea"), e.participants); assertEquals(3, e.feeds.size)
        assertEquals(listOf("c2", "c1", "c3").sorted(), e.feeds.map { it.channelId }.sorted())
        assertEquals("c2", e.feeds.first().channelId)
        val hindi = e.feeds.first { it.channelId == "c3" }
        assertEquals("hi", hindi.language); assertEquals(MetadataSource.PARSED_FROM_NAME, hindi.languageSource); assertTrue(hindi.catchUp)
        assertEquals(SportsEventState.LIVE, e.state(t0 + 10 * min)); assertEquals(SportsEventState.UPCOMING, e.state(t0 - 10 * min)); assertEquals(SportsEventState.FINISHED, e.state(t0 + 3 * h))
    }

    @Test fun androidLanguageAndQualityStayUnknownUnlessANameSaysSo() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "Sky Sports Football"), "Premier League: Arsenal v Chelsea", t0)           // the Android channel model has no language or quality
        val feed = service(g).run().first().feeds.first()
        assertNull(feed.language); assertNull(feed.quality); assertEquals(MetadataSource.UNKNOWN, feed.languageSource); assertEquals(MetadataSource.UNKNOWN, feed.qualitySource); assertNull(feed.variant)
        g.add(g.channel("c2", a, "Sky Sports Football HD Hindi"), "Premier League: Arsenal v Chelsea", t0)
        val hinted = service(g).run().first().feeds.first { it.channelId == "c2" }
        assertEquals("HD", hinted.quality); assertEquals(MetadataSource.PARSED_FROM_NAME, hinted.qualitySource); assertEquals("hi", hinted.language); assertEquals(MetadataSource.PARSED_FROM_NAME, hinted.languageSource)
        assertTrue("no provider-supplied value is ever claimed", service(g).run().first().feeds.none { it.languageSource == MetadataSource.PROVIDER || it.qualitySource == MetadataSource.PROVIDER })
    }

    @Test fun reversedSidesOnDifferentChannelsAreOneEvent() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "NBA 1"), "NBA: Lakers vs Celtics", t0); g.add(g.channel("c2", a, "NBA 2"), "NBA | Celtics @ Lakers", t0)
        val events = service(g).run()
        assertEquals(1, events.size); assertEquals(2, events[0].feeds.size); assertEquals(listOf("Lakers", "Celtics"), events[0].participants)
    }

    @Test fun twoSourcesCarryingTheSameEventAreOneEventWithACompositeRevision() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "rA", b to "rB")
        g.add(g.channel("a1", a, "A Sports"), "Premier League: Arsenal v Chelsea", t0); g.add(g.channel("b1", b, "B Sports"), "Premier League: Arsenal vs Chelsea", t0 + 10 * min)
        g.add(g.channel("a2", a, "A Cricket"), "IPL: Mumbai Indians vs Chennai Super Kings", t0)
        val events = service(g).run()
        val football = events.first { it.sport == Sport.FOOTBALL }; val cricket = events.first { it.sport == Sport.CRICKET }
        assertEquals(setOf(a, b), football.sourceIds); assertTrue(football.guideRevision.contains("rA") && football.guideRevision.contains("rB"))
        assertEquals(setOf(a), cricket.sourceIds); assertTrue(cricket.guideRevision.contains("rA") && !cricket.guideRevision.contains("rB"))
    }

    @Test fun sameSidesAtDifferentTimesStaySeparateEvents() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "Sports 1"), "Premier League: Arsenal v Chelsea", t0); g.add(g.channel("c2", a, "Sports 2"), "Premier League: Arsenal v Chelsea", t0 + 8 * h)
        assertEquals(2, service(g).run().size)
    }

    @Test fun sameSidesAndTimeInDifferentCompetitionsAreNotMerged() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "Sports 1"), "Premier League: Arsenal v Chelsea", t0); g.add(g.channel("c2", a, "Sports 2"), "FA Cup: Arsenal v Chelsea", t0)
        g.add(g.channel("c3", a, "Football 3"), "Arsenal v Chelsea", t0)           // no competition named: compatible with either, joins the first
        val events = service(g).run()
        assertEquals(2, events.size); assertEquals(listOf(1, 2), events.map { it.feeds.size }.sorted())
    }

    @Test fun eventsNearAFifteenMinuteBoundaryAreNotSplitOrMerged() = runBlocking {
        val boundary = (t0 / 900_000L + 1) * 900_000L
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "S1"), "Premier League: Arsenal v Chelsea", boundary - min); g.add(g.channel("c2", a, "S2"), "Premier League: Arsenal v Chelsea", boundary + min)
        g.add(g.channel("c3", a, "S3"), "NBA: Lakers vs Celtics", boundary - min); g.add(g.channel("c4", a, "S4"), "NBA: Heat vs Bulls", boundary + min)
        val events = service(g).events(boundary - h, boundary + 6 * h, ctx)
        assertEquals(3, events.size); assertEquals(2, events.first { it.title.contains("Arsenal") }.feeds.size)
    }

    @Test fun feedsWhoseProgrammesOverlapAreOneEventEvenIfTheyStartFarApart() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "S1"), "Premier League: Arsenal v Chelsea", t0, 240.0); g.add(g.channel("c2", a, "S2"), "Premier League: Arsenal v Chelsea", t0 + 110 * min, 110.0)
        assertEquals(1, service(g, 20 * min).run().size)
        val g2 = FakeGuide(); g2.revisions = hashMapOf(a to "r1")
        g2.add(g2.channel("c1", a, "S1"), "Premier League: Arsenal v Chelsea", t0, 90.0); g2.add(g2.channel("c2", a, "S2"), "Premier League: Arsenal v Chelsea", t0 + 110 * min, 90.0)
        assertEquals(2, service(g2, 20 * min).run().size); assertEquals(1, service(g2, 2 * h).run().size)
    }

    @Test fun daylightSavingAndTimeZonesAreHandledInAbsoluteTime() = runBlocking {
        val ny = ZoneId.of("America/New_York")
        val spring = ZonedDateTime.of(2026, 3, 8, 1, 50, 0, 0, ny).toInstant().toEpochMilli()            // 01:50 EST, ten minutes before the clocks jump
        val later = ZonedDateTime.of(2026, 3, 8, 3, 10, 0, 0, ny).toInstant().toEpochMilli()             // 03:10 EDT: twenty real minutes after
        assertEquals(20 * min, later - spring)
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "S1"), "NBA: Lakers vs Celtics", spring, 150.0); g.add(g.channel("c2", a, "S2"), "NBA: Lakers vs Celtics", later, 150.0)
        val e = service(g).events(spring - h, spring + 6 * h, ctx).single()
        assertEquals(2, e.feeds.size); assertEquals(170 * min, e.endMs - e.startMs)
        assertEquals(SportsEventState.LIVE, e.state(later)); assertEquals(SportsEventState.FINISHED, e.state(spring + 4 * h))
        val g2 = FakeGuide(); g2.revisions = hashMapOf(a to "r1")
        val fall = ZonedDateTime.of(2026, 11, 1, 0, 30, 0, 0, ny).toInstant().toEpochMilli() + h                // the repeated 01:30 hour
        g2.add(g2.channel("c1", a, "S1"), "NBA: Lakers vs Celtics", fall, 100.0); g2.add(g2.channel("c2", a, "S2"), "NBA: Lakers vs Celtics", fall + h, 100.0)
        assertEquals(1, service(g2, 20 * min).events(fall - h, fall + 4 * h, ctx).size)
    }

    @Test fun lockedAndHiddenChannelsNeverLeakThroughAnEvent() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("open", a, "Open 1", "cat-open"), "Premier League: Arsenal v Chelsea", t0); g.add(g.channel("locked", a, "Locked 1", "cat-adult"), "Premier League: Arsenal v Chelsea", t0)
        g.add(g.channel("hidden", a, "Hidden 1", "cat-open"), "Premier League: Arsenal v Chelsea", t0); g.add(g.channel("onlyLocked", a, "Locked 2", "cat-adult"), "NBA: Lakers vs Celtics", t0)
        val svc = service(g)
        assertEquals(4, svc.run().flatMap { it.feeds }.size)
        val limited = SportsContext("main", true, setOf("cat-adult"), setOf("hidden"))
        val events = svc.run(limited)
        assertEquals(1, events.size); assertEquals(listOf("open"), events[0].feeds.map { it.channelId })
        assertEquals(SportsRestriction.LOCKED_FOLDER, limited.restriction(g.channel("x", a, "x", "cat-adult"))); assertEquals(SportsRestriction.HIDDEN_CHANNEL, limited.restriction(g.channel("hidden", a, "h")))
        assertEquals(4, svc.run(SportsContext("main", false, setOf("cat-adult"), emptySet())).flatMap { it.feeds }.size)
    }

    @Test fun switchingProfileNeverServesTheOtherProfilesResults() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("shared", a, "Shared", "ok"), "NBA: Lakers vs Celtics", t0); g.add(g.channel("adultOnly", a, "Adult", "adult"), "NFL: Chiefs vs Eagles", t0)
        val svc = service(g)
        val parent = SportsContext("parent", false, setOf("adult"), emptySet()); val kid = SportsContext("kid", true, setOf("adult"), emptySet())
        assertEquals(2, svc.run(parent).size); assertEquals(1, svc.run(kid).size); assertEquals(2, svc.run(parent).size)
    }

    @Test fun aProfileSwitchWhileClassifyingCancelsTheOldWorkAndPublishesNothingFromIt() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("shared", a, "Shared", "ok"), "NBA: Lakers vs Celtics", t0); g.add(g.channel("adultOnly", a, "Adult", "adult"), "NFL: Chiefs vs Eagles", t0)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); val first = AtomicInteger()
        g.onProgrammes = { if (first.getAndIncrement() == 0) { entered.complete(Unit); release.await() } }
        val svc = service(g)
        val parent = SportsContext("parent", false, setOf("adult"), emptySet()); val kid = SportsContext("kid", true, setOf("adult"), emptySet())
        val oldWork = async { runCatching { svc.run(parent) } }
        entered.await()
        val kidWork = async { svc.run(kid) }
        delay(100); release.complete(Unit)
        val kidEvents = kidWork.await()
        assertEquals(1, kidEvents.size); assertTrue(kidEvents.flatMap { it.feeds }.none { it.channelId == "adultOnly" })
        assertTrue("the parent's work is cancelled and never published", oldWork.await().exceptionOrNull() is CancellationException)
        assertTrue(svc.run(kid).flatMap { it.feeds }.none { it.channelId == "adultOnly" })
    }

    @Test fun aFilterChangeCancelsWorkInFlight() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1")
        g.add(g.channel("c1", a, "Sports 1"), "NBA: Lakers vs Celtics", t0)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); val first = AtomicInteger()
        g.onProgrammes = { if (first.getAndIncrement() == 0) { entered.complete(Unit); release.await() } }
        val svc = service(g)
        val work = async { runCatching { svc.run() } }
        entered.await(); svc.contextDidChange(); release.complete(Unit)
        assertTrue(work.await().exceptionOrNull() is CancellationException)
        assertEquals(1, svc.run().size)
    }

    @Test fun theCacheIsKeyedByEachPlaylistsOwnRevisionSoOneUpdateDoesNotRedoTheOther() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "a1", b to "b1")
        g.add(g.channel("a1", a, "A Sports"), "Premier League: Arsenal v Chelsea", t0); g.add(g.channel("b1", b, "B Sports"), "NBA: Lakers vs Celtics", t0)
        val svc = service(g)
        svc.run(); assertEquals(2, svc.classifiedSources)
        svc.run(); assertEquals("answered from the cache", 2, svc.classifiedSources)
        g.revisions[b] = "b2"; svc.run(); assertEquals("only B was classified again", 3, svc.classifiedSources)
        g.add(g.channel("a9", a, "A Sports 2"), "NBA: Heat vs Bulls", t0)
        assertEquals(3, svc.run().size); assertEquals("a changed channel list is a change too", 4, svc.classifiedSources)
        svc.invalidate(); svc.run(); assertEquals("invalidate drops everything", 6, svc.classifiedSources)
    }

    @Test fun floorDivRoundsTowardsNegativeInfinityLikeTheJavaOne() {
        for (a in listOf(-1_000_000_000_007L, -86_400_000L, -1L, 0L, 1L, 86_399_999L, 86_400_000L, 1_800_000_000_000L)) for (b in listOf(900_000L, 86_400_000L)) assertEquals("$a / $b", Math.floorDiv(a, b), SportsEventService.floorDiv(a, b))
    }

    @Test fun theWindowIsBounded() = runBlocking {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "r1"); g.add(g.channel("c1", a, "Sports 1"), "NBA: Lakers vs Celtics", t0)
        service(g).events(t0, t0 + 30 * 24 * h, ctx)
        val (from, to) = g.asked.last()
        assertTrue("no more than 72 hours of guide is ever read", to - from <= SportsEventService.MAX_WINDOW_MS + 900_000L)
    }

    // ---- the benchmark, the shortcut, stopping work and bounded memory

    private val sportsTitles = listOf("Premier League: Arsenal v Chelsea", "NBA: Lakers vs Celtics", "IPL: Mumbai Indians vs Chennai Super Kings", "Formula 1: Monaco Grand Prix - Race", "UFC 300: Main Card")
    private val otherTitles = listOf("Evening News", "The Movie: Alien vs. Predator", "Cooking Today", "Cricket Highlights", "Kids Cartoon Hour", "Sky Sports News", "Weather", "Documentary: The Sea", "Quiz Night", "Football Focus Tonight")

    private fun largeGuide(): Pair<FakeGuide, Int> {
        val g = FakeGuide(); g.revisions = hashMapOf(a to "big"); var injected = 0
        for (i in 0 until 10_000) {
            val ch = g.channel("ch$i", a, "Channel $i", "cat${i % 40}")
            for (j in 0 until 12) {
                val isSport = i % 33 == 0 && j == 3
                if (isSport) injected++
                g.add(ch, if (isSport) sportsTitles[(i / 33) % sportsTitles.size] else otherTitles[(i + j) % otherTitles.size], t0 + j * h)
            }
        }
        return g to injected
    }

    @Test fun aLargeSyntheticGuideIsReadInBatchesAndClassifiedQuickly() = runBlocking {
        val (g, injected) = largeGuide()
        assertEquals(304, injected)
        val svc = service(g)
        val start = System.nanoTime()
        val events = svc.events(t0, t0 + 13 * h, ctx)
        val seconds = (System.nanoTime() - start) / 1e9
        println("SPORTS PERF (Kotlin) 10000 channels x 12 programmes (120000 total): ${events.size} events in ${"%.2f".format(seconds)} s; guide read in ${g.calls.get()} batches")
        assertEquals((10_000 + SportsEventService.BATCH - 1) / SportsEventService.BATCH, g.calls.get())
        assertEquals(5, events.size); assertEquals(injected, events.sumOf { it.feeds.size })
        assertTrue("classified in $seconds s", seconds < 20)
        val again = System.nanoTime(); svc.events(t0, t0 + 13 * h, ctx)
        assertTrue("the second request comes from the cache", (System.nanoTime() - again) / 1e9 < 1.5)
    }

    @Test fun theBenchmarkContainsExactlyTheEventsItWasBuiltToContainOnBothPaths() = runBlocking {
        val (g, injected) = largeGuide()
        for (title in sportsTitles) for (fast in listOf(true, false)) assertNotNull("$title fast=$fast", SportsClassifier.classify(title, channelName = "Channel 1", fastReject = fast))
        for (title in otherTitles) for (fast in listOf(true, false)) assertNull("$title fast=$fast", SportsClassifier.classify(title, channelName = "Channel 1", fastReject = fast))
        val fast = service(g).events(t0, t0 + 13 * h, ctx, fastReject = true); val full = service(g).events(t0, t0 + 13 * h, ctx, fastReject = false)
        assertEquals(5, fast.size); assertEquals(injected, fast.sumOf { it.feeds.size }); assertEquals(injected, full.sumOf { it.feeds.size })
        assertEquals(fast.map { it.id }, full.map { it.id }); assertEquals(fast.map { it.feeds.size }, full.map { it.feeds.size })
    }

    @Test fun aRequestOverTheLargeGuideCanBeCancelledQuicklyAndTheServiceStaysUsable() = runBlocking {
        val (g, _) = largeGuide()
        val svc = service(g)
        val started = System.nanoTime()
        val work = launch { svc.events(t0, t0 + 13 * h, ctx) }
        delay(20); work.cancel(); work.join()
        val took = (System.nanoTime() - started) / 1e9
        println("SPORTS CANCEL (Kotlin) stopped after ${"%.2f".format(took)} s")
        assertTrue("cancelling stops the work ($took s)", took < 1.5)
        assertEquals(5, svc.events(t0, t0 + 13 * h, ctx).size)
    }

    @Test fun theCacheCannotGrowWithoutLimitAcrossRevisionsProfilesAndWindows() = runBlocking {
        val g = FakeGuide(); g.add(g.channel("c1", a, "NBA 1"), "NBA: Lakers vs Celtics", t0); g.add(g.channel("c2", b, "NBA 2"), "NBA: Lakers vs Celtics", t0)
        val svc = service(g); var peak = 0
        for (revision in 0 until 40) {
            g.revisions = hashMapOf(a to "a$revision", b to "b$revision")
            for (profile in 0 until 5) for (day in 0 until 3) {
                svc.events(t0 + day * 24 * h - h, t0 + day * 24 * h + 6 * h, SportsContext("p$profile", profile % 2 == 0, setOf("x"), emptySet()))
                peak = maxOf(peak, svc.cachedEntries)
            }
        }
        assertTrue("at most ${SportsEventService.CACHE_LIMIT} entries were ever held (peak $peak)", peak <= SportsEventService.CACHE_LIMIT)
        svc.invalidate(); assertEquals(0, svc.cachedEntries)
    }
}
