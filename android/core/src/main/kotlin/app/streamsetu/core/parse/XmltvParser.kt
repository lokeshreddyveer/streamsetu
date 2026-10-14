package app.streamsetu.core.parse

import app.streamsetu.core.model.EpgProgram
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Reads an XMLTV guide and reports programmes one by one. Only programmes that end after [notBeforeMs] and start before [notAfterMs] are kept. */
object XmltvParser {
    fun parse(input: InputStream, notBeforeMs: Long, notAfterMs: Long, onProgram: (EpgProgram) -> Unit): Int {
        val p = XmlPullParserFactory.newInstance().newPullParser()
        p.setInput(input, null)
        var count = 0
        var channel: String? = null; var start = 0L; var stop = 0L; var title = ""; var desc: String? = null
        var inProgramme = false
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
                    "title", "desc" -> text = if (inProgramme) "" else null
                }
                XmlPullParser.TEXT -> if (text != null) text += p.text
                XmlPullParser.END_TAG -> when (p.name) {
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

    /** "20261013183000 +0200" → epoch milliseconds. */
    internal fun parseTime(s: String?): Long {
        if (s.isNullOrBlank()) return 0
        val t = s.trim()
        val hasZone = t.length > 14
        val fmt = SimpleDateFormat(if (hasZone) "yyyyMMddHHmmss Z" else "yyyyMMddHHmmss", Locale.US)
        if (!hasZone) fmt.timeZone = TimeZone.getTimeZone("UTC")
        return runCatching { fmt.parse(if (hasZone) t.replace(Regex("\\s+"), " ") else t.take(14))?.time ?: 0L }.getOrDefault(0L)
    }
}
