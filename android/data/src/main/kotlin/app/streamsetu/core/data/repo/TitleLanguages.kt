package app.streamsetu.core.data.repo

/**
 * The language a playlist names in a title, such as "Whalefall (2026) (English)" or "Lucky Baskhar [Telugu]". Only a language written inside brackets is read, so a title
 * like "The Hindi Teacher" is not mistaken for a Hindi film; when the title says nothing, the folder name ("Telugu Movies") is used.
 */
object TitleLanguages {
    val known = listOf(
        "Arabic", "Bengali", "Chinese", "Dutch", "English", "French", "German", "Gujarati", "Hindi", "Indonesian", "Italian", "Japanese", "Kannada", "Korean",
        "Malayalam", "Marathi", "Persian", "Polish", "Portuguese", "Punjabi", "Russian", "Spanish", "Tamil", "Telugu", "Thai", "Turkish", "Urdu",
    )
    private val names = known.joinToString("|")
    private val inBrackets = Regex("""[(\[]([^)\]]*)[)\]]""")
    private val word = Regex("""\b($names)\b""", RegexOption.IGNORE_CASE)

    fun of(title: String, folderName: String? = null): String? {
        for (group in inBrackets.findAll(title)) word.find(group.groupValues[1])?.let { return canonical(it.value) }
        return folderName?.let { word.find(it)?.let { m -> canonical(m.value) } }
    }

    private fun canonical(found: String): String = known.first { it.equals(found, ignoreCase = true) }
}
