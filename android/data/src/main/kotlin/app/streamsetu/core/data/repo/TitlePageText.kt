package app.streamsetu.core.data.repo

/** The short texts of the title page (movie and series), as pure functions so the phone, the TV and the tests read the same words. */
object TitlePageText {
    /** "★ 7.4", or null for anything that is not a credible rating (0, 10.0, unknown, text). */
    fun rating(raw: String?): String? = DisplayRating.starText(raw)

    /** "01:48:00" or "108 min" or "6480" (seconds) as "1h 48m"; null for empty or zero. */
    fun runtime(raw: String?): String? {
        val t = raw?.trim().orEmpty()
        if (t.isEmpty()) return null
        val minutes = when {
            Regex("""\d+:\d{2}(:\d{2})?""").matches(t) -> t.split(':').map { it.toInt() }.let { p -> if (p.size == 3) p[0] * 60 + p[1] else p[0] }
            t.endsWith("min", true) -> t.dropLast(3).trim().toIntOrNull()
            t.toIntOrNull() != null -> t.toInt().let { if (it > 600) it / 60 else it }
            else -> null
        } ?: return null
        if (minutes <= 0) return null
        return if (minutes >= 60) "${minutes / 60}h" + (if (minutes % 60 > 0) " ${minutes % 60}m" else "") else "${minutes}m"
    }

    /** FHD, 4K or HD from the words in the title, else null (nothing is guessed). */
    fun quality(vararg texts: String?): String? = QualityBadges.from(texts.toList()).let { b -> when { "4K" in b -> "4K"; "1080p" in b -> "FHD"; "720p" in b -> "HD"; else -> null } }

    /** "2006 · 2h 48m · PG-13 · FHD · ★ 7.4": only what is known, quietly, in this order. */
    fun metaLine(year: Int?, runtime: String?, ageRating: String?, quality: String?, ratingRaw: String?): String =
        listOfNotNull(year?.toString(), runtime?.takeIf { it.isNotBlank() }, ageRating?.takeIf { it.isNotBlank() }, quality, rating(ratingRaw)).joinToString(" · ")

    /** "English · 2 versions ▾"; null when there is only one version. [language] is the current version's language (or its label). */
    fun pickerLabel(language: String?, count: Int): String? = if (count < 2) null else listOfNotNull(language?.takeIf { it.isNotBlank() }, "$count versions").joinToString(" · ") + " ▾"

    fun playMovie(positionMs: Long, durationMs: Long, resumable: Boolean): String = if (!resumable) "Play" else "Resume · ${left((durationMs - positionMs).coerceAtLeast(0))} left"
    private fun left(ms: Long): String { val m = (ms / 60000).toInt(); return if (m >= 60) "${m / 60}h" + (if (m % 60 > 0) " ${m % 60}m" else "") else "${m.coerceAtLeast(1)}m" }

    /** The series Play button: "Play S1 E3", "Resume S1 E3", "Watch again", or what is happening while episodes load. */
    fun playSeries(inProgress: Pair<Int, Int>?, forward: Pair<Int, Int>?, first: Pair<Int, Int>?, allFinished: Boolean, loading: Boolean): String = when {
        inProgress != null -> "Resume S${inProgress.first} E${inProgress.second}"
        forward != null -> "Play S${forward.first} E${forward.second}"
        first != null && allFinished -> "Watch again"
        first != null -> "Play S${first.first} E${first.second}"
        loading -> "Loading episodes…"
        else -> "No episodes"
    }

    /** "Action, Drama / Thriller" into chips. */
    fun genres(raw: String?): List<String> = raw.orEmpty().split(',', '/', '|', ';').map { it.trim() }.filter { it.length in 2..28 }.distinct().take(6)

    /** The names in "A, B and C" or "A, B, C". */
    fun people(raw: String?, max: Int = 8): List<String> = raw.orEmpty().replace(" and ", ", ").split(',', ';', '/').map { it.trim() }.filter { it.length in 2..60 }.distinct().take(max)

    data class Row(val label: String, val value: String? = null, val names: List<String> = emptyList(), val folder: Boolean = false)
    /** The details list, top to bottom: only rows that have something to say. */
    fun details(director: String?, cast: String?, country: String?, studio: String?, released: String?, hasFolder: Boolean): List<Row> = listOfNotNull(
        people(director).takeIf { it.isNotEmpty() }?.let { Row("Directed by", names = it) },
        people(cast).takeIf { it.isNotEmpty() }?.let { Row("Starring", names = it) },
        country?.takeIf { it.isNotBlank() }?.let { Row("Country", it.trim()) },
        studio?.takeIf { it.isNotBlank() }?.let { Row("Studio", it.trim()) },
        released?.takeIf { it.isNotBlank() }?.let { Row("Released", it.trim()) },
        if (hasFolder) Row("In folder", folder = true) else null,
    )
}
