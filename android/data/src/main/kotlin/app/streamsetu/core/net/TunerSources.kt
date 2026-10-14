package app.streamsetu.core.net

import app.streamsetu.core.data.db.CategoryEntity
import app.streamsetu.core.data.db.ChannelEntity
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.Source
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.int
import app.streamsetu.core.parse.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** Live channels read from a tuner or receiver on the local network. */
data class LiveCatalog(val categories: List<CategoryEntity>, val channels: List<ChannelEntity>)

/** An HDHomeRun tuner: its channel list is at /lineup.json, and each channel has its own stream address on the tuner. */
object HdHomeRun {
    fun lineupUrl(address: String): String {
        var a = address.trim().trimEnd('/'); if ("://" !in a) a = "http://$a"
        return if (a.endsWith(".json")) a else "$a/lineup.json"
    }

    fun parse(source: Source, json: String): LiveCatalog {
        val list = runCatching { Xtream.json.parseToJsonElement(json) }.getOrNull() as? JsonArray ?: error("That address did not answer like an HDHomeRun tuner.")
        val cat = CategoryEntity("${source.id}:CHANNEL:HDHomeRun", source.id, ContentKind.CHANNEL.name, "HDHomeRun", 0)
        val rows = list.mapNotNull { it as? JsonObject }.filter { it.int("DRM") != 1 }.mapIndexedNotNull { i, o ->
            val url = o.str("URL") ?: return@mapIndexedNotNull null
            val number = o.str("GuideNumber")
            ChannelEntity("${source.id}:ch:${number ?: i}", source.id, cat.id, o.str("GuideName") ?: "Channel ${number ?: i}", number?.toIntOrNull(), null, url, null, 0, i)
        }
        return LiveCatalog(listOf(cat), rows)
    }
}

/** Enigma2 satellite and cable receivers with the OpenWebif interface: channels by bouquet, streamed from the receiver's own stream port. */
object Enigma2 {
    const val STREAM_PORT = 8001

    /** Normal TV and radio services start "1:0:". Markers ("1:64:") and directories ("1:832:") are not channels. */
    fun isChannel(ref: String) = ref.startsWith("1:0:")

    fun base(address: String): String { var a = address.trim().trimEnd('/'); if ("://" !in a) a = "http://$a"; return a }

    fun parse(source: Source, json: String): LiveCatalog {
        val root = Xtream.parseObject(json) ?: error("The receiver did not answer like an Enigma2 box. Is OpenWebif turned on?")
        val cats = ArrayList<CategoryEntity>(); val rows = ArrayList<ChannelEntity>(); val seen = HashSet<String>()
        for (b in (root["services"] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()) {
            val name = b.str("servicename") ?: "Channels"
            val cid = "${source.id}:CHANNEL:$name"
            var any = false
            for (s in (b["subservices"] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()) {
                val ref = s.str("servicereference") ?: continue
                if (!isChannel(ref) || !seen.add(ref)) continue
                val n = s.str("servicename") ?: continue
                rows += ChannelEntity("${source.id}:ch:${ref.hashCode()}", source.id, cid, n, null, null, "e2:$ref", null, 0, rows.size)
                any = true
            }
            if (any) cats += CategoryEntity(cid, source.id, ContentKind.CHANNEL.name, name, cats.size)
        }
        if (rows.isEmpty()) error("The receiver listed no channels. Is OpenWebif turned on?")
        return LiveCatalog(cats, rows)
    }

    /** `http://host:8001/<service reference>`; the login, if any, goes in the Authorization header. */
    fun streamUrl(address: String, ref: String): String {
        val u = java.net.URI(base(address))
        return "http://${u.host}:$STREAM_PORT/" + ref.removePrefix("e2:")
    }
}

/** TVHeadend: the playlist and the guide are on fixed addresses and sign in with HTTP Basic. */
object TvHeadend {
    fun base(address: String): String { var a = address.trim().trimEnd('/'); if ("://" !in a) a = "http://$a"; return a }
    fun playlistUrl(address: String) = base(address) + "/playlist/channels.m3u?profile=pass"
    fun guideUrl(address: String) = base(address) + "/xmltv/channels"
}
