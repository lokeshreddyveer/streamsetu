package app.streamsetu.core.model

/**
 * Counted phrases in English, Hindi and Telugu ("1 title", "2 titles"), chosen by the CLDR rule of the language: English and Telugu use "one" for exactly 1; Hindi uses "one" for 0 and 1.
 * A table, so a phrase or a language is added by adding a row. Each form holds one `{}` where the number goes. [language] follows the app's language setting (see the I18n object of the app).
 */
object Plurals {
    @Volatile var language: String = "en"

    /** key -> language -> (one, other). */
    private val table: Map<String, Map<String, Pair<String, String>>> = mapOf(
        "title" to mapOf("en" to ("{} title" to "{} titles"), "hi" to ("{} शीर्षक" to "{} शीर्षक"), "te" to ("{} శీర్షిక" to "{} శీర్షికలు")),
        "titleInLibrary" to mapOf("en" to ("{} title in your library" to "{} titles in your library"), "hi" to ("आपकी लाइब्रेरी में {} शीर्षक" to "आपकी लाइब्रेरी में {} शीर्षक"), "te" to ("మీ లైబ్రరీలో {} శీర్షిక" to "మీ లైబ్రరీలో {} శీర్షికలు")),
        "match" to mapOf("en" to ("{} match" to "{} matches"), "hi" to ("{} मिलान" to "{} मिलान"), "te" to ("{} సరిపోలిక" to "{} సరిపోలికలు")),
        "channel" to mapOf("en" to ("{} channel" to "{} channels"), "hi" to ("{} चैनल" to "{} चैनल"), "te" to ("{} ఛానెల్" to "{} ఛానెల్స్")),
        "result" to mapOf("en" to ("{} result" to "{} results"), "hi" to ("{} परिणाम" to "{} परिणाम"), "te" to ("{} ఫలితం" to "{} ఫలితాలు")),
        "season" to mapOf("en" to ("{} season" to "{} seasons"), "hi" to ("{} सीज़न" to "{} सीज़न"), "te" to ("{} సీజన్" to "{} సీజన్లు")),
        "feed" to mapOf("en" to ("{} feed" to "{} feeds"), "hi" to ("{} फ़ीड" to "{} फ़ीड"), "te" to ("{} ఫీడ్" to "{} ఫీడ్‌లు")),
        "view" to mapOf("en" to ("{} view" to "{} views"), "hi" to ("{} व्यू" to "{} व्यू"), "te" to ("{} వ్యూ" to "{} వ్యూలు")),
        "reminderSet" to mapOf("en" to ("{} reminder set." to "{} reminders set."), "hi" to ("{} रिमाइंडर सेट किया गया।" to "{} रिमाइंडर सेट किए गए।"), "te" to ("{} రిమైండర్ సెట్ చేయబడింది." to "{} రిమైండర్లు సెట్ చేయబడ్డాయి.")),
        "reminder" to mapOf("en" to ("{} reminder" to "{} reminders"), "hi" to ("{} रिमाइंडर" to "{} रिमाइंडर"), "te" to ("{} రిమైండర్" to "{} రిమైండర్లు")),
        "connection" to mapOf("en" to ("{} connection" to "{} connections"), "hi" to ("{} कनेक्शन" to "{} कनेक्शन"), "te" to ("{} కనెక్షన్" to "{} కనెక్షన్లు")),
        "decoder" to mapOf("en" to ("{} decoder" to "{} decoders"), "hi" to ("{} डिकोडर" to "{} डिकोडर"), "te" to ("{} డీకోడర్" to "{} డీకోడర్లు")),
    )

    val keys: Set<String> get() = table.keys
    val languages = listOf("en", "hi", "te")
    fun forms(key: String, lang: String): Pair<String, String>? = table[key]?.get(lang)

    /** "one" or "other" for a count in a language. */
    fun category(lang: String, n: Long): String = if (lang == "hi") (if (n == 0L || n == 1L) "one" else "other") else (if (n == 1L) "one" else "other")

    /** The phrase for [n] in [lang] (the current language by default); English when the language or key is missing. */
    fun format(key: String, n: Long, lang: String = language): String {
        val f = forms(key, lang) ?: forms(key, "en") ?: return n.toString()
        return (if (category(lang, n) == "one") f.first else f.second).replace("{}", n.toString())
    }
    fun format(key: String, n: Int, lang: String = language) = format(key, n.toLong(), lang)
}
