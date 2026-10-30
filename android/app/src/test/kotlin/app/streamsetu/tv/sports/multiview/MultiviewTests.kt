package app.streamsetu.tv.sports.multiview

import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.sports.FakePlaybackDeps
import app.streamsetu.tv.sports.RankInput
import app.streamsetu.tv.sports.SportsAuthorization
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class FakeTileEngine(val deps: FakeMultiviewDeps) : TileEngine {
    override var onEvent: (TileEvent) -> Unit = {}
    val loads = java.util.Collections.synchronizedList(ArrayList<TileRequest>())
    @Volatile var vol = -1f; @Volatile var caps = false; @Volatile var released = false; @Volatile var stopped = 0
    override fun load(request: TileRequest) { loads.add(request); deps.loadCalls.incrementAndGet() }
    override fun setVolume(volume: Float) { vol = volume }
    override fun setCaptions(enabled: Boolean) { caps = enabled }
    override fun stop() { stopped++ }
    override fun release() { if (!released) deps.activeNow.decrementAndGet(); released = true; deps.releasedCount.incrementAndGet() }
    override fun view(context: android.content.Context): android.view.View? = null
    fun emit(e: TileEvent) = onEvent(e)
}

class FakeMultiviewDeps(val auth: FakePlaybackDeps = FakePlaybackDeps()) : MultiviewDeps, SportsAuthorization by auth {
    val engines = java.util.Collections.synchronizedList(ArrayList<FakeTileEngine>())
    val createdCount = AtomicInteger(); val releasedCount = AtomicInteger(); val loadCalls = AtomicInteger(); val resolveCalls = AtomicInteger()
    val resolveThreads = java.util.Collections.synchronizedList(ArrayList<String>())
    @Volatile var engineLimit = Int.MAX_VALUE
    @Volatile var resolveGate: CompletableDeferred<Unit>? = null
    @Volatile var unresolvable = HashSet<String>()
    @Volatile var time = 5_000L
    val activeNow = AtomicInteger(); val peak = AtomicInteger()
    override fun createEngine(): TileEngine? { if (createdCount.get() >= engineLimit) return null; createdCount.incrementAndGet(); peak.accumulateAndGet(activeNow.incrementAndGet()) { a, b -> maxOf(a, b) }; return FakeTileEngine(this).also { engines.add(it) } }
    override suspend fun resolve(channel: Channel): TileRequest? {
        resolveCalls.incrementAndGet(); resolveThreads.add(Thread.currentThread().name); resolveGate?.await()
        return if (channel.id in unresolvable) null else TileRequest("http://user:SECRET@host.example/${channel.id}.ts", mapOf("X-Token" to "SECRET"), 1280, 720)
    }
    override fun nowMs(): Long { time += 3; return time }
    val active get() = engines.count { !it.released }
}

class MultiviewTests {
    private val main = Executors.newSingleThreadExecutor { Thread(it, "mv-main") }.asCoroutineDispatcher()
    private val scope = CoroutineScope(main + SupervisorJob())
    @After fun stop() { scope.cancel(); main.close() }

    private fun facts(lowRam: Boolean = false, mem: Int = 384, cores: Int = 8, decoders: List<HardwareDecoder> = listOf(HardwareDecoder("video/avc", false, 16), HardwareDecoder("video/hevc", false, 8))) = DeviceFacts(lowRam, mem, cores, decoders)
    private fun cap(f: DeviceFacts = facts()) = MultiviewCapability { f }
    private fun channel(id: String, name: String = "Channel $id", cat: String? = "cat") = Channel(id, "A", cat, name, null, null, "http://u:SECRET@host.example/$id", null)
    private fun feed(id: String, q: String? = null, qs: MetadataSource = MetadataSource.UNKNOWN, name: String = "Channel $id") = SportsFeed(id, "A", name, null, MetadataSource.UNKNOWN, q, qs, null, id, 0L, false)
    private fun event(id: String, vararg feeds: SportsFeed, title: String = "Event $id") =
        SportsEvent(id, Sport.FOOTBALL, SportsEventKind.HEAD_TO_HEAD, "League", listOf("X", "Y"), null, title, 1000L, 100_000_000L, feeds.toList(), 0.95, setOf("A"), "r")
    private fun await(timeout: Long = 5_000, p: () -> Boolean) = runBlocking { withTimeout(timeout) { while (!p()) delay(3) } }
    private fun entry(ch: String, ev: String = "e$ch", title: String = "Event $ev") = MultiviewEntry(ev, ch, "A", title, "Channel $ch · Playlist A")

    private class Rig(val d: FakeMultiviewDeps, val c: MultiviewCapability, val s: MultiviewSession, val reports: MutableList<MultiviewReport>)
    private fun rig(vararg ids: String, capability: MultiviewCapability = cap()): Rig {
        val d = FakeMultiviewDeps(); ids.forEach { d.auth.channels[it] = channel(it) }
        val reports = java.util.Collections.synchronizedList(ArrayList<MultiviewReport>())
        return Rig(d, capability, MultiviewSession(d, capability, scope, Dispatchers.IO) { reports.add(it) }, reports)
    }
    private fun Rig.engine(i: Int) = d.engines[i]
    private fun Rig.ready(i: Int) { await { d.engines.size > i && d.engines[i].loads.isNotEmpty() }; d.engines[i].emit(TileEvent.Ready) }
    private fun Rig.states() = s.state.value.tiles

    // ---- capability

    @Test fun theTileLimitComesFromWhatTheDeviceReports() {
        assertEquals(4, TileLimitPolicy.limit(facts()))
        assertEquals(3, TileLimitPolicy.limit(facts(mem = 224)))
        assertEquals(2, TileLimitPolicy.limit(facts(mem = 160))); assertEquals(2, TileLimitPolicy.limit(facts(lowRam = true))); assertEquals(2, TileLimitPolicy.limit(facts(cores = 4)))
        assertEquals("the decoder's own limit is an upper bound", 3, TileLimitPolicy.limit(facts(decoders = listOf(HardwareDecoder("video/avc", false, 3)))))
        assertEquals("an unknown instance count is taken as two", 2, TileLimitPolicy.limit(facts(decoders = listOf(HardwareDecoder("video/avc", false, 0)))))
    }

    @Test fun withoutAHardwareDecoderThereIsOnePictureNeverSeveralInSoftware() {
        assertEquals(1, TileLimitPolicy.limit(facts(decoders = emptyList())))
        assertEquals("a decoder that is only for protected content is not counted", 1, TileLimitPolicy.limit(facts(decoders = listOf(HardwareDecoder("video/avc", true, 16)))))
    }

    @Test fun anUnsupportedCodecIsKnownBeforeAnythingPlays() {
        assertTrue(TileLimitPolicy.canDecode(facts(), "video/hevc")); assertFalse(TileLimitPolicy.canDecode(facts(), "video/av01"))
    }

    @Test fun aDecoderFailureLowersTheUsableCountForTheRestOfTheSession() {
        val c = cap(); assertEquals(4, c.usableLimit())
        c.noteAllocationFailure(2); assertEquals(2, c.usableLimit()); assertEquals("the device itself did not change", 4, c.deviceLimit())
        c.noteAllocationFailure(3); assertEquals("it never rises again", 2, c.usableLimit())
        val none = cap(); none.noteAllocationFailure(0); assertEquals("never below one", 1, none.usableLimit())
    }

    @Test fun capabilityIsReadFromThePlatformAndNeedsNoProviderRequest() {
        val d = FakeMultiviewDeps(); val c = MultiviewCapability { facts() }
        c.deviceLimit(); c.usableLimit()
        assertEquals(0, d.resolveCalls.get() + d.loadCalls.get() + d.createdCount.get() + d.auth.lookups.get())
    }

    @Test fun smallerTilesGetSmallerPictures() {
        assertEquals(1280 to 720, TileVideoCap.forCount(2)); assertEquals(1280 to 720, TileVideoCap.forCount(3)); assertEquals(960 to 540, TileVideoCap.forCount(4))
    }

    // ---- layouts and the remote

    @Test fun everyLayoutFillsTheSafeViewportExactlyWithNothingCutOff() {
        for (n in 1..4) {
            val r = MultiviewLayout.rects(n); assertEquals(n, r.size)
            r.forEach { assertTrue("$n: $it", it.x >= 0f && it.y >= 0f && it.x + it.w <= 1.0001f && it.y + it.h <= 1.0001f && it.w > 0 && it.h > 0) }
            assertEquals("no overlap or gap for $n tiles", 1f, r.sumOf { (it.w * it.h).toDouble() }.toFloat(), 0.001f)
        }
        assertTrue("the primary is the large one in three", MultiviewLayout.rects(3)[0].let { it.w * it.h > MultiviewLayout.rects(3)[1].let { o -> o.w * o.h } * 3 })
    }

    @Test fun directionKeysMoveGeometricallyInEveryLayoutAndStopAtTheEdges() {
        val two = MultiviewLayout.rects(2)
        assertEquals(1, MultiviewNav.move(two, 0, Dir.RIGHT)); assertEquals(0, MultiviewNav.move(two, 1, Dir.LEFT)); assertNull(MultiviewNav.move(two, 0, Dir.LEFT)); assertNull(MultiviewNav.move(two, 0, Dir.UP)); assertNull(MultiviewNav.move(two, 1, Dir.RIGHT))
        val three = MultiviewLayout.rects(3)
        assertEquals(1, MultiviewNav.move(three, 0, Dir.RIGHT)); assertEquals(2, MultiviewNav.move(three, 1, Dir.DOWN)); assertEquals(1, MultiviewNav.move(three, 2, Dir.UP))
        assertEquals(0, MultiviewNav.move(three, 1, Dir.LEFT)); assertEquals(0, MultiviewNav.move(three, 2, Dir.LEFT)); assertNull(MultiviewNav.move(three, 2, Dir.DOWN)); assertNull(MultiviewNav.move(three, 1, Dir.RIGHT)); assertNull(MultiviewNav.move(three, 0, Dir.DOWN))
        val four = MultiviewLayout.rects(4)
        assertEquals(1, MultiviewNav.move(four, 0, Dir.RIGHT)); assertEquals(2, MultiviewNav.move(four, 0, Dir.DOWN)); assertEquals(3, MultiviewNav.move(four, 1, Dir.DOWN)); assertEquals(3, MultiviewNav.move(four, 2, Dir.RIGHT))
        assertEquals(0, MultiviewNav.move(four, 2, Dir.UP)); assertEquals(2, MultiviewNav.move(four, 3, Dir.LEFT)); assertNull(MultiviewNav.move(four, 3, Dir.DOWN)); assertNull(MultiviewNav.move(four, 0, Dir.LEFT))
    }

    @Test fun anyRunOfKeysLeavesOneValidSlot() {
        val rnd = java.util.Random(7)
        for (n in 2..4) { val r = MultiviewLayout.rects(n); var at = 0; repeat(500) { MultiviewNav.move(r, at, Dir.values()[rnd.nextInt(4)])?.let { at = it }; assertTrue(at in 0 until n) } }
    }

    @Test fun makingATilePrimaryOnlyReordersTheSlots() {
        assertEquals(listOf("c", "a", "b"), MultiviewLayout.makePrimary(listOf("a", "b", "c"), 2)); assertEquals(listOf("a", "b"), MultiviewLayout.makePrimary(listOf("a", "b"), 0))
    }

    // ---- the builder

    private fun selRig(limit: Int = 4, vararg events: SportsEvent, rank: RankInput = RankInput()): Triple<SportsMultiviewSelection, FakeMultiviewDeps, MultiviewCapability> {
        val d = FakeMultiviewDeps(); events.flatMap { it.feeds }.forEach { d.auth.channels[it.channelId] = channel(it.channelId, it.channelName) }
        val c = cap(facts(mem = if (limit >= 4) 384 else if (limit == 3) 224 else 160))
        val sel = SportsMultiviewSelection(d, c) { rank }; sel.useEvents { events.toList() }
        return Triple(sel, d, c)
    }

    @Test fun eventsAreAddedRemovedReplacedAndReordered() = runBlocking {
        val (sel, _, _) = selRig(4, event("e1", feed("1")), event("e2", feed("2")), event("e3", feed("3", name = "Three")))
        assertTrue(sel.add("e1") is SelectionResult.Done); assertFalse("one is not enough", sel.state.value.canStart)
        sel.add("e2"); assertTrue(sel.state.value.canStart)
        sel.move(1, -1); assertEquals(listOf("2", "1"), sel.state.value.entries.map { it.channelId })
        assertTrue(sel.replace(0, "e3") is SelectionResult.Done); assertEquals(listOf("3", "1"), sel.state.value.entries.map { it.channelId })
        sel.remove(1); assertEquals(listOf("3"), sel.state.value.entries.map { it.channelId }); assertFalse(sel.state.value.canStart)
    }

    @Test fun theDevicesTileLimitIsEnforced() = runBlocking {
        val (sel, _, c) = selRig(2, event("e1", feed("1")), event("e2", feed("2")), event("e3", feed("3")))
        assertEquals(2, c.usableLimit()); sel.add("e1"); sel.add("e2")
        assertEquals(SelectionResult.Refused(AddRefusal.LIMIT), sel.add("e3")); assertEquals(2, sel.state.value.entries.size)
    }

    @Test fun theSameChannelOrTheSameEventIsRefusedUnlessComparingFeedsIsChosen() = runBlocking {
        val (sel, _, _) = selRig(4, event("e1", feed("1"), feed("1b")), event("e2", feed("1")))
        sel.add("e1", "1")
        assertEquals("another event carrying the same channel", SelectionResult.Refused(AddRefusal.SAME_CHANNEL), sel.add("e2"))
        assertEquals("another feed of the same event", SelectionResult.Refused(AddRefusal.SAME_EVENT), sel.add("e1", "1b"))
        assertTrue("explicitly comparing feeds of one event", sel.add("e1", "1b", allowSameEvent = true) is SelectionResult.Done)
        assertEquals(SelectionResult.Refused(AddRefusal.SAME_CHANNEL), sel.add("e1", "1b", allowSameEvent = true))
    }

    @Test fun restrictedStaleAndUnsupportedFeedsAreRefused() = runBlocking {
        val (sel, d, _) = selRig(4, event("e1", feed("1")), event("e2", feed("2")), event("e4k", feed("k", "4K", MetadataSource.PROVIDER)), rank = RankInput(deviceDecodes4K = false))
        d.auth.lockedCategories.add("cat")
        assertEquals(SelectionResult.Refused(AddRefusal.NOT_AVAILABLE), sel.add("e1"))
        d.auth.lockedCategories.clear(); d.auth.hiddenChannels.add("2")
        assertEquals(SelectionResult.Refused(AddRefusal.NOT_AVAILABLE), sel.add("e2")); d.auth.hiddenChannels.clear()
        assertEquals(SelectionResult.Refused(AddRefusal.EVENT_GONE), sel.add("nope"))
        assertEquals("a provider-supplied quality this device cannot show", SelectionResult.Refused(AddRefusal.UNSUPPORTED_QUALITY), sel.add("e4k"))
        assertTrue(sel.state.value.entries.isEmpty())
    }

    @Test fun focusAndReadingTheSelectionCauseNoPlaybackOrRepositoryCall() {
        val (sel, d, _) = selRig(4, event("e1", feed("1")))
        sel.state.value; sel.liveEvents(2000L); sel.state.value.canStart
        assertEquals(0, d.auth.lookups.get() + d.createdCount.get() + d.resolveCalls.get() + d.loadCalls.get() + d.auth.played.size)
    }

    @Test fun aRestrictionChangeDropsTheRestrictedEntryAtOnceAndReplacesNothing() = runBlocking {
        val (sel, d, _) = selRig(4, event("e1", feed("1")), event("e2", feed("2")))
        sel.add("e1"); sel.add("e2"); d.auth.hiddenChannels.add("1"); sel.revalidate()
        assertEquals(listOf("2"), sel.state.value.entries.map { it.channelId })
    }

    // ---- starting

    @Test fun tilesStartOneAtATimeEachWhenTheOneBeforeHasAnswered() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3")))
        await { r.d.engines.size == 1 && r.engine(0).loads.size == 1 }; Thread.sleep(60)
        assertEquals("the second decoder is not asked for before the first has answered", 1, r.d.createdCount.get())
        r.engine(0).emit(TileEvent.Buffering); await { r.d.engines.size == 2 && r.engine(1).loads.size == 1 }; Thread.sleep(60)
        assertEquals(2, r.d.createdCount.get())
        r.engine(1).emit(TileEvent.Ready); await { r.d.engines.size == 3 && r.engine(2).loads.size == 1 }
        r.engine(0).emit(TileEvent.Ready); r.engine(2).emit(TileEvent.Ready)
        await { r.states().all { it.status == TileStatus.PLAYING } }
        assertTrue(r.reports.count { it.stage == MultiviewStage.TILE_STARTED } == 3)
    }

    @Test fun oneTileFailingKeepsTheWorkingOnesAndOffersItsOwnChoices() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3")))
        r.ready(0); await { r.d.engines.size == 2 && r.engine(1).loads.isNotEmpty() }
        r.engine(1).emit(TileEvent.Failed(TileFailure.NETWORK, false)); r.ready(2)
        await { r.states().size == 3 && r.states()[2].status == TileStatus.PLAYING }
        assertEquals(listOf(TileStatus.PLAYING, TileStatus.FAILED, TileStatus.PLAYING), r.states().map { it.status }); assertEquals("This feed could not be played", r.states()[1].message)
        assertEquals("only the failed tile stopped being useful; nothing was torn down", 0, r.d.releasedCount.get())
    }

    @Test fun staleOrRestrictedEntriesAreRejectedBeforeAnythingPlays() {
        val r = rig("1", "2", "3"); r.d.auth.hiddenChannels.add("3")
        r.s.start(listOf(entry("1"), entry("2"), entry("3"))); r.ready(0)
        try { await { r.states().size == 2 && r.d.createdCount.get() >= 2 } }                           // observable session state, bounded: the list is published and the second engine has been made
        catch (e: Throwable) { fail("timed out: tiles=${r.states().map { it.channelId }} created=${r.d.createdCount.get()} released=${r.d.releasedCount.get()} loads=${r.d.loadCalls.get()}") }
        assertEquals(listOf("1", "2"), r.states().map { it.channelId })
        // createdCount counts every engine ever made, including one made and then released, so equality here is the whole history
        assertEquals("exactly the two allowed tiles made one engine each, and the restricted one never made one", 2, r.d.createdCount.get())
        assertEquals("none was made and then torn down", 0, r.d.releasedCount.get())
        assertTrue("tiles load one after another, so by now one or both have loaded, never a third", r.d.loadCalls.get() in 1..2); assertTrue("it was never asked to play, even briefly", r.d.auth.played.none { it.id == "3" })
        val few = rig("1", "2"); few.d.auth.channels.remove("2"); few.s.start(listOf(entry("1"), entry("2")))
        await { few.s.state.value.notice == MultiviewNotice.NOT_ENOUGH }
        assertEquals("fewer than two valid feeds: no player was ever made", 0, few.d.createdCount.get())
    }

    @Test fun aSecurityChangeWhileStartingCancelsTheTilesNotYetStarted() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3")))
        r.ready(0); await { r.d.engines.size == 2 }
        r.d.auth.profile = "kid"; r.s.revalidate()
        await { r.d.active == 0 && r.states().isEmpty() }
        Thread.sleep(80); assertEquals("nothing further was started", 2, r.d.createdCount.get())
    }

    @Test fun everyTileIsResolvedBySharedPathOffTheMainThread() {
        val r = rig("1", "2"); r.s.start(listOf(entry("1"), entry("2"))); r.ready(0); r.ready(1)
        await { r.states().all { it.status == TileStatus.PLAYING } }
        assertEquals(2, r.d.resolveCalls.get()); assertTrue("no stream address is resolved on the main thread: ${r.d.resolveThreads}", r.d.resolveThreads.none { it == "mv-main" })
        assertFalse("no address or header in anything the screen draws", r.s.state.value.toString().contains("SECRET") || r.s.state.value.toString().contains("http"))
    }

    // ---- sound

    @Test fun exactlyOneTileHasSoundAndItStartsOnThePrimary() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3")))
        r.ready(0); r.ready(1); r.ready(2); await { r.states().all { it.status == TileStatus.PLAYING } }
        assertEquals(listOf(true, false, false), r.states().map { it.audio }); assertEquals(listOf(1f, 0f, 0f), listOf(r.engine(0).vol, r.engine(1).vol, r.engine(2).vol))
        assertEquals("captions follow the sound", listOf(true, false, false), listOf(r.engine(0).caps, r.engine(1).caps, r.engine(2).caps))
    }

    @Test fun movingTheSoundNeverReloadsAPicture() {
        val r = rig("1", "2"); r.s.start(listOf(entry("1"), entry("2"))); r.ready(0); r.ready(1); await { r.states().all { it.status == TileStatus.PLAYING } }
        val loads = r.d.loadCalls.get(); val id2 = r.states()[1].id
        r.s.listenHere(id2); await { r.states()[1].audio }
        assertEquals(listOf(false, true), r.states().map { it.audio }); assertEquals(listOf(0f, 1f), listOf(r.engine(0).vol, r.engine(1).vol))
        assertEquals("no reload, no stop", Triple(loads, 0, 0), Triple(r.d.loadCalls.get(), r.engine(0).stopped, r.engine(1).stopped)); assertTrue(r.reports.any { it.stage == MultiviewStage.AUDIO_CHANGED })
    }

    @Test fun removingTheTileWithSoundChoosesTheNextPlayingTile() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3"))); r.ready(0); await { r.d.engines.size == 2 }
        r.engine(1).emit(TileEvent.Failed(TileFailure.NETWORK, false)); r.ready(2); await { r.states().size == 3 && r.states()[2].status == TileStatus.PLAYING }
        r.s.remove(r.states()[0].id); await { r.states().size == 2 }
        assertEquals("the failed tile is skipped: the next one that plays has the sound", listOf(false, true), r.states().map { it.audio })
    }

    @Test fun makingATilePrimaryReordersWithoutRestartingAndKeepsTheSound() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3"))); r.ready(0); r.ready(1); r.ready(2); await { r.states().all { it.status == TileStatus.PLAYING } }
        val loads = r.d.loadCalls.get(); r.s.makePrimary(r.states()[2].id); await { r.states()[0].channelId == "3" }
        assertEquals(listOf("3", "1", "2"), r.states().map { it.channelId }); assertEquals("1", r.states().single { it.audio }.channelId); assertEquals(loads, r.d.loadCalls.get()); assertEquals(0, r.d.releasedCount.get())
    }

    // ---- changing a feed

    private fun playing2(): Rig { val r = rig("1", "2", "9"); r.s.start(listOf(entry("1"), entry("2"))); r.ready(0); r.ready(1); await { r.states().all { it.status == TileStatus.PLAYING } }; return r }

    @Test fun aSuccessfulSwitchChangesOneTileInItsOwnPlayerAndNothingElse() {
        val r = playing2(); val before = r.engine(0).loads.size
        r.s.replace(r.states()[1].id, entry("9")); await { r.engine(1).loads.size == 2 }
        r.engine(1).emit(TileEvent.Ready); await { r.states()[1].channelId == "9" && r.states()[1].status == TileStatus.PLAYING }
        assertEquals("the other tile was not touched", Triple(before, 0, false), Triple(r.engine(0).loads.size, r.engine(0).stopped, r.engine(0).released)); assertEquals("still two players", 2, r.d.active)
        assertTrue(r.reports.any { it.stage == MultiviewStage.FEED_SWITCHED })
    }

    @Test fun aFailedSwitchStartsThePreviousFeedAgainAndNeverAnAlternate() {
        val r = playing2()
        r.s.replace(r.states()[1].id, entry("9")); await { r.engine(1).loads.size == 2 }
        r.engine(1).emit(TileEvent.Failed(TileFailure.REFUSED, false)); await { r.engine(1).loads.size == 3 }
        assertTrue("the third load is the previous feed (channel 2)", r.engine(1).loads[2].url.contains("/2.ts"))
        r.engine(1).emit(TileEvent.Ready); await { r.states()[1].message == "Could not switch. Returned to the previous feed." }
        assertEquals("2", r.states()[1].channelId); assertEquals(3, r.engine(1).loads.size); assertEquals(1, r.engine(0).loads.size)
        assertTrue(r.reports.any { it.stage == MultiviewStage.FEED_RESTORED })
    }

    @Test fun ifTheRestorationAlsoFailsTheTileShowsItsOwnFailureOnly() {
        val r = playing2()
        r.s.replace(r.states()[1].id, entry("9")); await { r.engine(1).loads.size == 2 }
        r.engine(1).emit(TileEvent.Failed(TileFailure.REFUSED, false)); await { r.engine(1).loads.size == 3 }
        r.engine(1).emit(TileEvent.Failed(TileFailure.NETWORK, false)); await { r.states()[1].status == TileStatus.FAILED }
        assertEquals(TileStatus.PLAYING, r.states()[0].status); assertEquals("no fourth attempt", 3, r.engine(1).loads.size)
    }

    @Test fun aRestrictedReplacementIsRefusedAndTheTileKeepsPlaying() {
        val r = playing2(); r.d.auth.hiddenChannels.add("9")
        r.s.replace(r.states()[1].id, entry("9")); await { r.states()[1].message == "That feed is not available." }
        assertEquals(1, r.engine(1).loads.size); assertEquals(TileStatus.PLAYING, r.states()[1].status); assertEquals("2", r.states()[1].channelId)
    }

    @Test fun aSwitchFromBeforeASecurityChangeIsCancelled() {
        val r = playing2(); r.d.resolveGate = CompletableDeferred()
        r.s.replace(r.states()[1].id, entry("9")); await { r.d.resolveCalls.get() >= 3 }
        r.d.auth.hiddenChannels.add("8"); r.s.revalidate(); Thread.sleep(80); r.d.resolveGate!!.complete(Unit); Thread.sleep(120)
        assertEquals("the pending switch never loaded anything", 1, r.engine(1).loads.size)
    }

    // ---- who may see what

    @Test fun onlyTheTileThatIsNoLongerAllowedIsRemovedAndTheOthersKeepPlaying() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3"))); r.ready(0); r.ready(1); r.ready(2); await { r.states().all { it.status == TileStatus.PLAYING } }
        r.d.auth.hiddenChannels.add("2"); r.s.revalidate(); await { r.states().size == 2 }
        assertEquals(listOf("1", "3"), r.states().map { it.channelId }); assertTrue(r.engine(1).released); assertFalse(r.engine(0).released); assertFalse(r.engine(2).released); assertEquals("nothing replaced it", 3, r.d.createdCount.get())
    }

    @Test fun aProfileSwitchStopsEveryTile() {
        val r = playing2(); r.d.auth.profile = "kid"; r.s.revalidate(); await { r.states().isEmpty() }
        assertEquals(0, r.d.active)
    }

    @Test fun aGuideChangeOnlyDetachesTheTileFromItsEvent() {
        val r = playing2(); r.s.detachMissing { it != "e2" }; await { r.states()[1].eventId == null }
        assertEquals(listOf("e1", null), r.states().map { it.eventId }); assertNull(r.states()[1].eventTitle); assertEquals(TileStatus.PLAYING, r.states()[1].status); assertEquals(0, r.d.releasedCount.get())
    }

    // ---- decoders

    @Test fun aDecoderThatCannotBeAllocatedLeavesTheWorkingTilesAndLowersTheLimit() {
        val r = rig("1", "2", "3"); r.d.engineLimit = 2
        r.s.start(listOf(entry("1"), entry("2"), entry("3"))); r.ready(0); r.ready(1)
        await { r.states().size == 3 && r.states()[2].status == TileStatus.NO_DECODER }
        assertEquals("This device cannot play another video at the same time.", r.states()[2].message); assertEquals(MultiviewNotice.NO_DECODER, r.s.state.value.notice)
        assertEquals(2, r.c.usableLimit()); assertEquals(listOf(TileStatus.PLAYING, TileStatus.PLAYING), r.states().take(2).map { it.status })
        r.s.useAtMost(2); await { r.states().size == 2 }; assertNull(r.s.state.value.notice)
    }

    @Test fun anAllocationFailureReportedByThePlayerIsHandledTheSameWay() {
        val r = rig("1", "2"); r.s.start(listOf(entry("1"), entry("2"))); r.ready(0); await { r.d.engines.size == 2 && r.engine(1).loads.isNotEmpty() }
        r.engine(1).emit(TileEvent.Failed(TileFailure.NO_DECODER, true)); await { r.states()[1].status == TileStatus.NO_DECODER }
        assertEquals(1, r.c.usableLimit()); assertTrue(r.engine(1).released); assertFalse(r.engine(0).released); assertTrue(r.reports.any { it.stage == MultiviewStage.ALLOCATION_FAILED })
    }

    @Test fun whenOnlyOneTileIsLeftTheScreenIsToldAndNothingExitsSilently() {
        val r = playing2(); r.s.remove(r.states()[1].id); await { r.states().size == 1 }
        assertEquals(MultiviewNotice.ONE_LEFT, r.s.state.value.notice); assertTrue(r.s.state.value.active); assertEquals(TileStatus.PLAYING, r.states()[0].status)
    }

    // ---- resources

    @Test fun removingATileAndLeavingReleaseTheirPlayersAtOnce() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3"))); r.ready(0); r.ready(1); r.ready(2); await { r.states().all { it.status == TileStatus.PLAYING } }
        r.s.remove(r.states()[1].id); await { r.engine(1).released }; assertEquals(2, r.d.active)
        r.s.stopAll(); await { r.d.active == 0 }; assertTrue(r.states().isEmpty()); assertEquals(0, r.s.engineCount())
    }

    @Test fun aLateCallbackFromAReleasedPlayerChangesNothing() {
        val r = playing2(); val old = r.engine(1); r.s.remove(r.states()[1].id); await { old.released }
        old.emit(TileEvent.Failed(TileFailure.NETWORK, false)); old.emit(TileEvent.Ready); Thread.sleep(60)
        assertEquals(1, r.states().size); assertEquals(TileStatus.PLAYING, r.states()[0].status)
    }

    @Test fun fiftyBuilderAndMultiviewCyclesLeaveNothingBehind() {
        val d = FakeMultiviewDeps(); listOf("1", "2", "3", "4").forEach { d.auth.channels[it] = channel(it) }
        val c = cap(); val s = MultiviewSession(d, c, scope, Dispatchers.IO) {}
        val sel = SportsMultiviewSelection(d, c) { RankInput() }; sel.useEvents { listOf(event("e1", feed("1")), event("e2", feed("2")), event("e3", feed("3")), event("e4", feed("4"))) }
        val rt = Runtime.getRuntime(); System.gc(); val before = rt.totalMemory() - rt.freeMemory(); val t0 = System.nanoTime()
        repeat(50) { i ->
            runBlocking { listOf("e1", "e2", "e3", "e4").forEach { sel.add(it) } }
            s.start(sel.state.value.entries); val base = d.engines.size
            await { d.engines.size == base + 0 || true }
            for (k in 0 until 4) { await { d.engines.size >= (i * 4 + k + 1) && d.engines[i * 4 + k].loads.isNotEmpty() }; d.engines[i * 4 + k].emit(TileEvent.Ready) }
            await { s.state.value.tiles.size == 4 && s.state.value.tiles.all { it.status == TileStatus.PLAYING } }
            s.stopAll(); await { s.state.value.tiles.isEmpty() && d.active == 0 }; sel.clear()
        }
        val ms = (System.nanoTime() - t0) / 1_000_000; System.gc(); val after = rt.totalMemory() - rt.freeMemory()
        println("MULTIVIEW 50 builder+multiview cycles (4 tiles): $ms ms, heap ${before / 1_000_000} MB -> ${after / 1_000_000} MB, engines created ${d.createdCount.get()} released ${d.releasedCount.get()}")
        assertEquals(d.createdCount.get(), d.releasedCount.get()); assertEquals(0, s.engineCount()); assertTrue(sel.state.value.entries.isEmpty())
        assertTrue("retained state grew by ${(after - before) / 1_000_000} MB", after - before < 40_000_000)
    }

    // ---- privacy

    @Test fun diagnosticsCarryOnlyCountsAndFixedWords() {
        val r = rig("1", "2"); r.d.auth.channels["1"] = channel("1", "SECRET Channel"); r.s.start(listOf(entry("1", title = "SECRET FC v SECRET United"), entry("2")))
        r.ready(0); r.ready(1); await { r.states().all { it.status == TileStatus.PLAYING } }
        r.s.listenHere(r.states()[1].id); r.s.replace(r.states()[1].id, entry("1", ev = "x")); Thread.sleep(100)
        val text = r.reports.joinToString("\n") { it.line() }
        assertFalse(text, text.uppercase().contains("SECRET") || text.contains("http") || text.contains("host.example")); assertTrue(r.reports.isNotEmpty())
        val kinds = MultiviewReport::class.java.declaredFields.filter { !it.name.startsWith("$") }.map { it.type }.toSet()
        assertTrue(kinds.toString(), kinds.none { it == String::class.java || List::class.java.isAssignableFrom(it) })
    }

    // ---- measurements

    @Test fun measuredCoordinationTimes() {
        val r = rig("1", "2", "3", "4"); val t0 = System.nanoTime()
        r.s.start((1..4).map { entry("$it") }); r.ready(0); await { r.states().isNotEmpty() && r.states()[0].status == TileStatus.PLAYING }
        val first = (System.nanoTime() - t0) / 1_000_000
        r.ready(1); r.ready(2); r.ready(3); await { r.states().size == 4 && r.states().all { it.status == TileStatus.PLAYING } }
        val full = (System.nanoTime() - t0) / 1_000_000
        var t = System.nanoTime(); r.s.listenHere(r.states()[2].id); await { r.states()[2].audio }; val audio = (System.nanoTime() - t) / 1_000_000
        t = System.nanoTime(); r.s.makePrimary(r.states()[3].id); await { r.states()[0].channelId == "4" }; val primary = (System.nanoTime() - t) / 1_000_000
        t = System.nanoTime(); r.d.auth.channels["5"] = channel("5"); r.s.replace(r.states()[1].id, entry("5")); await { r.engine(0).loads.size == 2 }; r.engine(0).emit(TileEvent.Ready);   // after the primary switch slot 1 holds channel 1, whose player is the first one made
         await { r.states()[1].channelId == "5" && r.states()[1].status == TileStatus.PLAYING }; val replace = (System.nanoTime() - t) / 1_000_000
        println("MULTIVIEW coordination (fake players): first tile $first ms, all four $full ms, audio switch $audio ms, primary switch $primary ms, replace $replace ms, decoders ${r.d.active}")
        assertEquals(4, r.d.active)
    }

    // ---- one implementation behind both Multi-Views

    private fun limited(mem: Int, vararg ids: String): Rig = rig(*ids, capability = cap(facts(mem = mem)))
    private fun settle(r: Rig, n: Int) { for (i in 0 until n) { r.ready(i) } }

    @Test fun theOrdinaryEntryObeysTheTwoThreeAndFourTileLimits() {
        for ((mem, limit) in listOf(160 to 2, 224 to 3, 384 to 4)) {
            val r = limited(mem, "1", "2", "3", "4", "5", "6"); assertEquals(limit, r.c.usableLimit())
            r.s.start(listOf(entry("1")), minimum = 1, owner = "ordinary"); r.ready(0)
            for (k in 2..6) { r.s.add(entry("$k"), "ordinary"); if (k <= limit) r.ready(k - 1) else Thread.sleep(30) }
            await { r.states().size >= minOf(limit, 6) }; Thread.sleep(60)
            assertEquals("limit $limit", limit, r.states().size); assertEquals(limit, r.d.createdCount.get())
            assertEquals("This device can show $limit views at once.", r.s.state.value.message)
        }
    }

    @Test fun theOrdinaryEntryStartsItsTilesOneAfterAnother() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1")), minimum = 1, owner = "o"); r.s.add(entry("2"), "o"); r.s.add(entry("3"), "o")
        await { r.d.engines.size == 1 && r.engine(0).loads.isNotEmpty() }; Thread.sleep(60); assertEquals("the second waits for the first", 1, r.d.createdCount.get())
        r.engine(0).emit(TileEvent.Buffering); await { r.d.engines.size == 2 && r.engine(1).loads.isNotEmpty() }; Thread.sleep(60); assertEquals(2, r.d.createdCount.get())
        r.engine(1).emit(TileEvent.Ready); await { r.d.engines.size == 3 }
        assertEquals("1", r.states()[0].channelId); assertTrue(r.states()[0].audio)
    }

    @Test fun anOversizedPresetIsNeitherStartedNorShortenedAndIsLeftAsItWas() {
        val preset = (1..5).map { entry("$it") }; val before = preset.toList()
        val plan = PresetFit.plan(preset, 3)
        assertEquals(PresetPlan.NeedsChoice(3, preset), plan); assertEquals(before, preset)
        assertEquals(PresetPlan.Ready(preset.take(3)), PresetFit.plan(preset.take(3), 3)); assertEquals(PresetPlan.Empty, PresetFit.plan(emptyList(), 3))
        val r = rig("1", "2", "3", "4", "5"); Thread.sleep(50)
        assertEquals("nothing was made or started for the oversized set", 0, r.d.createdCount.get() + r.d.resolveCalls.get())
        r.s.start(listOf(preset[0], preset[2], preset[4]), minimum = 1, owner = "o")                // the person's choice
        await { r.d.engines.size == 1 }; assertEquals("the set itself is unchanged", before, preset)
    }

    @Test fun oneFailingTileThroughTheOrdinaryEntryKeepsTheOthers() {
        val r = rig("1", "2", "3"); r.s.start(listOf(entry("1")), minimum = 1, owner = "o"); r.s.add(entry("2"), "o"); r.s.add(entry("3"), "o")
        r.ready(0); await { r.d.engines.size == 2 && r.engine(1).loads.isNotEmpty() }
        r.engine(1).emit(TileEvent.Failed(TileFailure.TIMEOUT, false)); r.ready(2)
        await { r.states().size == 3 && r.states()[2].status == TileStatus.PLAYING }
        assertEquals(listOf(TileStatus.PLAYING, TileStatus.FAILED, TileStatus.PLAYING), r.states().map { it.status })
    }

    @Test fun aDecoderFailureLowersTheLimitForEveryLaterAdd() {
        val r = rig("1", "2", "3", "4"); r.d.engineLimit = 2
        r.s.start(listOf(entry("1")), minimum = 1, owner = "o"); r.s.add(entry("2"), "o"); r.s.add(entry("3"), "o")
        r.ready(0); r.ready(1); await { r.states().size == 3 && r.states()[2].status == TileStatus.NO_DECODER }
        assertEquals(2, r.c.usableLimit()); r.s.add(entry("4"), "o"); await { r.s.state.value.message == "This device can show 2 views at once." }
        assertEquals("the working tiles went on", listOf(TileStatus.PLAYING, TileStatus.PLAYING), r.states().take(2).map { it.status })
    }

    @Test fun leavingEitherScreenReleasesEveryPlayer() {
        for (screen in listOf("ordinary", "sports")) {
            val r = rig("1", "2", "3"); r.s.start(listOf(entry("1"), entry("2"), entry("3")), minimum = if (screen == "ordinary") 1 else 2, owner = screen)
            r.ready(0); r.ready(1); r.ready(2); await { r.states().all { it.status == TileStatus.PLAYING } }
            r.s.stopAll(screen); await { r.d.active == 0 && r.states().isEmpty() }
            assertEquals(r.d.createdCount.get(), r.d.releasedCount.get()); assertEquals(0, r.s.engineCount())
        }
    }

    @Test fun theSportsAndOrdinaryScreensNeverRunTogether() {
        val r = rig("1", "2", "3", "4"); r.s.start(listOf(entry("1"), entry("2")), owner = "sports"); r.ready(0); r.ready(1); await { r.states().size == 2 && r.states().all { it.status == TileStatus.PLAYING } }
        r.s.start(listOf(entry("3")), minimum = 1, owner = "ordinary")
        await { r.d.engines.size == 3 && r.states().map { it.channelId } == listOf("3") }
        assertEquals("the first screen's players were released before the second's was made", 2, r.d.releasedCount.get()); assertEquals(1, r.d.active)
        r.s.stopAll("sports"); Thread.sleep(80)
        assertEquals("a screen that left late does not stop the one that took over", listOf("3"), r.states().map { it.channelId }); assertEquals(1, r.d.active)
        assertTrue("never more than the first screen's two players, and one at a time after", r.d.peak.get() <= 2)
        r.s.stopAll("ordinary"); await { r.d.active == 0 }
    }

    @Test fun anOldAndroidVersionIsTreatedConservatively() {
        assertEquals("before Android 6 no instance count is claimed", 0, MultiviewCapability.instancesFor(22, 32)); assertEquals(32, MultiviewCapability.instancesFor(23, 32))
        assertEquals("so an unknown count on a strong device is two", 2, TileLimitPolicy.limit(facts(decoders = listOf(HardwareDecoder("video/avc", false, MultiviewCapability.instancesFor(22, 32))))))
    }

    @Test fun softwareDecodersNeverCountAndTilesNeverAskForSoftwareDecoding() {
        assertFalse(MultiviewCapability.hardwareByName("OMX.google.h264.decoder")); assertFalse(MultiviewCapability.hardwareByName("c2.android.avc.decoder")); assertTrue(MultiviewCapability.hardwareByName("OMX.qcom.video.decoder.avc"))
        assertEquals("a device with only software decoders shows one picture", 1, TileLimitPolicy.limit(facts(decoders = emptyList())))
        val real = java.io.File("src/main/kotlin/app/streamsetu/tv/sports/multiview/RealMultiviewDeps.kt").readText()
        assertTrue(real.contains("softwareDecoding = false")); assertFalse(real.contains("softwareDecoding = true"))
    }

    @Test fun thereIsOneMultiviewImplementationAndNeitherScreenBuildsPlayersItself() {
        val old = java.io.File("src/main/kotlin/app/streamsetu/tv/ui/screens/MultiViewScreen.kt").readText()
        val sports = java.io.File("src/main/kotlin/app/streamsetu/tv/ui/screens/sports/SportsMultiviewScreen.kt").readText()
        for ((name, t) in listOf("ordinary" to old, "sports" to sports)) { assertFalse("$name must not make players", t.contains("ExoEngine(") || t.contains("EngineRequest(")); assertTrue("$name uses the shared session", t.contains("c.sportsMultiview")) }
        assertTrue(old.contains("session.start(") && old.contains("session.add(") && old.contains("session.stopAll(owner)"))
    }

    @Test fun aDeviceThatCanShowOnlyOnePictureHasNoMultiview() {
        val one = rig("1", "2", capability = cap(facts(decoders = emptyList())))
        assertEquals(1, one.c.usableLimit())
        one.s.start(listOf(entry("1"), entry("2")), owner = "o"); await { one.s.state.value.notice == MultiviewNotice.NOT_ENOUGH }
        assertEquals("a Multiview of two is never started", 0, one.d.createdCount.get())
        one.s.add(entry("1"), "o"); one.s.add(entry("2"), "o"); await { one.s.state.value.message == "This device can show 1 view at once." }
        assertEquals("a second picture is refused", 1, one.s.state.value.tiles.size)
    }

    @Test fun thePortraitLayoutsFillTheScreenToo() {
        for (n in 1..4) { val r = MultiviewLayout.rects(n, portrait = true); assertEquals(n, r.size); assertEquals(1f, r.sumOf { (it.w * it.h).toDouble() }.toFloat(), 0.001f) }
        val two = MultiviewLayout.rects(2, true); assertEquals(1, MultiviewNav.move(two, 0, Dir.DOWN)); assertEquals(0, MultiviewNav.move(two, 1, Dir.UP)); assertNull(MultiviewNav.move(two, 0, Dir.RIGHT))
    }
}
