package app.streamsetu.core.data.repo.smartmix

/**
 * What can be told about a title from its own words: its identity key, year, language, quality and folder family (see [IdentityKey]). A pure function, the same wherever it runs;
 * nothing about the title is read from the network and nothing is guessed from the stream.
 */
object Derive {
    data class Result(val identityKey: String, val year: Int?, val lang: String?, val qualityRank: Int, val isCam: Boolean, val folderKey: String?, val inHash: Long)

    /** English names of the language words providers put in titles and folder names. */
    private val names = mapOf(
        "english" to "English", "hindi" to "Hindi", "tamil" to "Tamil", "telugu" to "Telugu", "kannada" to "Kannada", "malayalam" to "Malayalam", "urdu" to "Urdu",
        "punjabi" to "Punjabi", "bengali" to "Bengali", "bangla" to "Bengali", "marathi" to "Marathi", "gujarati" to "Gujarati", "odia" to "Odia", "oriya" to "Odia",
        "assamese" to "Assamese", "nepali" to "Nepali", "sinhala" to "Sinhala", "sinhalese" to "Sinhala", "arabic" to "Arabic", "persian" to "Persian", "farsi" to "Persian",
        "hebrew" to "Hebrew", "turkish" to "Turkish", "spanish" to "Spanish", "french" to "French", "german" to "German", "italian" to "Italian", "portuguese" to "Portuguese",
        "russian" to "Russian", "korean" to "Korean", "japanese" to "Japanese", "chinese" to "Chinese", "thai" to "Thai", "indonesian" to "Indonesian", "malay" to "Malay",
        "vietnamese" to "Vietnamese", "tagalog" to "Filipino", "filipino" to "Filipino", "pashto" to "Pashto",
    )
    private val codes = mapOf(
        "en" to "English", "hi" to "Hindi", "ta" to "Tamil", "te" to "Telugu", "kn" to "Kannada", "ml" to "Malayalam", "ur" to "Urdu", "pa" to "Punjabi", "bn" to "Bengali", "mr" to "Marathi",
        "gu" to "Gujarati", "ar" to "Arabic", "fa" to "Persian", "tr" to "Turkish", "es" to "Spanish", "fr" to "French", "de" to "German", "it" to "Italian", "pt" to "Portuguese",
        "ru" to "Russian", "ko" to "Korean", "ja" to "Japanese", "zh" to "Chinese", "th" to "Thai", "id" to "Indonesian", "eng" to "English", "hin" to "Hindi", "tam" to "Tamil", "tel" to "Telugu",
    )

    /** The English name for a language word, name or two or three letter code ("hi", "Hindi", "HINDI"); null when it is none. */
    fun languageName(word: String?): String? { val w = word?.trim()?.lowercase(java.util.Locale.ROOT) ?: return null; return names[w] ?: codes[w] }

    private val tag = Regex("""[(\[]\s*(\p{L}+)\s*[)\]]""")
    private val subtitleWords = setOf("subtitles", "subtitle", "subs", "sub", "subbed")
    private val cinemaRip = Regex("""\b(cam|hdcam|hd-cam|camrip|ts|hdts|telesync|tc|telecine|scr|screener|dvdscr)\b""", RegexOption.IGNORE_CASE)

    /** The language in this order: a "(Tamil)" tag in the title; a dub named by the folder; the first language word of the folder (not one followed by "subtitles"); a language word in the title. */
    fun languageOf(title: String, folder: String?): String? {
        tag.findAll(title).firstNotNullOfOrNull { names[it.groupValues[1].lowercase(java.util.Locale.ROOT)] }?.let { return it }
        val words = folder?.let { IdentityKey.normalize(it).split(' ').filter { w -> w.isNotEmpty() } }.orEmpty()
        for (i in words.indices) {
            if (words[i] != "dubbed" && words[i] != "dub") continue
            val before = words.getOrNull(i - 1)?.let { names[it] }
            val after = if (words.getOrNull(i + 1) == "in") words.getOrNull(i + 2)?.let { names[it] } else words.getOrNull(i + 1)?.let { names[it] }
            (before ?: after)?.let { return it }
        }
        for (i in words.indices) {
            val n = names[words[i]] ?: continue
            if (words.getOrNull(i + 1) in subtitleWords) continue
            return n
        }
        return IdentityKey.normalize(title).split(' ').firstNotNullOfOrNull { names[it] }
    }

    /** 5 = 4K, 4 = FHD, 3 = HD, 2 = not marked, 1 = SD, 0 = a recording made in a cinema. */
    fun qualityRank(title: String, folder: String?): Int {
        val text = if (folder.isNullOrBlank()) title else "$title $folder"
        if (cinemaRip.containsMatchIn(text)) return 0
        val w = IdentityKey.normalize(text).split(' ').toHashSet()
        return when {
            "4k" in w || "uhd" in w || "2160p" in w -> 5
            "fhd" in w || "1080p" in w -> 4
            "hd" in w || "720p" in w -> 3
            "sd" in w || "480p" in w || "360p" in w || "576p" in w -> 1
            else -> 2
        }
    }

    fun folderKey(kind: String, categoryName: String?): String? = categoryName?.let { IdentityKey.normalize(it) }?.takeIf { it.isNotEmpty() }?.let { "$kind|$it" }

    /** What the row was derived from, as one number: when it is the same the row is not derived again. The rule's version is part of it, so a new rule re-derives everything once. */
    fun inHash(kind: String, title: String, categoryName: String?, year: Int?): Long = IdentityKey.fnv1a64("v${IdentityKey.VERSION}|$kind|$title|${categoryName.orEmpty()}|${year ?: 0}")

    fun derive(kind: String, title: String, categoryName: String?, year: Int?): Result {
        val rank = qualityRank(title, categoryName)
        return Result(IdentityKey.ofOrFallback(title), IdentityKey.yearOf(title, year), languageOf(title, categoryName), rank, rank == 0, folderKey(kind, categoryName), inHash(kind, title, categoryName, year))
    }
}
