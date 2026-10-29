package app.streamsetu.tv.sports

import app.streamsetu.tv.trace.SSTrace

enum class SportsPlayMode { BEST, EXACT, SWITCH, RESTORE }

/** Why a request to play was refused before anything started. Fixed words: the person is told only that the feed is not available. */
enum class PlayRejection { EVENT_GONE, FEED_NOT_IN_EVENT, CHANNEL_MISSING, SOURCE_OFF, NOT_IN_LIBRARY, PROFILE_CHANGED, FOLDER_LOCKED, RESTRICTED, HIDDEN, NO_FEED, STALE, PLAYER_REFUSED }

enum class PlayFailure { NETWORK, REFUSED, NOT_FOUND, TIMEOUT, FORMAT, OTHER }

enum class SportsPlayStage { REQUESTED, ACCEPTED, REJECTED, PLAYING, FAILED }

/**
 * One step of a Sports playback, as numbers and fixed words only: no event, team, channel or connection name, no address, no credential and no playback message (which can hold an address).
 * [ms] is measured from the request.
 */
class SportsPlaybackReport(
    val stage: SportsPlayStage,
    val mode: SportsPlayMode,
    val feedCount: Int,
    /** True when the person chose the feed, false when the ranking did. */
    val manual: Boolean,
    val reason: RankReason?,
    val rejection: PlayRejection?,
    val failure: PlayFailure?,
    val ms: Long,
) {
    fun line(): String = buildString {
        append("sports play stage=").append(stage.name.lowercase()).append(" mode=").append(mode.name.lowercase()).append(" feeds=").append(feedCount)
        append(" choice=").append(if (manual) "manual" else "recommended")
        reason?.let { append(" reason=").append(it.name.lowercase()) }
        rejection?.let { append(" rejected=").append(it.name.lowercase()) }
        failure?.let { append(" error=").append(it.name.lowercase()) }
        append(" ms=").append(ms)
    }
}

fun interface SportsPlaybackDiagnostics {
    fun record(report: SportsPlaybackReport)

    object Log : SportsPlaybackDiagnostics {
        override fun record(report: SportsPlaybackReport) { SSTrace.v { report.line() } }
    }
}
