package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventState
import app.streamsetu.tv.sports.personal.FollowKind
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.sports.personal.SportsKeys
import app.streamsetu.tv.sports.recording.SportsRecordingStatus
import app.streamsetu.tv.ui.screens.sports.SportsEventCard
import app.streamsetu.tv.ui.screens.sports.SportsSections
import java.util.TimeZone

enum class PageKind { TEAM, COMPETITION }

/** Which team or competition a page is about: the strict identity (see [SportsIdentity]) and the name it was found under. Nothing else. */
data class PageRef(val kind: PageKind, val sport: Sport, val key: String, val name: String)

/** One section of a page or of My Sports: a title and its cards. [id] is fixed text used for tags and focus. */
class PageSectionUi(val id: String, val title: String, val cards: List<SportsEventCard>)

/** A recording shown on a page. [eventId] is set when the recording is tied to an event in the guide. */
class PageRecordingUi(val id: String, val line: String, val status: SportsRecordingStatus, val playId: String?, val eventId: String?)

class SportsPageUi(
    val ref: PageRef, val sportLabel: String,
    val following: Boolean, val canFollow: Boolean,
    /** "Names may refer to different teams", "Choose the team in Manage My Sports", or null. */
    val note: String?,
    val sections: List<PageSectionUi>,
    val recordings: List<PageRecordingUi>,
    val reminderCount: Int, val channelCount: Int,
    val catchUpLoading: Boolean,
) {
    val isEmpty: Boolean get() = sections.all { it.cards.isEmpty() } && recordings.isEmpty()
    val allCardIds: List<String> get() = sections.flatMap { s -> s.cards.map { it.id } }
}

/** My Sports as ordered sections, each event once, plus recordings whose event is no longer in the guide. */
class MyBoardUi(val sections: List<PageSectionUi>, val recordings: List<PageRecordingUi>) {
    val isEmpty: Boolean get() = sections.all { it.cards.isEmpty() } && recordings.isEmpty()
}

/**
 * Builds Team pages, Competition pages and the My Sports board from what is already loaded. Pure: no database, no clock, no UI, no provider. Everything that varies (marks on a card, the file a
 * recording plays) is passed in, so the builders can be run and tested on a large guide without a screen.
 */
object SportsPages {
    private const val MAX_RECORDINGS = 30

    class Env(
        val events: List<SportsEvent>, val history: List<SportsEvent>, val nowMs: Long, val zone: TimeZone, val index: IdentityIndex, val follows: FollowSet,
        val recordings: RecordingIndex, val remindedEventKeys: Set<String>,
        val decorate: (SportsEvent, SportsEventCard) -> SportsEventCard,
        val playIdOf: (SportsRecordingEntity) -> String?, val clock: (Long) -> String,
        val labels: SportsSections.Labels,
    )

    /** The events a page is about. A key that is ambiguous matches nothing: a candidate's events are never combined under the shared name. */
    fun eventsFor(ref: PageRef, events: List<SportsEvent>, index: IdentityIndex): List<SportsEvent> = events.filter { e ->
        e.sport == ref.sport && when (ref.kind) { PageKind.TEAM -> ref.key in index.participants(e); PageKind.COMPETITION -> index.competition(e) == ref.key }
    }

    fun eventKey(e: SportsEvent) = SportsKeys.identity(e) + "#" + SportsKeys.slot(e.startMs)

    private fun card(e: SportsEvent, env: Env, ended: Boolean = false): SportsEventCard {
        val c = SportsSections.card(e, env.nowMs, env.labels).let { if (ended) it.copy(statusLabel = "Ended", live = false) else it }
        return env.decorate(e, c)
    }

    /** One card per underlying event: the same sides in the same half hour listed twice (two playlists) are one. */
    private fun distinct(list: List<SportsEvent>): List<SportsEvent> { val seen = HashSet<String>(); return list.filter { seen.add(eventKey(it)) } }

    fun page(ref: PageRef, env: Env, catchUpLoading: Boolean): SportsPageUi {
        val now = env.nowMs
        val mine = distinct(eventsFor(ref, env.events, env.index).filter { it.endMs > now }.sortedWith(compareBy({ it.startMs }, { it.title }, { it.id })))
        val live = mine.filter { it.state(now) == SportsEventState.LIVE }
        val rest = mine.filter { it.state(now) != SportsEventState.LIVE }
        val soon = rest.filter { it.startMs <= now + SportsSections.SOON_MS }
        val later = rest.filter { it.startMs > now + SportsSections.SOON_MS }
        val sections = ArrayList<PageSectionUi>()
        fun add(id: String, title: String, l: List<SportsEvent>, ended: Boolean = false) { if (l.isNotEmpty()) sections += PageSectionUi(id, title, l.map { card(it, env, ended) }) }
        add("LIVE_NOW", "Live Now", live)
        add("STARTING_SOON", "Starting Soon", soon)
        if (ref.kind == PageKind.TEAM) add("UPCOMING", "Upcoming", later)
        else {
            val dayEnd = SportsSections.endOfLocalDay(now, env.zone)
            add("TODAY", "Today", later.filter { it.startMs < dayEnd })
            for ((label, l) in groupByDay(later.filter { it.startMs >= dayEnd }, env.zone)) add("DAY_$label", label, l)
        }
        val seenIds = mine.map { it.id }.toSet()
        val caught = distinct(eventsFor(ref, env.history, env.index).filter { it.endMs <= now && it.id !in seenIds && it.feeds.any { f -> f.catchUp } }.sortedWith(compareBy({ -it.startMs }, { it.id })))
        add("CATCH_UP", "Catch-Up", caught.take(20), ended = true)

        val shownEvents = mine + caught
        val status = env.follows.follows.firstOrNull { it.kind == (if (ref.kind == PageKind.TEAM) FollowKind.PARTICIPANT else FollowKind.COMPETITION) && it.sport == ref.sport && it.key == ref.key }
        val ambiguous = env.index.isAmbiguous(ref.key)
        val scoped = SportsIdentity.isScoped(ref.key)
        val note = when {
            ambiguous -> "More than one team or competition has this name. Choose one in Manage My Sports."
            scoped -> "This name is also used by another playlist, and nothing shows they are the same. They are kept apart."
            else -> null
        }
        return SportsPageUi(
            ref, ref.sport.title, status != null && !ambiguous, canFollow = !ambiguous, note = note, sections = sections,
            recordings = recordingsFor(ref, shownEvents, env),
            reminderCount = shownEvents.count { eventKey(it) in env.remindedEventKeys },
            channelCount = mine.flatMap { e -> e.feeds.map { it.channelId } }.toSet().size,
            catchUpLoading = catchUpLoading,
        )
    }

    private fun groupByDay(l: List<SportsEvent>, zone: TimeZone): List<Pair<String, List<SportsEvent>>> {
        val fmt = java.text.SimpleDateFormat("EEE d MMM", java.util.Locale.getDefault()).also { it.timeZone = zone }
        val out = LinkedHashMap<String, MutableList<SportsEvent>>()          // l is in time order, so the days come in order
        for (e in l) out.getOrPut(fmt.format(java.util.Date(e.startMs))) { ArrayList() }.add(e)
        return out.map { it.key to it.value }
    }

    private fun recordingLine(r: SportsRecordingEntity, env: Env) = when (SportsRecordingStatus.valueOf(r.status)) {
        SportsRecordingStatus.SCHEDULED -> "Recording scheduled · " + env.clock(r.startMs)
        SportsRecordingStatus.RECORDING -> "Recording now"
        SportsRecordingStatus.COMPLETED -> "Recorded · " + env.clock(r.startMs)
        SportsRecordingStatus.FAILED -> "Recording failed · " + env.clock(r.startMs)
        SportsRecordingStatus.REVIEW_REQUIRED -> "Schedule changed — review required"
        SportsRecordingStatus.CANCELLED -> ""
    }

    private fun recordingsFor(ref: PageRef, events: List<SportsEvent>, env: Env): List<PageRecordingUi> {
        val byEvent = HashMap<String, SportsRecordingEntity>()
        for (e in events) env.recordings.forEvent(e)?.let { byEvent[it.id] = it }
        // A recording whose event has left the guide belongs here only when the name leaves no doubt: exactly one identity fits the key it was made under.
        val legacyKind = if (ref.kind == PageKind.TEAM) FollowKind.PARTICIPANT else FollowKind.COMPETITION
        for (r in env.recordings.rows) {
            if (r.id in byEvent || r.sport != ref.sport.name || r.status == SportsRecordingStatus.CANCELLED.name) continue
            val keys = if (ref.kind == PageKind.TEAM) r.participantsKey.split('|').filter { it.isNotEmpty() } else listOfNotNull(r.competitionKey)
            val fits = keys.any { k -> env.index.legacyCandidates(legacyKind, ref.sport, k).singleOrNull() == ref.key }
            if (fits) byEvent[r.id] = r
        }
        return byEvent.values.sortedWith(compareBy({ if (RecordingIndex.isOpen(it)) 0 else 1 }, { -it.startMs }, { it.id })).take(MAX_RECORDINGS).map { toUi(it, env) }
    }

    private fun toUi(r: SportsRecordingEntity, env: Env) = PageRecordingUi(r.id, recordingLine(r, env), SportsRecordingStatus.valueOf(r.status), env.playIdOf(r), r.matchedEventId)

    /**
     * My Sports, in this order: live followed events, followed events starting soon, recordings running, recordings scheduled, reminders, the rest of what is followed, recent Catch-Up for what is
     * followed. An event appears once, in the highest section that applies, with all its marks. A recording or a reminder is the person's own, so it is listed whether or not its sides are followed.
     */
    fun board(env: Env): MyBoardUi {
        val now = env.nowMs
        val seen = HashSet<String>()
        val sections = ArrayList<PageSectionUi>()
        val ordered = distinct(env.events.filter { it.endMs > now }.sortedWith(compareBy({ it.startMs }, { it.title }, { it.id })))
        fun take(id: String, title: String, pred: (SportsEvent) -> Boolean, source: List<SportsEvent> = ordered, ended: Boolean = false) {
            val l = source.filter { pred(it) && seen.add(eventKey(it)) }
            if (l.isNotEmpty()) sections += PageSectionUi(id, title, l.map { e -> card(e, env, ended).copy(reason = env.follows.reason(e)?.let { "Because you follow ${it.displayName}" }) })
        }
        val followed = { e: SportsEvent -> env.follows.matches(e) }
        fun live(e: SportsEvent) = e.state(now) == SportsEventState.LIVE
        fun soon(e: SportsEvent) = !live(e) && e.startMs <= now + SportsSections.SOON_MS
        fun status(e: SportsEvent) = env.recordings.forEvent(e)?.status
        take("LIVE_NOW", "Live Now", { live(it) && followed(it) })
        take("STARTING_SOON", "Starting Soon", { soon(it) && followed(it) })
        take("RECORDING_NOW", "Recording Now", { status(it) == SportsRecordingStatus.RECORDING.name })
        take("RECORDING_SCHEDULED", "Scheduled Recordings", { status(it) == SportsRecordingStatus.SCHEDULED.name || status(it) == SportsRecordingStatus.REVIEW_REQUIRED.name })
        take("REMINDERS", "Reminders", { eventKey(it) in env.remindedEventKeys })
        take("UPCOMING", "Upcoming", { followed(it) })
        val caught = distinct(env.history.filter { it.endMs <= now && followed(it) && it.feeds.any { f -> f.catchUp } }.sortedWith(compareBy({ -it.startMs }, { it.id }))).take(20)
        take("CATCH_UP", "Recent Catch-Up", { true }, caught, ended = true)
        // Recordings whose event is not in the guide any more stay reachable here.
        val inGuide = env.events.mapNotNull { env.recordings.forEvent(it)?.id }.toSet()
        val orphans = env.recordings.rows.filter { it.id !in inGuide && it.status != SportsRecordingStatus.CANCELLED.name && (RecordingIndex.isOpen(it) || it.status == SportsRecordingStatus.COMPLETED.name) }
            .sortedWith(compareBy({ if (RecordingIndex.isOpen(it)) 0 else 1 }, { -it.startMs }, { it.id })).take(MAX_RECORDINGS).map { toUi(it, env) }
        return MyBoardUi(sections, orphans)
    }
}
