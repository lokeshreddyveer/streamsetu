package app.streamsetu.core.data.repo

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** One rating rule: no code outside DisplayRating may judge or format a rating on its own. Fails on a raw read of a rating's text as a number, or a hand-made star. */
class RatingSourceScanTests {
    private val root: File = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "settings.gradle.kts").exists() }

    /** Files that may touch a raw rating: the rule itself, the rating search/sort/smart-mix features that compare numbers (no display), and the subtitle ranking (a different thing). */
    private val exempt = listOf("DisplayRating.kt", "NaturalQuery.kt", "SearchRepository.kt", "SubtitleRanking.kt", "OnlineSubtitles.kt", "Features.kt", "RatingSourceScanTests.kt")

    private fun mainKotlin() = root.walkTopDown().filter { it.isFile && it.extension == "kt" && "/src/main/" in it.path && "/build/" !in it.path }.filter { f -> exempt.none { f.name == it } }

    @Test fun noRawRatingIsReadOrFormattedOutsideTheSharedRule() {
        val bad = ArrayList<String>()
        val raw = listOf(Regex("""rating\??\.toDoubleOrNull\(\)"""), Regex("""rating\??\.toFloatOrNull\(\)"""), Regex("""rating\??\.toDouble\(\)"""), Regex("""\"★ %"""))
        for (f in mainKotlin()) f.readLines().forEachIndexed { i, line -> if (raw.any { it.containsMatchIn(line) }) bad += "${f.name}:${i + 1}" }
        assertTrue("raw rating reads (use DisplayRating): $bad", bad.isEmpty())
    }

    @Test fun thereIsOneRatingRuleObject() {
        val rules = mainKotlin().filter { f -> f.readText().contains(Regex("""object\s+RatingRule\b""")) }.map { it.name }.toList()
        assertTrue("a second rating rule: $rules", rules.isEmpty())
    }
}
