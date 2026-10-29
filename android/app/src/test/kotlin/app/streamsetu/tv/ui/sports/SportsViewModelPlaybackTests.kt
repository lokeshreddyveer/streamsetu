package app.streamsetu.tv.ui.sports

import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.sports.*
import app.streamsetu.tv.ui.screens.sports.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class SportsViewModelPlaybackTests {
    private val h = 3_600_000L
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    @After fun stop() { scope.cancel() }
    private fun d0() = 1_800_000_000_000L + 2 * h
    private fun feed(id: String, q: String? = null) = SportsFeed(id, "A", "Channel $id", null, MetadataSource.UNKNOWN, q, if (q != null) MetadataSource.PARSED_FROM_NAME else MetadataSource.UNKNOWN, null, id, 0L, false)
    private val ev get() = SportsEvent("e", Sport.FOOTBALL, SportsEventKind.HEAD_TO_HEAD, "League", listOf("X", "Y"), null, "Event e", d0() + h, d0() + 3 * h, listOf(feed("sd", "SD"), feed("fhd", "FHD")), 0.95, setOf("A"), "r")

    private class Rig(val sd: FakeSportsDeps, val pd: FakePlaybackDeps, val vm: SportsViewModel)
    private fun rig(): Rig {
        val sd = FakeSportsDeps().also { it.result = { listOf(ev) } }; val pd = FakePlaybackDeps()
        listOf("sd", "fhd").forEach { pd.channels[it] = Channel(it, "A", "cat", "Channel $it", null, null, "ref", null) }
        sd.tick()
        val c = SportsPlaybackCoordinator(pd, scope, SportsPlaybackDiagnostics {})
        return Rig(sd, pd, SportsViewModel(sd, scope, 40L, SportsDiagnostics.Log, c))
    }
    private suspend fun SportsViewModel.until(p: (SportsHubUiState) -> Boolean) = withTimeout(5_000) { uiState.first(p) }

    @Test fun theDetailListsFeedsBestFirstAndTheBadgeNamesTheOneWatchBestFeedPlays() = runBlocking {
        val r = rig(); r.vm.until { !it.loading }
        r.vm.openDetail("e")
        val d = r.vm.until { it.detail != null }.detail!!
        assertEquals(listOf("fhd", "sd"), d.feeds.map { it.channelId }); assertEquals(listOf(true, false), d.feeds.map { it.recommended })
        assertEquals("Best available · FHD", d.bestLabel)
        assertTrue("opening the event plays nothing", r.pd.played.isEmpty())
        r.vm.watchBest(); withTimeout(5_000) { while (r.pd.played.isEmpty()) delay(5) }
        assertEquals("fhd", r.pd.played.single().id)
    }

    @Test fun aProfileSwitchStopsWhatSportsStartedAndClearsTheContent() = runBlocking {
        val r = rig(); r.vm.until { !it.loading }
        r.vm.openDetail("e"); r.vm.watchBest(); withTimeout(5_000) { while (r.pd.played.isEmpty()) delay(5) }
        r.pd.profile = "kid"; r.sd.scopeFlow.value = r.sd.scopeFlow.value.copy(profileId = "kid")
        withTimeout(5_000) { while (r.pd.stops.get() == 0) delay(5) }
        assertNull(r.vm.until { it.detail == null }.detail)
    }

    @Test fun anUnrelatedSecurityChangeClearsTheContentButLeavesAnAllowedStreamPlaying() = runBlocking {
        val r = rig(); r.vm.until { !it.loading }
        r.vm.openDetail("e"); r.vm.watchBest(); withTimeout(5_000) { while (r.pd.played.isEmpty()) delay(5) }
        r.sd.scopeFlow.value = r.sd.scopeFlow.value.copy(hiddenChannelIds = setOf("some-other-channel"))
        assertNull(r.vm.until { it.detail == null }.detail)
        assertTrue("Sports gives the stream to Live TV's embedded player", r.vm.until { it.playbackHandoff }.playbackHandoff)
        assertEquals(0, r.pd.stops.get())
    }

    @Test fun closingTheEventReleasesTheStream() = runBlocking {
        val r = rig(); r.vm.until { !it.loading }
        r.vm.openDetail("e"); r.vm.watchBest(); withTimeout(5_000) { while (r.pd.played.isEmpty()) delay(5) }
        r.vm.closeDetail(); assertEquals(1, r.pd.stops.get())
    }
}
