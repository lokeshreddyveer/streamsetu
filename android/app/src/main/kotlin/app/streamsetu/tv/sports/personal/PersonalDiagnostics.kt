package app.streamsetu.tv.sports.personal

import app.streamsetu.tv.trace.SSTrace

enum class NotificationState { GRANTED, DENIED, NOT_ASKED, NOT_NEEDED }
enum class ScheduleOutcome { ARMED, CANCELLED, NOTIFIED, FAILED }

/**
 * Counts and fixed words about follows and reminders: how many of each kind, how many reminders are in each state, how a refresh associated them, how long that took, and how a notification fared.
 * No team, competition or event name, no notification text, no channel or connection name, no address and no credential can be in it: every field is a number or an enum.
 */
class PersonalReport(
    val sportFollows: Int, val competitionFollows: Int, val participantFollows: Int,
    val scheduled: Int, val unmatched: Int, val ambiguous: Int, val finished: Int,
    val reassociated: Int, val matchingMs: Long,
    val outcome: ScheduleOutcome?, val permission: NotificationState?,
) {
    fun line(): String = buildString {
        append("sports personal follows=").append(sportFollows).append('/').append(competitionFollows).append('/').append(participantFollows)
        append(" reminders scheduled=").append(scheduled).append(" unmatched=").append(unmatched).append(" ambiguous=").append(ambiguous).append(" finished=").append(finished)
        append(" reassociated=").append(reassociated).append(" ms=").append(matchingMs)
        outcome?.let { append(" outcome=").append(it.name.lowercase()) }
        permission?.let { append(" permission=").append(it.name.lowercase()) }
    }
}

fun interface PersonalDiagnostics {
    fun record(report: PersonalReport)

    object Log : PersonalDiagnostics {
        override fun record(report: PersonalReport) { SSTrace.v { report.line() } }
    }
}
