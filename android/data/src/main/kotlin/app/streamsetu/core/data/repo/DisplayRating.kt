package app.streamsetu.core.data.repo

import java.util.Locale

/**
 * The one rule for the rating a title shows, on every screen (the same on Apple and Windows; cases in artwork/fixtures/display-rating.json). TMDB's average counts only when enough people
 * voted (a film with two votes can score 10.0). Otherwise the provider's own rating, if it passes the junk filter (not readable, 0, 10 or 10.0, or above 10); otherwise none.
 */
object DisplayRating {
    /** Below this many votes a TMDB average is not trusted. */
    const val TMDB_VOTE_FLOOR = 10

    /** A numeric TMDB average with its vote count (person filmography, details): the average when real and from enough votes, else null. */
    fun credible(average: Double?, votes: Int?): Double? = average?.takeIf { it > 0.0 && it <= 10.0 && (votes ?: 0) >= TMDB_VOTE_FLOOR }

    /** TMDB's average as the one-decimal text stored with the title, or null when it is not credible. */
    fun tmdbText(average: Double?, votes: Int?): String? =
        credible(average, votes)?.let { String.format(Locale.US, "%.1f", it) }

    /** The provider's rating when it is readable, above 0, not 10 / 10.0 (junk providers send) and at most 10. */
    fun credibleProvider(raw: String?): Double? {
        val v = raw?.trim()?.toDoubleOrNull() ?: return null
        return v.takeIf { it > 0.0 && it < 10.0 }          // 10 and 10.0 are junk, and nothing above 10 is a rating
    }

    /** The star text ("★ 7.4") for a provider rating, or null when it is not credible. The only place a rating becomes text outside tiles. */
    fun starText(raw: String?): String? = credibleProvider(raw)?.let(::star)

    /** "★ 7.4" for a number already judged credible (a filmography credit), always with a point decimal. */
    fun star(v: Double): String = "★ " + String.format(Locale.US, "%.1f", v)

    fun value(tmdbAverage: Double?, tmdbVotes: Int?, provider: String?): Double? = tmdbText(tmdbAverage, tmdbVotes)?.toDouble() ?: credibleProvider(provider)
}
