package app.streamsetu.core.parse

import app.streamsetu.core.model.EpgProgram
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.InputStream

/** Reads an XMLTV guide and reports programmes one by one. Only programmes that end after [notBeforeMs] and start before [notAfterMs] are kept. */
object XmltvParser {
    fun parse(input: InputStream, notBeforeMs: Long, notAfterMs: Long, onChannel: (id: String, name: String) -> Unit = { _, _ -> }, onProgram: (EpgProgram) -> Unit): Int {
        val p = XmlPullParserFactory.newInstance().newPullParser()
        p.setInput(input, null)
        var count = 0
        var channel: String? = null; var start = 0L; var stop = 0L; var title = ""; var desc: String? = null
        var inProgramme = false
        var channelId: String? = null; var nameText: String? = null
        var text: String? = null
        while (true) {
            when (p.next()) {
                XmlPullParser.START_TAG -> when (p.name) {
                    "programme" -> {
                        inProgramme = true
                        channel = p.getAttributeValue(null, "channel")
                        start = parseTime(p.getAttributeValue(null, "start")); stop = parseTime(p.getAttributeValue(null, "stop"))
                        title = ""; desc = null
                    }
                    "channel" -> channelId = p.getAttributeValue(null, "id")
                    "display-name" -> nameText = if (channelId != null && !inProgramme) "" else null
                    "title", "desc" -> text = if (inProgramme) "" else null
                }
                XmlPullParser.TEXT -> { if (text != null) text += p.text; if (nameText != null) nameText += p.text }
                XmlPullParser.END_TAG -> when (p.name) {
                    "display-name" -> { val id = channelId; val n = nameText?.trim(); if (id != null && !n.isNullOrEmpty()) onChannel(id, n); nameText = null }
                    "channel" -> channelId = null
                    "title" -> { if (inProgramme && text != null && title.isEmpty()) title = text.trim(); text = null }
                    "desc" -> { if (inProgramme && text != null) desc = text.trim().ifEmpty { null }; text = null }
                    "programme" -> {
                        inProgramme = false
                        if (channel != null && stop > notBeforeMs && start < notAfterMs && stop > start) { onProgram(EpgProgram(channel, start, stop, title, desc)); count++ }
                    }
                }
                XmlPullParser.END_DOCUMENT -> return count
            }
        }
    }

    /** "20261013183000 +0200" → epoch milliseconds. Parsed by hand: a guide has hundreds of thousands of programmes and a formatter per value is far too slow. */
    fun parseTime(s: String?): Long {
        if (s.isNullOrBlank()) return 0
        val t = s.trim()
        if (t.length < 12 || !t.take(12).all { it in '0'..'9' }) return 0
        fun n(from: Int, to: Int): Int = if (to <= t.length && t.substring(from, to).all { it in '0'..'9' }) t.substring(from, to).toInt() else 0
        val sec = if (t.length >= 14) n(12, 14) else 0
        val days = daysFromCivil(n(0, 4), n(4, 6), n(6, 8))
        var ms = ((days * 24L + n(8, 10)) * 60 + n(10, 12)) * 60 + sec
        val zone = t.drop(14).trim()
        if (zone.length >= 5 && (zone[0] == '+' || zone[0] == '-') && zone.substring(1, 5).all { it in '0'..'9' }) {
            val off = zone.substring(1, 3).toInt() * 3600L + zone.substring(3, 5).toInt() * 60
            ms -= if (zone[0] == '+') off else -off
        }
        return ms * 1000
    }

    /** Days since 1970-01-01 of a proleptic Gregorian date. */
    private fun daysFromCivil(y0: Int, m: Int, d: Int): Long {
        val y = if (m <= 2) y0 - 1 else y0
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097L + doe - 719468
    }
}
