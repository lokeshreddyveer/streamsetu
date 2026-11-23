package app.streamsetu.core.data.repo

import app.streamsetu.core.data.repo.smartmix.IdentityKey
import java.text.Normalizer

/**
 * The one pure rule that turns a provider's title ("TELUGU | Pushpa The Rise (Telugu) FHD 2026") into the name TMDB knows. The same rules are used by the Apple and Windows apps; the cases are in
 * artwork/fixtures/name-cleaning.json (see the README there) and [ArtworkNamesTests] runs every one. Case, accents, "&", colons, roman numerals and non-Latin scripts are left alone.
 */
object ArtworkNames {
    data class Parsed(val text: String, val year: Int?)

    private val languages = setOf("telugu", "hindi", "tamil", "malayalam", "kannada", "bengali", "bangla", "marathi", "punjabi", "gujarati", "urdu", "english", "arabic", "spanish", "french", "german", "turkish", "korean", "japanese", "chinese", "italian", "russian", "portuguese", "thai", "indonesian", "persian", "dutch", "polish", "odia", "assamese", "nepali", "sinhala", "hebrew", "vietnamese", "tagalog", "malay", "pashto", "farsi", "filipino", "oriya", "odiya", "multi")
    private val prefixes = setOf("in", "us", "uk", "en", "fr", "de", "es", "it", "pt", "tr", "ar", "hi", "te", "ta", "ml", "kn", "bn", "mr", "pa", "gu", "ur", "pk", "bd", "lk", "nl", "pl", "ru", "kr", "jp", "cn", "ir", "ca", "au", "mx", "br", "nf", "amzn", "dsnp", "hotstar", "zee5", "sonyliv", "jio", "atvp", "hulu", "max", "hbo", "ja", "ko", "zh", "th", "id", "vi", "fa", "he", "sv", "da", "fi", "el", "cs", "hu", "ro", "bg", "sr", "hr", "sk", "sl", "sa", "ae", "qa", "eg", "sg", "my", "ph", "za", "ng", "ke", "nz", "ie", "se", "dk", "gr", "at", "ch", "be", "prime", "netflix", "vod", "mov", "movie", "movies", "series", "new", "top")
    private val strongTags = setOf("4k", "uhd", "fhd", "hevc", "x264", "x265", "h264", "h265", "avc", "hdr10", "hdr10+", "1080p", "720p", "480p", "360p", "1440p", "2160p", "1080i", "web-dl", "webdl", "webrip", "bluray", "blu-ray", "brrip", "bdrip", "dvdrip", "hdtv", "hdrip", "hdcam", "hdts", "10bit", "5.1", "atmos")
    private val weakTags = setOf("hd", "sd", "hq", "hdr", "cam", "dubbed", "dub", "subbed", "sub", "subs", "dual", "audio", "multi", "uncut", "extended", "remastered", "proper", "new", "dv", "vod", "original")
    private const val MARK = "\u0001"
    private val separatorSet = setOf("-", "|", ":", "~", "/", MARK)
    private val seasonWord = setOf("season", "series", "saison", "temporada")
    private val tailTrim = charArrayOf(',', '.', '-', ':', '|')
    private val edgeTrim = charArrayOf(' ', '-', ':', '|', '.', ',', '~', '/')
    private val seasonCode = Regex("^s\\d{1,2}(e\\d{1,3})?$")
    private val smallNumber = Regex("^\\d{1,2}$")
    private val episodeX = Regex("^\\d{1,2}x\\d{1,3}$")
    private val episodeNumber = Regex("^\\d{1,3}$")
    private val episodeWord = setOf("episode", "ep", "episodio", "folge")
    private val releaseGroup = Regex("[-.\\s](yify|yts([. ]mx)?|rarbg|etrg|mkvcage|fgt|ntb|tgx|psa|evo|ntg|ion10|sparks|cmrg|galaxytv|eztv|ettv|rartv|mkvking|tigole|qxr|megusta|pahe)\\s*$", RegexOption.IGNORE_CASE)
    private val attachedGroup = Regex("\\s*-(yify|yts([. ]mx)?|rarbg|etrg|mkvcage|fgt|ntb|tgx|psa|evo|ntg|ion10|sparks|cmrg|galaxytv|eztv|ettv|rartv|mkvking|tigole|qxr|megusta|pahe)(?=[\\s.\\[(]|$)", RegexOption.IGNORE_CASE)
    private val leadingPipeCode = Regex("^\\s*\\|[A-Za-z0-9]{2,5}\\|\\s*")
    private val trailingArticle = Regex(",\\s*(The|A|An)$", RegexOption.IGNORE_CASE)

    fun clean(title: String, year: Int? = null): String = parse(title, year).text

    private fun isSep(x: String) = x in separatorSet

    /** Step 1 of the rules: NFKC, curly quotes and dashes made plain, no-break space and "_" to a space, trimmed. */
    fun normalizeText(title: String): String {
        var s = Normalizer.normalize(title, Normalizer.Form.NFKC)
        for ((a, b) in listOf("\u2019" to "'", "\u2018" to "'", "\u201C" to "\"", "\u201D" to "\"", "\u2013" to "-", "\u2014" to "-", "\u2012" to "-", "\u00A0" to " ", "_" to " ")) s = s.replace(a, b)
        return s.trim { it.isWhitespace() }
    }

    /** The cleaned name and the year to search with (the library's, else one written in brackets). */
    /** A word with dots inside a name that has spaces: split when it is a dotted title ("KO.-.The.Delicious.Guys"), or a dot glues a year, a quality tag or a language prefix to the name ("Chiquititas.2013", "Tomorrow.x265.5.1", "JP:.Bleach"). */
    private fun dotted(s: String): String = s.split(' ').joinToString(" ") { w ->
        val parts = w.split('.')
        if (parts.size >= 3 && parts.count { it.length >= 2 } >= 2 && parts.count { it.length == 1 } <= 1) return@joinToString parts.joinToString(" ")
        if (parts.size < 2 || parts.none { it.length >= 2 && it.any(Char::isLetter) }) return@joinToString w
        val glued = parts.any { p -> (p.length == 4 && p.toIntOrNull()?.let { it in 1900..2030 } == true) || p.lowercase() in strongTags } || w.contains(":.")
        if (glued) parts.joinToString(" ") else w
    }

    private val episodeTail = Regex("(?i)(?<=\\S)\\s+(?:(?:season|saison|temporada|staffel)\\s*\\d+|episode\\s*\\d+|s\\d{1,2}\\s?e\\d{1,3})\\b.*$")

    fun parse(title: String, year: Int? = null): Parsed {
        var s = normalizeText(title)
        val original = s
        if (s.none { it.isWhitespace() } && s.contains('.')) s = s.replace('.', ' ')          // The.Matrix.1999.1080p
        else if (!s.contains("..") && s.contains('.')) s = dotted(s)
        val found = arrayOf(year)
        s = stripBrackets(s, found)
        s = attachedGroup.replace(s, "")          // a group attached in the middle ("[2019]-TGx Season 5", "720p-EVO.S05E16")
        s = releaseGroup.replaceFirst(s, "")          // "1080p-YIFY": the group goes, the tag before it is then removed as usual
        s = leadingPipeCode.replaceFirst(s, "")
        s = s.replace("|", " | ")
        // "Show.S03E17.1080p", "x265.S04E10": an episode marker glued to its neighbours with dots stands on its own, so the tail rules see it.
        s = Regex("\\.(?=S\\d{1,2}E\\d{1,3}\\b)", RegexOption.IGNORE_CASE).replace(s, " ")
        s = Regex("(\\bS\\d{1,2}E\\d{1,3})\\.(?=\\S)", RegexOption.IGNORE_CASE).replace(s, "$1 ")
        val t = s.split(Regex("[\\s\\u00A0]+")).filter { it.isNotEmpty() }.map { if (it.lowercase() in strongTags) MARK else it }.toMutableList()
        // Surround-sound tag "5.1" / "7.1" (a name with dots reads it as "5" "1"): a tag, never part of a title, when something comes before it.
        run {
            val u = ArrayList<String>(); var i = 0
            while (i < t.size) {
                val w = t[i].lowercase()
                if (i > 0 && w in setOf("5.1", "6.1", "7.1")) { i++; continue }
                if (i > 0 && i + 1 < t.size && w in setOf("5", "6", "7") && t[i + 1] == "1") { i += 2; continue }
                u.add(t[i]); i++
            }
            if (u.isNotEmpty()) { t.clear(); t.addAll(u) }
        }
        // Head: "IN:", "TELUGU |", "EN -", and a year that leads the name behind a separator ("2019 - Title").
        while (t.isNotEmpty()) {
            val f = t.first()
            if (t.size > 2 && f.length == 4 && f.toIntOrNull()?.let { it in 1900..2030 } == true && (t[1] == "-" || t[1] == "|")) {
                if (found[0] == null) found[0] = f.toInt()
                t.removeAt(0); t.removeAt(0); continue
            }
            val word = f.trim(':', '-', '|').lowercase()
            val endsSep = f.endsWith(":") || f.endsWith("|") || (f.endsWith("-") && f.length > 1 && f.dropLast(1).isNotEmpty())
            val nextSep = t.size > 1 && isSep(t[1]) && t[1] != MARK
            if (isSep(f)) { t.removeAt(0); continue }
            if ((word in prefixes || word in languages || word in weakTags) && (endsSep || nextSep) && t.size > 1) { t.removeAt(0); if (nextSep && !endsSep) t.removeAt(0); continue }
            break
        }
        // Tail: separators, tags, languages after a separator or "dubbed", season markers, and a year that follows a tag (or equals the library's).
        var sawDub = false
        while (t.size > 1) {
            val l = t.last()
            val low = l.lowercase().trim(*tailTrim)
            val prev = t[t.size - 2]
            val prevLow = prev.lowercase().trim(*tailTrim)
            if (isSep(l) || low.isEmpty()) { t.removeAt(t.size - 1); continue }
            if (low in weakTags) { if (low in setOf("dubbed", "dub", "audio", "subbed", "sub", "subs")) sawDub = true; t.removeAt(t.size - 1); continue }
            if (low in languages && (isSep(prev) || sawDub || prevLow in weakTags)) { t.removeAt(t.size - 1); continue }
            if (seasonCode.matches(low) || episodeX.matches(low)) { t.removeAt(t.size - 1); continue }          // S02E05, 1x02
            if (episodeNumber.matches(low) && prevLow in episodeWord && t.size > 2) { t.removeAt(t.size - 1); t.removeAt(t.size - 1); continue }          // "Episode 2"
            if (Regex("^\\d{2,3}$").matches(low) && prev == "-" && t.size > 2) { t.removeAt(t.size - 1); t.removeAt(t.size - 1); continue }          // "Naruto - 062"
            if (smallNumber.matches(low) && prevLow in seasonWord && t.size > 2) { t.removeAt(t.size - 1); t.removeAt(t.size - 1); continue }
            val y = if (low.length == 4) low.toIntOrNull() else null
            if (y != null && y in 1900..2030 && (y == year || prevLow in weakTags || prevLow in languages || prev == MARK)) {
                if (found[0] == null) found[0] = y
                t.removeAt(t.size - 1); continue
            }
            break
        }
        var text = t.filter { it != MARK }.joinToString(" ").replace(Regex("\\s+"), " ").trim(*edgeTrim)
        // "Matrix, The" -> "The Matrix"
        trailingArticle.find(text)?.let { r -> val art = r.value.trim(',', ' '); text = art + " " + text.substring(0, r.range.first) }
        // An episode title after the marker ("Some Show Season 2 Episode 5 Pilot"): the name ends where the marker starts, when a word comes before it.
        episodeTail.find(text)?.let { text = text.substring(0, it.range.first) }
        // A name made of brackets alone ("[REC] [2007]"): the first bracket group that is not a year is the title.
        if (text.isEmpty()) Regex("[(\\[{]([^)\\]}]*\\p{L}[^)\\]}]*)[)\\]}]").find(original)?.let { text = it.value.trim('(', ')', '[', ']', '{', '}', ' ') }
        if (text.isEmpty()) text = original.trim(*edgeTrim)
        return Parsed(text, found[0])
    }

    /** Removes (...), [...] and {...} groups; the first year inside one is remembered. A leading number in brackets that is not a year ("(500) Days of Summer") stays. */
    private fun stripBrackets(s: String, year: Array<Int?>): String {
        val pairs = mapOf('(' to ')', '[' to ']', '{' to '}')
        val out = StringBuilder(); var open: Char? = null; val buf = StringBuilder()
        for (ch in s) {
            if (open != null) {
                if (ch == pairs[open]) {
                    val inner = buf.toString().trim { it == ' ' || it == '\t' }
                    val yv = if (inner.length == 4) inner.toIntOrNull() else null
                    val isYear = yv != null && yv in 1900..2030
                    if (isYear && year[0] == null) year[0] = yv
                    if (out.toString().trim { it == ' ' || it == '\t' }.isEmpty() && inner.isNotEmpty() && inner.all { it.isDigit() } && !isYear) out.append("($inner)") else out.append(" $MARK ")
                    open = null; buf.clear()
                } else buf.append(ch)
            } else if (pairs.containsKey(ch)) open = ch else out.append(ch)
        }
        if (open != null) out.append(" $MARK ")          // an unclosed bracket drops its tail
        return out.toString()
    }

    // ---- title similarity (for choosing among TMDB's answers) ----

    private fun key(s: String): String {
        val k = IdentityKey.normalize(s.replace("&", " and "))
        return if (k.startsWith("the ") && k.length > 4) k.substring(4) else k
    }

    /** 0..1: how alike two titles are after lower case, no accents, "&" as "and" and no leading "the": the better of word overlap and edit distance. */
    fun similarity(a: String, b: String): Double {
        val x = key(a); val y = key(b)
        if (x.isEmpty() || y.isEmpty()) return 0.0
        if (x == y) return 1.0
        val xs = x.split(' ').toSet(); val ys = y.split(' ').toSet()
        val dice = 2.0 * (xs intersect ys).size / (xs.size + ys.size)
        val lev = 1.0 - editDistance(x, y).toDouble() / maxOf(x.length, y.length)
        return maxOf(dice, lev)
    }

    private fun editDistance(a: String, b: String): Int {
        var prev = IntArray(b.length + 1) { it }; var cur = IntArray(b.length + 1)
        for (i in 1..a.length) {
            cur[0] = i
            for (j in 1..b.length) cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            val t = prev; prev = cur; cur = t
        }
        return prev[b.length]
    }

    /** A name worth searching without a year: two or more words and at least 8 characters, or one word of 12 or more. */
    fun distinctive(title: String): Boolean { val words = title.trim().split(Regex("\\s+")).size; return (words >= 2 && title.length >= 8) || (words == 1 && title.length >= 12) }
}
