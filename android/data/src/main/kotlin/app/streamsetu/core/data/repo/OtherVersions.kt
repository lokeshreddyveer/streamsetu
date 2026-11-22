package app.streamsetu.core.data.repo

import kotlin.math.abs

/**
 * "Other languages": the same film or show elsewhere in the library, in another language (providers list a dub as its own title, "Leo (2023) (Tamil) FHD" next to "Leo 2023 Hindi"),
 * or as a different copy in another playlist. Titles are matched with [Similarity.identity], as everywhere else in the app; this is the grouping and the labels, a pure function
 * that can be tested.
 *
 * What real libraries do, and what the rules here answer:
 * - The same playlist added twice gives every title a twin. A twin (another playlist, the same title, year and folder) is not a version and is not shown.
 * - Most titles carry their language only in their folder's name ("TELUGU | GENERAL", "ENGLISH | HINDI DUBBED"). The folder is read before a loose word in the title, a dub
 *   is read as the dubbed language, and "ARABIC SUBTITLES" is not an Arabic version.
 * - Providers date the same film a year apart in different languages. A one-year difference matches when something else agrees (the running time, the rating, the start of
 *   the description, the genres, the number of seasons).
 */
object OtherVersions {
    enum class Kind { MOVIE, SERIES }

    /**
     * A title as the grouping sees it. [folder]: its folder's name. [playlist]: its playlist's name. [providerKey]: the provider's own id for it (the same item in a duplicate
     * playlist has the same one). [durationSec], [genres] and [seasons] are optional extra evidence for a one-year difference; null when not known.
     */
    data class Candidate(
        val id: String, val kind: Kind, val title: String, val year: Int?, val folder: String?, val sourceId: String, val playlist: String?,
        val rating: String? = null, val plot: String? = null, val durationSec: Int? = null, val genres: Set<String>? = null, val seasons: Int? = null, val providerKey: String? = null,
    )

    /** What a version's language is: its English name (null when unknown), whether it is a dub, and the folder's own words when no language is named. */
    data class Language(val name: String?, val dubbed: Boolean, val folderLabel: String?)

    /**
     * One version for the row. [language]: the English name, or the folder's words ("Indian", "Multi language") when no language is named, or null. [native]: the second line:
     * "Dubbed" for a dub; for the first version of a language, the language in its own script; for a further version of the same language, its folder's own words ("2026",
     * "FHD 2025"), or else its quality and length ("FHD · 1h 48m"), or "Another version". No playlist or profile name is ever shown. [quality]: 4K, FHD, HD, SD or CAM.
     * [label]: everything on one line (for a screen reader).
     */
    data class Version(
        val id: String, val language: String?, val native: String?, val dubbed: Boolean, val quality: String?, val label: String, val current: Boolean,
    )

    // ---- Languages ----

    /** Language words in titles and folder names, and the name shown for each. Several spellings share one name (Bangla and Bengali, Farsi and Persian). */
    private val names = mapOf(
        "english" to "English", "hindi" to "Hindi", "tamil" to "Tamil", "telugu" to "Telugu", "kannada" to "Kannada", "malayalam" to "Malayalam", "urdu" to "Urdu",
        "punjabi" to "Punjabi", "bengali" to "Bengali", "bangla" to "Bengali", "marathi" to "Marathi", "gujarati" to "Gujarati", "odia" to "Odia", "oriya" to "Odia",
        "assamese" to "Assamese", "nepali" to "Nepali", "sinhala" to "Sinhala", "sinhalese" to "Sinhala", "arabic" to "Arabic", "persian" to "Persian", "farsi" to "Persian",
        "hebrew" to "Hebrew", "turkish" to "Turkish", "spanish" to "Spanish", "french" to "French", "german" to "German", "italian" to "Italian", "portuguese" to "Portuguese",
        "russian" to "Russian", "korean" to "Korean", "japanese" to "Japanese", "chinese" to "Chinese", "thai" to "Thai", "indonesian" to "Indonesian", "malay" to "Malay",
        "vietnamese" to "Vietnamese", "tagalog" to "Filipino", "filipino" to "Filipino", "pashto" to "Pashto",
    )

    /** Each language in its own script, for the second line of a chip. */
    private val nativeNames = mapOf(
        "Telugu" to "తెలుగు", "Hindi" to "हिन्दी", "Tamil" to "தமிழ்", "Malayalam" to "മലയാളം", "Kannada" to "ಕನ್ನಡ", "Bengali" to "বাংলা", "Marathi" to "मराठी",
        "Gujarati" to "ગુજરાતી", "Punjabi" to "ਪੰਜਾਬੀ", "Urdu" to "اردو", "Odia" to "ଓଡ଼ିଆ", "Assamese" to "অসমীয়া", "Nepali" to "नेपाली", "Sinhala" to "සිංහල",
        "Arabic" to "العربية", "Persian" to "فارسی", "Hebrew" to "עברית", "English" to "English", "Spanish" to "Español", "French" to "Français", "German" to "Deutsch",
        "Italian" to "Italiano", "Portuguese" to "Português", "Russian" to "Русский", "Korean" to "한국어", "Japanese" to "日本語", "Chinese" to "中文", "Thai" to "ไทย",
        "Turkish" to "Türkçe", "Indonesian" to "Bahasa Indonesia", "Malay" to "Bahasa Melayu", "Vietnamese" to "Tiếng Việt", "Filipino" to "Filipino", "Pashto" to "پښتو",
    )

    private val tag = Regex("""[(\[]\s*(\p{L}+)\s*[)\]]""")
    private val subtitleWords = setOf("subtitles", "subtitle", "subs", "sub", "subbed")
    /** Words of a folder name that say nothing about the language, left out of its label: "INDIAN | GENERAL" is labelled "Indian". */
    private val folderNoise = setOf("general", "movies", "movie", "series", "shows", "show", "tv", "vod", "hd", "fhd", "uhd", "4k", "sd", "new", "latest", "all", "and", "the")

    /** The English name of a language word, or null. */
    fun languageName(word: String): String? = names[word.lowercase()]

    /** The language in its own script, or null. */
    fun nativeName(language: String): String? = nativeNames[language]

    /**
     * A version's language, in this order: (a) a "(Tamil)" or "[Tamil]" tag in the title; (b) a dub named by the folder ("HINDI DUBBED", "DUBBED IN HINDI", "ENGLISH | HINDI
     * DUBBED"), which is that language and marked as a dub; (c) the first language word of the folder, leaving out one followed by "SUBTITLES" (subtitles are not a version);
     * (d) a language word elsewhere in the title. With none of these, the folder's own words are kept as its label.
     */
    fun languageOf(title: String, folder: String?): Language {
        tag.findAll(title).firstNotNullOfOrNull { languageName(it.groupValues[1]) }?.let { return Language(it, dubbed = false, folderLabel = null) }
        val words = folder?.let { Similarity.normalize(it).split(' ').filter { w -> w.isNotEmpty() } }.orEmpty()
        for (i in words.indices) {
            if (words[i] != "dubbed" && words[i] != "dub") continue
            val before = words.getOrNull(i - 1)?.let(::languageName)
            val after = if (words.getOrNull(i + 1) == "in") words.getOrNull(i + 2)?.let(::languageName) else words.getOrNull(i + 1)?.let(::languageName)
            (before ?: after)?.let { return Language(it, dubbed = true, folderLabel = null) }
        }
        for (i in words.indices) {
            val name = languageName(words[i]) ?: continue
            if (words.getOrNull(i + 1) in subtitleWords) continue
            return Language(name, dubbed = false, folderLabel = null)
        }
        Similarity.normalize(title).split(' ').firstNotNullOfOrNull { languageName(it) }?.let { return Language(it, dubbed = false, folderLabel = null) }
        val label = words.filter { it !in folderNoise && it.any(Char::isLetter) }.joinToString(" ").replaceFirstChar { it.uppercaseChar() }
        return Language(null, dubbed = false, folderLabel = label.ifBlank { null })
    }

    // ---- Matching ----

    private val yearInTitle = Regex("""(?<!\d)(19|20)\d{2}(?!\d)""")

    /** The year from the provider, or a 19xx/20xx year written in the title. */
    fun yearOf(title: String, year: Int?): Int? = year?.takeIf { it in 1888..2100 } ?: yearInTitle.find(title)?.value?.toInt()

    /** The quality written in a title: 4K (also UHD, 2160p), FHD (1080p), HD (720p), SD (480p) or CAM (also HDCAM). */
    fun qualityOf(title: String): String? {
        val w = Similarity.normalize(title).split(' ').toSet()
        return when {
            "4k" in w || "uhd" in w || "2160p" in w -> "4K"
            "cam" in w || "hdcam" in w || "camrip" in w -> "CAM"
            "fhd" in w || "1080p" in w -> "FHD"
            "hd" in w || "720p" in w -> "HD"
            "sd" in w || "480p" in w -> "SD"
            else -> null
        }
    }

    /** The key two versions share: the identity, without a leading article and with "and" left out (so "The Fast & Furious" meets "Fast and Furious"). */
    fun key(title: String): String {
        val words = Similarity.identity(title).split(' ').filter { it.isNotEmpty() && it != "and" }.toMutableList()
        if (words.size > 1 && words.first() in setOf("the", "a", "an")) words.removeAt(0)
        return words.joinToString(" ")
    }

    private fun sameRating(a: String?, b: String?): Boolean {
        val x = a?.toDoubleOrNull()?.takeIf { it > 0 } ?: return false; val y = b?.toDoubleOrNull()?.takeIf { it > 0 } ?: return false
        return abs(x - y) < 0.05
    }
    private fun samePlotStart(a: String?, b: String?): Boolean {
        val x = a?.let(Similarity::normalize)?.takeIf { it.length >= 40 } ?: return false; val y = b?.let(Similarity::normalize)?.takeIf { it.length >= 40 } ?: return false
        return x.take(40) == y.take(40)
    }

    /** How many signals besides the title say two entries are the same film or show. */
    fun corroboration(a: Candidate, b: Candidate): Int {
        var n = 0
        if (a.durationSec != null && b.durationSec != null && a.durationSec > 0 && b.durationSec > 0 && abs(a.durationSec - b.durationSec) <= 0.08 * maxOf(a.durationSec, b.durationSec)) n++
        if (sameRating(a.rating, b.rating)) n++
        if (samePlotStart(a.plot, b.plot)) n++
        if (!a.genres.isNullOrEmpty() && a.genres == b.genres) n++
        if (a.kind == Kind.SERIES && a.seasons != null && b.seasons != null && abs(a.seasons - b.seasons) <= 1) n++
        return n
    }

    /**
     * True when [c] is another version of [open]: the same kind, the same key (and not an empty one), and years that agree. The same year matches; a year apart matches when
     * one other signal agrees (two for a short one-word title of up to seven letters, which many films share); no year on one side matches when the title has two words or more, or a signal agrees.
     */
    fun sameTitle(open: Candidate, c: Candidate, openKey: String = key(open.title)): Boolean {
        if (c.kind != open.kind || openKey.isEmpty() || key(c.title) != openKey) return false
        val ya = yearOf(open.title, open.year); val yb = yearOf(c.title, c.year)
        // A short one-word title ("Tuesday", "Stolen": the brief's own examples, so up to seven letters) is shared by many unrelated films.
        val short = !openKey.contains(' ') && openKey.length <= 7
        return when {
            ya != null && yb != null -> when (abs(ya - yb)) { 0 -> true; 1 -> corroboration(open, c) >= (if (short) 2 else 1); else -> false }
            ya == null && yb == null -> true
            else -> openKey.contains(' ') || corroboration(open, c) >= 1
        }
    }

    /** A twin from a duplicate playlist: another playlist, the same title, year and folder (or the same provider id and running time). */
    fun twin(a: Candidate, b: Candidate): Boolean {
        if (a.sourceId == b.sourceId) return false
        if (a.providerKey != null && a.providerKey == b.providerKey && a.durationSec == b.durationSec) return true
        return Similarity.normalize(a.title) == Similarity.normalize(b.title) && yearOf(a.title, a.year) == yearOf(b.title, b.year) &&
            (a.folder?.let(Similarity::normalize) ?: "") == (b.folder?.let(Similarity::normalize) ?: "")
    }

    private val qualityRank = listOf("4K", "FHD", "HD", "SD", "CAM")

    /**
     * The versions of [open] found in [pool], the open one first; empty when there is no other version. A twin of one already listed is left out; so is a copy with the same
     * language, dub and quality as one already listed, unless it comes from another folder of another playlist (then its second line tells them apart). The language the
     * person listens to ([preferred]) comes right after the open version; the rest are in alphabetical order, then by quality.
     */
    fun group(open: Candidate, pool: List<Candidate>, preferred: String? = null): List<Version> {
        val k = key(open.title)
        if (k.isEmpty()) return emptyList()
        val matches = pool.filter { it.id != open.id && sameTitle(open, it, k) }
        if (matches.isEmpty()) return emptyList()
        fun folderOf(c: Candidate) = c.folder?.let(Similarity::normalize) ?: ""
        val kept = mutableListOf(Kept(open, languageOf(open.title, open.folder), qualityOf(open.title)))
        for (c in matches) {
            if (kept.any { twin(it.c, c) }) continue
            val lang = languageOf(c.title, c.folder); val q = qualityOf(c.title)
            val same = kept.filter { it.lang.name == lang.name && it.lang.dubbed == lang.dubbed && it.quality == q && (lang.name != null || it.lang.folderLabel == lang.folderLabel) }
            if (same.any { it.c.sourceId == c.sourceId || folderOf(it.c) == folderOf(c) }) continue
            kept += Kept(c, lang, q)
        }
        if (kept.size < 2) return emptyList()
        // The order shown: the open version, then the language the person listens to, then the rest in alphabetical order, dubs after originals, then by quality.
        val pref = preferred?.let { languageName(it) ?: it }
        val ordered = listOf(kept.first()) + kept.drop(1).sortedWith(
            compareBy<Kept>({ if (pref != null && it.name.equals(pref, true)) 0 else 1 }, { it.name ?: "\uFFFF" }, { if (it.lang.dubbed) 1 else 0 },
                { qualityRank.indexOf(it.quality).let { i -> if (i < 0) 99 else i } }, { it.c.title })
        )
        // The second line of each chip.
        val firstOf = HashSet<String?>()
        val seconds = ArrayList<String?>()
        for (kp in ordered) {
            val second = when {
                kp.lang.dubbed -> "Dubbed"
                firstOf.add(kp.name) -> kp.lang.name?.let(::nativeName)
                else -> folderWords(kp.c.folder)?.takeIf { w -> w !in seconds } ?: qualityAndLength(kp)?.takeIf { w -> w !in seconds } ?: "Another version"
            }
            seconds += second
        }
        return ordered.mapIndexed { i, kp ->
            val name = kp.name
            val label = listOfNotNull(name ?: kp.quality ?: "Another version", if (kp.lang.dubbed) "dubbed" else null, kp.quality.takeIf { name != null },
                seconds[i].takeIf { !kp.lang.dubbed && it != kp.lang.name?.let(::nativeName) }).joinToString(", ")
            Version(kp.c.id, name, seconds[i], kp.lang.dubbed, kp.quality, label, kp.c.id == open.id)
        }
    }

    /** The open version on its own, for the line under the title ("Hindi · Dubbed · FHD"): its language (or folder words), whether it is a dub, and its quality. */
    fun describe(c: Candidate): Version {
        val lang = languageOf(c.title, c.folder); val q = qualityOf(c.title)
        val name = lang.name ?: lang.folderLabel
        val label = listOfNotNull(name, if (lang.dubbed) "Dubbed" else null, q).joinToString(" · ")
        return Version(c.id, name, if (lang.dubbed) "Dubbed" else lang.name?.let(::nativeName), lang.dubbed, q, label, current = true)
    }

    /** A folder name without its language words and separators, in sentence case: "TELUGU | 2026" is "2026", "TAMIL | GENERAL" is "General". Null when nothing is left. */
    fun folderWords(folder: String?): String? {
        val words = folder?.let { Similarity.normalize(it).split(' ').filter { w -> w.isNotEmpty() && languageName(w) == null && w != "dubbed" && w != "dub" } }.orEmpty()
        if (words.isEmpty()) return null
        return words.joinToString(" ") { w -> if (w in setOf("fhd", "uhd", "hd", "sd", "4k", "hdr", "vod", "tv", "uk", "us", "usa")) w.uppercase() else w }.replaceFirstChar { it.uppercaseChar() }
    }

    /** A version found for the row, with what was read from it. */
    private class Kept(val c: Candidate, val lang: Language, val quality: String?) { val name get() = lang.name ?: lang.folderLabel }

    /** "FHD · 1h 48m": the quality and the running time, when the folder says nothing that tells two versions apart. */
    private fun qualityAndLength(kp: Kept): String? {
        val c = kp.c
        val q = kp.quality
        val len = c.durationSec?.takeIf { it > 0 }?.let { s -> val m = (s + 30) / 60; if (m >= 60) "${m / 60}h ${m % 60}m" else "${m}m" }
        return listOfNotNull(q, len).joinToString(" · ").ifBlank { null }
    }
}
