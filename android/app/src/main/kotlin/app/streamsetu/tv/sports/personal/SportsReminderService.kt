package app.streamsetu.tv.sports.personal

import app.streamsetu.core.data.db.SportsDao
import app.streamsetu.core.data.db.SportsReminderEntity
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.sports.SportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorizer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Sets or cancels the system alarm for one reminder. Arming the same id again replaces it, so scheduling is idempotent. */
interface ReminderScheduler {
    fun arm(id: String, atMs: Long)
    fun cancel(id: String)
}

/** The notification side. [post] is only ever called with the current title of an event that is matched and allowed; there is no general notice. */
interface ReminderNotifier {
    fun permission(): NotificationState
    /** Asks the system for the notification permission (only ever called from the first reminder that needs it). */
    fun requestPermission()
    fun post(id: String, title: String, startMs: Long): Boolean
    fun cancel(id: String)
}

/** What the reminders need from the rest of the app. */
interface ReminderDeps : SportsAuthorization {
    val activeProfile: StateFlow<String>
    fun nowMs(): Long
    /** The events of the guide as it is now, for what this profile may see. Slow: only ever called off the main thread. */
    suspend fun events(fromMs: Long, toMs: Long): List<SportsEvent>
    val scheduler: ReminderScheduler
    val notifier: ReminderNotifier
}

sealed interface CreateResult {
    data class Created(val id: String, val permission: NotificationState) : CreateResult
    /** The same event already has this reminder. */
    data class Exists(val id: String) : CreateResult
    /** The event is not (or no longer) one this profile may see. */
    data object Refused : CreateResult
}

/** The banner shown while StreamSetu is open. Held in memory only; [title] is null when nothing may be named. */
data class ReminderBanner(val id: String, val title: String?, val startMs: Long)

/**
 * The reminders the active profile asked for. They are durable records of normalized facts; this finds the event each is for in the current guide, keeps its alarm in step with that event's time, and
 * announces it once. It never starts playback and never stores an address.
 *
 *  - Association: batch, off the main thread, by [ReminderMatcher]. A reminder with no safe match stays pending and keeps its schedule; an event that comes back is found again.
 *  - Alarms: one per reminder, for the active profile only, set again after a reboot, an app update or a time change.
 *  - Announcing: the event is checked again first (profile, library, locks, filters, hidden channels, connections). No restricted title is ever shown; the notice says only that a reminder is due.
 */
class SportsReminderService(
    private val dao: SportsDao,
    private val deps: ReminderDeps,
    private val scope: CoroutineScope,
    private val diagnostics: PersonalDiagnostics = PersonalDiagnostics.Log,
) {
    private val mutex = Mutex()
    private val _banner = MutableStateFlow<ReminderBanner?>(null)
    val banner: StateFlow<ReminderBanner?> = _banner.asStateFlow()
    @Volatile private var titles: Map<String, String> = emptyMap()          // matched temporary id -> title, in memory only
    @Volatile private var generation = 0
    private var ticker: Job? = null
    @Volatile private var active: List<SportsReminderEntity> = emptyList()
    /** What is armed right now, by reminder id: an alarm already set for the same time is not set again (a refresh that changes nothing does no scheduling work). Cleared when the system may have lost the alarms. */
    private val armed = HashMap<String, Long>()

    /** The active profile's reminders; switches with the profile. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val reminders: Flow<List<SportsReminderEntity>> = deps.activeProfile.flatMapLatest { dao.remindersFlow(it) }

    /** The ids of the events with a reminder right now, for ordering and the "reminded" mark. */
    fun remindedEventIds(rows: List<SportsReminderEntity>): Set<String> = rows.filter { it.status == ReminderStatus.SCHEDULED.name }.mapNotNull { it.matchedEventId }.toSet()

    /** One reminder of the active profile, or null (another profile's reminder is never handed out here). */
    suspend fun get(id: String): SportsReminderEntity? = dao.reminder(id)?.takeIf { it.profileId == deps.activeProfile.value }

    // ---- making, changing, removing

    /** [guide] is the events as they are now, so a doubleheader can be recognised: which of the same sides' fixtures this is, and how many there are. */
    suspend fun create(event: SportsEvent, leadMs: Long = ReminderLeads.DEFAULT_MS, guide: List<SportsEvent> = listOf(event)): CreateResult = mutex.withLock {
        val owner = deps.activeProfile.value
        if (SportsAuthorizer.authorizedFeeds(deps, event, owner).isEmpty() || deps.activeProfile.value != owner) return CreateResult.Refused
        val identity = SportsKeys.identity(event); val slot = SportsKeys.slot(event.startMs)
        dao.reminders(owner).firstOrNull { it.identity == identity && it.slot == slot }?.let { return CreateResult.Exists(it.id) }
        val siblings = (guide.filter { it.id != event.id && SportsKeys.identity(it) == identity && kotlin.math.abs(it.startMs - event.startMs) <= ReminderMatcher.TOLERANCE_MS } + event).sortedWith(compareBy({ it.startMs }, { it.id }))
        var permission = deps.notifier.permission()
        if (permission == NotificationState.NOT_ASKED) { deps.notifier.requestPermission(); permission = deps.notifier.permission() }          // asked once, at the first reminder
        val now = deps.nowMs()
        val r = SportsReminderEntity(
            id = java.util.UUID.randomUUID().toString(), profileId = owner, sport = event.sport.name, identity = identity, competitionKey = SportsKeys.competition(event), participantsKey = SportsKeys.participantsKey(event),
            startMs = event.startMs, endMs = event.endMs, leadMs = leadMs, slot = slot, siblings = siblings.size, distinguishing = distinguishing(event, siblings.filter { it.id != event.id }), matchedEventId = event.id, candidateChannelIds = candidates(event), status = ReminderStatus.SCHEDULED.name,
            notifiedAt = 0, bannerAt = 0, kept = false, createdAt = now, updatedAt = now,
        )
        if (dao.insertReminder(r) == -1L) return CreateResult.Exists(r.id)
        titles = titles + (event.id to event.title)
        apply(listOf(r), now)
        refresh(owner)
        CreateResult.Created(r.id, permission)
    }

    suspend fun change(id: String, leadMs: Long) = mutex.withLock {
        val r = dao.reminder(id) ?: return
        val now = deps.nowMs()
        val moved = r.copy(leadMs = leadMs, notifiedAt = if (ReminderTiming.fireAt(r.startMs, leadMs) > now) 0 else r.notifiedAt, bannerAt = if (ReminderTiming.fireAt(r.startMs, leadMs) > now) 0 else r.bannerAt,
            status = if (r.status == ReminderStatus.FIRED.name || r.status == ReminderStatus.MISSED.name) ReminderStatus.SCHEDULED.name else r.status, updatedAt = now)
        dao.updateReminders(listOf(moved)); apply(listOf(moved), now); refresh(moved.profileId)
    }

    suspend fun remove(id: String) = mutex.withLock {
        val r = dao.reminder(id)
        dao.deleteReminder(id); armed.remove(id); deps.scheduler.cancel(id); deps.notifier.cancel(id)
        if (_banner.value?.id == id) _banner.value = null
        r?.let { refresh(it.profileId) }
    }

    /** "Keep Reminder" on an event that left the guide: it stays pending and is not asked about again. */
    suspend fun keep(id: String) = mutex.withLock { dao.reminder(id)?.let { dao.updateReminders(listOf(it.copy(kept = true, updatedAt = deps.nowMs()))); refresh(it.profileId) } }

    // ---- association

    /**
     * After a guide refresh (or whenever the events were rebuilt): finds the event of every pending reminder of the active profile in one pass, and updates the matching alarms. A result from before a
     * profile change is dropped.
     */
    suspend fun reassociate(events: List<SportsEvent>): Int = mutex.withLock {
        val owner = deps.activeProfile.value; val gen = generation
        val started = System.nanoTime()
        val now = deps.nowMs()
        val rows = dao.reminders(owner).filter { it.status in PENDING && it.endMs > now - ReminderMatcher.TOLERANCE_MS }
        if (rows.isEmpty()) return 0
        val windowEnd = (events.maxOfOrNull { it.startMs } ?: now) + ReminderMatcher.TOLERANCE_MS
        val outcome = ReminderMatcher.associate(rows.map { it.forMatching() }, events, windowEnd)
        if (deps.activeProfile.value != owner || gen != generation) return 0
        val byId = rows.associateBy { it.id }
        val updates = ArrayList<SportsReminderEntity>(); var matched = 0
        val newTitles = HashMap(titles)
        for (a in outcome) {
            val r = byId[a.reminderId] ?: continue
            when (a) {
                is Association.Matched -> {
                    val e = a.event; matched++
                    newTitles[e.id] = e.title
                    updates += r.copy(startMs = e.startMs, endMs = e.endMs, matchedEventId = e.id, candidateChannelIds = candidates(e), distinguishing = distinguishing(e, events.filter { it.id != e.id && SportsKeys.identity(it) == SportsKeys.identity(e) && kotlin.math.abs(it.startMs - e.startMs) <= ReminderMatcher.TOLERANCE_MS }), status = ReminderStatus.SCHEDULED.name, kept = false, updatedAt = now)
                }
                is Association.Unmatched -> updates += r.copy(matchedEventId = null, candidateChannelIds = "", status = ReminderStatus.UNMATCHED.name, updatedAt = now)
                is Association.Ambiguous -> updates += r.copy(matchedEventId = null, candidateChannelIds = "", status = ReminderStatus.AMBIGUOUS.name, updatedAt = now)
                is Association.NotYet -> {}
            }
        }
        titles = newTitles.filterKeys { k -> events.any { it.id == k } }
        val changed = updates.filter { it != byId[it.id] }
        if (changed.isNotEmpty()) dao.updateReminders(changed)
        apply(updates, now)
        refresh(owner)
        val all = dao.reminders(owner)
        diagnostics.record(PersonalReport(0, 0, 0, all.count { it.status == "SCHEDULED" }, all.count { it.status == "UNMATCHED" }, all.count { it.status == "AMBIGUOUS" }, all.count { it.status == "FIRED" || it.status == "ENDED" || it.status == "MISSED" }, matched, (System.nanoTime() - started) / 1_000_000, null, null))
        matched
    }

    /** The channels that carry this fixture and none of the others close to it: what tells a doubleheader apart when the order cannot be trusted. */
    private fun distinguishing(e: SportsEvent, others: List<SportsEvent>): String =
        (e.feeds.map { it.channelId }.toSet() - others.flatMap { o -> o.feeds.map { it.channelId } }.toSet()).sorted().take(8).joinToString(",")

    private fun candidates(e: SportsEvent) = e.feeds.map { it.channelId }.distinct().take(8).joinToString(",")

    /** Sets, replaces or cancels the alarm for each reminder according to its plan. A reminder due now is announced once. */
    private fun arm(id: String, atMs: Long) { if (armed[id] != atMs) { armed[id] = atMs; deps.scheduler.arm(id, atMs); diagnostics.record(outcomeReport(ScheduleOutcome.ARMED)) } }
    private fun disarm(id: String) { if (armed.remove(id) != null) { deps.scheduler.cancel(id); diagnostics.record(outcomeReport(ScheduleOutcome.CANCELLED)) } }

    private suspend fun apply(list: List<SportsReminderEntity>, now: Long) {
        for (r in list) {
            if (r.profileId != deps.activeProfile.value) { disarm(r.id); continue }
            when (val p = ReminderTiming.plan(r.startMs, r.endMs, r.leadMs, r.notifiedAt, now)) {
                is ReminderPlan.Arm -> arm(r.id, p.atMs)
                ReminderPlan.NotifyNow -> { disarm(r.id); announce(r, now) }
                is ReminderPlan.Done -> {
                    disarm(r.id)
                    // A reminder with no current match is kept for a later refresh until its event is over; only a matched one is marked fired or missed.
                    val keep = r.status != ReminderStatus.SCHEDULED.name && p.status != ReminderStatus.ENDED
                    if (!keep && (r.status in PENDING)) dao.updateReminders(listOf(r.copy(status = p.status.name, updatedAt = now)))
                }
            }
        }
    }

    // ---- announcing

    /** The alarm for [id] went off (the app may have been closed). The event is found afresh and checked again before anything is shown. */
    suspend fun fire(id: String): Boolean {
        val r0 = dao.reminder(id) ?: run { deps.scheduler.cancel(id); return false }
        if (r0.profileId != deps.activeProfile.value) return false                       // another profile's reminder: never shown here
        val before = r0.notifiedAt
        val now = deps.nowMs()
        val events = runCatching { deps.events(now - 4 * 3_600_000L, now + 72 * 3_600_000L) }.getOrDefault(emptyList())
        reassociate(events)                                                              // the association itself announces a reminder that is due, once
        return mutex.withLock {
            val r = dao.reminder(id) ?: return false
            when (val p = ReminderTiming.plan(r.startMs, r.endMs, r.leadMs, r.notifiedAt, now)) {
                is ReminderPlan.Arm -> arm(r.id, p.atMs)                                  // the event moved later: it will be announced then
                ReminderPlan.NotifyNow -> announce(r, now)
                is ReminderPlan.Done -> dao.updateReminders(listOf(r.copy(status = p.status.name, updatedAt = now)))
            }
            before == 0L && (dao.reminder(id)?.notifiedAt ?: 0L) > 0L                      // true only when this delivery was the one that announced it
        }
    }

    /**
     * Announces a reminder that is due. Only an event that is matched in the guide right now, with at least one channel this profile may still use, is announced, and by its current title. A reminder
     * with no safe current match (unmatched, ambiguous) or whose channels are all restricted shows nothing at all, not even a general notice: it stays as it is for a later refresh.
     */
    private suspend fun announce(r: SportsReminderEntity, now: Long) {
        val title = r.matchedEventId?.let { titles[it] }
        if (r.status != ReminderStatus.SCHEDULED.name || title == null || !allowed(r)) return
        val shown = deps.notifier.post(r.id, title, r.startMs)
        diagnostics.record(outcomeReport(if (shown) ScheduleOutcome.NOTIFIED else ScheduleOutcome.FAILED, deps.notifier.permission()))
        dao.updateReminders(listOf(r.copy(notifiedAt = now, status = ReminderStatus.FIRED.name, updatedAt = now)))
    }

    /** At least one of the event's channels passes every check right now. */
    private suspend fun allowed(r: SportsReminderEntity): Boolean {
        val owner = deps.activeProfile.value
        for (id in r.candidateChannelIds.split(',').filter { it.isNotEmpty() }) {
            val ch = deps.channel(id) ?: continue
            if (SportsAuthorizer.refusal(deps, ch, owner) == null) return true
        }
        return false
    }

    // ---- the banner while the app is open

    /** Starts the minute check. It reads the reminders already in memory; it never queries per tick. */
    fun start() {
        if (ticker != null) return
        scope.launch { rescheduleAll() }                                                  // alarms follow the active profile from the moment the app is up (also after a clock change)
        scope.launch { reminders.collect { rows -> active = rows; evaluate() } }
        ticker = scope.launch { while (true) { val now = deps.nowMs(); delay(60_000L - now % 60_000L); evaluate() } }
    }

    /** Looks for a reminder that is due and shows its banner, checking first that the event is still one this profile may see. */
    suspend fun evaluate() {
        val now = deps.nowMs(); val owner = deps.activeProfile.value
        val due = active.filter { it.profileId == owner && it.status == ReminderStatus.SCHEDULED.name && it.bannerAt == 0L && ReminderTiming.fireAt(it.startMs, it.leadMs) <= now && now < it.startMs }.minByOrNull { it.startMs }
        if (due == null) { _banner.value = null; return }
        if (!allowed(due)) { _banner.value = null; return }                               // nothing restricted is ever named
        _banner.value = ReminderBanner(due.id, due.matchedEventId?.let { titles[it] }, due.startMs)
    }

    /** The banner was dismissed or opened: it is not shown again. */
    suspend fun bannerDone(id: String) {
        dao.reminder(id)?.let { dao.updateReminders(listOf(it.copy(bannerAt = deps.nowMs()))); refresh(it.profileId) }
        if (_banner.value?.id == id) _banner.value = null
    }

    // ---- who may see what

    /** The profile, library, locks, filters, hidden channels or connections changed: a shown banner goes at once, work in flight is dropped, and the alarms follow the active profile. */
    fun securityChanged() {
        generation++; _banner.value = null; titles = emptyMap()
        scope.launch { rescheduleAll(); evaluate() }
    }

    /** Sets again the alarms of the active profile's pending reminders, and cancels everyone else's (after a reboot, an update, a time change, or a profile switch). */
    suspend fun rescheduleAll() = mutex.withLock {
        val now = deps.nowMs(); val owner = deps.activeProfile.value
        armed.clear()                                                                      // after a restart, an update or a time change the system may have dropped them: all are set again
        for (r in dao.activeReminders(now)) {
            if (r.profileId != owner) { deps.scheduler.cancel(r.id); continue }
            apply(listOf(r), now)
        }
    }

    private suspend fun refresh(owner: String) { if (owner == deps.activeProfile.value) active = dao.reminders(owner); }

    private fun outcomeReport(o: ScheduleOutcome, p: NotificationState? = null) = PersonalReport(0, 0, 0, 0, 0, 0, 0, 0, 0, o, p)

    companion object { val PENDING = setOf(ReminderStatus.SCHEDULED.name, ReminderStatus.UNMATCHED.name, ReminderStatus.AMBIGUOUS.name) }
}
