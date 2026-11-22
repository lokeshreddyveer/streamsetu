package app.streamsetu.core.data.repo.smartmix

import java.text.Normalizer
import java.util.Locale

/**
 * What a title is, with everything that only says which copy it is taken out: year, quality, language, "dubbed", a leading article and "and". Two copies of the same film or
 * show (another language, another quality, the same playlist added twice) share one key. This is version 1 of the rule and is frozen: changing it means raising [VERSION],
 * which makes every saved key be derived again in the background.
 */
object IdentityKey {
    const val VERSION = 1

    private val spaces = Regex("\\s+")

    /**
     * Lower case with the root locale, accents removed from Latin letters, every character that is not a letter or digit becomes a space. Vowel signs of other scripts (Tamil, Hindi, Thai...) are
     * part of their word and stay, so two different words in those scripts never fall together.
     */
    fun normalize(s: String): String {
        val folded = Normalizer.normalize(s, Normalizer.Form.NFKD).lowercase(Locale.ROOT)
        val sb = StringBuilder(folded.length)
        var latin = false
        var i = 0
        // By code point (a letter outside the first plane, a CJK extension for instance, is one letter and not two stray halves), and with the accents to drop taken from the frozen
        // table of marks that the Smart Mix engine also uses, so the key does not depend on the Unicode version of the phone's system library.
        while (i < folded.length) {
            val cp = folded.codePointAt(i); i += Character.charCount(cp)
            when {
                app.streamsetu.core.data.smartmix.CombiningClass.isCombining(cp) -> if (!latin) sb.appendCodePoint(cp)          // an accent on a Latin letter is dropped; a mark of another script is kept
                Character.getType(cp) == Character.COMBINING_SPACING_MARK.toInt() || Character.getType(cp) == Character.NON_SPACING_MARK.toInt() -> sb.appendCodePoint(cp)          // a vowel sign or other mark that joins its letter is part of the word
                Character.isLetterOrDigit(cp) -> { sb.appendCodePoint(cp); latin = isLatin(cp) }
                else -> { sb.append(' '); latin = false }
            }
        }
        return sb.toString().trim().replace(spaces, " ")
    }

    /** Latin letters, by fixed ranges (not by the system's script table). */
    private fun isLatin(cp: Int) = cp in 0x41..0x5A || cp in 0x61..0x7A || cp in 0xC0..0x24F || cp in 0x1E00..0x1EFF || cp in 0x2C60..0x2C7F || cp in 0xA720..0xA7FF || cp in 0xFF21..0xFF3A || cp in 0xFF41..0xFF5A

    internal val languageWords = setOf("english", "hindi", "tamil", "telugu", "kannada", "malayalam", "urdu", "punjabi", "bengali", "marathi", "gujarati", "arabic", "spanish", "french", "german", "korean", "japanese", "chinese", "turkish", "russian", "italian", "portuguese", "thai", "indonesian",
        "bangla", "odia", "oriya", "assamese", "nepali", "sinhala", "sinhalese", "pashto", "farsi", "tagalog", "vietnamese", "hebrew")
    internal val noiseWords = setOf("hd", "fhd", "uhd", "4k", "sd", "hdcam", "cam", "webrip", "web", "dl", "bluray", "dvdrip", "hevc", "x264", "x265", "h264", "h265", "dubbed", "dub", "multi", "sub", "subs", "eng", "season", "episode")
    private val articles = setOf("the", "a", "an")

    private fun isYear(w: String) = w.length == 4 && w.all(Char::isDigit) && (w.startsWith("19") || w.startsWith("20"))

    /** The key of a title; empty when nothing is left of it. */
    fun of(title: String): String {
        val words = normalize(title).split(' ').filter { it.isNotEmpty() && !isYear(it) && it !in noiseWords && it !in languageWords && it != "and" }.toMutableList()
        if (words.size > 1 && words.first() in articles) words.removeAt(0)
        return words.joinToString(" ")
    }

    /** The key, or the plain normalized title when the key came out empty (a title made only of tags), so a row always has one. */
    fun ofOrFallback(title: String): String = of(title).ifEmpty { normalize(title) }

    private val yearInTitle = Regex("""(?<!\d)(19|20)\d{2}(?!\d)""")

    /** The year from the provider, or a 19xx/20xx year written in the title. */
    fun yearOf(title: String, year: Int?): Int? = year?.takeIf { it in 1888..2100 } ?: yearInTitle.find(title)?.value?.toInt()

    /** 64-bit FNV-1a, the same on every platform. */
    fun fnv1a64(s: String): Long {
        var h = -3750763034362895579L
        for (b in s.toByteArray(Charsets.UTF_8)) h = (h xor (b.toLong() and 0xff)) * 1099511628211L
        return h
    }
}
