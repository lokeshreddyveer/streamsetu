package app.streamsetu.tv.sports.recording

import app.streamsetu.core.model.Channel
import app.streamsetu.core.net.RecordableFormat
import app.streamsetu.tv.record.*
import app.streamsetu.tv.sports.FakePlaybackDeps
import app.streamsetu.tv.sports.SportsAuthorization
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class FakeGateDeps(val auth: FakePlaybackDeps = FakePlaybackDeps()) : GateDeps, SportsAuthorization by auth {
    override val profileId: String get() = auth.profile
    val formats = HashMap<String, RecordableFormat>(); override fun format(channel: Channel) = formats[channel.id] ?: RecordableFormat.TS
    val maxima = HashMap<String, Int>(); override fun providerMax(sourceId: String) = maxima[sourceId] ?: 0
    var running: List<ScheduledRec> = emptyList(); override fun activeRecordings(excluding: String) = running.filter { it.id != excluding }
    var playing: List<String> = emptyList(); override fun playingSources() = playing
    override val storage = FakeProbe()
    var sportsAnswer: RecordingFailure? = null; var sportsCalls = 0
    override suspend fun sportsCheck(rec: ScheduledRec): RecordingFailure? { sportsCalls++; return sportsAnswer }
    var alternateChannel: Channel? = null; override suspend fun alternate(rec: ScheduledRec, failed: String, nowMs: Long) = alternateChannel
}

/** The check made when any scheduled recording is due: profile, library, connection, channel, locks, filters, capacity and space, all read at that moment. */
class RecordingGateTests {
    private lateinit var d: FakeGateDeps
    private lateinit var gate: SharedRecordingGate
    private val now = 1_800_000_000_000L; private val h = 3_600_000L

    @Before fun set() { d = FakeGateDeps(); d.auth.channels["1"] = Channel("1", "A", "cat", "Fresh name", null, null, "fresh-ref", null); gate = SharedRecordingGate(d) }

    private fun rec(origin: String = "sports", profile: String = "main", channel: String = "1", source: String = "A", id: String = "r") =
        ScheduledRec(id, channel, "Saved name", source, "saved-ref", "T", now, now + 2 * h, origin = origin, profileId = profile)
    private fun check(r: ScheduledRec = rec()) = runBlocking { gate.check(r, now) }
    private fun refused(r: ScheduledRec = rec()) = (check(r) as? GateDecision.Refuse)?.failure

    @Test fun anAllowedRecordingGoesOnTheChannelAsItIsNowNotAsItWasSaved() {
        val go = check() as GateDecision.Go; assertEquals(listOf("Fresh name", "fresh-ref"), listOf(go.channelName, go.streamRef))
    }

    @Test fun anotherProfileOrACreationTimeStampDoNotAuthorize() {
        d.auth.profile = "kid"; assertEquals(RecordingFailure.PROFILE_CHANGED, refused())
        d.auth.profile = "main"; assertNotNull("allowed again for its own profile", check() as? GateDecision.Go)
    }

    @Test fun everyRestrictionIsReadAtTheMomentItIsDue() {
        d.auth.lockedCategories.add("cat"); assertEquals("a folder relocked", RecordingFailure.UNAUTHORIZED, refused()); d.auth.lockedCategories.clear()
        d.auth.hiddenChannels.add("1"); assertEquals("hidden", RecordingFailure.UNAUTHORIZED, refused()); d.auth.hiddenChannels.clear()
        d.auth.adultFilter = true; d.auth.adultCategories.add("cat"); assertEquals("adult or kids rules", RecordingFailure.UNAUTHORIZED, refused()); d.auth.adultFilter = false
        d.auth.disabledSources.add("A"); assertEquals("the connection switched off", RecordingFailure.SOURCE_OFF, refused()); d.auth.disabledSources.clear()
        d.auth.active = setOf("Z"); assertEquals("another library is open", RecordingFailure.UNAUTHORIZED, refused()); d.auth.active = setOf("A")
        d.auth.channels.remove("1"); assertEquals("the channel is gone", RecordingFailure.CHANNEL_MISSING, refused())
        d.auth.channels["1"] = Channel("1", "B", "cat", "Moved", null, null, "r", null); assertEquals("it now belongs to another connection", RecordingFailure.CHANNEL_MISSING, refused())
    }

    @Test fun everyScheduledRecordingGetsTheSameChecksWhoeverMadeIt() {
        d.auth.hiddenChannels.add("1"); assertEquals(RecordingFailure.UNAUTHORIZED, refused(rec(origin = "", profile = "")))          // as the Guide saves it, before profiles were recorded
        assertEquals("the Sports row is not consulted for it", 0, d.sportsCalls)
    }

    @Test fun aSportsRecordingAlsoNeedsItsOwnRowToAgree() {
        d.sportsAnswer = RecordingFailure.REVIEW_REQUIRED; assertEquals(RecordingFailure.REVIEW_REQUIRED, refused()); assertEquals(1, d.sportsCalls)
        d.sportsAnswer = null; assertNotNull(check() as? GateDecision.Go)
    }

    @Test fun anHlsChannelIsRefusedBeforeAnythingStarts() {
        d.formats["1"] = RecordableFormat.HLS; assertEquals(RecordingFailure.UNSUPPORTED_FORMAT, refused())
    }

    @Test fun anAlternateFeedOfTheSameEventMayBeUsedWhenTheChosenOneIsUnusableBeforeStart() {
        d.auth.hiddenChannels.add("1"); d.auth.channels["2"] = Channel("2", "A", "cat", "Alternate", null, null, "alt-ref", null); d.alternateChannel = d.auth.channels["2"]
        val go = check() as GateDecision.Go; assertEquals("Alternate", go.channelName)
        d.auth.hiddenChannels.add("2"); assertEquals("an alternate that is itself unusable is never used", RecordingFailure.UNAUTHORIZED, refused())
        d.auth.hiddenChannels.clear(); d.auth.hiddenChannels.add("1"); assertEquals("only Sports recordings may use an alternate", RecordingFailure.UNAUTHORIZED, refused(rec(origin = "")))
    }

    @Test fun anUnknownProviderLimitAllowsOneRecordingAtATimeAndNothingIsStopped() {
        d.running = listOf(rec(id = "other"))
        assertEquals(RecordingFailure.CONNECTION_LIMIT, refused()); assertEquals("the other recording is untouched", 1, d.running.size)
    }

    @Test fun playbackAndARecordingShareAOneConnectionProvider() {
        d.maxima["A"] = 1; d.playing = listOf("A"); assertEquals(RecordingFailure.CONNECTION_LIMIT, refused())
        d.playing = emptyList(); assertNotNull(check() as? GateDecision.Go)
    }

    @Test fun twoAllowedRecordingsOnDifferentProvidersRunTogetherButNotThree() {
        d.auth.channels["2"] = Channel("2", "B", "cat", "B channel", null, null, "r2", null); d.auth.active = setOf("A", "B")
        d.running = listOf(rec(channel = "2", source = "B", id = "other"))
        assertNotNull("a different provider is independent", check() as? GateDecision.Go)
        d.running = listOf(rec(channel = "2", source = "B", id = "o1"), rec(channel = "9", source = "C", id = "o2")); assertEquals(RecordingFailure.DEVICE_RECORDING_LIMIT, refused())
    }

    @Test fun storageIsReadAgainRightBeforeStarting() {
        d.storage.free = 1L; assertEquals(RecordingFailure.STORAGE, refused()); d.storage.free = 100L shl 30; d.storage.ok = false; assertEquals(RecordingFailure.STORAGE, refused())
        d.storage.ok = true; assertNotNull(check() as? GateDecision.Go)
    }
}
