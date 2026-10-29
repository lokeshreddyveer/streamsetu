package app.streamsetu.tv.sports

import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.SportsFeed

/** Which rule put a feed where it is. A category only: it carries no names. */
enum class RankReason { YOUR_CHOICE, PLAYED_EARLIER, LANGUAGE, PROVIDER_QUALITY, INFERRED_QUALITY, PREFERRED_SOURCE, KNOWN_HEALTHY, PROVIDER_ORDER }

/** What the ranking is allowed to look at. Everything here is already in memory: ranking never reads a database or the network. */
class RankInput(
    /** The feed the person chose for this event (returning to it). */
    val selectedChannelId: String? = null,
    /** The feed that played successfully for this event earlier in this session. */
    val playedChannelId: String? = null,
    /** The preferred audio language as a lower-case code, or null. */
    val preferredLanguage: String? = null,
    /** Connections in the order the person prefers them; the active library's order is the usual choice. */
    val preferredSourceIds: List<String> = emptyList(),
    /** Channels already known to work, from information the app already keeps. Usually empty. */
    val healthyChannelIds: Set<String> = emptySet(),
    /** Whether this device has a hardware decoder that can show 4K (HEVC, VP9 or AV1). */
    val deviceDecodes4K: Boolean = true,
)

class RankedFeed(val feed: SportsFeed, val reason: RankReason, val position: Int, val deprioritized: Boolean)

/**
 * The one ranking of an event's feeds, used by Watch Best Feed and by the recommended badge so they can never disagree. Deterministic and free of side effects. The caller passes only feeds
 * that are authorised right now; a feed that is not allowed is never ranked.
 *
 * Order: the person's own choice, the feed that played earlier this session, a feed the device is not known to be unable to show, the preferred language (a language the provider supplied
 * before one read from a name), quality (supplied before inferred), the preferred connection, a feed already known to work, then the order the provider listed them in.
 */
object SportsFeedRanker {
    private val QUALITY = mapOf("4K" to 4, "FHD" to 3, "HD" to 2, "SD" to 1)

    fun qualityRank(q: String?): Int = q?.let { QUALITY[it.uppercase()] } ?: 0

    /** A quality the provider supplied that this device cannot decode. A quality read from a name is never called unsupported: it just does not earn a preference. */
    fun unsupported(f: SportsFeed, input: RankInput): Boolean = !input.deviceDecodes4K && f.qualitySource == MetadataSource.PROVIDER && qualityRank(f.quality) >= 4

    fun rank(feeds: List<SportsFeed>, input: RankInput): List<RankedFeed> {
        val lang = input.preferredLanguage?.lowercase()?.takeIf { it.isNotBlank() }
        fun languageScore(f: SportsFeed) = if (lang == null || f.language?.lowercase() != lang) 0 else if (f.languageSource == MetadataSource.PROVIDER) 2 else 1
        fun providerQuality(f: SportsFeed) = if (f.qualitySource == MetadataSource.PROVIDER) qualityRank(f.quality) else 0
        fun inferredQuality(f: SportsFeed): Int {
            if (f.qualitySource != MetadataSource.PARSED_FROM_NAME) return 0
            val q = qualityRank(f.quality)
            return if (!input.deviceDecodes4K && q >= 4) 3 else q                                   // an inferred 4K earns no more than FHD on a device that cannot show 4K
        }
        fun sourceOrder(f: SportsFeed) = input.preferredSourceIds.indexOf(f.sourceId).let { if (it < 0) Int.MAX_VALUE else it }
        val indexed = feeds.withIndex().toList()
        val sorted = indexed.sortedWith(
            compareBy<IndexedValue<SportsFeed>> { if (it.value.channelId == input.selectedChannelId) 0 else 1 }
                .thenBy { if (it.value.channelId == input.playedChannelId) 0 else 1 }
                .thenBy { if (unsupported(it.value, input)) 1 else 0 }
                .thenByDescending { languageScore(it.value) }
                .thenByDescending { providerQuality(it.value) }
                .thenByDescending { inferredQuality(it.value) }
                .thenBy { sourceOrder(it.value) }
                .thenBy { if (it.value.channelId in input.healthyChannelIds) 0 else 1 }
                .thenBy { it.index },
        )
        return sorted.map { (i, f) ->
            val reason = when {
                f.channelId == input.selectedChannelId -> RankReason.YOUR_CHOICE
                f.channelId == input.playedChannelId -> RankReason.PLAYED_EARLIER
                languageScore(f) > 0 -> RankReason.LANGUAGE
                providerQuality(f) > 0 -> RankReason.PROVIDER_QUALITY
                inferredQuality(f) > 0 -> RankReason.INFERRED_QUALITY
                sourceOrder(f) != Int.MAX_VALUE -> RankReason.PREFERRED_SOURCE
                f.channelId in input.healthyChannelIds -> RankReason.KNOWN_HEALTHY
                else -> RankReason.PROVIDER_ORDER
            }
            RankedFeed(f, reason, i, unsupported(f, input))
        }
    }

    /** "Best available · English · FHD": what makes this the feed to start with, in plain words. Unknown parts are left out, never guessed. */
    fun explain(r: RankedFeed, languageName: (String) -> String = { it }): String {
        val lead = when (r.reason) { RankReason.YOUR_CHOICE -> "Your choice"; RankReason.PLAYED_EARLIER -> "Played earlier"; else -> "Best available" }
        return listOfNotNull(lead, r.feed.language?.let(languageName), r.feed.quality).joinToString(" · ")
    }
}
