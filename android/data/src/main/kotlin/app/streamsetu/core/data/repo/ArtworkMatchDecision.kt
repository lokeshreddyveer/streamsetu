package app.streamsetu.core.data.repo

import java.text.Normalizer
import java.util.Locale

/**
 * Engine v2: the pure decision that picks the TMDB result for a library title, or none. No network, no database: candidates in, an id (or null) out. A wrong poster is worse than a missing
 * one, so a title is matched only when one result is clearly it. The same rules run on Apple and Windows; every case in artwork/fixtures/match-decision.json must come out exactly
 * ([ArtworkMatchDecisionTests]). There is no "one year out" relaxation for short titles: a one-word name or one of 5 letters or fewer needs its exact year.
 */
object ArtworkMatchDecision {
    data class Query(val title: String, val year: Int?, val isSeries: Boolean, /** The library's language for the title ("Telugu"), or empty. */ val languageTag: String = "")
    data class Candidate(val id: Long, val title: String?, val originalTitle: String?, val year: Int?, val popularity: Double, val originalLanguage: String?)

    const val MIN_SIMILARITY = 0.88

    /** Language word (as the library spells it) -> TMDB original-language code. A table, so a language is added by adding a row; it only breaks ties between equally good results. */
    private val languageCodes: Map<String, String> = linkedMapOf(
        "telugu" to "te", "hindi" to "hi", "tamil" to "ta", "malayalam" to "ml", "kannada" to "kn", "bengali" to "bn", "punjabi" to "pa", "marathi" to "mr", "gujarati" to "gu", "urdu" to "ur",
        "turkish" to "tr", "english" to "en", "arabic" to "ar", "korean" to "ko", "japanese" to "ja", "spanish" to "es", "french" to "fr", "german" to "de", "chinese" to "zh", "thai" to "th",
        "portuguese" to "pt", "italian" to "it", "russian" to "ru", "indonesian" to "id", "dutch" to "nl", "polish" to "pl", "persian" to "fa", "hebrew" to "he", "vietnamese" to "vi",
        "odia" to "or", "assamese" to "as", "nepali" to "ne", "sinhala" to "si", "malay" to "ms", "tagalog" to "tl",
    )
    private val codeNames: Map<String, String> by lazy { languageCodes.entries.associate { it.value to it.key } }
    /** The library's language word for a TMDB original-language code (the inverse of the table). */
    fun name(forCode: String): String? = codeNames[forCode.lowercase(Locale.ROOT)]
    /** The region-qualified language to ask TMDB for ("te-IN") for an Indian language, else null. */
    fun searchLanguage(tag: String): String? = code(tag)?.takeIf { it in setOf("te", "hi", "ta", "ml", "kn", "bn", "pa", "mr", "gu", "ur") }?.let { "$it-IN" }
    fun code(tag: String): String? = languageCodes[tag.lowercase(Locale.ROOT)]

    // ---- text

    private val romans = mapOf("ii" to "2", "iii" to "3", "iv" to "4", "vi" to "6", "vii" to "7", "viii" to "8", "ix" to "9")
    private val numberWords = mapOf("one" to "1", "two" to "2", "three" to "3", "four" to "4", "five" to "5", "six" to "6", "seven" to "7", "eight" to "8", "nine" to "9", "ten" to "10")

    private fun isAlnum(ch: Char) = ch.isLetterOrDigit() || Character.getType(ch).let { it == Character.NON_SPACING_MARK.toInt() || it == Character.COMBINING_SPACING_MARK.toInt() || it == Character.ENCLOSING_MARK.toInt() }

    /** Lower case, no accents, "&" as "and", no apostrophes, no punctuation, no leading article, roman numerals and "Part N" as digits. */
    fun canon(s: String): String {
        var t = Normalizer.normalize(s, Normalizer.Form.NFKC).lowercase(Locale.ROOT).replace("&", " and ").replace("+", " plus ").replace("'", "").replace("’", "").replace("ı", "i")
        t = Normalizer.normalize(t, Normalizer.Form.NFD).filter { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }
        val tokens = ArrayList<String>(); val sb = StringBuilder()
        for (ch in t) { if (isAlnum(ch)) sb.append(ch) else { if (sb.isNotEmpty()) { tokens += sb.toString(); sb.setLength(0) } } }
        if (sb.isNotEmpty()) tokens += sb.toString()
        if (tokens.size > 1 && tokens.first() in setOf("the", "a", "an")) tokens.removeAt(0)
        val out = ArrayList<String>()
        for ((i, tok) in tokens.withIndex()) {
            if (tok in setOf("part", "chapter", "vol", "volume", "episode") && i + 1 < tokens.size && isNumberLike(tokens[i + 1])) continue
            if (i > 0 && romans.containsKey(tok)) { out += romans.getValue(tok); continue }
            if (i > 0 && i == tokens.size - 1 && (tok == "v" || tok == "x" || tok == "i")) { out += if (tok == "v") "5" else if (tok == "x") "10" else "1"; continue }
            val prev = out.lastOrNull()
            if (i > 0 && prev != null && prev in setOf("part", "chapter") && numberWords.containsKey(tok)) { out += numberWords.getValue(tok); continue }
            out += tok
        }
        return out.joinToString(" ")
    }
    private fun isNumberLike(t: String) = t.toIntOrNull() != null || romans.containsKey(t) || numberWords.containsKey(t) || t in setOf("v", "x", "i")

    private val foldPairs = listOf("sh" to "s", "ph" to "f", "th" to "t", "dh" to "d", "bh" to "b", "kh" to "k", "gh" to "g", "ch" to "c", "aa" to "a", "ee" to "i", "oo" to "u", "ii" to "i", "uu" to "u", "ou" to "u", "ae" to "e", "ai" to "e", "ay" to "e", "ey" to "e", "w" to "v", "z" to "j", "q" to "k", "x" to "ks")

    /** Spellings that differ only by transliteration are folded together (aa/a, ee/i, w/v, th/t, ph/f, double letters ...). */
    fun fold(canon: String): String {
        var s = canon
        for ((a, b) in foldPairs) s = s.replace(a, b)
        val out = StringBuilder(); var last: Char? = null
        for (ch in s) { if (ch == last && ch.isLetter()) continue; out.append(ch); last = ch }
        return out.toString()
    }

    /** The consonant skeleton of the whole name (first letter kept). */
    fun skeleton(canon: String): String {
        val out = StringBuilder(); var prev: Char? = null
        for (tok in canon.split(' ').filter { it.isNotEmpty() }) for (ch in fold(tok)) {
            if (!(ch.isLetter() || ch.isDigit())) continue
            val vowel = "aeiouyh".indexOf(ch) >= 0
            if (!vowel) { if (ch != prev) out.append(ch); prev = ch } else prev = null
        }
        return out.toString()
    }

    // ---- similarity

    /** The code points of a string, by a plain loop (String.codePoints needs API 24; the app runs from 22). */
    private fun cps(s: String): IntArray { val out = IntArray(s.codePointCount(0, s.length)); var i = 0; var n = 0; while (i < s.length) { val cp = s.codePointAt(i); out[n++] = cp; i += Character.charCount(cp) }; return out }

    fun levenshteinRatio(a: String, b: String): Double {
        val x = cps(a); val y = cps(b)
        if (x.contentEquals(y)) return 1.0
        if (x.isEmpty() || y.isEmpty()) return 0.0
        var prev = IntArray(y.size + 1) { it }
        for (i in 1..x.size) {
            val cur = IntArray(y.size + 1); cur[0] = i
            for (j in 1..y.size) cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (x[i - 1] == y[j - 1]) 0 else 1)
            prev = cur
        }
        return 1.0 - prev[y.size].toDouble() / maxOf(x.size, y.size)
    }

    fun jaroWinkler(a: String, b: String): Double {
        val s = cps(a); val t = cps(b)
        if (s.isEmpty() || t.isEmpty()) return 0.0
        if (s.contentEquals(t)) return 1.0
        val window = maxOf(0, maxOf(s.size, t.size) / 2 - 1)
        val sm = BooleanArray(s.size); val tm = BooleanArray(t.size)
        var matches = 0
        for (i in s.indices) {
            val lo = maxOf(0, i - window); val hi = minOf(t.size - 1, i + window)
            if (lo > hi) continue
            for (j in lo..hi) if (!tm[j] && s[i] == t[j]) { sm[i] = true; tm[j] = true; matches++; break }
        }
        if (matches == 0) return 0.0
        var k = 0; var trans = 0
        for (i in s.indices) if (sm[i]) { while (!tm[k]) k++; if (s[i] != t[k]) trans++; k++ }
        val m = matches.toDouble()
        val jaro = (m / s.size + m / t.size + (m - trans / 2.0) / m) / 3
        var l = 0
        while (l < minOf(4, minOf(s.size, t.size)) && s[l] == t[l]) l++
        return jaro + l * 0.1 * (1 - jaro)
    }

    /** Words in any order: the sorted words are compared. */
    fun tokenSetRatio(a: String, b: String): Double =
        levenshteinRatio(a.split(' ').filter { it.isNotEmpty() }.sorted().joinToString(" "), b.split(' ').filter { it.isNotEmpty() }.sorted().joinToString(" "))

    /** How alike two names are, 0..1, over the plain, the transliteration-folded and the space-free forms. */
    fun similarity(a: String, b: String): Double {
        val ca = canon(a); val cb = canon(b)
        if (ca.isEmpty() || cb.isEmpty()) return 0.0
        if (ca == cb) return 1.0
        val fa = fold(ca); val fb = fold(cb)
        if (fa == fb) return 0.98
        val nsa = fa.replace(" ", ""); val nsb = fb.replace(" ", "")
        var best = maxOf(levenshteinRatio(ca, cb), tokenSetRatio(ca, cb) * 0.99, levenshteinRatio(fa, fb) * 0.99, tokenSetRatio(fa, fb) * 0.98, levenshteinRatio(nsa, nsb) * 0.97)
        if (nsa.codePointCount(0, nsa.length) >= 8) best = maxOf(best, if (jaroWinkler(nsa, nsb) >= 0.96) 0.9 else 0.0)
        // A different number is a different film ("Dhoom" and "Dhoom 2"): never close enough.
        val da = ca.split(' ').filter { it.isNotEmpty() && it.all(Char::isDigit) }.toSet(); val db = cb.split(' ').filter { it.isNotEmpty() && it.all(Char::isDigit) }.toSet()
        if (da != db) best = minOf(best, 0.8)
        return best
    }

    /** The name before a subtitle (": ", " - ", " | "), when there is one. */
    fun head(s: String): String? {
        for (sep in listOf(": ", " - ", " | ", " – ")) { val i = s.indexOf(sep); if (i >= 0) { val h = s.substring(0, i); if (h.codePointCount(0, h.length) >= 2) return h } }
        return null
    }

    data class Score(val sim: Double, val phonetic: Boolean, val viaHead: Boolean)

    /** The best similarity of a library name to a candidate's names (title and original title), also trying the name without its subtitle on either side (a little less sure). */
    fun score(libraryText: String, c: Candidate): Score {
        var best = Score(0.0, false, false)
        val libs = listOf(libraryText) + listOfNotNull(head(libraryText))
        val libSkeleton = skeleton(canon(libraryText))
        for (name in listOfNotNull(c.title, c.originalTitle).filter { it.isNotEmpty() }) {
            val names = listOf(name) + listOfNotNull(head(name))
            for ((li, l) in libs.withIndex()) for ((ni, n) in names.withIndex()) {
                var s = similarity(l, n)
                val isHead = li > 0 || ni > 0
                if (isHead) s *= 0.95
                if (s > best.sim) best = Score(s, false, isHead)
            }
            val sk = skeleton(canon(name))
            if (sk.length >= 4 && sk == libSkeleton && best.sim < 0.9) best = Score(0.9, true, false)
        }
        return best
    }

    // ---- decision

    fun isShort(text: String): Boolean { val n = canon(text); return n.split(' ').filter { it.isNotEmpty() }.size <= 1 || n.codePointCount(0, n.length) <= 5 }

    /** Owner policy: the match is decided by the cleaned NAME only (no year, language, runtime or popularity is read; `Query.year` / `languageTag` are kept for the callers). The first result in result order whose title or original title equals the name token for token wins; else the existing similarity tiers (>= 0.88) and the best name wins, ties by result order. A different name is never accepted. */
    fun decide(q: Query, candidates: List<Candidate>, text: String? = null): Long? {
        val lib = text ?: ArtworkNames.clean(q.title, q.year)
        if (lib.isEmpty()) return null
        val libCanon = canon(lib)
        var best: Pair<Long, Double>? = null
        for (c in candidates) {
            val s = score(lib, c)
            if (s.sim < MIN_SIMILARITY) continue
            val exact = !s.phonetic && !s.viaHead && listOf(c.title, c.originalTitle).any { it != null && canon(it) == libCanon }
            if (exact) return c.id
            if (best == null || s.sim > best.second) best = c.id to s.sim
        }
        return best?.first
    }
}
