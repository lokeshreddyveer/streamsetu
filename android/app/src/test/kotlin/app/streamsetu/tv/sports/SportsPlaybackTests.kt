package app.streamsetu.tv.sports

import app.streamsetu.core.model.Channel
import app.streamsetu.tv.PlayStart
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Scripted application services that record every call, so a test can prove what did and did not happen. */
class FakePlaybackDeps : SportsPlaybackDeps {
    @Volatile var profile = "main"
    @Volatile var active: Set<String> = setOf("A")
    val channels = ConcurrentHashMap<String, Channel>()
    val disabledSources = java.util.Collections.synchronizedSet(HashSet<String>())
    val lockedCategories = java.util.Collections.synchronizedSet(HashSet<String>())
    val adultCategories = java.util.Collections.synchronizedSet(HashSet<String>())
    @Volatile var adultFilter = false
    val hiddenChannels = java.util.Collections.synchronizedSet(HashSet<String>())
    val played = java.util.Collections.synchronizedList(ArrayList<Channel>())
    val stops = AtomicInteger(); val lookups = AtomicInteger()
    @Volatile var gate: CompletableDeferred<Unit>? = null
    @Volatile var onLookup: (() -> Unit)? = null
    /** How the next play requests end. When [manualResults] is set a request waits until [complete] is called, so a test can finish them in any order. */
    @Volatile var result: PlayStart = PlayStart.STARTED
    @Volatile var manualResults = false
    val waiting = java.util.Collections.synchronizedList(ArrayList<(PlayStart) -> Unit>())
    @Volatile var decodes4K = true
    @Volatile var time = 1_000_000L
    val phases = MutableSharedFlow<PlaybackPhase>(extraBufferCapacity = 64)

    override val profileId get() = profile
    override val activeSourceIds get() = active
    override suspend fun channel(id: String): Channel? { lookups.incrementAndGet(); onLookup?.invoke(); gate?.await(); return channels[id] }
    override suspend fun sourceEnabled(sourceId: String) = sourceId !in disabledSources
    override suspend fun folderLocked(categoryId: String?) = categoryId != null && categoryId in lockedCategories
    override suspend fun adultBlocked(categoryId: String?) = adultFilter && categoryId != null && categoryId in adultCategories
    override suspend fun hidden(channelId: String) = channelId in hiddenChannels
    override suspend fun sourceNames() = mapOf("A" to "Playlist A", "B" to "Playlist B")
    override fun play(channel: Channel, onResult: (PlayStart) -> Unit) { played.add(channel); if (manualResults) waiting.add(onResult) else onResult(result) }
    override fun stop() { stops.incrementAndGet() }
    override val phase: Flow<PlaybackPhase> get() = phases
    override fun nowMs(): Long { time += 7; return time }
    override fun baseRank() = RankInput(preferredLanguage = null, preferredSourceIds = listOf("A", "B"), deviceDecodes4K = decodes4K)
}

class SportsPlaybackTests {
    private val job = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.Default + job)
    @After fun stop() { scope.cancel() }

    class Reports : SportsPlaybackDiagnostics { val all = java.util.Collections.synchronizedList(ArrayList<SportsPlaybackReport>()); override fun record(report: SportsPlaybackReport) { all.add(report) } }

    private fun channel(id: String, name: String = "Channel $id", source: String = "A", cat: String? = "cat") = Channel(id, source, cat, name, null, null, "http://user:SECRET@host.example/$id.ts", null)
    private fun feed(id: String, source: String = "A", q: String? = null, qSrc: MetadataSource = MetadataSource.UNKNOWN, name: String = "Channel $id") =
        SportsFeed(id, source, name, null, MetadataSource.UNKNOWN, q, qSrc, null, id, 0L, false)
    private fun event(id: String, vararg feeds: SportsFeed, title: String = "Event $id") =
        SportsEvent(id, Sport.FOOTBALL, SportsEventKind.HEAD_TO_HEAD, "League", listOf("X", "Y"), null, title, 1000L, 2000L, feeds.toList(), 0.95, setOf("A"), "r")

    private class Rig(val deps: FakePlaybackDeps, val c: SportsPlaybackCoordinator, val reports: Reports, val ev: SportsEvent)
    private fun rig(vararg feeds: SportsFeed, title: String = "Event e"): Rig {
        val d = FakePlaybackDeps(); feeds.forEach { d.channels[it.channelId] = channel(it.channelId, it.channelName, it.sourceId) }
        val r = Reports(); val c = SportsPlaybackCoordinator(d, scope, r); val ev = event("e", *feeds, title = title)
        c.useEvents { id -> ev.takeIf { it.id == id } }
        return Rig(d, c, r, ev)
    }
    private fun await(timeout: Long = 5_000, p: () -> Boolean) = runBlocking { withTimeout(timeout) { while (!p()) delay(5) } }
    private fun Rig.phase(id: String?, kind: PhaseKind, failure: PlayFailure? = null) = runBlocking { withTimeout(5_000) { while (deps.phases.subscriptionCount.value == 0) delay(2) }; deps.phases.emit(PlaybackPhase(id, kind, failure)) }
    private fun Rig.startPlaying(id: String) { phase(id, PhaseKind.LOADING); phase(id, PhaseKind.PLAYING); await { c.state.value.status == SportsPlayStatus.PLAYING } }

    // ---- playback integration

    @Test fun watchBestFeedPlaysTheRankedChannelThroughTheLivePlayAction() {
        val r = rig(feed("sd", q = "SD", qSrc = MetadataSource.PARSED_FROM_NAME), feed("fhd", q = "FHD", qSrc = MetadataSource.PARSED_FROM_NAME))
        r.c.watch("e"); await { r.deps.played.size == 1 }
        assertEquals("fhd", r.deps.played.single().id)
        assertEquals(SportsPlayStatus.STARTING, r.c.state.value.status); assertEquals("e", r.c.state.value.origin?.eventId)
        assertEquals("the recommendation badge and the button use the same ranking", "fhd", r.c.recommendedFor("e").first.first().feed.channelId)
    }

    @Test fun okOnAFeedPlaysThatExactChannel() {
        val r = rig(feed("a", q = "FHD", qSrc = MetadataSource.PARSED_FROM_NAME), feed("b"))
        r.c.watchFeed("e", "b"); await { r.deps.played.size == 1 }
        assertEquals("b", r.deps.played.single().id)
    }

    @Test fun rankingAndFocusPerformNoLookupAndStartNothing() {
        val r = rig(feed("a"), feed("b"))
        r.c.recommendedFor("e"); r.c.rankInput("e"); r.c.refreshOptions()
        assertEquals("ranking reads memory only", 0, r.deps.lookups.get()); assertTrue(r.deps.played.isEmpty()); assertEquals(0, r.deps.stops.get())
        assertNull(r.c.state.value.origin)
    }

    @Test fun aRejectedRequestLeavesTheEventAloneAndNothingPlays() {
        val r = rig(feed("a")); r.deps.channels.clear()
        r.c.watch("e"); await { r.c.state.value.message != null }
        assertTrue(r.deps.played.isEmpty()); assertNull(r.c.state.value.origin); assertEquals("That feed is not available.", r.c.state.value.message)
    }

    @Test fun aFailureOffersChoicesButNeverSwitchesByItself() {
        val r = rig(feed("a", q = "FHD", qSrc = MetadataSource.PARSED_FROM_NAME), feed("b"))
        r.c.watch("e"); await { r.deps.played.size == 1 }
        r.phase("a", PhaseKind.LOADING); r.phase("a", PhaseKind.FAILED, PlayFailure.TIMEOUT)
        await { r.c.state.value.status == SportsPlayStatus.FAILED }
        val s = r.c.state.value
        assertEquals("This feed could not be played.", s.message); assertEquals("b", s.suggestedChannelId)
        Thread.sleep(150)
        assertEquals("the next best feed is suggested, not played", 1, r.deps.played.size)
    }

    @Test fun liveTvsOwnRecoveryRunsFirstAndItsSuccessIsAccepted() {
        val r = rig(feed("a"), feed("b"))
        r.c.watch("e"); await { r.deps.played.size == 1 }
        r.phase("a", PhaseKind.LOADING); r.phase("a-copy-on-another-playlist", PhaseKind.LOADING); r.phase("a-copy-on-another-playlist", PhaseKind.PLAYING)
        await { r.c.state.value.status == SportsPlayStatus.PLAYING }
        assertEquals("a", r.c.state.value.origin?.channelId); assertEquals(1, r.deps.played.size); assertNull(r.c.state.value.message)
    }

    @Test fun aViewingLimitOrAFolderThePlayActionRefusesClearsStartingAtOnce() {
        val r = rig(feed("a")); r.deps.result = PlayStart.REJECTED
        r.c.watch("e"); await { r.deps.played.size == 1 }
        await { r.c.state.value.status == SportsPlayStatus.IDLE && r.c.state.value.message != null }
        assertNull(r.c.state.value.origin); assertEquals("That feed is not available.", r.c.state.value.message)
        assertTrue(r.reports.all.toTypedArray().any { it.stage == SportsPlayStage.REJECTED && it.rejection == PlayRejection.PLAYER_REFUSED })
    }

    // ---- authorization at the moment of the request

    private fun refused(why: PlayRejection, change: (Rig) -> Unit) {
        val r = rig(feed("a")); change(r)
        r.c.watchFeed("e", "a"); await { r.reports.all.toTypedArray().any { it.stage == SportsPlayStage.REJECTED } }
        assertTrue("nothing may play: $why", r.deps.played.isEmpty()); assertNull(r.c.state.value.origin)
        assertEquals(why, r.reports.all.first { it.stage == SportsPlayStage.REJECTED }.rejection)
        assertEquals("That feed is not available.", r.c.state.value.message)
    }
    @Test fun aChannelRemovedBeforeTheTapIsRefused() = refused(PlayRejection.CHANNEL_MISSING) { it.deps.channels.clear() }
    @Test fun aDisabledSourceBeforeTheTapIsRefused() = refused(PlayRejection.SOURCE_OFF) { it.deps.disabledSources.add("A") }
    @Test fun aChangedLibraryBeforeTheTapIsRefused() = refused(PlayRejection.NOT_IN_LIBRARY) { it.deps.active = setOf("Z") }
    @Test fun aRelockedFolderBeforeTheTapIsRefused() = refused(PlayRejection.FOLDER_LOCKED) { it.deps.lockedCategories.add("cat") }
    @Test fun aChangedAdultOrKidsRestrictionBeforeTheTapIsRefused() = refused(PlayRejection.RESTRICTED) { it.deps.adultCategories.add("cat"); it.deps.adultFilter = true }
    @Test fun aHiddenChannelBeforeTheTapIsRefused() = refused(PlayRejection.HIDDEN) { it.deps.hiddenChannels.add("a") }

    @Test fun aFeedThatIsNotPartOfTheEventIsRefused() {
        val r = rig(feed("a")); r.deps.channels["other"] = channel("other")
        r.c.watchFeed("e", "other"); await { r.reports.all.toTypedArray().any { it.stage == SportsPlayStage.REJECTED } }
        assertTrue(r.deps.played.isEmpty())
    }

    @Test fun anEventThatNoLongerExistsIsRefused() {
        val r = rig(feed("a")); r.c.useEvents { null }
        r.c.watch("e"); await { r.reports.all.toTypedArray().any { it.rejection == PlayRejection.EVENT_GONE } }
        assertTrue(r.deps.played.isEmpty())
    }

    @Test fun aProfileChangedWhileTheChecksRunIsRefused() {
        val r = rig(feed("a")); r.deps.onLookup = { r.deps.profile = "kid" }
        r.c.watchFeed("e", "a"); await { r.reports.all.toTypedArray().any { it.stage == SportsPlayStage.REJECTED } }
        assertTrue(r.deps.played.isEmpty()); assertEquals(PlayRejection.PROFILE_CHANGED, r.reports.all.first { it.stage == SportsPlayStage.REJECTED }.rejection)
    }

    @Test fun aRequestOvertakenByASecurityChangeIsDropped() {
        val r = rig(feed("a")); r.deps.gate = CompletableDeferred()
        r.c.watchFeed("e", "a"); await { r.deps.lookups.get() >= 1 }
        r.c.invalidate(); r.deps.gate!!.complete(Unit)
        Thread.sleep(150)
        assertTrue("the old request must not start anything", r.deps.played.isEmpty()); assertNull(r.c.state.value.origin)
    }

    // ---- feed switching

    @Test fun switchingKeepsThePlayerAndKeepsTheOldFeedSelectedUntilTheNewOneIsPlaying() {
        val r = rig(feed("a", q = "FHD", qSrc = MetadataSource.PARSED_FROM_NAME), feed("b"))
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        assertTrue(r.c.state.value.canSwitch())
        r.c.switchTo("b"); await { r.deps.played.size == 2 }
        assertEquals("b", r.deps.played.last().id); assertEquals(0, r.deps.stops.get())
        r.phase("a", PhaseKind.PLAYING)                                                       // Live TV still shows the old stream for a moment
        Thread.sleep(100)
        assertEquals("a", r.c.state.value.origin?.channelId); assertEquals(SportsPlayStatus.STARTING, r.c.state.value.status)
        r.phase("b", PhaseKind.LOADING); r.phase("b", PhaseKind.PLAYING)
        await { r.c.state.value.status == SportsPlayStatus.PLAYING }
        assertEquals("b", r.c.state.value.origin?.channelId); assertTrue(r.c.state.value.options.single { it.channelId == "b" }.current)
        assertEquals("the stream was never stopped to switch", 0, r.deps.stops.get())
    }

    @Test fun aPlayingFeedThatBecomesRestrictedIsLetGoAndTheListIsEmptied() {
        val r = rig(feed("a"), feed("b"), feed("c"))
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        assertEquals(3, r.c.state.value.options.size)
        r.deps.lockedCategories.add("cat")                                                   // the folder relocks: all three channels are in it
        r.c.refreshOptions(); await { r.deps.stops.get() == 1 }
        assertNull(r.c.state.value.origin); assertTrue("no restricted row is kept", r.c.state.value.options.isEmpty())
    }

    @Test fun aHiddenAlternateFeedDisappearsAndTheSwitchActionGoes() {
        val r = rig(feed("a"), feed("b"))
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        r.deps.hiddenChannels.add("b"); r.c.refreshOptions(); await { r.c.state.value.options.size == 1 }
        assertFalse("one allowed feed: no Feeds action", r.c.state.value.canSwitch()); assertEquals(listOf("a"), r.c.state.value.options.map { it.channelId })
    }

    @Test fun aSwitchFromBeforeAProfileOrLibraryChangeIsCancelled() {
        val r = rig(feed("a"), feed("b"))
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        r.deps.gate = CompletableDeferred(); r.c.switchTo("b"); await { r.deps.lookups.get() >= 3 }
        r.c.invalidate(); r.deps.gate!!.complete(Unit); Thread.sleep(150)
        assertEquals("only the first feed was ever started", 1, r.deps.played.size)
        assertTrue("the feed list is empty until the events are rebuilt", r.c.state.value.options.isEmpty())
    }

    @Test fun oneFeedHasNoFeedsActionAndSeveralDo() {
        val one = rig(feed("a")); one.c.watch("e"); await { one.deps.played.size == 1 }
        assertFalse(one.c.state.value.canSwitch())
        val many = rig(feed("a"), feed("b")); many.c.watch("e"); await { many.deps.played.size == 1 }
        assertTrue(many.c.state.value.canSwitch())
    }

    @Test fun theFeedThatPlayedAndTheFeedYouChoseAreRememberedForThisEventUntilTheSituationChanges() {
        val r = rig(feed("a", q = "FHD", qSrc = MetadataSource.PARSED_FROM_NAME), feed("b"))
        r.c.watchFeed("e", "b"); await { r.deps.played.size == 1 }; r.startPlaying("b")
        assertEquals("b", r.c.recommendedFor("e").first.first().feed.channelId)
        r.c.invalidate()
        assertEquals("a", r.c.recommendedFor("e").first.first().feed.channelId)
    }

    @Test fun endingStopsWhatSportsStartedAndOnlyThat() {
        val r = rig(feed("a")); r.c.end(); assertEquals("nothing of Sports was playing", 0, r.deps.stops.get())
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.c.end(); assertEquals(1, r.deps.stops.get()); assertNull(r.c.state.value.origin)
    }

    // ---- privacy and the network path

    @Test fun diagnosticsAndTheOriginCarryNoNamesAddressesOrCredentials() {
        val r = rig(feed("a", name = "SECRET Channel A"), feed("b", name = "SECRET Channel B"), title = "SECRET FC v SECRET United")
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        r.c.switchTo("b"); await { r.deps.played.size == 2 }; r.phase("b", PhaseKind.LOADING); r.phase("b", PhaseKind.FAILED, PlayFailure.NETWORK)
        await { r.deps.played.size == 3 }; r.phase("a", PhaseKind.LOADING); r.phase("a", PhaseKind.FAILED, PlayFailure.NETWORK)
        await { r.c.state.value.status == SportsPlayStatus.FAILED }
        val text = r.reports.all.joinToString("\n") { it.line() } + "\n" + r.c.state.value.origin.toString()
        assertFalse(text, text.uppercase().contains("SECRET") || text.contains("http") || text.contains("host.example"))
        assertTrue(r.reports.all.isNotEmpty())
        val kinds = SportsPlaybackReport::class.java.declaredFields.filter { !it.name.startsWith("$") }.map { it.type }.toSet()
        assertTrue(kinds.toString(), kinds.none { it == String::class.java || List::class.java.isAssignableFrom(it) })
        assertEquals("the origin holds identifiers only", setOf("eventId", "channelId", "generation"), SportsOrigin::class.java.declaredFields.map { it.name }.filter { !it.startsWith("$") }.toSet())
    }

    @Test fun sportsHasNoNetworkPathOfItsOwn() {
        val roots = listOf("src/main/kotlin/app/streamsetu/tv/sports", "src/main/kotlin/app/streamsetu/tv/ui/screens/sports")
        val files = roots.flatMap { java.io.File(it).walkTopDown().filter { f -> f.extension == "kt" }.toList() }
        val sports = files.filter { it.name.startsWith("Sports") && it.name != "SportsAdapter.kt" || it.name == "RealSportsPlaybackDeps.kt" }
        assertTrue(sports.size >= 8)
        // The guide-reading adapter and the event service read the database only; the playback and screens may not touch the network or build a stream request at all.
        val forbidden = listOf("OkHttp", "StreamResolver", "HttpURLConnection", "java.net.URL", "Request.Builder", "streamRef", "http://", "https://", "Dns", "Proxy", "\"Authorization\"", "Authenticator")          // the header name as a string, not the name of the permission-check interface
        for (f in sports) { val t = f.readText(); for (w in forbidden) assertFalse("${f.name} must not contain $w", t.contains(w)) }
        val real = java.io.File("src/main/kotlin/app/streamsetu/tv/sports/RealSportsPlaybackDeps.kt").readText()
        assertTrue("Sports starts a stream with the application's play action, the one Live TV uses", real.contains("c.play(item, listOf(item), onResult = onResult)"))
        val live = java.io.File("src/main/kotlin/app/streamsetu/tv/ui/screens/live/LiveScreen.kt").readText()
        assertTrue("and Live TV's own channel choice calls that same action", live.contains("c.play(ChannelPlayable(ch)"))
    }

    // ---- performance

    @Test fun fiftyFeedSelectorRefreshesAreQuickAndRapidRequestsLeaveOnlyTheLastOne() {
        val r = rig(feed("a"), feed("b"), feed("c"))
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        val t0 = System.nanoTime()
        repeat(50) { val before = r.deps.lookups.get(); r.c.refreshOptions(); await { r.deps.lookups.get() >= before + 3 } }
        val ms = (System.nanoTime() - t0) / 1_000_000
        println("SPORTS feed selector refresh x50: $ms ms")
        assertTrue("$ms ms", ms < 5_000)
        r.deps.gate = CompletableDeferred()
        repeat(20) { r.c.switchTo(if (it % 2 == 0) "b" else "c") }                      // a burst of presses while a request is pending
        r.deps.gate!!.complete(Unit)
        await { r.deps.played.size >= 2 }; Thread.sleep(150)
        assertEquals("only the last request started a stream", 2, r.deps.played.size); assertEquals("c", r.deps.played.last().id)
    }

    // ---- rollback: a failed switch restores the stream the person was watching

    private fun playingAThenSwitchingToB(): Rig {
        val r = rig(feed("a", q = "FHD", qSrc = MetadataSource.PARSED_FROM_NAME), feed("b"), feed("c"))
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        r.c.switchTo("b"); await { r.deps.played.size == 2 }
        return r
    }

    @Test fun aFailedSwitchStartsThePreviousFeedAgainThroughTheSamePlayAction() {
        val r = playingAThenSwitchingToB()
        r.phase("b", PhaseKind.LOADING); r.phase("b", PhaseKind.FAILED, PlayFailure.REFUSED)
        await { r.deps.played.size == 3 }
        assertEquals(listOf("a", "b", "a"), r.deps.played.map { it.id })
        r.phase("a", PhaseKind.LOADING); r.phase("a", PhaseKind.PLAYING)
        await { r.c.state.value.status == SportsPlayStatus.PLAYING }
        val s = r.c.state.value
        assertEquals("Could not switch. Returned to the previous feed.", s.message); assertEquals("a", s.origin?.channelId); assertTrue(s.options.single { it.channelId == "a" }.current)
        assertEquals("restoring is not switching to an alternate: the third feed was never started", 3, r.deps.played.size); assertEquals(0, r.deps.stops.get())
        assertTrue(r.reports.all.toTypedArray().any { it.mode == SportsPlayMode.RESTORE && it.stage == SportsPlayStage.PLAYING })
    }

    @Test fun ifTheRestorationAlsoFailsTheNormalFailureStateShows() {
        val r = playingAThenSwitchingToB()
        r.phase("b", PhaseKind.LOADING); r.phase("b", PhaseKind.FAILED); await { r.deps.played.size == 3 }
        r.phase("a", PhaseKind.LOADING); r.phase("a", PhaseKind.FAILED, PlayFailure.TIMEOUT)
        await { r.c.state.value.status == SportsPlayStatus.FAILED }
        assertEquals("This feed could not be played.", r.c.state.value.message); Thread.sleep(150)
        assertEquals("no further attempt without a choice", 3, r.deps.played.size)
    }

    @Test fun ifThePlayActionRefusesTheRestorationTheNormalFailureStateShows() {
        val r = playingAThenSwitchingToB()
        r.deps.result = PlayStart.REJECTED
        r.phase("b", PhaseKind.LOADING); r.phase("b", PhaseKind.FAILED)
        await { r.c.state.value.status == SportsPlayStatus.FAILED && r.deps.played.size == 3 }
        assertEquals("This feed could not be played.", r.c.state.value.message)
    }

    @Test fun aPreviousFeedThatIsNoLongerAllowedIsNotRestored() {
        val r = playingAThenSwitchingToB()
        r.deps.hiddenChannels.add("a")
        r.phase("b", PhaseKind.LOADING); r.phase("b", PhaseKind.FAILED)
        await { r.c.state.value.status == SportsPlayStatus.FAILED }
        Thread.sleep(100); assertEquals(2, r.deps.played.size); assertEquals("This feed could not be played.", r.c.state.value.message)
    }

    @Test fun aFirstStartThatFailsHasNothingToRestore() {
        val r = rig(feed("a"), feed("b"))
        r.c.watch("e"); await { r.deps.played.size == 1 }
        r.phase("a", PhaseKind.LOADING); r.phase("a", PhaseKind.FAILED)
        await { r.c.state.value.status == SportsPlayStatus.FAILED }; Thread.sleep(100)
        assertEquals(1, r.deps.played.size)
    }

    @Test fun aSwitchThePlayActionRefusesLeavesTheOldStreamPlayingWithNoRestoration() {
        val r = rig(feed("a", q = "FHD", qSrc = MetadataSource.PARSED_FROM_NAME), feed("b"))
        r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        r.deps.result = PlayStart.REJECTED
        r.c.switchTo("b"); await { r.c.state.value.message == "That feed is not available." }
        val s = r.c.state.value
        assertEquals(SportsPlayStatus.PLAYING, s.status); assertEquals("a", s.origin?.channelId); assertEquals(0, r.deps.stops.get())
        Thread.sleep(100); assertEquals("nothing was replaced, so nothing was restarted", 2, r.deps.played.size)
    }

    // ---- request completion: "Starting…" always ends

    @Test fun aRequestTheNewerOneOvertookReportsNothingThatChangesTheState() {
        val r = rig(feed("a"), feed("b")); r.deps.manualResults = true
        r.c.watchFeed("e", "a"); await { r.deps.waiting.size == 1 }
        r.c.watchFeed("e", "b"); await { r.deps.waiting.size == 2 }
        r.deps.waiting[0](PlayStart.SUPERSEDED)                                               // the older one reports late
        Thread.sleep(50)
        assertEquals(SportsPlayStatus.STARTING, r.c.state.value.status); assertEquals("b", r.c.state.value.attemptedChannelId)
        r.deps.waiting[1](PlayStart.REJECTED)
        await { r.c.state.value.status == SportsPlayStatus.IDLE }
    }

    @Test fun anOlderCompletionNeverOverwritesANewerRequest() {
        val r = rig(feed("a"), feed("b")); r.deps.manualResults = true
        r.c.watchFeed("e", "a"); await { r.deps.waiting.size == 1 }
        r.c.watchFeed("e", "b"); await { r.deps.waiting.size == 2 }
        r.deps.waiting[1](PlayStart.STARTED); r.deps.waiting[0](PlayStart.REJECTED)
        Thread.sleep(50)
        assertEquals("the older refusal must not clear the newer start", SportsPlayStatus.STARTING, r.c.state.value.status); assertEquals("b", r.c.state.value.attemptedChannelId)
        assertNotNull(r.c.state.value.origin)
    }

    @Test fun anotherCallerTakingThePlayerEndsTheSportsClaimWithoutStoppingIt() {
        val r = rig(feed("a")); r.deps.result = PlayStart.SUPERSEDED
        r.c.watch("e"); await { r.deps.played.size == 1 }
        await { r.c.state.value.origin == null }
        assertEquals(SportsPlayStatus.IDLE, r.c.state.value.status); assertEquals("Sports does not stop a stream it no longer owns", 0, r.deps.stops.get())
    }

    @Test fun rapidRepeatedRequestsAlwaysEndAndOnlyTheLastCounts() {
        val r = rig(feed("a"), feed("b")); r.deps.manualResults = true
        repeat(30) { r.c.watchFeed("e", if (it % 2 == 0) "a" else "b"); Thread.sleep(2) }
        await { r.deps.waiting.isNotEmpty() }; Thread.sleep(150)
        val all = r.deps.waiting.toList()
        all.dropLast(1).shuffled().forEach { it(if (java.util.Random().nextBoolean()) PlayStart.REJECTED else PlayStart.SUPERSEDED) }
        Thread.sleep(50)
        assertEquals("older reports changed nothing", SportsPlayStatus.STARTING, r.c.state.value.status)
        assertEquals("b", r.c.state.value.attemptedChannelId)
        all.last()(PlayStart.REJECTED)
        await { r.c.state.value.status == SportsPlayStatus.IDLE }                                // the last report always ends "Starting…"
    }

    @Test fun aRequestSupersededByAnEarlierCancelledOneStillTerminates() {
        val r = rig(feed("a")); r.deps.gate = CompletableDeferred()
        r.c.watchFeed("e", "a"); await { r.deps.lookups.get() >= 1 }
        r.c.watchFeed("e", "a")                                                              // the first request is cancelled while it checks
        r.deps.gate!!.complete(Unit); r.deps.manualResults = false
        await { r.deps.played.size >= 1 }; r.phase("a", PhaseKind.LOADING); r.phase("a", PhaseKind.PLAYING)
        await { r.c.state.value.status == SportsPlayStatus.PLAYING }
        assertEquals("one stream, one start", 1, r.deps.played.size)
    }

    // ---- guide changes do not stop an allowed channel

    @Test fun anEventThatVanishesFromTheGuideKeepsTheAllowedChannelPlayingAndIsLetGoOf() {
        val r = rig(feed("a"), feed("b")); r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        r.c.useEvents { null }; r.c.refreshOptions()
        await { r.c.state.value.held != null }
        assertNull(r.c.state.value.origin); assertEquals(SportsHeld("a", "Channel a"), r.c.state.value.held); assertFalse("Sports keeps its embedded player first", r.c.state.value.handoff)
        assertEquals("the stream was not stopped", 0, r.deps.stops.get()); assertEquals("and nothing was started again", 1, r.deps.played.size)
        r.c.handOff(); assertTrue(r.c.state.value.handoff)
        assertTrue(r.c.consumeHandoff()); assertFalse("only once", r.c.consumeHandoff())
        assertEquals("handing over neither stops nor restarts", Pair(0, 1), Pair(r.deps.stops.get(), r.deps.played.size))
        r.c.end(); assertEquals("nothing is left for Sports to stop", 0, r.deps.stops.get())
    }

    @Test fun anEventWhoseIdentityChangedAndNoLongerListsThePlayingChannelKeepsItPlaying() {
        val r = rig(feed("a"), feed("b")); r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        val renamed = event("e-new", feed("b"))
        r.deps.channels["b"] = channel("b"); r.c.useEvents { renamed.takeIf { _ -> true } }
        r.c.refreshOptions(); await { r.c.state.value.held != null }
        assertEquals(0, r.deps.stops.get()); assertEquals(1, r.deps.played.size)
    }

    private fun stopsWhen(change: (Rig) -> Unit) {
        val r = rig(feed("a"), feed("b")); r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        change(r); r.c.refreshOptions()
        await { r.deps.stops.get() == 1 }; assertNull(r.c.state.value.origin); assertNull(r.c.state.value.held)
    }
    @Test fun aHiddenChannelStopsIt() = stopsWhen { it.deps.hiddenChannels.add("a") }
    @Test fun aRelockedFolderStopsIt() = stopsWhen { it.deps.lockedCategories.add("cat") }
    @Test fun aDisabledSourceStopsIt() = stopsWhen { it.deps.disabledSources.add("A") }
    @Test fun aRemovedSourceOrChannelStopsIt() = stopsWhen { it.deps.channels.remove("a") }
    @Test fun anActiveLibraryThatNoLongerHasItStopsIt() = stopsWhen { it.deps.active = setOf("Z") }
    @Test fun anAdultFilterThatNowCoversItStopsIt() = stopsWhen { it.deps.adultCategories.add("cat"); it.deps.adultFilter = true }

    @Test fun aProfileSwitchStopsItAndAnUnrelatedSecurityChangeDoesNot() {
        val r = rig(feed("a"), feed("b")); r.c.watch("e"); await { r.deps.played.size == 1 }; r.startPlaying("a")
        r.c.invalidate(); r.c.revalidate()                                                   // e.g. a hidden channel elsewhere: the profile and the playing channel are unchanged
        await { r.c.state.value.handoff }; assertNotNull(r.c.state.value.held); assertEquals("cleared content: handed straight to Live TV", 0, r.deps.stops.get())
        val q = rig(feed("a"), feed("b")); q.c.watch("e"); await { q.deps.played.size == 1 }; q.startPlaying("a")
        q.deps.profile = "kid"; q.c.invalidate(); q.c.revalidate()
        await { q.deps.stops.get() == 1 }; assertNull(q.c.state.value.origin)
    }
}
