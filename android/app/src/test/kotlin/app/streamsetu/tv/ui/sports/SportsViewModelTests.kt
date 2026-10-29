package app.streamsetu.tv.ui.sports

import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.tv.ui.screens.sports.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicInteger

/** Scripted dependencies that count every call, so a test can prove what did and did not touch the repository. */
class FakeSportsDeps(startScope: SportsScope = SportsScope(listOf("A"), "main", false, emptySet(), emptySet())) : SportsDeps {
    val scopeFlow = MutableStateFlow(startScope)
    val signals = MutableSharedFlow<Unit>(extraBufferCapacity = 64)
    val minuteFlow = MutableSharedFlow<Long>(replay = 1)
    override val scope: Flow<SportsScope> get() = scopeFlow
    override val dataSignals: Flow<Unit> get() = signals
    override val minutes: Flow<Long> get() = minuteFlow
    override val zone: TimeZone = TimeZone.getTimeZone("UTC")
    @Volatile var nowMs = 1_800_000_000_000L + 2 * 3_600_000L
    override fun now() = nowMs
    val loads = AtomicInteger(); val nameCalls = AtomicInteger(); val guideCalls = AtomicInteger()
    val loadedScopes = java.util.Collections.synchronizedList(ArrayList<SportsScope>())
    @Volatile var gate: CompletableDeferred<Unit>? = null
    @Volatile var cancelledLoads = 0
    @Volatile var failNext = false
    @Volatile var failWith: Exception = IllegalStateException("boom")
    @Volatile var cacheHit = false
    @Volatile var hasGuide = true
    @Volatile var result: (SportsScope) -> List<SportsEvent> = { emptyList() }

    override suspend fun sourceNames(): Map<String, String> { nameCalls.incrementAndGet(); return mapOf("A" to "Playlist A", "B" to "Playlist B") }
    override suspend fun hasGuide(): Boolean { guideCalls.incrementAndGet(); return hasGuide }
    override suspend fun load(scope: SportsScope, fromMs: Long, toMs: Long): SportsLoad {
        loads.incrementAndGet(); loadedScopes.add(scope)
        try { gate?.await() } catch (e: CancellationException) { cancelledLoads++; throw e }
        if (failNext) { failNext = false; throw failWith }
        return SportsLoad(result(scope), "rev-${loads.get()}", cacheHit)
    }
    fun tick() { minuteFlow.tryEmit(nowMs) }

    // Catch-Up history for the pages: counted, optionally held, never part of the hub's own load
    val historyCalls = AtomicInteger(); val historyWindows = java.util.Collections.synchronizedList(ArrayList<Pair<Long, Long>>())
    @Volatile var historyGate: CompletableDeferred<Unit>? = null
    @Volatile var historyCancelled = 0
    @Volatile var historyResult: List<SportsEvent> = emptyList()
    @Volatile var declaredDays = 0
    val dayQueries = AtomicInteger()
    override suspend fun history(scope: SportsScope, fromMs: Long, toMs: Long): SportsLoad {
        historyCalls.incrementAndGet(); historyWindows.add(fromMs to toMs)
        try { historyGate?.await() } catch (e: CancellationException) { historyCancelled++; throw e }
        return SportsLoad(historyResult, "hist", false)
    }
    @Volatile var guide: (SportsEvent) -> app.streamsetu.tv.sports.discovery.GuideTarget? = { null }
    val guideChecks = AtomicInteger()
    override suspend fun guideTarget(event: SportsEvent, order: List<String>): app.streamsetu.tv.sports.discovery.GuideTarget? { guideChecks.incrementAndGet(); return guide(event) }
    override suspend fun catchUpDays(channelIds: List<String>): Int { dayQueries.incrementAndGet(); return declaredDays }
}

class SportsViewModelTests {
    private val h = 3_600_000L; private val min = 60_000L
    private val job = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.Default + job)
    @After fun stop() { scope.cancel() }

    private fun feed(ch: String) = SportsFeed(ch, "A", "Channel $ch", null, MetadataSource.UNKNOWN, null, MetadataSource.UNKNOWN, null, ch, 0, false, null)
    private fun event(id: String, start: Long, sport: Sport = Sport.FOOTBALL, end: Long = start + 2 * h) =
        SportsEvent(id, sport, SportsEventKind.HEAD_TO_HEAD, "League", listOf("X", "Y"), null, "Event $id", start, end, listOf(feed(id)), 0.95, setOf("A"), "r")

    private fun vm(d: FakeSportsDeps, debounce: Long = 40L): SportsViewModel { d.tick(); return SportsViewModel(d, scope, debounce) }
    private suspend fun SportsViewModel.until(timeout: Long = 5_000, p: (SportsHubUiState) -> Boolean) = withTimeout(timeout) { uiState.first(p) }
    private fun deps(vararg events: SportsEvent) = FakeSportsDeps().also { d -> d.result = { events.toList() } }

    @Test fun firstLoadBuildsTheSectionsOnce() = runBlocking {
        val d = deps(event("live", d0() - 30 * min), event("soon", d0() + h), event("today", d0() + 4 * h), event("later", d0() + 30 * h))
        val v = vm(d); val s = v.until { !it.loading }
        assertEquals(listOf("live"), s.live.map { it.id }); assertEquals(listOf("soon"), s.startingSoon.map { it.id }); assertEquals(listOf("today"), s.today.map { it.id }); assertEquals(listOf("later"), s.upcoming.map { it.id })
        assertEquals(1, d.loads.get()); assertNull(s.message); assertEquals("rev-1", s.revision)
        assertEquals(listOf(SportsSection.LIVE_NOW, SportsSection.STARTING_SOON, SportsSection.TODAY, SportsSection.UPCOMING), s.sections)
    }
    private fun d0() = 1_800_000_000_000L + 2 * h

    @Test fun selectingAFilterOpeningAndClosingDetailNeverTouchTheRepository() = runBlocking {
        val d = deps(event("f", d0() + h), event("c", d0() + 2 * h, Sport.CRICKET))
        val v = vm(d); v.until { !it.loading }
        val loads = d.loads.get(); val names = d.nameCalls.get(); val guide = d.guideCalls.get()
        v.select(Sport.CRICKET); assertEquals(listOf("c"), v.until { it.selectedSport == Sport.CRICKET }.startingSoon.map { it.id })
        v.select(null); v.until { it.selectedSport == null }
        v.openDetail("f"); assertEquals("f", v.until { it.detail != null }.detail!!.card.id)
        v.closeDetail(); v.until { it.detail == null }
        repeat(30) { v.select(if (it % 2 == 0) Sport.FOOTBALL else null) }
        v.until { true }
        assertEquals("no repository call for any of that", Triple(loads, names, guide), Triple(d.loads.get(), d.nameCalls.get(), d.guideCalls.get()))
    }

    @Test fun theMinuteTickMovesEventsBetweenSectionsWithoutLoading() = runBlocking {
        val d = deps(event("e", d0() + 3 * h))
        val v = vm(d); assertEquals(listOf("e"), v.until { !it.loading }.today.map { it.id })
        d.nowMs = d0() + 2 * h; d.tick()                                                     // now less than two hours before it
        assertEquals(listOf("e"), v.until { it.startingSoon.isNotEmpty() }.startingSoon.map { it.id })
        d.nowMs = d0() + 3 * h + min; d.tick()
        assertEquals(listOf("e"), v.until { it.live.isNotEmpty() }.live.map { it.id })
        d.nowMs = d0() + 6 * h; d.tick()
        assertTrue("finished events leave the screen", v.until { it.live.isEmpty() }.isEmpty)
        assertEquals("the clock never loads", 1, d.loads.get())
    }

    @Test fun aGuideRefreshBurstIsOneReloadAndTheOldContentStaysVisibleWhileItRuns() = runBlocking {
        val d = deps(event("e", d0() + h))
        val v = vm(d); v.until { !it.loading }
        d.gate = CompletableDeferred()
        repeat(10) { d.signals.tryEmit(Unit); delay(5) }                                    // a refresh writes the guide in bursts
        val during = v.until { it.refreshing }
        assertEquals("the old content is still there", listOf("e"), during.startingSoon.map { it.id }); assertFalse(during.loading)
        d.gate!!.complete(Unit); v.until { !it.refreshing }
        delay(150)
        assertEquals("one reload for the whole burst", 2, d.loads.get())
    }

    @Test fun aNewerRefreshCancelsTheOlderOne() = runBlocking {
        val d = deps(event("e", d0() + h))
        val v = vm(d); v.until { !it.loading }
        d.gate = CompletableDeferred()
        v.refresh(); v.until { it.refreshing }; delay(50)
        v.refresh(); delay(100)
        assertTrue("the first refresh was cancelled", d.cancelledLoads >= 1)
        d.gate!!.complete(Unit); v.until { !it.refreshing }
        assertEquals(3, d.loads.get())
    }

    @Test fun everySecurityContextChangeClearsTheScreenAtOnceAndNeverShowsTheOldResult() = runBlocking {
        val changes: List<Pair<String, (SportsScope) -> SportsScope>> = listOf(
            "profile switch" to { s -> s.copy(profileId = "kid") },
            "active library switch" to { s -> s.copy(sourceIds = listOf("B")) },
            "parental mode change" to { s -> s.copy(hideAdult = true) },
            "folder relock" to { s -> s.copy(lockedFolderIds = setOf("cat-1")) },
            "source removed or disabled" to { s -> s.copy(sourceIds = emptyList()) },
            "a channel hidden" to { s -> s.copy(hiddenChannelIds = setOf("x")) },
        )
        for ((name, change) in changes) {
            val d = deps(event("old", d0() + h))
            val v = vm(d); v.until { !it.loading }
            val gate = CompletableDeferred<Unit>(); d.gate = gate
            d.result = { s -> listOf(event("for-${s.profileId}-${s.sourceIds.joinToString()}-${s.hideAdult}-${s.lockedFolderIds.size}-${s.hiddenChannelIds.size}", d0() + h)) }
            d.scopeFlow.value = change(d.scopeFlow.value)
            val cleared = v.until { it.loading }
            assertTrue("$name: nothing from before stays on screen", cleared.isEmpty && cleared.filters.isEmpty() && cleared.detail == null && !cleared.refreshing)
            gate.complete(Unit)
            val after = v.until { !it.loading }
            assertEquals("$name: only the new scope's result", 1, after.startingSoon.size); assertTrue("$name", after.startingSoon.single().id.startsWith("for-"))
        }
    }

    @Test fun aResultStartedBeforeAScopeChangeIsNeverPublished() = runBlocking {
        val d = deps()
        d.result = { s -> listOf(event("of-${s.profileId}", d0() + h)) }
        d.gate = CompletableDeferred()
        val v = vm(d); delay(100)                                                              // the first load (profile "main") is held up
        d.scopeFlow.value = d.scopeFlow.value.copy(profileId = "kid"); delay(100)             // the profile switches meanwhile
        d.gate!!.complete(Unit)
        val s = v.until { !it.loading }
        assertEquals(listOf("of-kid"), s.startingSoon.map { it.id }); delay(150)
        assertEquals("the previous profile's result never replaced it", listOf("of-kid"), v.uiState.value.startingSoon.map { it.id })
        assertTrue(d.cancelledLoads >= 1)
    }

    @Test fun anOpenDetailIsClosedWhenTheScopeChanges() = runBlocking {
        val d = deps(event("e", d0() + h)); val v = vm(d); v.until { !it.loading }
        v.openDetail("e"); v.until { it.detail != null }
        d.gate = CompletableDeferred()                                                       // hold the rebuild so the cleared state can be seen
        d.scopeFlow.value = d.scopeFlow.value.copy(profileId = "kid")
        assertNull(v.until { it.loading }.detail); d.gate?.complete(Unit)
        assertNull(v.until { !it.loading }.detail)
    }

    @Test fun anOpenDetailForAnEventThatDisappearsIsDropped() = runBlocking {
        val d = deps(event("e", d0() + h)); val v = vm(d); v.until { !it.loading }
        v.openDetail("e"); v.until { it.detail != null }
        d.result = { emptyList() }; v.refresh()
        assertNull(v.until { it.detail == null && !it.refreshing }.detail)
    }

    @Test fun errorNoGuideAndNoSportsStates() = runBlocking {
        val d = deps(); d.failNext = true
        val v = vm(d); val err = v.until { it.message != null }
        assertTrue(err.message is SportsHubMessage.Error); assertFalse(err.loading)
        d.result = { emptyList() }; d.hasGuide = true; v.refresh()
        assertEquals(SportsHubMessage.NoSports, v.until { it.message == SportsHubMessage.NoSports }.message)
        d.hasGuide = false; v.refresh()
        assertEquals(SportsHubMessage.NoGuide, v.until { it.message == SportsHubMessage.NoGuide }.message)
    }

    @Test fun aFailedRefreshKeepsTheContentThatWasThere() = runBlocking {
        val d = deps(event("e", d0() + h)); val v = vm(d); v.until { !it.loading }
        d.failNext = true; v.refresh()
        val s = v.until { !it.refreshing && d.loads.get() >= 2 }
        assertEquals(listOf("e"), s.startingSoon.map { it.id }); assertNull("content exists, so no blocking error", s.message)
    }

    @Test fun enteringTheScreenAgainRefreshesOnlyOldContent() = runBlocking {
        val d = deps(event("e", d0() + h)); val v = vm(d); v.until { !it.loading }
        v.onEntered(); delay(100); assertEquals("fresh content is not reloaded", 1, d.loads.get())
        d.nowMs += 2 * h; v.onEntered(); v.until { true }; delay(200)
        assertEquals("old content is refreshed in the background", 2, d.loads.get())
    }

    @Test fun buildingTheStateForAHugeEventListIsFast() = runBlocking {
        val events = (0 until 5_000).map { event("e$it", d0() + (it % 72) * h, if (it % 3 == 0) Sport.CRICKET else Sport.FOOTBALL) }
        val d = deps(*events.toTypedArray()); val v = vm(d)
        val t0 = System.nanoTime(); v.until(20_000) { !it.loading }; val first = (System.nanoTime() - t0) / 1e6
        val t1 = System.nanoTime(); v.select(Sport.CRICKET); v.until { it.selectedSport == Sport.CRICKET }; val filter = (System.nanoTime() - t1) / 1e6
        println("SPORTS UI STATE (5000 events): first load+state ${"%.0f".format(first)} ms, filter change ${"%.0f".format(filter)} ms")
        assertTrue("first $first ms", first < 3_000); assertTrue("filter $filter ms", filter < 1_000)
    }

    // ---- counts-only diagnostics

    private class Reports : SportsDiagnostics { val all = java.util.Collections.synchronizedList(ArrayList<SportsLoadReport>()); override fun record(report: SportsLoadReport) { all.add(report) } }
    private fun vmWith(d: FakeSportsDeps, r: Reports): SportsViewModel { d.tick(); return SportsViewModel(d, scope, 40L, r) }

    @Test fun aLoadReportsOnlyCounts() = runBlocking {
        val d = deps(event("live", d0() - 30 * min), event("soon", d0() + h, Sport.CRICKET), event("later", d0() + 30 * h))
        d.cacheHit = true
        val r = Reports(); val v = vmWith(d, r); v.until { !it.loading }
        val x = r.all.single()
        assertEquals(SportsLoadOutcome.OK, x.outcome); assertEquals(3, x.totalEvents); assertEquals(3, x.feeds); assertEquals(0, x.lowConfidence); assertEquals(1, x.sources); assertEquals(true, x.cacheHit)
        assertEquals(mapOf(SportsSection.LIVE_NOW to 1, SportsSection.STARTING_SOON to 1, SportsSection.TODAY to 0, SportsSection.UPCOMING to 1), x.bySection)
        assertEquals(mapOf(Sport.FOOTBALL to 2, Sport.CRICKET to 1), x.bySport); assertTrue(x.loadMs >= 0)
        assertTrue(x.line(), x.line().contains("cache=hit") && x.line().contains("events=3"))
    }

    @Test fun lowConfidenceEventsAreCountedAndAMissIsReportedAsOne() = runBlocking {
        val weak = event("w", d0() + h).copy(confidence = 0.5)
        val d = deps(weak, event("s", d0() + 2 * h)); val r = Reports(); val v = vmWith(d, r); v.until { !it.loading }
        assertEquals(1, r.all.single().lowConfidence); assertEquals(false, r.all.single().cacheHit); assertTrue(r.all.single().line().contains("cache=miss"))
    }

    @Test fun aFailureReportsOnlyItsCategoryNeverTheMessage() = runBlocking {
        val d = deps(event("e", d0() + h)); d.failNext = true; d.failWith = java.io.IOException("SECRET https://user:pass@provider.example/get.php?token=SECRET")
        val r = Reports(); val v = vmWith(d, r); v.until { it.message != null }
        val x = r.all.single()
        assertEquals(SportsLoadOutcome.ERROR, x.outcome); assertEquals(SportsErrorCategory.IO, x.errorCategory); assertNull(x.cacheHit)
        assertFalse(x.line(), x.line().contains("SECRET") || x.line().contains("provider"))
    }

    @Test fun aCancelledLoadIsReportedAsCancelled() = runBlocking {
        val d = deps(event("e", d0() + h)); d.gate = CompletableDeferred()
        val r = Reports(); val v = vmWith(d, r); v.until { true }
        withTimeout(5_000) { while (d.loads.get() == 0) delay(5) }
        d.gate = null; v.refresh()                                                          // a newer load replaces the one waiting on the gate
        withTimeout(5_000) { while (r.all.none { it.outcome == SportsLoadOutcome.CANCELLED }) delay(5) }
        assertNull(r.all.first { it.outcome == SportsLoadOutcome.CANCELLED }.errorCategory)
    }

    @Test fun noNameAddressDescriptionOrCredentialReachesTheReport() = runBlocking {
        val secret = "SECRET"
        val named = SportsEvent("id-SECRET", Sport.FOOTBALL, SportsEventKind.HEAD_TO_HEAD, "SECRET League", listOf("SECRET FC", "SECRET United"), null, "SECRET FC v SECRET United", d0() + h, d0() + 3 * h,
            listOf(SportsFeed("SECRET-ch", "A", "SECRET Channel", "en", MetadataSource.UNKNOWN, "HD", MetadataSource.UNKNOWN, "SECRET variant", "SECRET-guide", 0L, false, "http://u:SECRET@SECRET.example/logo.png")),
            0.5, setOf("A"), "SECRET")
        val d = deps(named); val r = Reports(); val v = vmWith(d, r); v.until { !it.loading }
        val x = r.all.single(); val text = x.line() + " " + x.bySection + " " + x.bySport + " " + x.outcome + " " + x.errorCategory
        assertFalse(text, text.uppercase().contains(secret) || text.contains("http") || text.contains("example"))
        // the report's fields are all numbers, enums or flags: nothing in its type can carry text
        val kinds = SportsLoadReport::class.java.declaredFields.map { it.type }.toSet()
        assertTrue(kinds.toString(), kinds.none { it == String::class.java || it == CharSequence::class.java || List::class.java.isAssignableFrom(it) })
    }
}
