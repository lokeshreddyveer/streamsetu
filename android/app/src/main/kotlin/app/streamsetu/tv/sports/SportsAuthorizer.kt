package app.streamsetu.tv.sports

import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsFeed

/** What the app must be asked, at the moment of a request, to know whether a channel may be played. Shared by Sports playback and Multi-View: both ask the same questions. */
interface SportsAuthorization {
    val profileId: String
    val activeSourceIds: Set<String>
    suspend fun channel(id: String): Channel?
    suspend fun sourceEnabled(sourceId: String): Boolean
    suspend fun folderLocked(categoryId: String?): Boolean
    suspend fun adultBlocked(categoryId: String?): Boolean
    suspend fun hidden(channelId: String): Boolean
    suspend fun sourceNames(): Map<String, String>
}

/** The one set of checks. A channel is refused for exactly one fixed reason, or not at all. */
object SportsAuthorizer {
    suspend fun refusal(a: SportsAuthorization, ch: Channel, profile: String): PlayRejection? = when {
        a.profileId != profile -> PlayRejection.PROFILE_CHANGED
        !a.sourceEnabled(ch.sourceId) -> PlayRejection.SOURCE_OFF
        ch.sourceId !in a.activeSourceIds -> PlayRejection.NOT_IN_LIBRARY
        a.folderLocked(ch.categoryId) -> PlayRejection.FOLDER_LOCKED
        a.adultBlocked(ch.categoryId) -> PlayRejection.RESTRICTED
        a.hidden(ch.id) -> PlayRejection.HIDDEN
        else -> null
    }

    /** A feed read afresh: the channel must still exist under the same connection, then pass every check. */
    suspend fun refusal(a: SportsAuthorization, f: SportsFeed, profile: String): PlayRejection? {
        val ch = a.channel(f.channelId) ?: return PlayRejection.CHANNEL_MISSING
        if (ch.sourceId != f.sourceId) return PlayRejection.FEED_NOT_IN_EVENT
        return refusal(a, ch, profile)
    }

    /** Every feed of the event that passes, with its channel; stops early when [alive] turns false. */
    suspend fun authorizedFeeds(a: SportsAuthorization, event: SportsEvent, profile: String, alive: () -> Boolean = { true }): List<Pair<SportsFeed, Channel>> {
        val out = ArrayList<Pair<SportsFeed, Channel>>()
        for (f in event.feeds) {
            if (!alive()) break
            val ch = a.channel(f.channelId)
            if (ch != null && ch.sourceId == f.sourceId && refusal(a, ch, profile) == null) out += f to ch
        }
        return out
    }
}
