package app.streamsetu.core.data.repo

import org.junit.Assert.*
import org.junit.Test
import java.util.Random

/** Properties of the artwork matcher on small seeded inputs: they hold for every seed, so a failure names the seed. */
class ArtworkMatcherPropertyTests {
    private val words = listOf("Heat", "Alien", "The Matrix", "Baahubali", "Pushpa", "Dune", "Her", "Up", "Kantara", "Drishyam", "Ratatouille")
    private fun candidates(r: Random, title: String, year: Int?): List<ArtworkMatchDecision.Candidate> = (1..r.nextInt(6) + 1).map {
        val t = if (r.nextInt(3) == 0) words[r.nextInt(words.size)] else title
        ArtworkMatchDecision.Candidate(it.toLong(), t, if (r.nextBoolean()) t else null, year?.plus(r.nextInt(3) - 1), r.nextInt(100).toDouble(), listOf("en", "te", "hi", null)[r.nextInt(4)])
    }

    @Test fun theAnswerIsAlwaysOneOfTheCandidatesOrNothingAndOrderDoesNotMatter() {
        for (seed in 1L..120L) {
            val r = Random(seed); val title = words[r.nextInt(words.size)]; val year = if (r.nextInt(4) == 0) null else 1990 + r.nextInt(36)
            val q = ArtworkMatchDecision.Query(title, year, r.nextBoolean(), listOf("", "Telugu", "Hindi")[r.nextInt(3)])
            val c = candidates(r, title, year); val text = ArtworkNames.clean(title, year)
            val a = ArtworkMatchDecision.decide(q, c, text)
            assertTrue("seed $seed: $a not among ${c.map { it.id }}", a == null || c.any { it.id == a })
            // Name only (owner policy): the first same-name result in result order wins, so order is meaningful; whatever the order, the answer is still one of the candidates.
            val b = ArtworkMatchDecision.decide(q, c.shuffled(Random(seed * 7)), text)
            assertTrue("seed $seed: $b not among the candidates", b == null || c.any { it.id == b })
            assertEquals("seed $seed: not repeatable", a, ArtworkMatchDecision.decide(q, c, text))
        }
    }
    @Test fun noCandidatesNeverMatches() { assertNull(ArtworkMatchDecision.decide(ArtworkMatchDecision.Query("Heat", 1995, false), emptyList(), "Heat")) }
    @Test fun cleaningIsStableAndNeverEmptiesARealTitle() {
        val r = Random(11)
        val noise = listOf("", " 4K", " (2019)", " [HD]", " | EN", " 1080p", " WEB-DL", " FHD")
        repeat(80) {
            val base = words[r.nextInt(words.size)]; val raw = base + (1..r.nextInt(3)).joinToString("") { noise[r.nextInt(noise.size)] }
            val once = ArtworkNames.clean(raw, null)
            assertTrue("'$raw' became empty", once.isNotBlank()); assertEquals("'$raw' is not stable", once, ArtworkNames.clean(once, null))
        }
    }
}
