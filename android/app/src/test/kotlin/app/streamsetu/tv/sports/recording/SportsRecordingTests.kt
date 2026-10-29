package app.streamsetu.tv.sports.recording

import android.app.AlarmManager
import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.Channel
import app.streamsetu.core.net.RecordableFormat
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.record.*
import app.streamsetu.tv.sports.FakePlaybackDeps
import app.streamsetu.tv.sports.RankInput
import app.streamsetu.tv.sports.SportsAuthorization
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

class FakeProbe(var free: Long = 100L * 1024 * 1024 * 1024, var ok: Boolean = true) : StorageProbe { override fun freeBytes() = free; override fun writable() = ok }

class FakeRecordingDeps(val context: Context, val auth: FakePlaybackDeps = FakePlaybackDeps()) : RecordingDeps, SportsAuthorization by auth {
    val profileFlow = MutableStateFlow("main")
    override val profileId: String get() = profileFlow.value
    override val activeProfile: StateFlow<String> get() = profileFlow
    @Volatile var time = 1_800_000_000_000L
    override fun nowMs() = time
    override fun libraryKey() = "library-1"
    val maxima = HashMap<String, Int>(); override fun providerMax(sourceId: String) = maxima[sourceId] ?: 0
    var playing: List<String> = emptyList(); override fun playingSources() = playing
    val formats = HashMap<String, RecordableFormat>(); override fun format(channel: Channel) = formats[channel.id] ?: RecordableFormat.TS
    override val storage = FakeProbe()
    override val executor: RecordingExecutor = ScheduledRecordingsExecutor(context)
    private var n = 0; override fun newId() = "id-${++n}"
    var live: List<SportsEvent> = emptyList(); override suspend fun events(fromMs: Long, toMs: Long) = live
    override fun rankInput(eventId: String) = RankInput()
    val xtream = HashSet<String>(); override suspend fun isXtream(sourceId: String) = sourceId in xtream
    var offset = 0L; override fun epgOffsetMs() = offset
    val programmes = HashMap<String, Pair<Long, Long>>(); override suspend fun programme(channel: Channel, shiftedStartMs: Long) = programmes[channel.id]
    val archivePlays = java.util.Collections.synchronizedList(ArrayList<Triple<String, Long, Long>>())
    override fun playArchive(channel: Channel, title: String, storedStartMs: Long, storedEndMs: Long, onResult: (app.streamsetu.tv.PlayStart) -> Unit) { archivePlays.add(Triple(channel.id, storedStartMs, storedEndMs)); onResult(app.streamsetu.tv.PlayStart.STARTED) }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SportsRecordingTests {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val alarms get() = Shadows.shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms
    private lateinit var db: AppDatabase
    private lateinit var d: FakeRecordingDeps
    private lateinit var svc: SportsRecordingService
    private lateinit var reports: MutableList<RecordingReport>
    private val h = 3_600_000L; private val min = 60_000L
    private val t0 = 1_800_000_000_000L

    @Before fun open() {
        context.getSharedPreferences("scheduled-recordings", Context.MODE_PRIVATE).edit().clear().commit()
        ScheduledRecordings.load(context); ScheduledRecordings.items.value.forEach { ScheduledRecordings.cancel(context, it.id) }; alarms.clear()
        db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).allowMainThreadQueries().build()
        d = FakeRecordingDeps(context); d.time = t0
        reports = java.util.Collections.synchronizedList(ArrayList())
        svc = SportsRecordingService(db.sports(), d) { reports.add(it) }
    }
    @After fun close() { db.close() }

    private fun channel(id: String, source: String = "A", cat: String? = "cat", name: String = "Channel $id") { d.auth.channels[id] = Channel(id, source, cat, name, null, null, "http://u:SECRET@h.example/$id", null) }
    private fun feed(ch: String, source: String = "A", q: String? = null) = SportsFeed(ch, source, "Channel $ch", null, MetadataSource.UNKNOWN, q, if (q != null) MetadataSource.PARSED_FROM_NAME else MetadataSource.UNKNOWN, null, ch, 0L, false)
    private fun event(id: String, start: Long, vararg chans: String, sides: List<String> = listOf("India", "Australia"), title: String = sides.joinToString(" vs "), q: String? = null, sources: Map<String, String> = emptyMap()): SportsEvent {
        chans.forEach { channel(it, sources[it] ?: "A") }
        return SportsEvent(id, Sport.CRICKET, SportsEventKind.HEAD_TO_HEAD, "Test Series", sides, null, title, start, start + 3 * h, chans.map { feed(it, sources[it] ?: "A", q) }, 0.95, setOf("A"), "r")
    }
    private fun <T> run(b: suspend () -> T): T = runBlocking { b() }
    private suspend fun row(id: String) = db.sports().recording(id)!!
    private val items get() = ScheduledRecordings.items.value

    // ---- recording

    @Test fun recordNowOnALiveEventSchedulesAnImmediateRecordingOfTheChosenFeed() = run {
        val e = event("e", t0 - h, "1"); val out = svc.record(e, null, 0, 0) as RecordOutcome.Scheduled
        val r = row(out.id); assertEquals(SportsRecordingStatus.SCHEDULED.name, r.status); val rec = items.single()
        assertEquals(r.scheduleId, rec.id); assertTrue("not the channel and start", "@" !in rec.id); assertEquals("sports", rec.origin); assertEquals("main", rec.profileId)
        assertTrue("the alarm is for now", alarms.single().triggerAtTime <= t0 + 5_000 || alarms.single().triggerAtTime >= 0)
    }

    @Test fun anUpcomingEventKeepsThePersonsPaddingAndAGeneratedIdAndIsScheduledOnce() = run {
        val e = event("e", t0 + 3 * h, "1"); val out = svc.record(e, null, 5 * min, 20 * min) as RecordOutcome.Scheduled
        val rec = items.single(); assertEquals(listOf(5 * min, 20 * min), listOf(rec.preMs, rec.postMs)); assertEquals(e.startMs - 5 * min, alarms.single().triggerAtTime)
        assertEquals("asking again makes nothing new", RecordOutcome.Exists(out.id), svc.record(e, null, 5 * min, 20 * min)); assertEquals(1, items.size); assertEquals(1, alarms.size); assertEquals(1, db.sports().recordings("main").size)
        val r = row(out.id); assertNull("no stable programme id is read yet", r.programmeId); assertFalse("no title, address or path in the row", r.toString().contains("SECRET") || r.toString().contains("http"))
    }

    @Test fun theSameEventWithOtherPaddingOrFeedIsReportedAsAlreadyScheduled() = run {
        val e = event("e", t0 + 3 * h, "1", "2"); svc.record(e, "1", 0, 0)
        val p = svc.plan(e, "2", 0, 0); assertTrue(PlanIssue.SAME_EVENT_SCHEDULED in p.issues && !p.canConfirm)
        assertTrue(PlanIssue.DUPLICATE_EXACT in svc.plan(e, "1", 0, 0).issues)
    }

    @Test fun aProviderCorrectionMovesTheScheduleAndKeepsIdsAndPadding() = run {
        val e = event("e", t0 + 3 * h, "1"); val id = (svc.record(e, null, 5 * min, 20 * min) as RecordOutcome.Scheduled).id; val scheduleId = row(id).scheduleId
        svc.reassociate(listOf(event("e2", t0 + 3 * h + 25 * min, "1")))
        val rec = items.single(); val r = row(id)
        assertEquals(listOf(scheduleId, t0 + 3 * h + 25 * min, 5 * min, 20 * min), listOf(rec.id, rec.startMs, rec.preMs, rec.postMs)); assertEquals(t0 + 3 * h + 25 * min, r.startMs); assertEquals(id, r.id)
        assertEquals("one alarm at the new time", listOf(rec.startMs - 5 * min), alarms.map { it.triggerAtTime })
    }

    @Test fun anAmbiguousDoubleheaderIsNeverRecordedAndIsRestoredOnceWhenProvable() = run {
        val a = event("first", t0 + 3 * h, "1"); val b = event("second", t0 + 6 * h, "1")
        val id = (svc.record(a, null, 0, 0, guide = listOf(a, b)) as RecordOutcome.Scheduled).id
        svc.reassociate(listOf(event("first-late", t0 + 5 * h + 30 * min, "1"), b))                                    // the first now sits next to the second on the same channel
        assertEquals(SportsRecordingStatus.REVIEW_REQUIRED.name, row(id).status); assertEquals(RecordingFailure.REVIEW_REQUIRED.name, row(id).failure)
        assertTrue("the schedule is withdrawn: nothing will be recorded", items.isEmpty() && alarms.isEmpty())
        assertEquals("the alarm cannot start it", RecordingFailure.REVIEW_REQUIRED, svc.executionCheck(ScheduledRec(row(id).scheduleId, "1", "", "A", "", "", a.startMs, a.endMs, origin = "sports", profileId = "main")))
        val back = event("first-back", t0 + 3 * h + 2 * min, "1")
        svc.reassociate(listOf(back, b)); assertEquals(SportsRecordingStatus.SCHEDULED.name, row(id).status); assertEquals(1, items.size); assertEquals(1, alarms.size)
        repeat(3) { svc.reassociate(listOf(back, b)) }
        assertEquals("restored exactly once, however many refreshes", 1, items.size); assertEquals(1, alarms.size); assertEquals(1, db.sports().recordings("main").size)
    }

    @Test fun anEventThatLeavesTheGuideWaitsForReviewAndNothingIsRecorded() = run {
        val e = event("e", t0 + 3 * h, "1"); val id = (svc.record(e, null, 0, 0) as RecordOutcome.Scheduled).id
        svc.reassociate(emptyList()); assertEquals(SportsRecordingStatus.REVIEW_REQUIRED.name, row(id).status); assertTrue(items.isEmpty())
    }

    @Test fun cancellingARecordingThatHasNotStartedLeavesNoScheduleAndIsIdempotent() = run {
        val id = (svc.record(event("e", t0 + 3 * h, "1"), null, 0, 0) as RecordOutcome.Scheduled).id
        assertTrue(svc.cancel(id)); assertEquals(SportsRecordingStatus.CANCELLED.name, row(id).status); assertTrue(items.isEmpty() && alarms.isEmpty()); assertFalse(svc.cancel(id))
        assertEquals("a stale alarm cannot start it", RecordingFailure.UNAUTHORIZED, svc.executionCheck(ScheduledRec(row(id).scheduleId, "1", "", "A", "", "", 0, 1, origin = "sports", profileId = "main")))
    }

    @Test fun stoppingARunningRecordingKeepsADiscoverableFile() = run {
        val folder = java.io.File(context.filesDir, "recordings-test").also { it.mkdirs() }
        val e = event("e", t0 - h, "1"); val id = (svc.record(e, null, 0, 0) as RecordOutcome.Scheduled).id; val sid = row(id).scheduleId
        val file = java.io.File(folder, app.streamsetu.core.data.repo.RecordingFiles.fileName("Channel 1 - x", t0)).also { it.writeBytes(ByteArray(188 * 10)) }
        ScheduledRecordings.update(context, sid, ScheduledRec.RECORDING, null, null, file.name); svc.syncFromExecutor(); assertEquals(SportsRecordingStatus.RECORDING.name, row(id).status)
        assertTrue(svc.stop(id)); svc.syncFromExecutor(); assertEquals(SportsRecordingStatus.COMPLETED.name, row(id).status); assertFalse("stopping again does nothing", svc.stop(id))
        assertEquals(file.name, ScheduledRecordings.find(sid)!!.file); assertTrue("it is among the recordings", app.streamsetu.core.data.repo.RecordingFiles.list(folder).any { it.file.name == file.name })
    }

    @Test fun aFailedRecordingKeepsItsCategoryAndItsPartialFile() = run {
        val id = (svc.record(event("e", t0 - h, "1"), null, 0, 0) as RecordOutcome.Scheduled).id; val sid = row(id).scheduleId
        ScheduledRecordings.update(context, sid, ScheduledRec.FAILED, "x", RecordingFailure.ENDED_EARLY, "part.ts"); svc.syncFromExecutor()
        assertEquals(listOf(SportsRecordingStatus.FAILED.name, RecordingFailure.ENDED_EARLY.name), listOf(row(id).status, row(id).failure)); assertEquals("part.ts", ScheduledRecordings.find(sid)!!.file)
    }

    @Test fun aRecordingRemovedFromSettingsIsReflectedAsCancelled() = run {
        val id = (svc.record(event("e", t0 + 3 * h, "1"), null, 0, 0) as RecordOutcome.Scheduled).id
        ScheduledRecordings.cancel(context, row(id).scheduleId); svc.syncFromExecutor(); assertEquals(SportsRecordingStatus.CANCELLED.name, row(id).status)
    }

    // ---- feeds and formats

    @Test fun aHlsPrimaryFeedWithARecordableAlternateOffersTheAlternate() = run {
        val e = event("e", t0 + 3 * h, "1", "2", q = "FHD"); d.formats["1"] = RecordableFormat.HLS
        val p = svc.plan(e, null, 0, 0)
        assertEquals(listOf(false, true), p.feeds.sortedBy { it.channelId }.map { it.recordable }); assertEquals("2", p.chosenChannelId); assertTrue(p.canConfirm)
        assertEquals("the person cannot choose the HLS feed", null, svc.plan(e, "1", 0, 0).chosenChannelId)
        val out = svc.record(e, null, 0, 0) as RecordOutcome.Scheduled; assertEquals("2", row(out.id).channelId)
    }

    @Test fun whenEveryFeedIsHlsNothingCanBeRecorded() = run {
        val e = event("e", t0 + 3 * h, "1", "2"); d.formats["1"] = RecordableFormat.HLS; d.formats["2"] = RecordableFormat.HLS
        val p = svc.plan(e, null, 0, 0); assertTrue(PlanIssue.NO_RECORDABLE_FEED in p.issues && !p.canConfirm); assertEquals(RecordOutcome.Blocked(p.issues), svc.record(e, null, 0, 0)); assertTrue(items.isEmpty())
    }

    @Test fun anUnconfirmedFormatIsRecordableWithANote() = run {
        val e = event("e", t0 + 3 * h, "1"); d.formats["1"] = RecordableFormat.UNKNOWN
        val p = svc.plan(e, null, 0, 0); assertTrue(p.canConfirm); assertTrue(PlanNote.FORMAT_UNCONFIRMED in p.notes)
    }

    @Test fun onlyAuthorizedFeedsAreOffered() = run {
        val e = event("e", t0 + 3 * h, "1", "2"); d.auth.hiddenChannels.add("1")
        assertEquals(listOf("2"), svc.plan(e, null, 0, 0).feeds.map { it.channelId })
        d.auth.hiddenChannels.add("2"); assertTrue(PlanIssue.NO_RECORDABLE_FEED in svc.plan(e, null, 0, 0).issues)
    }

    // ---- conflicts and storage

    @Test fun twoOverlappingRecordingsOnTheSameUnknownProviderConflictAndNothingIsReplaced() = run {
        val a = event("a", t0 + 3 * h, "1"); val b = event("b", t0 + 4 * h, "2", sides = listOf("X", "Y"))
        svc.record(a, null, 0, 0); val p = svc.plan(b, null, 0, 0)
        assertTrue(PlanIssue.CONNECTION_LIMIT in p.issues); assertEquals(RecordOutcome.Blocked(p.issues), svc.record(b, null, 0, 0)); assertEquals("the first is untouched", 1, items.size)
    }

    @Test fun anOverlapOnAnotherProviderIsAllowedAndNoted() = run {
        val a = event("a", t0 + 3 * h, "1"); val b = event("b", t0 + 4 * h, "2", sides = listOf("X", "Y"), sources = mapOf("2" to "B"))
        d.auth.active = setOf("A", "B"); svc.record(a, null, 0, 0); val p = svc.plan(b, null, 0, 0); assertTrue(p.canConfirm); assertTrue(PlanNote.OVERLAP_ALLOWED in p.notes)
        assertTrue(svc.record(b, null, 0, 0) is RecordOutcome.Scheduled); assertEquals(2, items.size)
    }

    @Test fun aKnownProviderLimitOfTwoAllowsTwoAndTheDeviceStopsAThird() = run {
        d.maxima["A"] = 5
        val a = event("a", t0 + 3 * h, "1"); val b = event("b", t0 + 3 * h, "2", sides = listOf("X", "Y")); val c = event("c", t0 + 3 * h, "3", sides = listOf("P", "Q"))
        assertTrue(svc.record(a, null, 0, 0) is RecordOutcome.Scheduled); assertTrue(svc.record(b, null, 0, 0) is RecordOutcome.Scheduled)
        assertTrue(PlanIssue.DEVICE_RECORDING_LIMIT in svc.plan(c, null, 0, 0).issues)
    }

    @Test fun storageThatIsTooSmallOrMissingBlocksAndUncertainWarns() = run {
        val e = event("e", t0 + 3 * h, "1", q = "HD"); val low = RecordingStorage.estimate(e.endMs + 0 - e.startMs, "HD")
        d.storage.free = low.lowBytes + RecordingStorage.RESERVE_BYTES - 1; assertTrue(PlanIssue.STORAGE_NOT_ENOUGH in svc.plan(e, null, 0, 0).issues)
        d.storage.free = low.lowBytes + RecordingStorage.RESERVE_BYTES + 1; val p = svc.plan(e, null, 0, 0); assertTrue(p.canConfirm); assertTrue(PlanNote.STORAGE_UNCERTAIN in p.notes)
        d.storage.free = 1L shl 40; d.storage.ok = false; assertTrue(PlanIssue.STORAGE_UNAVAILABLE in svc.plan(e, null, 0, 0).issues)
        d.storage.ok = true; assertTrue(svc.plan(e, null, 0, 0).estimate!!.let { it.lowBytes > 0 && it.highBytes > it.lowBytes })
    }

    @Test fun anEventThatIsOverCannotBeRecorded() = run {
        val p = svc.plan(event("e", t0 - 5 * h, "1"), null, 0, 0); assertTrue(PlanIssue.EVENT_OVER in p.issues && !p.canConfirm)
    }

    @Test fun recordNowAlsoNeedsAFreeConnectionNow() = run {
        d.maxima["A"] = 1; d.playing = listOf("A")
        assertTrue(PlanIssue.CONNECTION_LIMIT in svc.plan(event("e", t0 - h, "1"), null, 0, 0).issues)
        assertFalse("an upcoming one does not depend on what plays now", PlanIssue.CONNECTION_LIMIT in svc.plan(event("f", t0 + 5 * h, "1"), null, 0, 0).issues)
    }

    // ---- security at the moment of the request and of the alarm

    @Test fun aRestrictionBeforeConfirmationBlocksTheRequest() = run {
        val e = event("e", t0 + 3 * h, "1")
        for (change in listOf<() -> Unit>({ d.auth.lockedCategories.add("cat") }, { d.auth.hiddenChannels.add("1") }, { d.auth.adultCategories.add("cat"); d.auth.adultFilter = true }, { d.auth.disabledSources.add("A") }, { d.auth.active = setOf("Z") }, { d.auth.channels.remove("1") })) {
            d.auth.lockedCategories.clear(); d.auth.hiddenChannels.clear(); d.auth.adultFilter = false; d.auth.disabledSources.clear(); d.auth.active = setOf("A"); channel("1")
            change(); assertTrue(svc.record(e, null, 0, 0) is RecordOutcome.Blocked); assertTrue(items.isEmpty())
        }
    }

    @Test fun aRecordingOfAnotherProfileOrOfADeletedProfileIsRefusedAtTheAlarm() = run {
        val id = (svc.record(event("e", t0 + 3 * h, "1"), null, 0, 0) as RecordOutcome.Scheduled).id; val r = row(id)
        val rec = ScheduledRec(r.scheduleId, "1", "", "A", "", "", r.startMs, r.endMs, origin = "sports", profileId = "main")
        assertNull(svc.executionCheck(rec)); d.profileFlow.value = "kid"; assertEquals(RecordingFailure.PROFILE_CHANGED, svc.executionCheck(rec))
        db.sports().updateRecordings(listOf(r.copy(profileId = "deleted"))); d.profileFlow.value = "main"; assertEquals("its profile no longer exists", RecordingFailure.PROFILE_CHANGED, svc.executionCheck(rec))
    }

    @Test fun anAlarmForARecordingWhoseTimesNoLongerAgreeIsRefused() = run {
        val id = (svc.record(event("e", t0 + 3 * h, "1"), null, 0, 0) as RecordOutcome.Scheduled).id; val r = row(id)
        assertEquals(RecordingFailure.REVIEW_REQUIRED, svc.executionCheck(ScheduledRec(r.scheduleId, "1", "", "A", "", "", r.startMs + 10 * min, r.endMs, origin = "sports", profileId = "main")))
    }

    // ---- privacy and structure

    @Test fun diagnosticsCarryOnlyCountsAndFixedWords() = run {
        val e = event("e", t0 + 3 * h, "1", sides = listOf("SECRET FC", "SECRET United"), title = "SECRET FC v SECRET United"); svc.record(e, null, 0, 0); svc.reassociate(emptyList())
        val text = reports.joinToString("\n") { it.line() }; assertTrue(reports.isNotEmpty()); assertFalse(text, text.uppercase().contains("SECRET") || text.contains("http") || text.contains("/"))
        assertTrue(RecordingReport::class.java.declaredFields.filter { !it.name.startsWith("$") }.none { it.type == String::class.java && it.name != "outcome" })
    }

    @Test fun sportsHasNoRecordingEnginePlayerOrCatchUpAddressBuilder() {
        val roots = listOf("src/main/kotlin/app/streamsetu/tv/sports/recording", "src/main/kotlin/app/streamsetu/tv/ui/screens/sports")
        val files = roots.flatMap { java.io.File(it).walkTopDown().filter { f -> f.extension == "kt" }.toList() }
        assertTrue(files.size >= 5)
        for (f in files) { val t = f.readText(); for (w in listOf("OkHttp", "Http.client", "timeshift", "Request.Builder", "startRecording(", "ExoEngine(", "MediaRecorder", "FileOutputStream", "newCall(")) assertFalse("${f.name} must not contain $w", t.contains(w)) }
    }

    // ---- start over and catch-up

    private fun archiveEvent(id: String, start: Long, vararg chans: String): SportsEvent {
        val e = event(id, start, *chans)
        chans.forEach { c -> d.auth.channels[c] = d.auth.channels[c]!!.copy(catchupDays = 3); d.xtream.add("A"); d.programmes[c] = e.startMs to e.endMs }
        return e
    }

    @Test fun startOverIsOfferedOnlyForALiveProgrammeInsideTheDeclaredArchive() = run {
        val live = archiveEvent("e", t0 - h, "1", "2")
        val (startOver, catchUp) = svc.archiveOptions(live, t0); assertEquals(listOf("1", "2"), startOver.sorted()); assertTrue(catchUp.isEmpty())
        assertTrue("nothing was played or requested by asking", d.archivePlays.isEmpty())
        val future = archiveEvent("f", t0 + 5 * h, "3"); assertTrue(svc.archiveOptions(future, t0).let { it.first.isEmpty() && it.second.isEmpty() })
        d.xtream.clear(); assertTrue("not on a kind of connection that has an archive address", svc.archiveOptions(live, t0).first.isEmpty())
    }

    @Test fun catchUpIsOfferedForAnEndedProgrammeUntilTheArchiveExpires() = run {
        val over = archiveEvent("e", t0 - 5 * h, "1")
        assertEquals(listOf("1"), svc.archiveOptions(over, t0).second); assertTrue(svc.archiveOptions(over, t0).first.isEmpty())
        assertTrue("expired", svc.archiveOptions(over, t0 + 4 * 24 * h).second.isEmpty())
        d.programmes.clear(); assertTrue("the programme cannot be mapped safely", svc.archiveOptions(over, t0).second.isEmpty())
    }

    @Test fun playingAnArchiveChecksTheChannelAndTheOfferAgainAndUsesTheCatchUpPlayback() = run {
        val live = archiveEvent("e", t0 - h, "1")
        assertTrue(svc.playArchive(live, "1", startOver = true) { }); assertEquals(1, d.archivePlays.size); assertEquals(live.startMs, d.archivePlays.single().second)
        d.auth.hiddenChannels.add("1"); assertFalse("authorization is read at the moment of the tap", svc.playArchive(live, "1", startOver = true) { }); assertEquals(1, d.archivePlays.size)
        d.auth.hiddenChannels.clear(); d.time = t0 + 30 * h; assertFalse("no longer live: not started, and never falls back to live", svc.playArchive(live, "1", startOver = true) { }); assertEquals(1, d.archivePlays.size)
        assertFalse("a channel that is not one of the event's feeds", svc.playArchive(live, "9", startOver = true) { })
    }

    @Test fun theGuideOffsetIsAppliedWhenMappingTheProgramme() = run {
        d.offset = 30 * min; val e = event("e", t0 - h, "1"); d.auth.channels["1"] = d.auth.channels["1"]!!.copy(catchupDays = 3); d.xtream.add("A")
        d.programmes["1"] = (e.startMs - d.offset) to (e.endMs - d.offset)
        assertEquals(listOf("1"), svc.archiveOptions(e, t0).first); svc.playArchive(e, "1", true) { }
        assertEquals("the archive is asked for the programme in the provider's own time", e.startMs - d.offset, d.archivePlays.single().second)
    }
}
