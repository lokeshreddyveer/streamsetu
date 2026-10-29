package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.model.EpgProgram
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.sports.SportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorizer
import app.streamsetu.tv.sports.personal.FollowSet

/** Where the Guide should open: an authorized channel, and the time of the programme as the Guide shows it (the guide time offset already applied). Ids and a time only. */
data class GuideTarget(val channelId: String, val startMs: Long)

/** What the Guide did with a [GuideTarget]. */
sealed interface GuideLanding {
    /** The programme that starts at that time is on the channel's row. */
    data class Programme(val channelId: String, val startMs: Long) : GuideLanding
    /** The programme moved or is gone: the channel's row, at the programme on air at that time or else the first one shown. */
    data class Channel(val channelId: String, val startMs: Long?) : GuideLanding
    /** The channel is not among the rows. The Guide is asked once for exactly that channel id; if it still is not there, it says so. */
    data object NotListed : GuideLanding
}

object GuideLink {
    /**
     * The first feed of the event that passes every check right now (profile, playlist, library, folder lock, adult and kids rules, hidden channel), best first. Null when none does:
     * nothing is opened, so a restricted channel cannot be reached through this link.
     */
    suspend fun target(auth: SportsAuthorization, event: SportsEvent, offsetMs: Long, order: List<String>): GuideTarget? {
        val profile = auth.profileId
        val allowed = SportsAuthorizer.authorizedFeeds(auth, event, profile)
        if (auth.profileId != profile) return null
        val rank = order.withIndex().associate { it.value to it.index }
        val feed: SportsFeed = allowed.map { it.first }.minWithOrNull(compareBy({ rank[it.channelId] ?: Int.MAX_VALUE }, { it.channelId })) ?: return null
        return GuideTarget(feed.channelId, feed.programmeStartMs + offsetMs)
    }

    /** The one-shot Guide filter: exactly this channel id, which already names its playlist. Never a name, so a same-named channel of another playlist, language or quality is never taken instead. */
    fun <T> onlyId(channels: List<T>, id: String, idOf: (T) -> String): List<T> = channels.filter { idOf(it) == id }

    /** Pure: where on the rows the target lands. */
    fun land(rows: List<Pair<String, List<EpgProgram>>>, t: GuideTarget): GuideLanding {
        val row = rows.firstOrNull { it.first == t.channelId } ?: return GuideLanding.NotListed
        val exact = row.second.firstOrNull { it.startMs == t.startMs }
        if (exact != null) return GuideLanding.Programme(t.channelId, exact.startMs)
        val onAir = row.second.firstOrNull { it.startMs <= t.startMs && it.endMs > t.startMs } ?: row.second.firstOrNull { it.endMs > t.startMs } ?: row.second.firstOrNull()
        return GuideLanding.Channel(t.channelId, onAir?.startMs)
    }
}

/** The Multi-View builder's "followed" hint, from the same strict, playlist-aware identities as the pages and My Sports. */
object MultiviewHints {
    /** Ids of the [shown] events that a follow matches. A follow that is unresolved (an old key that fits several teams, or a name shared by unrelated playlists) matches nothing. */
    fun followedIds(follows: FollowSet, all: List<SportsEvent>, shown: List<SportsEvent>): Set<String> {
        if (follows.isEmpty) return emptySet()
        val scoped = follows.withIndex(IdentityIndex.build(all))
        return shown.filter { scoped.matches(it) }.map { it.id }.toSet()
    }
}
