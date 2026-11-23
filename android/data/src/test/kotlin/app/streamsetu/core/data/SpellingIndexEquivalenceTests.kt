package app.streamsetu.core.data

import app.streamsetu.core.data.repo.ArtworkMatchDecision
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.core.data.repo.Spelling
import app.streamsetu.core.data.repo.SpellingIndex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.math.abs

/** The indexed spelling lookup must answer exactly what a plain scan of the whole vocabulary answers (the scan is kept here as the reference). */
class SpellingIndexEquivalenceTests {
    private val vocab: Map<String, Int> = ("avengers endgame infinity war interstellar inception baahubali conclusion pushpa kalki dhoom jawan pathaan animal gladiator godfather matrix reloaded revolutions parasite squid game money heist amelie casablanca titanic avatar frozen shrek madagascar minions oppenheimer barbie dune spiderman batman superman joker wicked sholay lagaan dangal drishyam kantara vikram leo master theri mersal bigil sarkar")
        .split(' ').withIndex().filter { it.value.length >= 3 }.associate { it.value to 1 + it.index % 5 }

    private fun reference(query: String, v: Map<String, Int>): String? {
        var changed = false
        val fixed = query.split(Regex("\\s+")).filter { it.isNotEmpty() }.map { raw ->
            val w = SearchText.normalize(raw).filter { it.isLetterOrDigit() }
            if (w.length < 4 || v.containsKey(w)) return@map raw
            if (v.keys.any { it.startsWith(w) }) return@map raw
            val fw = ArtworkMatchDecision.fold(w)
            v.filter { ArtworkMatchDecision.fold(it.key) == fw && it.key != w }.entries.sortedWith(compareBy({ -it.value }, { it.key })).firstOrNull()?.let { changed = true; return@map it.key }
            val allowed = if (w.length <= 5) 1 else 2
            fun pick(pool: List<String>, limit: Int): String? {
                var best: Triple<String, Int, Int>? = null
                for (cand in pool.sorted()) {
                    val d = Spelling.distance(w, cand, limit); val n = v[cand] ?: 0
                    if (d > limit) continue
                    val b = best
                    if (b == null || d < b.second || (d == b.second && n > b.third)) best = Triple(cand, d, n)
                }
                return best?.first
            }
            var hit = pick(v.keys.filter { abs(it.length - w.length) <= allowed && it.first() == w.first() }, allowed)
            if (hit == null && w.length >= 5) hit = pick(v.keys.filter { abs(it.length - w.length) <= 1 && it.first() != w.first() && it.drop(1).take(3) == w.drop(1).take(3) }, 1)
            if (hit == null) raw else { changed = true; hit }
        }
        return if (changed) fixed.joinToString(" ") else null
    }

    @Test fun sameAnswersAsTheScan() {
        val queries = listOf("avngers", "avengrs endgam", "intersteller", "bahubali", "baahubalee", "qvengers", "gladiater", "godfater", "parasit", "squid gme", "money hiest", "zzzzzz", "avenge", "matrx reloded", "oppenheimr", "kantaraa", "dhoomm", "pushpaa", "shreck", "frozn", "wicked", "the avengers", "superman", "supermen")
        val ix = SpellingIndex(vocab)
        for (q in queries) assertEquals(q, reference(q, vocab), Spelling.correct(q, vocab, ix))
    }

    @Test fun realMisspellingsAreFixed() {
        assertEquals("avengers", Spelling.correct("avngers", vocab))
        assertEquals("avengers", Spelling.correct("qvengers", vocab))
        assertNull(Spelling.correct("avenge", vocab))                    // a word being typed is left alone
        assertEquals("baahubali", Spelling.correct("bahubali", vocab))   // transliteration spelling
    }

    @Test fun theIndexAnswersPrefixesByBinarySearch() {
        val ix = SpellingIndex(vocab)
        assertEquals(true, ix.hasWord("aven")); assertEquals(false, ix.hasWord("avenx")); assertEquals(true, ix.hasWord("sarkar")); assertEquals(false, ix.hasWord("zzz"))
    }
}
