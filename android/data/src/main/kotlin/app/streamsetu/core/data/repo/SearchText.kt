package app.streamsetu.core.data.repo

import java.text.Normalizer

/** Pure text rules for search, kept apart from the database so they can be tested without a device. */
object SearchText {
    private val marks = Regex("\\p{Mn}+")

    /** Lower case, accents removed, anything that is not a letter or digit becomes a space. */
    private val SPACES = Regex("\\s+")
    fun normalize(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFD).replace(marks, "").lowercase()
        .map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("").trim().replace(SPACES, " ")

    fun tokens(s: String): List<String> = normalize(s).split(' ').filter { it.isNotEmpty() }

    /** An FTS query that matches each typed word as a prefix: "bat man" becomes `bat* man*`. */
    fun matchQuery(typed: String): String = tokens(typed).take(6).joinToString(" ") { "$it*" }

    /** Higher is better. 0 means no match. */
    fun score(title: String, typed: String): Int {
        val t = normalize(title); val q = normalize(typed)
        if (q.isEmpty()) return 0
        val words = t.split(' ')
        val qTokens = q.split(' ')
        return when {
            t == q -> 1000
            t.startsWith(q) -> 800
            words.contains(q) -> 700
            qTokens.all { qt -> words.any { it == qt } } -> 650
            qTokens.all { qt -> words.any { it.startsWith(qt) } } -> 600 - minOf(t.length, 100) / 4
            t.contains(q) -> 400
            qTokens.all { qt -> t.contains(qt) } -> 300
            else -> 0
        }
    }

    /** A bounded edit distance (stops counting once it passes [max]); used only to re-rank a small candidate list. */
    fun distance(a: String, b: String, max: Int = 2): Int {
        if (kotlin.math.abs(a.length - b.length) > max) return max + 1
        var prev = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            val cur = IntArray(b.length + 1); cur[0] = i
            var best = cur[0]
            for (j in 1..b.length) {
                cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
                best = minOf(best, cur[j])
            }
            if (best > max) return max + 1
            prev = cur
        }
        return prev[b.length]
    }

    /** Score for a title when the typed word was probably misspelt: the closest title word, within two edits. 0 when nothing is close. */
    fun fuzzyScore(title: String, typed: String): Int {
        val q = tokens(typed)
        if (q.isEmpty()) return 0
        val words = tokens(title)
        var total = 0
        for (qt in q) {
            val best = words.minOfOrNull { w -> minOf(distance(qt, w), distance(qt, w.take(qt.length))) } ?: return 0
            if (best > (if (qt.length >= 6) 2 else 1)) return 0
            total += 200 - best * 40
        }
        return total / q.size
    }
}
