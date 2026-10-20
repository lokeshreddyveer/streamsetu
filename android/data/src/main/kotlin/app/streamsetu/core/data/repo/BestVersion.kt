package app.streamsetu.core.data.repo

/**
 * Which copy of a title is the best one to start with, judged only by the words the playlist put in its name and its folder ("[4K HDR]", "FHD", "HDCAM"). A recording
 * made in a cinema ranks below everything else, and a copy that says nothing about its quality ranks between SD and 720p. Nothing is guessed from the stream itself.
 */
object BestVersion {
    private val cinemaRip = Regex("""\b(cam|hdcam|hd-cam|camrip|ts|hdts|telesync|tc|telecine|scr|screener|dvdscr)\b""", RegexOption.IGNORE_CASE)
    private val standardDefinition = Regex("""\b(sd|480p|360p|576p)\b""", RegexOption.IGNORE_CASE)

    fun score(vararg texts: String?): Int {
        val badges = QualityBadges.from(texts.toList(), 9)
        val text = texts.filterNotNull().joinToString(" ")
        var s = when {
            "4K" in badges -> 400
            "1080p" in badges -> 300
            "720p" in badges -> 200
            standardDefinition.containsMatchIn(text) -> 50
            else -> 100
        }
        if ("Dolby Vision" in badges) s += 12
        if ("HDR10+" in badges) s += 10 else if ("HDR" in badges) s += 8
        if ("Atmos" in badges) s += 6
        if ("7.1" in badges) s += 3 else if ("5.1" in badges) s += 2
        if (cinemaRip.containsMatchIn(text)) s -= 400
        return s
    }

    /** The copies, best first. Copies that score the same keep the order they came in, so the one the person opened stays first when nothing is better. */
    fun <T> order(copies: List<T>, words: (T) -> List<String?>): List<T> = copies.withIndex().sortedWith(compareByDescending<IndexedValue<T>> { score(*words(it.value).toTypedArray()) }.thenBy { it.index }).map { it.value }

    /** The best copy; [preferred] wins a tie, so nothing changes when no copy is better than the one the person chose. */
    fun <T> pick(copies: List<T>, preferred: T, words: (T) -> List<String?>): T {
        if (copies.isEmpty()) return preferred
        val best = copies.maxOf { score(*words(it).toTypedArray()) }
        val mine = score(*words(preferred).toTypedArray())
        return if (mine >= best) preferred else order(copies, words).first()
    }
}
