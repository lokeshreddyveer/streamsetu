package app.streamsetu.tv.sports.discovery

/** What a discovery piece of work was. A fixed word, never a name. */
enum class DiscoveryKind { SEARCH, TEAM_PAGE, COMPETITION_PAGE, MY_SPORTS, CATCH_UP, IDENTITIES }

enum class DiscoveryOutcome { OK, EMPTY, CANCELLED, ERROR }

/**
 * Counts, a duration, whether a cache answered and how it ended. No event, team, competition, channel or playlist name, no search text, no address and no path is ever in one of these, and the
 * class has nowhere to put one.
 */
class DiscoveryReport(
    val kind: DiscoveryKind, val outcome: DiscoveryOutcome, val results: Int, val millis: Long, val cacheHit: Boolean,
    /** Names that are carried by playlists that share no event, and so are kept apart. */
    val ambiguous: Int = 0,
    /** Events the classifier could not give sides or a competition. */
    val unclassified: Int = 0,
    /** Failure category (the exception class name's kind, never its message). */
    val failure: String? = null,
) {
    fun line() = "sports-discovery kind=$kind outcome=$outcome results=$results ms=$millis cache=${if (cacheHit) "hit" else "miss"} ambiguous=$ambiguous unclassified=$unclassified" + (failure?.let { " failure=$it" } ?: "")
}

fun interface DiscoveryDiagnostics {
    fun record(report: DiscoveryReport)
    companion object { val Log = DiscoveryDiagnostics { android.util.Log.i("SportsDiscovery", it.line()) }; val None = DiscoveryDiagnostics { } }
}
