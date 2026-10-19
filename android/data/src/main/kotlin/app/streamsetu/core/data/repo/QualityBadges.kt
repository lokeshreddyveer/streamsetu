package app.streamsetu.core.data.repo

/**
 * What a title's own text says about its picture and sound: "…[4K HDR] Dolby Atmos 5.1" gives 4K, HDR, Atmos and 5.1. It reads only the words the playlist put in the
 * title or the folder name, so a title with no such words shows nothing rather than a guess.
 */
object QualityBadges {
    private val rules = listOf(
        "4K" to Regex("""\b(4k|uhd|2160p)\b"""),
        "1080p" to Regex("""\b(fhd|1080p|1080i)\b"""),
        "720p" to Regex("""\b720p\b"""),
        "HDR10+" to Regex("""hdr10\s?(\+|plus)"""),
        "HDR" to Regex("""\bhdr(10)?\b(?!\s?(\+|plus))"""),
        "Dolby Vision" to Regex("""dolby[\s._-]?vision|\bdovi\b|\bdv\b"""),
        "Atmos" to Regex("""\batmos\b"""),
        "7.1" to Regex("""(?<![0-9])7\.1(?![0-9])"""),
        "5.1" to Regex("""(?<![0-9])5\.1(?![0-9])"""),
    )

    /** The badges for the given pieces of text, in a fixed order (picture, then sound), at most [limit]. */
    fun from(texts: List<String?>, limit: Int = 4): List<String> {
        val text = texts.filterNotNull().joinToString(" ").lowercase()
        if (text.isEmpty()) return emptyList()
        val out = ArrayList<String>()
        for ((label, rule) in rules) {
            if ((label == "720p" && ("4K" in out || "1080p" in out)) || (label == "1080p" && "4K" in out)) continue
            if (rule.containsMatchIn(text)) out += label
        }
        return out.take(limit)
    }
}
