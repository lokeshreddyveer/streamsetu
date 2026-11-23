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
 * Everything derived from the vocabulary once, so a correction does no whole-vocabulary scan: the words sorted (a prefix test by binary search), grouped by first letter and length (edit candidates),
 * by their ending after the first letter (first-letter slips), and by spelling-insensitive key (transliteration: "bahubali" and "baahubali").
 */
class SpellingIndex(vocabulary: Map<String, Int>) {
    val sorted: Array<String> = vocabulary.keys.sorted().toTypedArray()
    val byFirstAndLength: Map<String, List<String>>
    val byTail: Map<String, List<String>>
    /** Fold key -> the commonest word with that key (ties: the earlier word). */
    val folded: Map<String, String>

    init {
        val a = HashMap<String, ArrayList<String>>(); val t = HashMap<String, ArrayList<String>>(); val best = HashMap<String, String>()
        for (w in sorted) {
            a.getOrPut(key(w.firstOrNull(), w.length)) { ArrayList() }.add(w)
            t.getOrPut(w.drop(1).take(3)) { ArrayList() }.add(w)
            val k = ArtworkMatchDecision.fold(w); val n = vocabulary[w] ?: 0
            val b = best[k]
            if (b != null && (vocabulary[b] ?: 0) >= n) continue
            best[k] = w
        }
        byFirstAndLength = a; byTail = t; folded = best
    }

    /** Whether any word starts with [prefix] (binary search over the sorted words). */
    fun hasWord(withPrefix: String): Boolean {
        var lo = 0; var hi = sorted.size
        while (lo < hi) { val m = (lo + hi) ushr 1; if (sorted[m] < withPrefix) lo = m + 1 else hi = m }
        return lo < sorted.size && sorted[lo].startsWith(withPrefix)
    }

    companion object { fun key(first: Char?, length: Int): String = (first ?: ' ').toString() + length }
}

/**
 * Fixes a misspelt search using the words that really occur in the library's titles and channel names. It only steps in when the search found
 * nothing, and the screen tells the person what it searched for instead.
 */
object Spelling {
    @Volatile private var cached: Pair<Map<String, Int>, SpellingIndex>? = null

    /** The index of [vocabulary], built once per vocabulary instance (the library's word list is rebuilt only when the library changes). */
    private fun indexOf(vocabulary: Map<String, Int>): SpellingIndex = cached?.takeIf { it.first === vocabulary }?.second ?: SpellingIndex(vocabulary).also { cached = vocabulary to it }

    /**
     * The corrected search, or null when nothing needed fixing or nothing close was found. [vocabulary] maps a word to how often it occurs. Order for a word of 4+ letters that is not in the
     * vocabulary and not a prefix: (a) the same word spelt another way (fold key); (b) edit distance (1 up to 5 letters, else 2) among words with the same first letter and a length within the limit,
     * best = smaller distance, then commoner, then alphabetical; (c) a word of 5+ letters whose first letter is the slip: the same 3 letters after the first, one edit.
     */
    fun correct(query: String, vocabulary: Map<String, Int>, index: SpellingIndex? = null): String? {
        if (vocabulary.isEmpty()) return null
        val ix = index ?: indexOf(vocabulary)
        var changed = false
        val fixed = query.split(Regex("\\s+")).filter { it.isNotEmpty() }.map { raw ->
            val w = SearchText.normalize(raw).filter { it.isLetterOrDigit() }
            if (w.length < 4 || vocabulary.containsKey(w)) return@map raw
            if (ix.hasWord(w)) return@map raw                                       // a word being typed is not a mistake
            ix.folded[ArtworkMatchDecision.fold(w)]?.let { alt -> if (alt != w) { changed = true; return@map alt } }
            val allowed = if (w.length <= 5) 1 else 2
            var best: String? = null; var bestD = 0; var bestN = 0
            fun consider(cand: String, d: Int) {
                val n = vocabulary[cand] ?: 0
                val b = best
                if (b == null || d < bestD || (d == bestD && (n > bestN || (n == bestN && cand < b)))) { best = cand; bestD = d; bestN = n }
            }
            for (len in (w.length - allowed)..(w.length + allowed)) for (cand in ix.byFirstAndLength[SpellingIndex.key(w.first(), len)].orEmpty()) {
                val d = distance(w, cand, allowed)
                if (d <= allowed) consider(cand, d)
            }
            if (best == null && w.length >= 5) for (cand in ix.byTail[w.drop(1).take(3)].orEmpty()) {
                if (abs(cand.length - w.length) > 1 || cand.first() == w.first()) continue
                val d = distance(w, cand, 1)
                if (d <= 1) consider(cand, d)
            }
            best?.let { changed = true; it } ?: raw
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
