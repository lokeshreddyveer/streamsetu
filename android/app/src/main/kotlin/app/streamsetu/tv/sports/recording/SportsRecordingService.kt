package app.streamsetu.tv.sports.recording

import app.streamsetu.core.data.db.SportsDao
import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.model.Channel
import app.streamsetu.core.net.RecordableFormat
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.record.GateDecision
import app.streamsetu.tv.record.RecordingFailure
import app.streamsetu.tv.record.ScheduledRec
import app.streamsetu.tv.sports.SportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorizer
import app.streamsetu.tv.sports.SportsFeedRanker
import app.streamsetu.tv.sports.RankInput
import app.streamsetu.tv.sports.personal.Association
import app.streamsetu.tv.sports.personal.ReminderMatcher
import app.streamsetu.tv.sports.personal.SportsEventReminder
import app.streamsetu.tv.sports.personal.SportsKeys
import app.streamsetu.tv.trace.SSTrace
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Where a Sports recording stands. The executor (the scheduled-recording service) does the recording; this follows it. */
enum class SportsRecordingStatus { SCHEDULED, RECORDING, COMPLETED, FAILED, CANCELLED, REVIEW_REQUIRED }

/** The scheduled-recording service as the Sports recordings use it. The real one is a thin shell over `ScheduledRecordings`. */
interface RecordingExecutor {
    val items: StateFlow<List<ScheduledRec>>
    fun refresh()
    fun schedule(r: ScheduledRec): Boolean
    fun reschedule(id: String, startMs: Long, endMs: Long): Boolean
    fun cancel(id: String)
    fun stop(id: String): Boolean
}

/** What the recordings need from the rest of the app. */
interface RecordingDeps : SportsAuthorization {
    val activeProfile: StateFlow<String>
    fun nowMs(): Long
    fun libraryKey(): String
    /** What the provider says it allows at once; 0 when it has not said. */
    fun providerMax(sourceId: String): Int
    /** Sources that playback and Multi-View are using right now, one entry per connection. */
    fun playingSources(): List<String>
    /** What the channel would be recorded as, from what is already known (no request). */
    fun format(channel: Channel): RecordableFormat
    val storage: StorageProbe
    val executor: RecordingExecutor
    fun newId(): String
    /** The events of the guide as it is now (slow; only ever off the main thread). */
    suspend fun events(fromMs: Long, toMs: Long): List<SportsEvent>
    fun rankInput(eventId: String): RankInput
    /** Whether the connection is an Xtream one (the only kind the app can ask an archive of). */
    suspend fun isXtream(sourceId: String): Boolean
    /** The guide offset the app applies to programme times, in milliseconds. */
    fun epgOffsetMs(): Long
    /** The programme this channel has at about [shiftedStartMs], as the guide stores it (start, end), or null when it cannot be matched. */
    suspend fun programme(channel: Channel, shiftedStartMs: Long): Pair<Long, Long>?
    /** Plays an archived programme through the app's catch-up playback. The address is built there, never here. */
    fun playArchive(channel: Channel, title: String, storedStartMs: Long, storedEndMs: Long, onResult: (app.streamsetu.tv.PlayStart) -> Unit)
}

enum class PlanIssue { EVENT_OVER, NO_RECORDABLE_FEED, DUPLICATE_EXACT, SAME_EVENT_SCHEDULED, CONNECTION_LIMIT, DEVICE_RECORDING_LIMIT, STORAGE_NOT_ENOUGH, STORAGE_UNAVAILABLE, REVIEW_REQUIRED }
enum class PlanNote { OVERLAP_ALLOWED, STORAGE_UNCERTAIN, FORMAT_UNCONFIRMED }
enum class FeedBlock { UNSUPPORTED_FORMAT }

/** One authorized feed of the event, and whether it can be recorded. Channel ids only. */
class FeedRecordability(val channelId: String, val format: RecordableFormat, val block: FeedBlock?, val quality: String?) { val recordable get() = block == null }

/**
 * What the person is shown before confirming: which feeds can be recorded, the one chosen, when it records and for how long, an estimate of the space it needs, and anything in the way. An overlap with
 * another recording is a note, not a problem, if the provider, the device and the space allow both. Nothing is cancelled or replaced to make room.
 */
class RecordingPreview(
    val eventId: String, val feeds: List<FeedRecordability>, val chosenChannelId: String?, val startMs: Long, val endMs: Long, val preMs: Long, val postMs: Long, val recordNow: Boolean,
    val estimate: StorageEstimate?, val freeBytes: Long, val issues: List<PlanIssue>, val notes: List<PlanNote>, val overlaps: Int,
) {
    val canConfirm: Boolean get() = issues.isEmpty() && chosenChannelId != null
    val durationMs: Long get() = endMs + postMs - (if (recordNow) startMs.coerceAtLeast(0) else startMs - preMs)
}

sealed interface RecordOutcome {
    data class Scheduled(val id: String) : RecordOutcome
    /** Already requested for this event: nothing new was made. */
    data class Exists(val id: String) : RecordOutcome
    data class Blocked(val issues: List<PlanIssue>) : RecordOutcome
}

/** Counts and fixed words only: no event, team, channel or connection name, no address, no path. */
class RecordingReport(val outcome: String, val issues: List<PlanIssue>, val reassociated: Int, val ambiguous: Int, val feeds: Int, val recordable: Int, val ms: Long) {
    fun line() = "sports record outcome=$outcome issues=${issues.joinToString(",") { it.name.lowercase() }} feeds=$feeds recordable=$recordable reassociated=$reassociated ambiguous=$ambiguous ms=$ms"
}

fun interface RecordingDiagnostics {
    fun record(report: RecordingReport)
    object Log : RecordingDiagnostics { override fun record(report: RecordingReport) { SSTrace.v { report.line() } } }
}

/**
 * Recordings asked for from Sports events. The durable row holds the Sports identity and its matching; the recording is made by the scheduled-recording service, linked by a generated schedule id that never
 * changes. Everything here is conservative:
 *
 *  - Asking twice (a repeated tap, a restart, a guide refresh) makes one recording.
 *  - After a guide change a recording follows its programme only on the evidence reminders use (channels that single out one fixture, or a start that has not moved); otherwise its schedule is withdrawn,
 *    it shows "Schedule changed — review required", nothing is recorded, and it is restored once, exactly, if the match later becomes provable.
 *  - Before it starts, [executionCheck] reads the row again and refuses anything cancelled, finished, ambiguous or no longer allowed.
 */
class SportsRecordingService(private val dao: SportsDao, private val deps: RecordingDeps, private val diagnostics: RecordingDiagnostics = RecordingDiagnostics.Log) {
    private val mutex = Mutex()

    /** The active profile's recordings; switches with the profile. */
    @kotlin.OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    val recordings: Flow<List<SportsRecordingEntity>> = deps.activeProfile.flatMapLatest { dao.recordingsFlow(it) }

    private val OPEN = listOf(SportsRecordingStatus.SCHEDULED.name, SportsRecordingStatus.RECORDING.name, SportsRecordingStatus.REVIEW_REQUIRED.name)

    // ---- the preview

    suspend fun plan(event: SportsEvent, wantedChannelId: String?, preMs: Long, postMs: Long, guide: List<SportsEvent> = listOf(event)): RecordingPreview {
        val owner = deps.activeProfile.value; val now = deps.nowMs()
        val allowed = SportsAuthorizer.authorizedFeeds(deps, event, owner)
        val feeds = SportsFeedRanker.rank(allowed.map { it.first }, deps.rankInput(event.id)).map { r ->
            val ch = allowed.first { it.first.channelId == r.feed.channelId }.second
            val format = deps.format(ch)
            FeedRecordability(r.feed.channelId, format, if (format == RecordableFormat.HLS) FeedBlock.UNSUPPORTED_FORMAT else null, r.feed.quality)
        }
        val chosen = (if (wantedChannelId != null) feeds.firstOrNull { it.channelId == wantedChannelId && it.recordable } else feeds.firstOrNull { it.recordable })
        val issues = ArrayList<PlanIssue>(); val notes = ArrayList<PlanNote>()
        val recordNow = event.startMs <= now
        if (event.endMs <= now) issues += PlanIssue.EVENT_OVER
        if (chosen == null) issues += PlanIssue.NO_RECORDABLE_FEED
        // The same event already requested.
        val identity = SportsKeys.identity(event); val slot = SportsKeys.slot(event.startMs)
        val existing = dao.recordings(owner).firstOrNull { it.identity == identity && it.slot == slot && it.status in OPEN }
        if (existing != null) issues += if (existing.status == SportsRecordingStatus.REVIEW_REQUIRED.name) PlanIssue.REVIEW_REQUIRED else if (chosen != null && existing.channelId == chosen.channelId && existing.preMs == preMs && existing.postMs == postMs) PlanIssue.DUPLICATE_EXACT else PlanIssue.SAME_EVENT_SCHEDULED
        var estimate: StorageEstimate? = null; var free = 0L; var overlaps = 0
        if (chosen != null) {
            val ch = allowed.first { it.first.channelId == chosen.channelId }.second
            if (chosen.format == RecordableFormat.UNKNOWN) notes += PlanNote.FORMAT_UNCONFIRMED
            val from = if (recordNow) now else event.startMs - preMs
            val window = RecordingWindow(ch.sourceId, from, event.endMs + postMs)
            val others = deps.executor.items.value.filter { it.state == ScheduledRec.SCHEDULED || it.state == ScheduledRec.RECORDING }.map { RecordingWindow(it.sourceId, it.startMs - it.preMs, it.endMs + it.postMs) }
            overlaps = others.count { it.fromMs < window.toMs && it.toMs > window.fromMs }
            when (RecordingCapacity.window(window, others, deps.providerMax(ch.sourceId))) {
                CapacityResult.CONNECTION_LIMIT -> issues += PlanIssue.CONNECTION_LIMIT
                CapacityResult.DEVICE_RECORDING_LIMIT -> issues += PlanIssue.DEVICE_RECORDING_LIMIT
                CapacityResult.OK -> if (overlaps > 0) notes += PlanNote.OVERLAP_ALLOWED
            }
            if (recordNow) {                                                                    // starting now also needs a free connection now
                val active = deps.executor.items.value.filter { it.state == ScheduledRec.RECORDING }
                when (RecordingCapacity.now(deps.providerMax(ch.sourceId), active.count { it.sourceId == ch.sourceId }, active.size, deps.playingSources().count { it == ch.sourceId }, 0)) {
                    CapacityResult.CONNECTION_LIMIT -> if (PlanIssue.CONNECTION_LIMIT !in issues) issues += PlanIssue.CONNECTION_LIMIT
                    CapacityResult.DEVICE_RECORDING_LIMIT -> if (PlanIssue.DEVICE_RECORDING_LIMIT !in issues) issues += PlanIssue.DEVICE_RECORDING_LIMIT
                    CapacityResult.OK -> {}
                }
            }
            estimate = RecordingStorage.estimate(window.toMs - window.fromMs, chosen.quality)
            free = deps.storage.freeBytes()
            when (RecordingStorage.verdict(estimate, deps.storage)) {
                StorageVerdict.NOT_ENOUGH -> issues += PlanIssue.STORAGE_NOT_ENOUGH
                StorageVerdict.UNAVAILABLE -> issues += PlanIssue.STORAGE_UNAVAILABLE
                StorageVerdict.UNCERTAIN -> notes += PlanNote.STORAGE_UNCERTAIN
                StorageVerdict.OK -> {}
            }
        }
        return RecordingPreview(event.id, feeds, chosen?.channelId, event.startMs, event.endMs, preMs, postMs, recordNow, estimate, free, issues, notes, overlaps)
    }

    /** Follows the executor from now on: every change to its list is reflected in the rows, once each. */
    fun start(scope: kotlinx.coroutines.CoroutineScope) {
        scope.launch { syncFromExecutor(); deps.executor.items.collect { runCatching { syncFromExecutor(refresh = false) } } }
    }

    // ---- making, cancelling, stopping

    /** Confirms what [plan] showed, after checking it all again. Never cancels or replaces another recording. */
    suspend fun record(event: SportsEvent, wantedChannelId: String?, preMs: Long, postMs: Long, guide: List<SportsEvent> = listOf(event)): RecordOutcome = mutex.withLock {
        val started = System.nanoTime()
        val preview = plan(event, wantedChannelId, preMs, postMs, guide)
        if (PlanIssue.DUPLICATE_EXACT in preview.issues || PlanIssue.SAME_EVENT_SCHEDULED in preview.issues) {
            val existing = dao.recordings(deps.activeProfile.value).first { it.identity == SportsKeys.identity(event) && it.slot == SportsKeys.slot(event.startMs) && it.status in OPEN }
            report("exists", preview, started); return RecordOutcome.Exists(existing.id)
        }
        if (!preview.canConfirm) { report("blocked", preview, started); return RecordOutcome.Blocked(preview.issues) }
        val owner = deps.activeProfile.value; val now = deps.nowMs()
        val feedChannel = SportsAuthorizer.authorizedFeeds(deps, event, owner).first { it.first.channelId == preview.chosenChannelId }.second
        if (deps.activeProfile.value != owner) { report("blocked", preview, started); return RecordOutcome.Blocked(listOf(PlanIssue.REVIEW_REQUIRED)) }
        val id = deps.newId(); val scheduleId = deps.newId()
        val siblings = (guide.filter { it.id != event.id && SportsKeys.identity(it) == SportsKeys.identity(event) && kotlin.math.abs(it.startMs - event.startMs) <= ReminderMatcher.TOLERANCE_MS } + event).sortedWith(compareBy({ it.startMs }, { it.id }))
        val others = siblings.filter { it.id != event.id }
        val row = SportsRecordingEntity(
            id = id, profileId = owner, libraryKey = deps.libraryKey(), sport = event.sport.name, identity = SportsKeys.identity(event), competitionKey = SportsKeys.competition(event), participantsKey = SportsKeys.participantsKey(event),
            sourceId = feedChannel.sourceId, channelId = feedChannel.id, startMs = event.startMs, endMs = event.endMs, preMs = preMs, postMs = postMs, slot = SportsKeys.slot(event.startMs), siblings = siblings.size,
            distinguishing = (event.feeds.map { it.channelId }.toSet() - others.flatMap { o -> o.feeds.map { it.channelId } }.toSet()).sorted().take(8).joinToString(","), programmeId = null, scheduleId = scheduleId, matchedEventId = event.id,
            status = SportsRecordingStatus.SCHEDULED.name, failure = null, authStamp = "p=$owner;l=${deps.libraryKey()};t=$now", createdAt = now, updatedAt = now,
        )
        if (dao.insertRecording(row) == -1L) { report("exists", preview, started); return RecordOutcome.Exists(dao.recordings(owner).first { it.identity == row.identity && it.slot == row.slot }.id) }
        val ok = deps.executor.schedule(ScheduledRec(scheduleId, feedChannel.id, feedChannel.name, feedChannel.sourceId, "", event.title, event.startMs, event.endMs, preMs = preMs, postMs = postMs, profileId = owner, origin = ORIGIN))
        if (!ok) { dao.deleteRecording(id); report("blocked", preview, started); return RecordOutcome.Blocked(listOf(PlanIssue.EVENT_OVER)) }
        report("scheduled", preview, started)
        RecordOutcome.Scheduled(id)
    }

    /** Cancel a recording that has not started: the schedule goes and no file exists. Idempotent. */
    suspend fun cancel(id: String): Boolean = mutex.withLock {
        val r = dao.recording(id) ?: return false
        if (dao.transition(id, listOf(SportsRecordingStatus.SCHEDULED.name, SportsRecordingStatus.REVIEW_REQUIRED.name), SportsRecordingStatus.CANCELLED.name, null, deps.nowMs()) == 0) return false
        deps.executor.cancel(r.scheduleId)
        true
    }

    /** Stop one that is recording: it is finalized and the part recorded is kept as a playable file. Idempotent. */
    suspend fun stop(id: String): Boolean = mutex.withLock {
        val r = dao.recording(id) ?: return false
        if (r.status != SportsRecordingStatus.RECORDING.name) return false
        deps.executor.stop(r.scheduleId)
    }

    // ---- following the executor

    /** The executor's states are reflected in the rows, each as a guarded transition, so a repeated or late report changes nothing. */
    suspend fun syncFromExecutor(refresh: Boolean = true): Int = mutex.withLock {
        if (refresh) deps.executor.refresh()
        val items = deps.executor.items.value.associateBy { it.id }; val now = deps.nowMs(); var changed = 0
        for (r in dao.openRecordings()) {
            val e = items[r.scheduleId]
            val to: Pair<SportsRecordingStatus, String?>? = when {
                e == null && r.status == SportsRecordingStatus.REVIEW_REQUIRED.name -> null                           // withdrawn on purpose
                e == null -> SportsRecordingStatus.CANCELLED to null                                                  // removed from Settings
                e.state == ScheduledRec.RECORDING -> SportsRecordingStatus.RECORDING to null
                e.state == ScheduledRec.DONE -> SportsRecordingStatus.COMPLETED to null
                e.state == ScheduledRec.FAILED || e.state == ScheduledRec.MISSED -> SportsRecordingStatus.FAILED to (e.failure ?: RecordingFailure.UNKNOWN.name)
                else -> null
            }
            if (to != null && to.first.name != r.status) changed += dao.transition(r.id, listOf(r.status), to.first.name, to.second, now)
        }
        changed
    }

    // ---- after a guide change

    /**
     * Finds the programme of every recording that has not started, in one pass, on the evidence reminders use. A provable match moves the schedule to the corrected times (the padding and the ids stay).
     * An unprovable one withdraws the schedule and waits for review; if it becomes provable again the same schedule is restored once.
     */
    suspend fun reassociate(events: List<SportsEvent>): Int = mutex.withLock {
        val owner = deps.activeProfile.value; val now = deps.nowMs(); val started = System.nanoTime()
        val rows = dao.recordings(owner).filter { (it.status == SportsRecordingStatus.SCHEDULED.name || it.status == SportsRecordingStatus.REVIEW_REQUIRED.name) && it.startMs - it.preMs > now }
        if (rows.isEmpty()) return 0
        val windowEnd = (events.maxOfOrNull { it.startMs } ?: now) + ReminderMatcher.TOLERANCE_MS
        val out = ReminderMatcher.associate(rows.map { SportsEventReminder(it.id, it.identity, it.competitionKey, it.startMs, it.siblings, it.distinguishing.split(',').filter { c -> c.isNotEmpty() }.toSet()) }, events, windowEnd)
        val byId = rows.associateBy { it.id }; var matched = 0; var ambiguous = 0
        for (a in out) {
            val r = byId[a.reminderId] ?: continue
            when (a) {
                is Association.Matched -> {
                    matched++
                    val e = a.event
                    if (r.status == SportsRecordingStatus.REVIEW_REQUIRED.name) {
                        // Provable again: restored once. The transition is guarded, so a repeated refresh does nothing more.
                        if (dao.transition(r.id, listOf(SportsRecordingStatus.REVIEW_REQUIRED.name), SportsRecordingStatus.SCHEDULED.name, null, now) == 1) {
                            dao.updateRecordings(listOf(dao.recording(r.id)!!.copy(startMs = e.startMs, endMs = e.endMs, matchedEventId = e.id, updatedAt = now)))
                            deps.executor.schedule(scheduled(r, e.startMs, e.endMs))
                        }
                    } else if (e.startMs != r.startMs || e.endMs != r.endMs || r.matchedEventId != e.id) {
                        dao.updateRecordings(listOf(r.copy(startMs = e.startMs, endMs = e.endMs, matchedEventId = e.id, updatedAt = now)))
                        if (e.startMs != r.startMs || e.endMs != r.endMs) deps.executor.reschedule(r.scheduleId, e.startMs, e.endMs)
                    }
                }
                is Association.Unmatched, is Association.Ambiguous -> {
                    ambiguous++
                    if (r.status == SportsRecordingStatus.SCHEDULED.name && dao.transition(r.id, listOf(SportsRecordingStatus.SCHEDULED.name), SportsRecordingStatus.REVIEW_REQUIRED.name, RecordingFailure.REVIEW_REQUIRED.name, now) == 1) {
                        dao.updateRecordings(listOf(dao.recording(r.id)!!.copy(matchedEventId = null)))
                        deps.executor.cancel(r.scheduleId)                                                                // nothing is recorded until it can be proven
                    }
                }
                is Association.NotYet -> {}
            }
        }
        diagnostics.record(RecordingReport("reassociated", emptyList(), matched, ambiguous, 0, 0, (System.nanoTime() - started) / 1_000_000))
        matched
    }

    private fun scheduled(r: SportsRecordingEntity, start: Long, end: Long) =
        ScheduledRec(r.scheduleId, r.channelId, "", r.sourceId, "", "", start, end, preMs = r.preMs, postMs = r.postMs, profileId = r.profileId, origin = ORIGIN)

    // ---- start over and catch-up

    /** What the file of a recording is called, once it has one: for opening it from Recordings. */
    fun fileOf(scheduleId: String): String? = deps.executor.items.value.firstOrNull { it.id == scheduleId }?.file

    /** The authorized feeds of the event that can offer Start Over (the programme is on now) and Catch-Up (it is over), best first. Only what the provider declares; nothing is requested. */
    suspend fun archiveOptions(event: SportsEvent, nowMs: Long): Pair<List<String>, List<String>> {
        val allowed = SportsAuthorizer.authorizedFeeds(deps, event, deps.activeProfile.value)
        val order = SportsFeedRanker.rank(allowed.map { it.first }, deps.rankInput(event.id)).map { it.feed.channelId }
        val startOver = ArrayList<String>(); val catchUp = ArrayList<String>()
        for (id in order) {
            val ch = allowed.first { it.first.channelId == id }.second; val feed = allowed.first { it.first.channelId == id }.first
            if (ch.catchupDays <= 0 || !deps.isXtream(ch.sourceId)) continue
            val p = deps.programme(ch, feed.programmeStartMs) ?: continue                              // the channel's own programme, or no archive is offered
            val offset = deps.epgOffsetMs()
            if (SportsArchive.canStartOver(true, ch.catchupDays, p.first + offset, p.second + offset, nowMs)) startOver += id
            if (SportsArchive.canWatchCatchUp(true, ch.catchupDays, p.first + offset, p.second + offset, nowMs)) catchUp += id
        }
        return startOver to catchUp
    }

    /** Plays the programme from its start (or the archived programme) through the normal catch-up playback, after checking that channel and the offer again right now. False if either no longer holds. */
    suspend fun playArchive(event: SportsEvent, channelId: String, startOver: Boolean, onResult: (app.streamsetu.tv.PlayStart) -> Unit): Boolean {
        val owner = deps.activeProfile.value; val now = deps.nowMs()
        val feed = event.feeds.firstOrNull { it.channelId == channelId } ?: return false
        val ch = deps.channel(channelId) ?: return false
        if (ch.sourceId != feed.sourceId || SportsAuthorizer.refusal(deps, ch, owner) != null || deps.activeProfile.value != owner) return false
        val offered = archiveOptions(event, now).let { if (startOver) it.first else it.second }
        if (channelId !in offered) return false
        val p = deps.programme(ch, feed.programmeStartMs) ?: return false
        deps.playArchive(ch, event.title, p.first, p.second, onResult)
        return true
    }

    // ---- when the alarm is due

    /**
     * Read at the moment a Sports recording is due, by its schedule id and nothing else. Refuses a recording that is missing, cancelled, finished, waiting for review, made under another profile, or whose
     * times no longer agree with the row. Returns null if it may go on to the shared checks.
     */
    suspend fun executionCheck(rec: ScheduledRec): RecordingFailure? {
        val r = dao.recordingBySchedule(rec.id) ?: return RecordingFailure.UNAUTHORIZED
        if (r.profileId != deps.activeProfile.value) return RecordingFailure.PROFILE_CHANGED
        if (r.status == SportsRecordingStatus.REVIEW_REQUIRED.name) return RecordingFailure.REVIEW_REQUIRED
        if (r.status != SportsRecordingStatus.SCHEDULED.name && r.status != SportsRecordingStatus.RECORDING.name) return RecordingFailure.UNAUTHORIZED
        if (r.startMs != rec.startMs || r.endMs != rec.endMs) return RecordingFailure.REVIEW_REQUIRED
        return null
    }

    /** If the chosen channel has become unusable before the recording starts, another authorized, recordable feed of the same event may be used; nothing else is changed. */
    suspend fun alternateChannel(rec: ScheduledRec, failed: String, nowMs: Long): Channel? {
        val r = dao.recordingBySchedule(rec.id) ?: return null
        val events = runCatching { deps.events(nowMs - 4 * 3_600_000L, nowMs + 72 * 3_600_000L) }.getOrDefault(emptyList())
        val match = ReminderMatcher.associate(listOf(SportsEventReminder(r.id, r.identity, r.competitionKey, r.startMs, r.siblings, r.distinguishing.split(',').filter { it.isNotEmpty() }.toSet())), events, nowMs + 80 * 3_600_000L).single() as? Association.Matched ?: return null
        val allowed = SportsAuthorizer.authorizedFeeds(deps, match.event, deps.activeProfile.value).filter { it.first.channelId != failed && deps.format(it.second) != RecordableFormat.HLS }
        val ranked = SportsFeedRanker.rank(allowed.map { it.first }, deps.rankInput(match.event.id))
        return ranked.firstOrNull()?.let { r0 -> allowed.first { it.first.channelId == r0.feed.channelId }.second }
    }

    private fun report(outcome: String, p: RecordingPreview, startedNs: Long) =
        diagnostics.record(RecordingReport(outcome, p.issues, 0, 0, p.feeds.size, p.feeds.count { it.recordable }, (System.nanoTime() - startedNs) / 1_000_000))

    companion object { const val ORIGIN = "sports" }
}
