package app.streamsetu.core.data.repo

/**
 * Reads a typed search the way a person says it: "telugu movies 2024 I haven't watched" is Telugu films from 2024 that were never played. It never guesses at a name: only words it
 * knows (a language, a year or decade, "4K", "unwatched", "favourites", "top rated", "recently added") become filters; everything else stays as the title to look for. A search with none
 * of those words is returned untouched. (Running time is not stored on Android, so "under 2 hours" is not understood here.)
 */
data class NaturalQuery(
    val text: String = "", val language: String? = null, val year: Int? = null, val decade: Int? = null, val quality: String? = null, val minRating: Double? = null,
    val unwatched: Boolean = false, val favorites: Boolean = false, val recent: Boolean = false,
) {
    val isStructured: Boolean get() = language != null || year != null || decade != null || quality != null || minRating != null || unwatched || favorites || recent

    /** "Telugu · 2024 · unwatched": what was understood, shown under the search box. */
    val summary: List<String> get() = listOfNotNull(language, year?.toString(), decade?.let { "${it}s" }, quality, minRating?.let { "rated ${it.toInt()}+" },
        if (unwatched) "unwatched" else null, if (favorites) "favourites" else null, if (recent) "added recently" else null)

    companion object {
        val languages = listOf("English", "Hindi", "Telugu", "Tamil", "Malayalam", "Kannada", "Bengali", "Marathi", "Punjabi", "Gujarati", "Urdu", "Korean", "Japanese", "Chinese", "Turkish", "Arabic", "Spanish", "French", "German", "Italian", "Portuguese", "Russian", "Thai")
        /** The words in a title or folder name that stand for each picture quality. */
        val qualityTerms = mapOf("4K" to listOf("4K", "UHD", "2160p"), "1080p" to listOf("1080p", "FHD"), "720p" to listOf("720p"), "HDR" to listOf("HDR"))
        private val qualityWords = mapOf("4k" to "4K", "uhd" to "4K", "2160p" to "4K", "1080p" to "1080p", "fhd" to "1080p", "720p" to "720p", "hdr" to "HDR")
        private val filler = setOf("movie", "movies", "film", "films", "series", "show", "shows", "serial", "serials", "me", "find", "please", "that", "which", "i", "ive", "i've")

        fun parse(raw: String): NaturalQuery {
            val tokens = raw.lowercase().replace('’', '\'').split(Regex("[\\s,]+")).filter { it.isNotEmpty() }
            val plain = NaturalQuery(text = raw.trim())
            if (tokens.size < 2 && (tokens.isEmpty() || tokens[0].all { it.isDigit() })) return plain          // one number is a title ("1917")
            var q = NaturalQuery(); val rest = ArrayList<String>(); var i = 0
            fun at(k: Int) = tokens.getOrNull(k)
            while (i < tokens.size) {
                val t = tokens[i]
                when {
                    t == "unwatched" || t == "unseen" -> { q = q.copy(unwatched = true); i++ }
                    t in setOf("havent", "haven't", "not", "never", "didnt", "didn't") && at(i + 1) in setOf("watched", "seen", "played") -> { q = q.copy(unwatched = true); i += 2 }
                    t in setOf("favorite", "favorites", "favourite", "favourites", "fav", "favs") -> { q = q.copy(favorites = true); i++ }
                    languages.any { it.lowercase() == t } -> { q = q.copy(language = languages.first { it.lowercase() == t }); i++ }
                    qualityWords.containsKey(t) -> { q = q.copy(quality = qualityWords[t]); i++ }
                    t == "dolby" && at(i + 1) == "vision" -> { q = q.copy(quality = "Dolby Vision"); i += 2 }
                    t.length == 4 && t.toIntOrNull()?.let { it in 1900..2099 } == true -> { q = q.copy(year = t.toInt()); i++ }
                    t.endsWith("s") && (t.length == 5 || t.length == 3) && t.dropLast(1).toIntOrNull() != null && decadeOf(t.dropLast(1).toInt()) != null -> { q = q.copy(decade = decadeOf(t.dropLast(1).toInt())); i++ }
                    t in setOf("top", "best", "highly") && at(i + 1) in setOf("rated", "rating") -> { q = q.copy(minRating = 8.0); i += 2 }
                    t.endsWith("+") && t.dropLast(1).toDoubleOrNull()?.let { it in 1.0..10.0 } == true -> { q = q.copy(minRating = t.dropLast(1).toDouble()); i++ }
                    t in setOf("rated", "rating") && at(i + 1)?.removeSuffix("+")?.toDoubleOrNull()?.let { it in 1.0..10.0 } == true -> { q = q.copy(minRating = at(i + 1)!!.removeSuffix("+").toDouble()); i += 2 }
                    t in setOf("recent", "recently", "latest") -> { q = q.copy(recent = true); i += if (at(i + 1) == "added") 2 else 1 }
                    t in filler -> i++
                    else -> { rest += t; i++ }
                }
            }
            q = q.copy(text = rest.joinToString(" "))
            return if (q.isStructured) q else plain
        }

        private fun decadeOf(n: Int): Int? { val full = if (n < 100) (if (n >= 30) 1900 + n else 2000 + n) else n; return if (full % 10 == 0 && full in 1930..2020) full else null }
    }
}
