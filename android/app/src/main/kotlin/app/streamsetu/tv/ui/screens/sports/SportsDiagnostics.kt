package app.streamsetu.tv.ui.screens.sports

import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.trace.SSTrace

enum class SportsLoadOutcome { OK, CANCELLED, ERROR }

/** Why a load failed, as a category only. The exception's message can carry an address or a name, so it is never kept. */
enum class SportsErrorCategory { IO, DATABASE, OTHER;
    companion object {
        fun of(e: Throwable): SportsErrorCategory = when {
            e is java.io.IOException -> IO
            e.javaClass.name.startsWith("android.database") -> DATABASE
            else -> OTHER
        }
    }
}

/**
 * What one load of the Sports Hub did, as numbers and fixed words only. Nothing here can hold an event, team, channel or playlist name, an address, a description, a stream link or a credential:
 * every field is a count, a duration, a flag or an enum.
 */
class SportsLoadReport(
    val outcome: SportsLoadOutcome,
    val errorCategory: SportsErrorCategory?,
    val totalEvents: Int,
    val bySection: Map<SportsSection, Int>,
    val bySport: Map<Sport, Int>,
    val feeds: Int,
    val lowConfidence: Int,
    val sources: Int,
    val loadMs: Long,
    /** Whether the classified events came from the cache. Null when the load did not finish. */
    val cacheHit: Boolean?,
) {
    /** The one line that is logged. Built only from the fields above. */
    fun line(): String = buildString {
        append("sports load outcome=").append(outcome.name.lowercase())
        errorCategory?.let { append(" error=").append(it.name.lowercase()) }
        append(" events=").append(totalEvents)
        append(" sections=").append(bySection.entries.joinToString(",") { it.key.name.lowercase() + ":" + it.value })
        append(" sports=").append(bySport.entries.joinToString(",") { it.key.name.lowercase() + ":" + it.value })
        append(" feeds=").append(feeds).append(" lowConfidence=").append(lowConfidence).append(" sources=").append(sources).append(" ms=").append(loadMs)
        append(" cache=").append(when (cacheHit) { true -> "hit"; false -> "miss"; null -> "none" })
    }

    companion object {
        fun of(events: List<SportsEvent>, nowMs: Long, zone: java.util.TimeZone, sources: Int, loadMs: Long, cacheHit: Boolean?): SportsLoadReport {
            val r = SportsSections.build(events, nowMs, zone, null, null, emptyMap())
            val sections = linkedMapOf(SportsSection.LIVE_NOW to r.live.size, SportsSection.STARTING_SOON to r.soon.size, SportsSection.TODAY to r.today.size, SportsSection.UPCOMING to r.upcoming.size)
            val bySport = events.groupingBy { it.sport }.eachCount().toSortedMap()
            return SportsLoadReport(SportsLoadOutcome.OK, null, events.size, sections, bySport, events.sumOf { it.feeds.size }, events.count { it.confidence < SportsSections.LOW_CONFIDENCE }, sources, loadMs, cacheHit)
        }
        fun failed(outcome: SportsLoadOutcome, e: Throwable?, sources: Int, loadMs: Long) =
            SportsLoadReport(outcome, e?.takeIf { outcome == SportsLoadOutcome.ERROR }?.let(SportsErrorCategory::of), 0, emptyMap(), emptyMap(), 0, 0, sources, loadMs, null)
    }
}

/** Where load reports go. The real one writes the line to the test log, which is off unless the device is told to turn it on. */
fun interface SportsDiagnostics {
    fun record(report: SportsLoadReport)

    object Log : SportsDiagnostics {
        override fun record(report: SportsLoadReport) { SSTrace.v { report.line() } }
    }
}
