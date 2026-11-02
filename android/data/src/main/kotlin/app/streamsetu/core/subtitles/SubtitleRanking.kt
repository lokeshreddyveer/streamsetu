package app.streamsetu.core.subtitles

import kotlin.math.log10
import kotlin.math.roundToInt

/** One subtitle a provider offers. Only what the provider said; nothing here is checked against the video yet. */
data class SubtitleCandidate(
    val fileId: Long, val fileName: String, val release: String, val language: String,
    val downloads: Int = 0, val rating: Double = 0.0, val hearingImpaired: Boolean = false,
    /** The provider matched the video's own file hash: it is the subtitle made for this exact file. */
    val hashMatch: Boolean = false, val trusted: Boolean = false, val aiTranslated: Boolean = false, val machineTranslated: Boolean = false,
    val title: String? = null, val year: Int? = null, val season: Int? = null, val episode: Int? = null, val runtimeMinutes: Int? = null, val provider: String = "OpenSubtitles",
)

/** What is being played, as far as the app knows it. Names the file only when it really knows the file's name. */
data class SubtitleWanted(
    val title: String, val year: Int?, val season: Int?, val episode: Int?, val language: String,
    val fileName: String? = null, val runtimeMinutes: Int? = null, val preferHearingImpaired: Boolean = false,
)

/** Why a result is shown where it is, in the words used on screen. */
enum class SubtitleMatch(val label: String) {
    EXACT_FILE("Exact file match"), SAME_EPISODE_AND_RUNTIME("Same episode and runtime"), TITLE_MATCH("Title match"), POSSIBLE("Possible match"),
}

enum class SubtitleConfidence(val label: String) { HIGH("High"), MEDIUM("Medium"), LOW("Low") }

data class RankedSubtitle(val candidate: SubtitleCandidate, val score: Int, val match: SubtitleMatch, val confidence: SubtitleConfidence, val reasons: List<String>) {
    /** What the list shows under the result: why, who, which language and whether it is for the hearing impaired. */
    val detail: String get() = listOfNotNull(
        match.label + " · ${confidence.label} confidence", candidate.provider, candidate.language.uppercase().takeIf { it.isNotBlank() }, "hearing impaired".takeIf { candidate.hearingImpaired },
        candidate.downloads.takeIf { it > 0 }?.let { "%,d downloads".format(it) }, "machine translated".takeIf { candidate.machineTranslated || candidate.aiTranslated },
    ).joinToString(" · ")

    /** True only for a result sure enough to be loaded without the person choosing it (Automatic subtitles). Low confidence is never applied by itself. */
    val safeToApplyAutomatically get() = confidence != SubtitleConfidence.LOW && !candidate.machineTranslated && !candidate.aiTranslated
}

/**
 * Orders what a provider returns by how likely it is to belong to this video. In this order of importance: the provider's own file-hash match; the episode (season and number);
 * the release or file name; the runtime; the title and year; the language; the hearing-impaired preference; how many people downloaded it and how they rated it; and whether the
 * provider trusts the uploader. A subtitle for another episode or another title is dropped, never ranked low. The order is stable: equal scores keep the provider's order.
 */
object SubtitleRanking {
    private val noise = Regex("""\b(480p|576p|720p|1080p|2160p|4k|hdr|dv|web[- ]?dl|webrip|web|bluray|brrip|bdrip|hdrip|dvdrip|hdtv|x264|x265|h264|h265|hevc|av1|aac|ac3|eac3|dts|ddp?5\.?1|atmos|10bit|proper|repack|extended|unrated|remastered|srt|sub|subs)\b""", RegexOption.IGNORE_CASE)

    /** Lower case, without the quality and release words, brackets and punctuation: the words that name the title. */
    fun words(text: String): List<String> = noise.replace(text.lowercase().replace(Regex("""[(\[][^)\]]*[)\]]"""), " "), " ")
        .replace(Regex("""[^\p{L}\p{N}]+"""), " ").trim().split(' ').filter { it.isNotBlank() }

    /** 0 to 1: the share of words two names have in common (so "Alpha Beta" and "alpha.beta.2024.1080p" are the same title). */
    fun similarity(a: String, b: String): Double {
        val x = words(a).toSet(); val y = words(b).toSet()
        if (x.isEmpty() || y.isEmpty()) return 0.0
        return x.intersect(y).size.toDouble() / x.union(y).size
    }

    /** The release's own name reduced to what identifies the file (kept with its quality words, since "WEB-DL" and "BluRay" are different files). */
    private fun fileKey(text: String) = text.lowercase().replace(Regex("""\.(srt|sub|ass|vtt|mkv|mp4|avi|m4v|ts|mov|wmv|webm)$"""), "").replace(Regex("""[^\p{L}\p{N}]+"""), " ").trim()

    private fun sameLanguage(a: String, b: String) = a.isBlank() || b.isBlank() || a.equals(b, true) || a.substringBefore('-').equals(b.substringBefore('-'), true)

    fun rank(found: List<SubtitleCandidate>, want: SubtitleWanted): List<RankedSubtitle> {
        val ranked = ArrayList<RankedSubtitle>()
        for (c in found) {
            if (!sameLanguage(c.language, want.language)) continue
            val why = ArrayList<String>(); var score = 0
            // ---- Identity first. A subtitle for another episode or another title is not "less good", it is wrong.
            val wantsEpisode = want.season != null && want.episode != null
            var episodeKnown = false
            if (wantsEpisode && c.season != null && c.episode != null) {
                if (c.season != want.season || c.episode != want.episode) continue
                score += 300; episodeKnown = true; why += "Same season and episode"
            } else if (wantsEpisode) { score -= 100; why += "Episode not stated by the provider" }
            if (!wantsEpisode && (c.season != null || c.episode != null)) continue          // an episode's subtitle for a film
            val titleSim = c.title?.let { similarity(it, want.title) } ?: similarity(c.release.ifBlank { c.fileName }, want.title)
            val titleKnown = c.title != null
            if (titleKnown && titleSim < 0.5) continue
            if (titleKnown && titleSim >= 0.99) { score += 200; why += "Title matches" } else if (titleSim >= 0.5) { score += (titleSim * 120).roundToInt(); why += "Title is close" } else { score -= 150; why += "Title not stated" }
            val yearMatch = want.year != null && c.year != null && c.year == want.year
            if (want.year != null && c.year != null) { if (yearMatch) { score += 60; why += "Same year" } else if (kotlin.math.abs(c.year - want.year) > 1) { score -= 80; why += "Different year" } }
            // ---- The file itself
            var exact = false
            if (c.hashMatch) { score += 1000; exact = true; why += "Made for this exact file" }
            want.fileName?.takeIf { it.isNotBlank() }?.let { name ->
                val own = (c.release.ifBlank { c.fileName })
                if (fileKey(own) == fileKey(name)) { score += 700; exact = true; why += "Same release name" }
                else { val s = similarity(own, name); if (s > 0.3) { score += (s * 250).roundToInt(); why += "Release name is similar" } }
            }
            var runtimeAgrees = false
            if (want.runtimeMinutes != null && c.runtimeMinutes != null && c.runtimeMinutes > 0) {
                val off = kotlin.math.abs(c.runtimeMinutes - want.runtimeMinutes).toDouble() / want.runtimeMinutes
                when { off <= 0.03 -> { score += 120; runtimeAgrees = true; why += "Same running time" }; off <= 0.10 -> { score += 40; why += "Running time is close" }; off > 0.15 -> { score -= 150; why += "Different running time" } }
            }
            // ---- Preferences and the provider's own signals
            if (c.hearingImpaired == want.preferHearingImpaired) score += 25 else score -= if (want.preferHearingImpaired) 25 else 40
            score += minOf(60, (log10(c.downloads.toDouble() + 1) * 15).roundToInt()); score += (c.rating.coerceIn(0.0, 10.0) * 3).roundToInt()
            if (c.trusted) { score += 40; why += "From a trusted uploader" }
            if (c.aiTranslated) { score -= 120; why += "Translated by AI" }; if (c.machineTranslated) { score -= 200; why += "Machine translated" }
            val match = when {
                exact -> SubtitleMatch.EXACT_FILE
                wantsEpisode && episodeKnown && runtimeAgrees -> SubtitleMatch.SAME_EPISODE_AND_RUNTIME
                titleKnown && titleSim >= 0.99 && (episodeKnown || !wantsEpisode) && (yearMatch || want.year == null) -> SubtitleMatch.TITLE_MATCH
                else -> SubtitleMatch.POSSIBLE
            }
            val confidence = when {
                match == SubtitleMatch.EXACT_FILE -> SubtitleConfidence.HIGH
                match == SubtitleMatch.SAME_EPISODE_AND_RUNTIME && score >= 400 -> SubtitleConfidence.HIGH
                (match == SubtitleMatch.TITLE_MATCH && score >= 330) -> SubtitleConfidence.MEDIUM
                match == SubtitleMatch.SAME_EPISODE_AND_RUNTIME -> SubtitleConfidence.MEDIUM
                else -> SubtitleConfidence.LOW
            }
            ranked += RankedSubtitle(c, score, match, confidence, why)
        }
        return dedupe(ranked).sortedWith(compareByDescending<RankedSubtitle> { it.score }.thenByDescending { it.candidate.downloads }.thenBy { it.candidate.fileId })
    }

    /** The same subtitle uploaded more than once (same language, same release name, same hearing-impaired flag) is shown once: the best of them. */
    fun dedupe(list: List<RankedSubtitle>): List<RankedSubtitle> =
        list.groupBy { Triple(it.candidate.language.lowercase(), fileKey(it.candidate.release.ifBlank { it.candidate.fileName }), it.candidate.hearingImpaired) }
            .map { (_, same) -> same.maxWith(compareBy<RankedSubtitle> { it.score }.thenBy { it.candidate.downloads }.thenByDescending { it.candidate.fileId }) }
}
