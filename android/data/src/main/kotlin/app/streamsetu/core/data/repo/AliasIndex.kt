package app.streamsetu.core.data.repo

import java.io.ByteArrayInputStream
import java.text.Normalizer
import java.util.zip.GZIPInputStream

/**
 * The offline alias index (same file as on Apple, see tools/aliases/README.md): UTF-8 lines `key TAB kind TAB id TAB rank`, sorted by key (byte order) and, within a key, best rank first;
 * `kind` is `m` (film) or `t` (series); plain or gzip. Consulted by NAME only: exact key, then consonant skeleton, then a skeleton one edit away. No year, language or popularity is read.
 * Memory: the decompressed text once plus four bytes per line; the phonetic structures are built on first use.
 */
object AliasKey {
    /** Compatibility-composed, lower case, "&" as "and", "+" as "plus", no apostrophes, accents removed from Latin letters only (below U+0370), non letter/digit/mark characters separate, a leading the/a/an dropped. */
    fun make(s: String): String {
        var t = Normalizer.normalize(s, Normalizer.Form.NFKC).lowercase(java.util.Locale.ROOT)
        t = t.replace("&", " and ").replace("+", " plus ").replace("'", "").replace("’", "").replace("ı", "i")
        val d = Normalizer.normalize(t, Normalizer.Form.NFD)
        val kept = StringBuilder()
        var i = 0
        while (i < d.length) { val cp = d.codePointAt(i); i += Character.charCount(cp); if (Character.getType(cp) == Character.NON_SPACING_MARK.toInt() && cp < 0x370) continue; kept.appendCodePoint(cp) }
        val nfc = Normalizer.normalize(kept.toString(), Normalizer.Form.NFC)
        val tokens = ArrayList<String>(); val cur = StringBuilder()
        i = 0
        while (i < nfc.length) {
            val cp = nfc.codePointAt(i); i += Character.charCount(cp)
            val keep = when (Character.getType(cp).toByte()) {
                Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER, Character.MODIFIER_LETTER, Character.OTHER_LETTER,
                Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER, Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> true
                else -> false
            }
            if (keep) cur.appendCodePoint(cp) else if (cur.isNotEmpty()) { tokens.add(cur.toString()); cur.setLength(0) }
        }
        if (cur.isNotEmpty()) tokens.add(cur.toString())
        if (tokens.size > 1 && tokens[0] in setOf("the", "a", "an")) tokens.removeAt(0)
        return tokens.joinToString(" ")
    }
}

class AliasIndex private constructor(private val blob: ByteArray, private val starts: IntArray, val count: Int) {
    data class Entry(val isSeries: Boolean, val tmdbId: Long, val rank: Int)
    enum class Tier { EXACT, PHONETIC, EDIT1 }

    /** Bytes held for the text and the line table (the phonetic structures come on top once used). */
    val residentBytes: Long get() = blob.size.toLong() + starts.size * 4L

    companion object {
        const val MIN_SKELETON = 4
        const val MIN_EDIT1_SKELETON = 6

        fun parse(data: ByteArray): AliasIndex? {
            val raw = if (data.size > 18 && data[0] == 0x1f.toByte() && data[1] == 0x8b.toByte()) runCatching { GZIPInputStream(ByteArrayInputStream(data)).use { it.readBytes() } }.getOrNull() ?: return null else data
            val s = IntArray(raw.size / 8 + 2); var n = 0; var i = 0
            while (i < raw.size) { if (n + 1 >= s.size) return parseSlow(raw); s[n++] = i; while (i < raw.size && raw[i] != 10.toByte()) i++; i++ }
            s[n] = raw.size
            return AliasIndex(raw, s.copyOf(n + 1), n)
        }
        private fun parseSlow(raw: ByteArray): AliasIndex {
            val l = ArrayList<Int>(); var i = 0
            while (i < raw.size) { l.add(i); while (i < raw.size && raw[i] != 10.toByte()) i++; i++ }
            l.add(raw.size); return AliasIndex(raw, l.toIntArray(), l.size - 1)
        }

        fun withinOneEdit(a: ByteArray, b: ByteArray): Boolean {
            if (a.contentEquals(b)) return true
            if (kotlin.math.abs(a.size - b.size) > 1) return false
            var i = 0; while (i < a.size && i < b.size && a[i] == b[i]) i++
            fun tail(x: ByteArray, from: Int) = if (from >= x.size) ByteArray(0) else x.copyOfRange(from, x.size)
            return when {
                a.size == b.size -> tail(a, i + 1).contentEquals(tail(b, i + 1))
                a.size > b.size -> tail(a, i + 1).contentEquals(tail(b, i))
                else -> tail(a, i).contentEquals(tail(b, i + 1))
            }
        }
        private fun hash(skel: String, series: Boolean): Long { var h = if (series) -3750763034362895579L else -8885099540516863707L; for (b in skel.toByteArray(Charsets.UTF_8)) { h = (h xor (b.toLong() and 0xff)) * 0x100000001b3L }; return h }
        private fun bucketKey(len: Int, first: Int, series: Boolean) = (if (series) 1 shl 24 else 0) or (minOf(len, 255) shl 8) or first
    }

    private fun keyEnd(line: Int): Int { var e = starts[line]; val end = starts[line + 1]; while (e < end && blob[e] != 9.toByte()) e++; return e }
    fun keyBytes(line: Int): ByteArray = blob.copyOfRange(starts[line], keyEnd(line))
    fun keyString(line: Int): String = String(keyBytes(line), Charsets.UTF_8)
    fun entry(line: Int): Entry {
        val end = starts[line + 1]; val e = keyEnd(line)
        val series = e + 1 < end && blob[e + 1] == 't'.code.toByte()
        val f = ArrayList<Long>(); var n = 0L; var p = e + 3
        while (p < end) { val c = blob[p].toInt(); if (c == 9) { f.add(n); n = 0 } else if (c in 48..57) n = n * 10 + (c - 48); p++ }
        f.add(n)
        return Entry(series, f[0], if (f.size > 1) f[1].toInt() else 0)
    }
    private fun compareKey(line: Int, k: ByteArray): Int {
        var a = starts[line]; val e = keyEnd(line); var j = 0
        while (a < e && j < k.size) { val x = blob[a].toInt() and 0xff; val y = k[j].toInt() and 0xff; if (x != y) return x - y; a++; j++ }
        return (e - starts[line]) - k.size
    }
    private fun lowerBound(k: ByteArray): Int { var lo = 0; var hi = count; while (lo < hi) { val m = (lo + hi) ushr 1; if (compareKey(m, k) < 0) lo = m + 1 else hi = m }; return lo }

    fun exact(name: String, isSeries: Boolean): Entry? {
        val k = AliasKey.make(name).toByteArray(Charsets.UTF_8); if (k.isEmpty()) return null
        var i = lowerBound(k)
        while (i < count && compareKey(i, k) == 0) { val e = entry(i); if (e.isSeries == isSeries) return e; i++ }
        return null
    }

    private var built = false
    private var hashes = LongArray(0); private var lines = IntArray(0)
    private var buckets: Map<Int, IntArray> = emptyMap()
    private fun skeletonOfKey(k: String) = ArtworkMatchDecision.skeleton(k)

    @Synchronized private fun buildPhonetic() {
        if (built) return
        class P(val h: Long, val line: Int, val rank: Int)
        val pairs = ArrayList<P>()
        for (i in 0 until count) {
            val kb = keyBytes(i)
            if (kb.size < 5 || kb.any { it < 0 }) continue
            val skel = skeletonOfKey(String(kb, Charsets.UTF_8)); if (skel.length < MIN_SKELETON) continue
            val e = entry(i); pairs.add(P(hash(skel, e.isSeries), i, e.rank))
        }
        // unsigned order, like the Swift side
        pairs.sortWith { x, y -> val c = java.lang.Long.compareUnsigned(x.h, y.h); if (c != 0) c else if (x.rank != y.rank) y.rank - x.rank else x.line - y.line }
        val hs = ArrayList<Long>(); val ls = ArrayList<Int>(); val bk = HashMap<Int, ArrayList<Int>>()
        for (p in pairs) {
            if (hs.isNotEmpty() && hs.last() == p.h) continue
            hs.add(p.h); ls.add(p.line)
            val skel = skeletonOfKey(keyString(p.line))
            if (skel.length >= MIN_EDIT1_SKELETON - 1) bk.getOrPut(bucketKey(skel.length, skel[0].code, entry(p.line).isSeries)) { ArrayList() }.add(p.line)
        }
        hashes = hs.toLongArray(); lines = ls.toIntArray(); buckets = bk.mapValues { it.value.toIntArray() }; built = true
    }
    val phoneticBytes: Long get() = hashes.size * 12L + buckets.values.sumOf { it.size * 4L + 24 }

    fun phonetic(name: String, isSeries: Boolean): Pair<Entry, Tier>? {
        val k = AliasKey.make(name); if (k.any { it.code >= 0x80 }) return null
        val skel = skeletonOfKey(k); if (skel.length < MIN_SKELETON) return null
        buildPhonetic()
        val h = hash(skel, isSeries)
        var lo = 0; var hi = hashes.size
        while (lo < hi) { val m = (lo + hi) ushr 1; if (java.lang.Long.compareUnsigned(hashes[m], h) < 0) lo = m + 1 else hi = m }
        if (lo < hashes.size && hashes[lo] == h) return entry(lines[lo]) to Tier.PHONETIC
        if (skel.length < MIN_EDIT1_SKELETON) return null
        val q = skel.toByteArray(Charsets.UTF_8); var best: Entry? = null
        for (d in -1..1) {
            val len = skel.length + d; if (len <= 0) continue
            for (li in buckets[bucketKey(len, skel[0].code, isSeries)] ?: IntArray(0)) {
                if (withinOneEdit(q, skeletonOfKey(keyString(li)).toByteArray(Charsets.UTF_8))) { val e = entry(li); if (best == null || e.rank > best.rank) best = e }
            }
        }
        return best?.let { it to Tier.EDIT1 }
    }

    fun resolve(name: String, isSeries: Boolean, usePhonetic: Boolean = true): Pair<Entry, Tier>? =
        exact(name, isSeries)?.let { it to Tier.EXACT } ?: if (usePhonetic) phonetic(name, isSeries) else null
}
