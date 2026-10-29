package app.streamsetu.tv.ui.screens.sports

import androidx.compose.runtime.Immutable
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventState
import java.util.Calendar
import java.util.TimeZone

/** The four sections of the Sports Hub. */
enum class SportsSection(val title: String) { LIVE_NOW("Live Now"), STARTING_SOON("Starting Soon"), TODAY("Today's Schedule"), UPCOMING("Upcoming") }

/** One card: one event, however many channels carry it. Everything the card shows is here, already worked out; the screen only draws it. */
@Immutable
data class SportsEventCard(
    /** The inferred event id (stable for the same event across guide refreshes). Used as the list key and for focus restoration. */
    val id: String,
    val title: String,
    val sport: Sport,
    val sportLabel: String,
    val competition: String?,
    val startMs: Long,
    val endMs: Long,
    val live: Boolean,
    val feedCount: Int,
    val logoUrl: String?,
    val catchUp: Boolean,
    /** "21:00" for an event today, "Sat 21:00" for a later day: in the person's own time zone, worked out with the state. */
    val timeLabel: String,
    /** "LIVE", "Starts in 45 min" or "Upcoming". */
    val statusLabel: String,
)

/** All Sports (null) or one sport that currently has events. */
@Immutable
data class SportsFilter(val sport: Sport?, val label: String, val count: Int)

/** A value shown to the person, and whether it was read out of a title or a channel name rather than supplied by the provider. */
@Immutable
data class SportsLabelled(val text: String, val inferred: Boolean)

@Immutable
data class SportsFeedRow(val channelName: String, val sourceName: String, val language: SportsLabelled?, val quality: SportsLabelled?, val catchUp: Boolean)

@Immutable
data class SportsEventDetail(
    val card: SportsEventCard,
    val stateLabel: String,
    /** "Sat 21:00 – 23:00". */
    val timeRange: String,
    val feeds: List<SportsFeedRow>,
    /** True when the rules were less sure this is a real event of this sport. */
    val lowConfidence: Boolean,
)

/** What the screen says when it has no events to show. */
sealed interface SportsHubMessage {
    data class Error(val text: String) : SportsHubMessage
    /** No guide has been read for the open library. */
    data object NoGuide : SportsHubMessage
    /** A guide exists, but nothing in it is a sports event. */
    data object NoSports : SportsHubMessage
}

/** Everything the Sports Hub draws, as one immutable value. Built off the main thread; the composables never compute or query. */
@Immutable
data class SportsHubUiState(
    /** First load, nothing to show yet: the skeleton. */
    val loading: Boolean = true,
    /** A refresh is running while the old content stays on screen. */
    val refreshing: Boolean = false,
    val selectedSport: Sport? = null,
    val filters: List<SportsFilter> = emptyList(),
    val live: List<SportsEventCard> = emptyList(),
    val startingSoon: List<SportsEventCard> = emptyList(),
    val today: List<SportsEventCard> = emptyList(),
    val upcoming: List<SportsEventCard> = emptyList(),
    val detail: SportsEventDetail? = null,
    val message: SportsHubMessage? = null,
    /** The guide revision the events were built from. */
    val revision: String = "",
    /** The time the sections were worked out for. */
    val nowMs: Long = 0,
) {
    val isEmpty: Boolean get() = live.isEmpty() && startingSoon.isEmpty() && today.isEmpty() && upcoming.isEmpty()
    fun section(s: SportsSection): List<SportsEventCard> = when (s) { SportsSection.LIVE_NOW -> live; SportsSection.STARTING_SOON -> startingSoon; SportsSection.TODAY -> today; SportsSection.UPCOMING -> upcoming }
    /** The sections that have events, in order. Only these are shown. */
    val sections: List<SportsSection> get() = SportsSection.values().filter { section(it).isNotEmpty() }
}

/** Works out the sections, filters and detail from the loaded events. Pure: no database, no clock, no UI. */
object SportsSections {
    const val SOON_MS = 2 * 3_600_000L
    const val LOW_CONFIDENCE = 0.75

    class Result(val live: List<SportsEventCard>, val soon: List<SportsEventCard>, val today: List<SportsEventCard>, val upcoming: List<SportsEventCard>, val filters: List<SportsFilter>, val selected: Sport?, val detail: SportsEventDetail?)

    /** Turns instants into the words on a card, in one time zone and locale. Made once per state, never inside a composable. */
    class Labels(private val zone: TimeZone, private val locale: java.util.Locale, private val nowMs: Long) {
        private val clock = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT, locale).also { it.timeZone = zone }
        private val day = java.text.SimpleDateFormat("EEE", locale).also { it.timeZone = zone }
        private val dayEnd = endOfLocalDay(nowMs, zone)
        fun time(ms: Long): String = if (ms < dayEnd) clock.format(java.util.Date(ms)) else day.format(java.util.Date(ms)) + " " + clock.format(java.util.Date(ms))
        fun status(e: SportsEvent): String = when {
            nowMs >= e.startMs && nowMs < e.endMs -> "LIVE"
            e.startMs - nowMs in 1..SOON_MS -> "Starts in ${maxOf(1, (e.startMs - nowMs + 59_999) / 60_000)} min"
            else -> "Upcoming"
        }
        fun range(e: SportsEvent) = time(e.startMs) + " – " + clock.format(java.util.Date(e.endMs))
    }

    fun card(e: SportsEvent, nowMs: Long, labels: Labels) = SportsEventCard(
        id = e.id, title = e.title, sport = e.sport, sportLabel = e.sport.title, competition = e.competition, startMs = e.startMs, endMs = e.endMs,
        live = nowMs >= e.startMs && nowMs < e.endMs, feedCount = e.feeds.size, logoUrl = e.feeds.firstNotNullOfOrNull { it.logoUrl }, catchUp = e.feeds.any { it.catchUp },
        timeLabel = labels.time(e.startMs), statusLabel = labels.status(e),
    )

    /** Midnight at the end of the local calendar day that [nowMs] falls on. */
    fun endOfLocalDay(nowMs: Long, zone: TimeZone): Long {
        val c = Calendar.getInstance(zone); c.timeInMillis = nowMs
        c.set(Calendar.HOUR_OF_DAY, 0); c.set(Calendar.MINUTE, 0); c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0)
        c.add(Calendar.DAY_OF_YEAR, 1)
        return c.timeInMillis
    }

    fun build(events: List<SportsEvent>, nowMs: Long, zone: TimeZone, selected: Sport?, detailId: String?, sourceNames: Map<String, String>, locale: java.util.Locale = java.util.Locale.getDefault()): Result {
        val labels = Labels(zone, locale, nowMs)
        val upcomingOrLive = events.filter { it.endMs > nowMs }                                   // a finished event is not listed
        val present = Sport.values().filter { s -> upcomingOrLive.any { it.sport == s } }
        val filters = if (present.isEmpty()) emptyList() else listOf(SportsFilter(null, "All Sports", upcomingOrLive.size)) + present.map { s -> SportsFilter(s, s.title, upcomingOrLive.count { it.sport == s }) }
        val effective = selected?.takeIf { it in present }                                         // a sport that no longer has events falls back to All
        val shown = if (effective == null) upcomingOrLive else upcomingOrLive.filter { it.sport == effective }
        val dayEnd = endOfLocalDay(nowMs, zone)
        val live = ArrayList<SportsEventCard>(); val soon = ArrayList<SportsEventCard>(); val today = ArrayList<SportsEventCard>(); val later = ArrayList<SportsEventCard>()
        for (e in shown.sortedWith(compareBy({ it.startMs }, { it.title }, { it.id }))) {
            val c = card(e, nowMs, labels)
            when {
                e.state(nowMs) == SportsEventState.LIVE -> live.add(c)
                e.startMs <= nowMs + SOON_MS -> soon.add(c)
                e.startMs < dayEnd -> today.add(c)
                else -> later.add(c)
            }
        }
        val detail = detailId?.let { id -> events.firstOrNull { it.id == id } }?.let { detail(it, nowMs, sourceNames, labels) }
        return Result(live, soon, today, later, filters, effective, detail)
    }

    fun detail(e: SportsEvent, nowMs: Long, sourceNames: Map<String, String>, labels: Labels): SportsEventDetail {
        val feeds = e.feeds.map { f ->
            SportsFeedRow(
                channelName = f.channelName, sourceName = sourceNames[f.sourceId] ?: "Playlist",
                language = f.language?.let { SportsLabelled(languageName(it), f.languageSource != MetadataSource.PROVIDER) },
                quality = f.quality?.let { SportsLabelled(it, f.qualitySource != MetadataSource.PROVIDER) }, catchUp = f.catchUp,
            )
        }
        val label = when (e.state(nowMs)) { SportsEventState.LIVE -> "Live now"; SportsEventState.UPCOMING -> "Upcoming"; SportsEventState.FINISHED -> "Finished" }
        return SportsEventDetail(card(e, nowMs, labels), label, labels.range(e), feeds, e.confidence < LOW_CONFIDENCE)
    }

    private val names = mapOf("en" to "English", "es" to "Spanish", "fr" to "French", "de" to "German", "ar" to "Arabic", "hi" to "Hindi", "te" to "Telugu", "ta" to "Tamil", "kn" to "Kannada", "ml" to "Malayalam",
        "bn" to "Bengali", "mr" to "Marathi", "ur" to "Urdu", "pa" to "Punjabi", "pt" to "Portuguese", "it" to "Italian", "tr" to "Turkish", "ru" to "Russian", "pl" to "Polish", "nl" to "Dutch", "fa" to "Persian",
        "zh" to "Chinese", "ja" to "Japanese", "ko" to "Korean", "th" to "Thai", "id" to "Indonesian")
    fun languageName(code: String) = names[code.lowercase()] ?: code.uppercase()
}
