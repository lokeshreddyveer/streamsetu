package app.streamsetu.core.subtitles

import java.security.MessageDigest

/** A downloaded subtitle that passed every check, as UTF-8 text, with the fingerprint of its content. */
class CheckedSubtitle(val text: String, val sha256: String, val extension: String)

/**
 * Makes a downloaded subtitle safe to hand to the player: size is limited before anything is read, a compressed file may not expand beyond the limit, the text encoding is found
 * (never assumed) and converted to UTF-8, the file must really look like subtitles, and it is named by the fingerprint of its content, so two downloads of the same file are one
 * file on disk and nothing a provider sends can choose a path.
 */
object SubtitleFiles {
    const val MAX_BYTES = 2 * 1024 * 1024
    const val MAX_EXPANDED_BYTES = 4 * 1024 * 1024
    /** The byte-order mark some editors put at the start of a text file. */
    private val BOM = Char(0xFEFF)
    private val timing = Regex("""\d{1,2}:\d{2}:\d{2}[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[.,]\d{1,3}""")

    class Rejected(message: String) : Exception(message)

    /** Reads a response of at most [MAX_BYTES]; a provider that says it is bigger, or sends more than it said, is refused. */
    fun readLimited(declared: Long, stream: java.io.InputStream): ByteArray {
        if (declared > MAX_BYTES) throw Rejected("The subtitle file is too large.")
        val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(8192); var total = 0
        while (true) { val n = stream.read(buf); if (n < 0) break; total += n; if (total > MAX_BYTES) throw Rejected("The subtitle file is too large."); out.write(buf, 0, n) }
        return out.toByteArray()
    }

    /** Unpacks a gzip file when the bytes are one, refusing one that would expand past [MAX_EXPANDED_BYTES]. */
    fun inflateIfGzip(bytes: ByteArray): ByteArray {
        if (bytes.size < 2 || bytes[0] != 0x1f.toByte() || bytes[1] != 0x8b.toByte()) return bytes
        java.util.zip.GZIPInputStream(bytes.inputStream()).use { return readCapped(it, MAX_EXPANDED_BYTES) }
    }
    private fun readCapped(s: java.io.InputStream, cap: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(8192); var total = 0
        while (true) { val n = s.read(buf); if (n < 0) break; total += n; if (total > cap) throw Rejected("The subtitle file expands to more than is allowed."); out.write(buf, 0, n) }
        return out.toByteArray()
    }

    fun check(raw: ByteArray): CheckedSubtitle {
        if (raw.isEmpty()) throw Rejected("The subtitle file was empty.")
        if (raw.size > MAX_BYTES) throw Rejected("The subtitle file is too large.")
        val bytes = inflateIfGzip(raw)
        val text = decode(bytes).replace("\r\n", "\n").replace('\r', '\n').replace("\u0000", "")
        val vtt = text.trimStart(BOM, ' ', '\n').startsWith("WEBVTT")
        if (!timing.containsMatchIn(text)) throw Rejected("That file does not look like subtitles.")
        val clean = text.trimStart(BOM)
        return CheckedSubtitle(clean, sha256(clean.toByteArray(Charsets.UTF_8)), if (vtt) "vtt" else "srt")
    }

    /** UTF-8 (with or without a byte-order mark), UTF-16 with a mark, otherwise the common legacy Western encoding: whichever reads without invalid sequences first. */
    fun decode(b: ByteArray): String {
        if (b.size >= 3 && b[0] == 0xEF.toByte() && b[1] == 0xBB.toByte() && b[2] == 0xBF.toByte()) return String(b, 3, b.size - 3, Charsets.UTF_8)
        if (b.size >= 2 && b[0] == 0xFF.toByte() && b[1] == 0xFE.toByte()) return String(b, 2, b.size - 2, Charsets.UTF_16LE)
        if (b.size >= 2 && b[0] == 0xFE.toByte() && b[1] == 0xFF.toByte()) return String(b, 2, b.size - 2, Charsets.UTF_16BE)
        val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        return try { decoder.decode(java.nio.ByteBuffer.wrap(b)).toString() } catch (e: java.nio.charset.CharacterCodingException) { String(b, charset("windows-1252")) }
    }

    fun sha256(b: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** A file name built only from the content fingerprint: never from anything a provider sent. */
    fun fileNameFor(c: CheckedSubtitle) = "${c.sha256}.${c.extension}"
}
