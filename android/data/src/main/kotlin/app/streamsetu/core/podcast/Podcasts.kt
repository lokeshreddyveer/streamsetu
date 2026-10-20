package app.streamsetu.core.podcast

import java.io.ByteArrayInputStream
import java.text.SimpleDateFormat
import java.util.Locale
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler

data class PodcastEpisode(val id: String, val title: String, val summary: String, val audioUrl: String, val publishedMs: Long?, val durationSec: Long?) {
    /** The id its resume point is kept under. */
    val itemId: String get() = "podcast:" + audioUrl.hashCode().toUInt().toString(16)
}

data class PodcastFeed(val title: String, val author: String, val artwork: String?, val episodes: List<PodcastEpisode>)

data class PodcastSub(val feedUrl: String, val title: String, val author: String, val artwork: String?)

/** Reads a podcast's RSS feed: the show, and its episodes newest first. A page that is not a feed gives null. */
object PodcastParser {
    fun parse(bytes: ByteArray): PodcastFeed? {
        val h = Handler()
        runCatching {
            val f = SAXParserFactory.newInstance().apply { isNamespaceAware = false; runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) } }
            f.newSAXParser().parse(ByteArrayInputStream(bytes), h)
        }
        if (h.title.isEmpty()) return null
        return PodcastFeed(h.title, h.author, h.artwork, h.episodes.sortedByDescending { it.publishedMs ?: Long.MIN_VALUE })
    }

    private class Handler : DefaultHandler() {
        var title = ""; var author = ""; var artwork: String? = null
        val episodes = mutableListOf<PodcastEpisode>()
        private val path = ArrayDeque<String>()
        private val text = StringBuilder()
        private var inItem = false
        private val item = HashMap<String, String>()
        private var enclosure: String? = null

        override fun startElement(uri: String?, local: String?, name: String, a: Attributes) {
            path.addLast(name); text.setLength(0)
            if (name == "item") { inItem = true; item.clear(); enclosure = null }
            if (name == "enclosure" && inItem) enclosure = a.getValue("url")
            if (name == "itunes:image" && !inItem) a.getValue("href")?.let { artwork = it }
        }
        override fun characters(ch: CharArray, start: Int, length: Int) { text.append(ch, start, length) }
        override fun endElement(uri: String?, local: String?, name: String) {
            val value = text.toString().trim()
            val parent = path.getOrNull(path.size - 2)
            if (inItem) {
                when (name) {
                    "title", "itunes:summary", "pubDate", "itunes:duration", "guid" -> item.putIfAbsent(name, value)
                    "description" -> item.putIfAbsent(name, value)
                    "item" -> {
                        inItem = false
                        val url = enclosure; val t = item["title"]
                        if (url != null && !t.isNullOrEmpty()) episodes += PodcastEpisode(item["guid"] ?: url, t, plain(item["itunes:summary"] ?: item["description"] ?: ""), url, item["pubDate"]?.let(::date), item["itunes:duration"]?.let(::duration))
                    }
                }
            } else if (parent == "channel") {
                when (name) { "title" -> if (title.isEmpty()) title = value; "itunes:author" -> if (author.isEmpty()) author = value }
            } else if (name == "url" && parent == "image" && artwork == null) artwork = value
            path.removeLast()
        }
    }

    /** Show notes come with HTML in them; the list shows plain text. */
    fun plain(s: String): String {
        var out = s.replace("<br>", "\n").replace("<br/>", "\n").replace("</p>", "\n").replace(Regex("<[^>]*>"), "")
        for ((e, c) in listOf("&amp;" to "&", "&lt;" to "<", "&gt;" to ">", "&quot;" to "\"", "&#39;" to "'", "&nbsp;" to " ")) out = out.replace(e, c)
        return out.trim()
    }

    fun date(s: String): Long? {
        for (f in listOf("EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXX"))
            runCatching { return SimpleDateFormat(f, Locale.US).parse(s)?.time }
        return null
    }

    /** "1:02:03", "45:10" or a number of seconds. */
    fun duration(s: String): Long? {
        val parts = s.split(":").map { it.toDoubleOrNull() ?: return null }
        return if (parts.isEmpty()) null else parts.fold(0.0) { acc, p -> acc * 60 + p }.toLong()
    }
}

/** Reads the answer of Apple's public podcast directory. */
object PodcastSearch {
    fun parse(json: String): List<PodcastSub> = runCatching {
        val results = org.json.JSONObject(json).getJSONArray("results")
        (0 until results.length()).mapNotNull { i ->
            val r = results.getJSONObject(i)
            val feed = r.optString("feedUrl").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            PodcastSub(feed, r.optString("collectionName").ifEmpty { return@mapNotNull null }, r.optString("artistName"), r.optString("artworkUrl600").takeIf { it.isNotEmpty() })
        }
    }.getOrDefault(emptyList())
}
