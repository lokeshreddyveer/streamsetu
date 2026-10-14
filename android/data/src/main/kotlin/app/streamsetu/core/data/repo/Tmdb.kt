package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.OverrideEntity
import app.streamsetu.core.net.Http
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.net.URLEncoder

/**
 * Fills in pictures and stories that a provider left out, from The Movie Database (https://www.themoviedb.org). It needs the person's own free API key, only looks up titles
 * that have no picture, and saves what it finds as a local correction (the provider's data is never edited). "This product uses the TMDB API but is not endorsed or certified by TMDB."
 */
class TmdbService(private val db: AppDatabase, private val key: () -> String?) {
    data class Query(val title: String, val year: Int?)
    data class Found(val posterUrl: String?, val plot: String?)

    companion object {
        /** "Heat (1995) [FHD] ᴴᴰ" to ("Heat", 1995). Brackets, quality tags and the year in the name are taken out of the search. */
        fun query(raw: String, knownYear: Int?): Query {
            var t = raw
            val year = Regex("[(\\[]((?:19|20)\\d\\d)[)\\]]").find(t)?.groupValues?.get(1)?.toIntOrNull() ?: knownYear
            t = t.replace(Regex("[(\\[][^)\\]]*[)\\]]"), " ")
            t = t.replace(Regex("(?i)\\b(4k|uhd|fhd|hd|sd|hevc|x26[45]|h26[45]|1080p|720p|2160p|bluray|web-?dl|multi|dual)\\b"), " ")
            t = t.replace(Regex("^[A-Za-z]{2,3}\\s*[|:-]\\s*"), "")          // a country or language prefix: "EN | Heat"
            return Query(t.replace(Regex("\\s+"), " ").trim(), year)
        }

        fun parse(json: String): Found? {
            val first = ((Xtream.parseObject(json)?.get("results") as? JsonArray)?.firstOrNull() as? JsonObject) ?: return null
            return Found(first.str("poster_path")?.let { "https://image.tmdb.org/t/p/w342$it" }, first.str("overview"))
        }
    }

    private fun lookup(kind: String, q: Query, apiKey: String): Found? {
        val url = "https://api.themoviedb.org/3/search/$kind?api_key=${URLEncoder.encode(apiKey, "UTF-8")}&query=${URLEncoder.encode(q.title, "UTF-8")}" +
            (q.year?.let { if (kind == "movie") "&year=$it" else "&first_air_date_year=$it" } ?: "")
        return parse(Http.text(url))
    }

    /** Looks up to [limit] titles without a picture; returns how many got one. [onProgress] is told (done, total). */
    suspend fun fillMissing(limit: Int = 150, onProgress: (Int, Int) -> Unit = { _, _ -> }): Int = withContext(Dispatchers.IO) {
        val apiKey = key()?.takeIf { it.isNotBlank() } ?: error("Enter your TMDB API key first.")
        val extras = db.extras()
        val movies = extras.moviesWithoutPoster(limit); val series = extras.seriesWithoutPoster(limit - movies.size.coerceAtMost(limit))
        val total = movies.size + series.size
        var done = 0; var filled = 0
        suspend fun one(id: String, title: String, year: Int?, kind: String) {
            val found = runCatching { lookup(kind, query(title, year), apiKey) }.getOrNull()
            // A title with no answer still gets a (blank) correction, so it is not asked about again and again.
            extras.putOverride(OverrideEntity(id, null, found?.posterUrl, found?.plot))
            if (found?.posterUrl != null) filled++
            onProgress(++done, total); delay(120)
        }
        movies.forEach { one(it.id, it.title, it.year, "movie") }
        series.forEach { one(it.id, it.title, it.year, "tv") }
        filled
    }
}
