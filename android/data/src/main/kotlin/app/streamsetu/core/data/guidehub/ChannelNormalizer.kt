package app.streamsetu.core.data.guidehub

import java.text.Normalizer

/** Name and id rules of channel-to-guide matching. A port of the Apple `ChannelNormalizer`; `epg/fixtures/mapping-cases.json` pins both. */
object ChannelNormalizer {
    data class NameKey(val base: String, val variant: String, val countryPrefix: String?) {
        val tokens: List<String> get() = if (base.isEmpty()) emptyList() else base.split(' ')
        val isEmpty: Boolean get() = base.isEmpty()
        val key: String get() = if (variant.isEmpty()) base else "$base $variant"
    }

    val qualityTokens = setOf("hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "1080p", "720p", "2160p", "50fps", "60fps", "hdr")
    val prefixCodes = ("uk gb us usa ca au nz ie de at ch fr be nl lu es pt it gr tr ru ua pl cz sk hu ro bg rs hr si ba mk al se no dk fi is ee lv lt in pk bd lk np ae sa qa kw eg ma dz tn il ir iq jo lb sy cn jp kr tw hk sg my th vn id ph br ar mx co cl pe ve za ng ke gh et cu do pr uy py bo ec").split(' ').toSet()

    private fun fold(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()

    fun words(s: String): String {
        val sb = StringBuilder()
        var lastSpace = true
        val text = fold(s).replace("&", " and ")
        var i = 0
        while (i < text.length) {                       // a plain loop: String.codePoints needs API 24 and the app runs from 22
            val cp = text.codePointAt(i); i += Character.charCount(cp)
            if (Character.isLetterOrDigit(cp)) { sb.appendCodePoint(cp); lastSpace = false }
            else if (!lastSpace) { sb.append(' '); lastSpace = true }
        }
        return sb.toString().trim()
    }

    private val plusVariant = Regex("""(?:^|[\s(\[])(?:\+|plus\s?)(\d{1,2})(?:h|\s?hours?)?(?=$|[\s)\]])""", RegexOption.IGNORE_CASE)

    /** "(backup)", "[alt 2]", "(mirror)": a copy marker of the same channel, not part of its name. */
    private val copyMarker = Regex("""[\(\[]\s*(backup|back-up|alt|alternate|mirror|raw|reserve)\s*\d{0,2}\s*[\)\]]""", RegexOption.IGNORE_CASE)

    /** A trailing word that only names which feed of a channel it is ("CNN East"); a second try, never to merge two names the guide lists apart. */
    val feedWords = setOf("east", "west", "north", "south", "london", "live")
    fun withoutFeedWord(k: NameKey): NameKey? {
        val t = k.tokens
        if (t.size < 2 || t.last() !in feedWords) return null
        return k.copy(base = t.dropLast(1).joinToString(" "))
    }

    fun name(raw: String): NameKey {
        var s = raw.trim()
        var prefix: String? = null
        fun isDelimiter(i: Int): Boolean {
            val c = s[i]
            if ("|:»>])".indexOf(c) >= 0) return true
            if ((c == '-' || c == '–') && i > 0 && s[i - 1] == ' ' && i + 1 < s.length && s[i + 1] == ' ') return true
            return false
        }
        // Providers sometimes stack two ("US| US: MTV"): up to two are read, the first one is kept.
        for (round in 0 until 2) {
            val r = s.indices.firstOrNull { isDelimiter(it) }
            if (r == null || r > 6) break
            val head = s.substring(0, r).trim { it in " []()" }
            if (!(head.length in 2..3 && head.lowercase() in prefixCodes && head.all { it.isLetter() })) break
            val h = head.lowercase()
            if (prefix == null) prefix = if (h == "gb") "uk" else if (h == "usa") "us" else h
            s = s.substring(r + 1)
        }
        s = copyMarker.replace(s, " ")
        var variant = ""
        val m = plusVariant.find(s)
        if (m != null) {
            variant = "+" + m.groupValues[1]
            s = s.replaceRange(m.range, " ")
        }
        val cleaned = words(s).split(' ').filter { it.isNotEmpty() && it !in qualityTokens }.joinToString(" ")
        return NameKey(cleaned, variant, prefix)
    }

    fun idParts(raw: String): Pair<String, String?> {
        var s = raw.trim().lowercase()
        val at = s.indexOf('@')
        if (at >= 0) s = s.substring(0, at)
        s = s.replace(" ", "")
        val dot = s.lastIndexOf('.')
        if (dot >= 0 && s.length - dot == 3) {
            val cc = s.substring(dot + 1)
            if (cc.all { it.isLetter() }) return s.substring(0, dot) to cc
        }
        return s to null
    }

    fun idsEqualNormalised(a: String, b: String): Boolean {
        val x = idParts(a); val y = idParts(b)
        if (x.first.isEmpty() || x.first != y.first) return false
        val c = x.second; val d = y.second
        return if (c != null && d != null) c == d else true
    }

    fun countryKey(raw: String?): String? {
        val r = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        return when (r) { "gb", "uk" -> "uk"; "usa", "us" -> "us"; else -> r }
    }
    fun languageKey(raw: String?): String? {
        val r = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        return r.split('-').first().take(2)
    }
}
