package app.streamsetu.core.data.guidehub

import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import org.xmlpull.v1.XmlPullParserFactory
import java.io.InputStream

data class GuideProgramme(
    val channel: String, val startMs: Long, val stopMs: Long, val title: String, val subtitle: String? = null, val description: String? = null, val category: String? = null,
    val icon: String? = null, val lang: String? = null, val episodeNum: String? = null, val date: String? = null, val rating: String? = null,
)
data class GuideChannelRecord(val id: String, val displayNames: List<String>, val icon: String?)

/** What a read found, including everything it skipped and why: this is what makes an empty guide explainable (same fields as the Apple `GuideReadStats`). */
data class GuideReadStats(
    val channels: Int = 0, val programmesSeen: Int = 0, val programmesKept: Int = 0, val droppedPast: Int = 0, val droppedFuture: Int = 0, val droppedInvalid: Int = 0,
    val truncated: Boolean = false, val firstStartMs: Long? = null, val lastStopMs: Long? = null,
)

class GuideReadException(message: String) : Exception(message)

/**
 * Streaming XMLTV reader (one programme at a time, bounded batches by the caller). Reads language, category, icon, episode number, date and rating; converts every time with its offset
 * (none means UTC, or the source's own zone); never resolves a DTD or an entity; cuts absurdly long text. A document cut off near its end is used when it already holds 1,000 programmes.
 */
object XmltvDecoder {
    const val MAX_TITLE = 300; const val MAX_TEXT = 4000; const val MAX_NAME = 300; const val MIN_FOR_TRUNCATED = 1000
    const val MAX_CHANNELS = 60_000; const val MAX_PROGRAMMES = 3_000_000

    fun read(
        input: InputStream, notBeforeMs: Long, notAfterMs: Long, localZone: String? = null,
        onChannel: (GuideChannelRecord) -> Unit = {}, onProgramme: (GuideProgramme) -> Unit,
    ): GuideReadStats {
        val p = XmlPullParserFactory.newInstance().newPullParser()
        runCatching { p.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false) }
        p.setInput(input, null)
        var channels = 0; var seen = 0; var kept = 0; var past = 0; var future = 0; var invalid = 0
        var first: Long? = null; var last: Long? = null
        var sawRoot = false; var truncated = false
        // channel
        var chId: String? = null; var chNames = ArrayList<String>(); var chIcon: String? = null
        // programme
        var inProg = false; var pCh = ""; var pStart: Long? = null; var pStop: Long? = null; var pLang: String? = null
        var title = ""; var sub: String? = null; var desc: String? = null; var cat: String? = null; var icon: String? = null; var ep: String? = null; var date: String? = null; var rating: String? = null
        var epSystem = ""; var inRating = false
        var capture: String? = null; val text = StringBuilder()
        fun cut(s: String, n: Int) = if (s.length > n) s.substring(0, n) else s

        try {
            while (true) {
                when (p.next()) {
                    XmlPullParser.START_TAG -> {
                        text.setLength(0)
                        when (val n = p.name) {
                            "tv" -> sawRoot = true
                            "channel" -> { chId = p.getAttributeValue(null, "id")?.takeIf { it.isNotEmpty() }; chNames = ArrayList(); chIcon = null }
                            "programme" -> {
                                inProg = true; pCh = p.getAttributeValue(null, "channel") ?: ""
                                pStart = p.getAttributeValue(null, "start")?.let { XmltvTime.parse(it, localZone) }; pStop = p.getAttributeValue(null, "stop")?.let { XmltvTime.parse(it, localZone) }
                                pLang = null; title = ""; sub = null; desc = null; cat = null; icon = null; ep = null; date = null; rating = null
                                seen++
                                if (seen > MAX_PROGRAMMES) throw GuideReadException("The guide holds far more programmes than a guide should, so it was not imported.")
                            }
                            "display-name", "title", "sub-title", "desc", "category", "date", "episode-num", "value" -> {
                                capture = n
                                if ((n == "title" || n == "desc") && inProg && pLang == null) pLang = p.getAttributeValue(null, "lang")
                                if (n == "episode-num") epSystem = p.getAttributeValue(null, "system") ?: ""
                            }
                            "rating" -> inRating = true
                            "icon" -> p.getAttributeValue(null, "src")?.takeIf { it.isNotEmpty() }?.let { src -> if (inProg) icon = icon ?: src else if (chId != null) chIcon = chIcon ?: src }
                        }
                    }
                    XmlPullParser.TEXT, XmlPullParser.CDSECT -> if (capture != null && text.length < 20_000) text.append(p.text)
                    XmlPullParser.END_TAG -> {
                        val v = text.toString().trim()
                        when (p.name) {
                            "display-name" -> if (chId != null && v.isNotEmpty() && chNames.size < 8) chNames.add(cut(v, MAX_NAME))
                            "title" -> if (inProg && title.isEmpty()) title = cut(v, MAX_TITLE)
                            "sub-title" -> if (inProg && sub == null && v.isNotEmpty()) sub = cut(v, MAX_TITLE)
                            "desc" -> if (inProg && desc == null && v.isNotEmpty()) desc = cut(v, MAX_TEXT)
                            "category" -> if (inProg && cat == null && v.isNotEmpty()) cat = cut(v, MAX_NAME)
                            "date" -> if (inProg && date == null && v.isNotEmpty()) date = cut(v, 16)
                            "value" -> if (inProg && inRating && rating == null && v.isNotEmpty()) rating = cut(v, 16)
                            "rating" -> inRating = false
                            "episode-num" -> if (inProg && v.isNotEmpty()) {
                                val f = if (epSystem == "xmltv_ns") episodeLabel(v) else v
                                if (ep == null || epSystem == "xmltv_ns") ep = cut(f, 32)
                            }
                            "channel" -> {
                                chId?.let { id -> channels++; if (channels > MAX_CHANNELS) throw GuideReadException("The guide lists far more channels than a guide should, so it was not imported."); onChannel(GuideChannelRecord(id, chNames, chIcon)) }
                                chId = null
                            }
                            "programme" -> {
                                inProg = false
                                val s = pStart; val e = pStop
                                if (s == null || e == null || e <= s || pCh.isEmpty() || title.isEmpty()) invalid++
                                else {
                                    first = minOf(first ?: s, s); last = maxOf(last ?: e, e)
                                    if (e < notBeforeMs) past++ else if (s > notAfterMs) future++
                                    else { onProgramme(GuideProgramme(pCh, s, e, title, sub, desc, cat, icon, pLang, ep, date, rating)); kept++ }
                                }
                            }
                        }
                        if (capture == p.name) capture = null
                        text.setLength(0)
                    }
                    XmlPullParser.END_DOCUMENT -> break
                }
            }
        } catch (e: XmlPullParserException) {
            if (kept < MIN_FOR_TRUNCATED) throw e
            truncated = true
        }
        if (!sawRoot) throw GuideReadException("The file is not a programme guide.")
        return GuideReadStats(channels, seen, kept, past, future, invalid, truncated, first, last)
    }

    /** xmltv_ns "1.4.0/2" (zero based season.episode.part) -> "S02E05"; ".7." -> "E08". */
    fun episodeLabel(v: String): String {
        val parts = v.split('.').map { it.substringBefore('/').trim() }
        if (parts.size < 2) return v
        val s = parts[0].toIntOrNull(); val e = parts[1].toIntOrNull()
        return when {
            s != null && e != null -> "S%02dE%02d".format(s + 1, e + 1)
            parts[0].isEmpty() && e != null -> "E%02d".format(e + 1)
            else -> v
        }
    }
}
