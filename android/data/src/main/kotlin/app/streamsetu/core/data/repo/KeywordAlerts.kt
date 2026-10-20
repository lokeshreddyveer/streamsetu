package app.streamsetu.core.data.repo

/** The rules for guide alerts: a programme that has a watched word, starts between two minutes and a day and a half from now, and was not announced before. */
object KeywordAlerts {
    const val MAX_WORDS = 20
    const val HORIZON_MS = 36 * 3_600_000L
    const val MIN_LEAD_MS = 2 * 60_000L

    fun clean(word: String) = word.trim()

    /** The words with [word] added, or the same list when it is too short, a repeat (any letter case) or the list is full. */
    fun add(words: List<String>, word: String): List<String> {
        val w = clean(word)
        return if (w.length < 2 || words.size >= MAX_WORDS || words.any { it.equals(w, ignoreCase = true) }) words else words + w
    }

    fun key(programmeId: String, word: String) = "$programmeId|${word.lowercase()}"

    /** Which of [startsMs] (a programme's start) are worth announcing now. */
    fun inWindow(startMs: Long, now: Long) = startMs > now + MIN_LEAD_MS && startMs < now + HORIZON_MS
}
