package app.streamsetu.core.data.repo

import kotlin.math.abs

/**
 * Reads a typed search the way a person means it, as the iPhone and Mac apps do: "hindi movies 2024" is Hindi titles from 2024, and the word
 * "movies" is not part of the title.
 */
object SmartQuery {
    data class Parsed(val text: String, val year: Int?)

    /** Words that say what kind of thing is wanted, which the screen already knows. */
    private val filler = setOf("movie", "movies", "film", "films", "series", "show", "shows", "serial", "serials", "new", "latest", "full")

    fun parse(raw: String): Parsed {
        val trimmed = raw.trim()
        val tokens = trimmed.split(Regex("\\s+")).filter { it.isNotEmpty() }
        // One word is always taken as it is: "1917" and "2012" are films, not years.
        if (tokens.size <= 1) return Parsed(trimmed, null)
        var year: Int? = null
        val rest = ArrayList<String>()
        for (t in tokens) {
            if (year == null && t.length == 4 && t.toIntOrNull()?.let { it in 1900..2099 } == true) year = t.toInt() else rest += t
        }
        val meaningful = rest.filter { it.lowercase() !in filler }
        if (meaningful.isEmpty()) return Parsed(if (year != null) "" else rest.joinToString(" "), year)
        return Parsed(meaningful.joinToString(" "), year)
    }
}

/**
 * Fixes a misspelt search using the words that really occur in the library's titles and channel names. It only steps in when the search found
 * nothing, and the screen tells the person what it searched for instead.
 */
object Spelling {
    /** The corrected search, or null when nothing needed fixing or nothing close was found. [vocabulary] maps a word to how often it occurs. */
    fun correct(query: String, vocabulary: Map<String, Int>): String? {
        if (vocabulary.isEmpty()) return null
        var changed = false
        val fixed = query.split(Regex("\\s+")).filter { it.isNotEmpty() }.map { raw ->
            val w = SearchText.normalize(raw).filter { it.isLetterOrDigit() }
            if (w.length < 4 || vocabulary.containsKey(w)) return@map raw
            if (vocabulary.keys.any { it.startsWith(w) }) return@map raw           // a word being typed is not a mistake
            val allowed = if (w.length <= 5) 1 else 2
            var best: Triple<String, Int, Int>? = null                              // word, distance, how common
            for ((cand, count) in vocabulary) {
                if (abs(cand.length - w.length) > allowed || cand.first() != w.first()) continue
                val d = distance(w, cand, allowed)
                val b = best
                if (d <= allowed && (b == null || d < b.second || (d == b.second && count > b.third))) best = Triple(cand, d, count)
            }
            best?.let { changed = true; it.first } ?: raw
        }
        return if (changed) fixed.joinToString(" ") else null
    }

    /** Edit distance (insert, delete, change, swap two neighbours), giving up above [limit]. */
    fun distance(x: String, y: String, limit: Int): Int {
        if (x.isEmpty()) return y.length
        if (y.isEmpty()) return x.length
        var prev2 = IntArray(y.length + 1)
        var prev = IntArray(y.length + 1) { it }
        for (i in 1..x.length) {
            val cur = IntArray(y.length + 1); cur[0] = i
            var rowMin = cur[0]
            for (j in 1..y.length) {
                val cost = if (x[i - 1] == y[j - 1]) 0 else 1
                cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if (i > 1 && j > 1 && x[i - 1] == y[j - 2] && x[i - 2] == y[j - 1]) cur[j] = minOf(cur[j], prev2[j - 2] + 1)
                rowMin = minOf(rowMin, cur[j])
            }
            if (rowMin > limit) return limit + 1
            prev2 = prev; prev = cur
        }
        return prev[y.length]
    }
}
