package app.streamsetu.core.sports

/**
 * Sports events found in the guide of the person's own playlists. Nothing here is stored: events are derived from channels and programmes, never written back to them, and can always be rebuilt.
 * No outside sports service is used to decide what an event is.
 */
enum class Sport(val title: String) {
    FOOTBALL("Football"), CRICKET("Cricket"), BASKETBALL("Basketball"), AMERICAN_FOOTBALL("American Football"), BASEBALL("Baseball"), ICE_HOCKEY("Ice Hockey"),
    TENNIS("Tennis"), MOTORSPORT("Motorsport"), GOLF("Golf"), BOXING("Boxing"), MMA("MMA"), RUGBY("Rugby"),
}

enum class SportsEventState { UPCOMING, LIVE, FINISHED }

/** What shape of event it is. Not every event has two sides. */
enum class SportsEventKind {
    /** Two sides: a match, a game, a bout. */
    HEAD_TO_HEAD,
    /** A motorsport session: a race, qualifying, a practice or a sprint of a named Grand Prix or round. */
    RACE_SESSION,
    /** A round, day or final of a named tournament (golf, tennis). */
    TOURNAMENT_ROUND,
    /** A named fight card or one of its parts (UFC 300 main card, prelims). */
    FIGHT_CARD,
    /** Any other event, accepted only when the competition is known and the listing names a specific final, match number or round. */
    GENERIC,
}

/** Where a piece of feed information came from. A language or quality read out of a channel name is a hint, never presented as something the provider said. */
enum class MetadataSource { PROVIDER, PARSED_FROM_NAME, UNKNOWN }

/** Why a channel is kept out of every result. */
enum class SportsRestriction { HIDDEN_CHANNEL, LOCKED_FOLDER }

/**
 * One channel carrying an event. A channel that is hidden or filtered for the person never becomes a feed: it is removed before any event is built. On Android the channel model carries no
 * language or quality, so those are unknown unless the title or the channel name says one, and then they are marked as hints.
 */
data class SportsFeed(
    val channelId: String,
    val sourceId: String,
    val channelName: String,
    /** A lower-case language code ("en", "hi", "te"), or null when nothing says one. See [languageSource]. */
    val language: String?,
    val languageSource: MetadataSource,
    /** "4K", "FHD", "HD" or "SD", or null when unknown. See [qualitySource]. */
    val quality: String?,
    val qualitySource: MetadataSource,
    /** "home", "away", "alt" or "clean" for a feed that is a particular commentary or camera (always a hint read from the title). */
    val variant: String?,
    /** The guide id the programme was read under. */
    val guideId: String,
    val programmeStartMs: Long,
    /** The provider keeps this channel's past programmes. */
    val catchUp: Boolean,
    /** The channel's own logo address, for showing a card; never shown as text. */
    val logoUrl: String? = null,
)

data class SportsEvent(
    /**
     * Stable: the same event keeps its id when a feed appears or disappears, a start time is corrected by a few minutes, or a playlist is refreshed. It comes from the normalized event identity, the UTC
     * day of the event and its place among that identity's occurrences that day (so the same two sides playing twice on one day get two ids). It can only change if an event sitting on UTC midnight has
     * its time corrected across that line. It is for list keys, focus and cache identity only: never the permanent identity of a reminder, recording or synced record, which need their own durable record
     * re-associated by normalized identity and a time tolerance (see docs/SPORTS.md).
     */
    val id: String,
    val sport: Sport,
    val kind: SportsEventKind,
    val competition: String?,
    /** The sides in the order the title gives them (for "A @ B", the home side first). Empty for an event with no sides. */
    val participants: List<String>,
    /** The part of a longer event: "race", "qualifying", "practice 2", "round 3", "final", "main card". */
    val stage: String?,
    val title: String,
    val startMs: Long,
    val endMs: Long,
    val feeds: List<SportsFeed>,
    /** 0 to 1: how sure the rules are that this is a real event of this sport. */
    val confidence: Double,
    val sourceIds: Set<String>,
    /** Made from the guide revision of every playlist that carries the event, and only those. */
    val guideRevision: String,
) {
    fun state(nowMs: Long) = if (nowMs < startMs) SportsEventState.UPCOMING else if (nowMs < endMs) SportsEventState.LIVE else SportsEventState.FINISHED
}
