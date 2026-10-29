package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.sports.personal.Follow
import app.streamsetu.tv.sports.personal.FollowKind
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.sports.personal.SportsKeys
import app.streamsetu.tv.ui.screens.sports.SportsSections
import java.util.TimeZone

/** Events and environments for the discovery tests. Everything is plain data: no database, no clock, no screen. */
object D {
    const val H = 3_600_000L
    const val MIN = 60_000L
    const val NOW = 1_800_000_000_000L + 2 * H
    val UTC: TimeZone = TimeZone.getTimeZone("UTC")

    fun feed(ch: String, source: String = "A", catchUp: Boolean = false) = SportsFeed(ch, source, "Channel $ch", null, MetadataSource.UNKNOWN, null, MetadataSource.UNKNOWN, null, ch, 0L, catchUp)

    fun event(id: String, start: Long, sides: List<String>, competition: String? = "League", sport: Sport = Sport.CRICKET, sources: Set<String> = setOf("A"), channels: List<String> = listOf("c-$id"), catchUp: Boolean = false, durationMs: Long = 3 * H) =
        SportsEvent(id, sport, SportsEventKind.HEAD_TO_HEAD, competition, sides, null, sides.joinToString(" vs "), start, start + durationMs,
            channels.flatMap { c -> sources.map { s -> feed(c + (if (sources.size > 1) "-$s" else ""), s, catchUp) } }, 0.95, sources, "r")

    fun recording(id: String, e: SportsEvent, status: String, updated: Long = NOW) = SportsRecordingEntity(
        id, "main", "lib", e.sport.name, SportsKeys.identity(e), e.competition?.let(SportsKeys::key), SportsKeys.participantsKey(e), "A", "c", e.startMs, e.endMs, 0, 0, SportsKeys.slot(e.startMs),
        1, "", null, "s-$id", e.id, status, null, "stamp", updated, updated)

    fun follow(kind: FollowKind, sport: Sport, name: String, key: String): Follow = Follow(kind, sport, key, name)
    fun team(sport: Sport, name: String) = Follow(FollowKind.PARTICIPANT, sport, SportsIdentity.participant(sport, name)!!, name)
    fun comp(sport: Sport, name: String) = Follow(FollowKind.COMPETITION, sport, SportsIdentity.competition(sport, name)!!, name)

    fun env(
        events: List<SportsEvent>, follows: List<Follow> = emptyList(), history: List<SportsEvent> = emptyList(), rows: List<SportsRecordingEntity> = emptyList(),
        reminded: Set<String> = emptySet(), now: Long = NOW,
    ): SportsPages.Env {
        val index = IdentityIndex.build(events + history)
        val fs = FollowSet(follows, index)
        return SportsPages.Env(events, history, now, UTC, index, fs, RecordingIndex(rows), reminded,
            decorate = { e, c -> c.copy(reminded = SportsPages.eventKey(e) in reminded, recordingLabel = RecordingIndex(rows).forEvent(e)?.status) },
            playIdOf = { null }, clock = { ms -> ms.toString() }, labels = SportsSections.Labels(UTC, java.util.Locale.US, now))
    }

    fun teamRef(sport: Sport, name: String, index: IdentityIndex, events: List<SportsEvent>): PageRef {
        val e = events.first { ev -> ev.sport == sport && ev.participants.any { SportsIdentity.strict(it) == SportsIdentity.strict(name) } }
        val key = index.participants(e).first { SportsIdentity.base(it).endsWith(":" + SportsIdentity.strict(name)) }
        return PageRef(PageKind.TEAM, sport, key, name)
    }
    fun compRef(sport: Sport, name: String, index: IdentityIndex, events: List<SportsEvent>): PageRef {
        val e = events.first { it.sport == sport && it.competition != null && SportsIdentity.strict(it.competition!!) == SportsIdentity.strict(name) }
        return PageRef(PageKind.COMPETITION, sport, index.competition(e)!!, name)
    }

    /** A guide the size of a busy week: [n] events over 72 hours, [teams] teams in [comps] competitions across every sport, three feeds each over two playlists, some of the same team on both. */
    fun large(n: Int, teams: Int = 160, comps: Int = 40, now: Long = NOW): List<SportsEvent> {
        val sports = Sport.values()
        return (0 until n).map { i ->
            val sport = sports[i % sports.size]
            val a = "Team ${(i * 7) % teams} ${sport.name.take(3)}"; val b = "Team ${(i * 13 + 5) % teams} ${sport.name.take(3)}"
            val start = now - 3 * H + (i * 97L % (72 * 12)) * 5 * MIN
            event("ev-$i", start, if (a == b) listOf(a, a + " II") else listOf(a, b), "Comp ${i % comps} ${sport.name.take(3)}", sport, if (i % 5 == 0) setOf("A", "B") else setOf(if (i % 2 == 0) "A" else "B"),
                channels = listOf("ch-$i-1", "ch-$i-2"), catchUp = i % 3 == 0, durationMs = 2 * H + (i % 3) * H)
        }
    }
}
