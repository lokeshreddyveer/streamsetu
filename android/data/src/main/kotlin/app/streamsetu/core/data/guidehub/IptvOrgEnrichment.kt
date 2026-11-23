package app.streamsetu.core.data.guidehub

import kotlinx.serialization.json.*

class BlocklistUnavailable : Exception("The public channel database's block list could not be loaded, so nothing was matched.")

data class IptvChannel(val id: String, val name: String, val altNames: List<String>, val country: String?, val categories: List<String>, val nsfw: Boolean, val closed: String?)
data class IptvLogo(val channel: String, val url: String, val width: Int, val tags: List<String>, val format: String?)
data class IptvFeed(val channel: String, val isMain: Boolean, val languages: List<String>, val timezones: List<String>)
data class IptvEnrichment(val dbId: String, val country: String?, val languages: List<String>, val categories: List<String>, val timezones: List<String>, val logoUrl: String?, val matchedBy: String, val confidence: Double)

/** The public channel database (Unlicense): matched locally, whole files, the block list FAIL CLOSED. A port of the Apple `IPTVOrgIndex` and `IPTVOrgEnricher`. */
class IptvOrgIndex private constructor(
    val channels: Map<String, IptvChannel>, val blocked: Set<String>, private val byName: Map<String, List<String>>, private val logos: Map<String, List<IptvLogo>>, private val feeds: Map<String, List<IptvFeed>>,
) {
    fun idsForName(key: String): List<String> = byName[key].orEmpty()
    fun logosFor(id: String): List<IptvLogo> = logos[id].orEmpty()
    fun feedsFor(id: String): List<IptvFeed> = feeds[id].orEmpty()

    companion object {
        private fun strs(e: JsonElement?): List<String> = (e as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        fun parseChannels(json: String): List<IptvChannel> = Json.parseToJsonElement(json).jsonArray.map {
            val o = it.jsonObject
            IptvChannel(o["id"]!!.jsonPrimitive.content, o["name"]?.jsonPrimitive?.contentOrNull ?: "", strs(o["alt_names"]), o["country"]?.jsonPrimitive?.contentOrNull, strs(o["categories"]),
                o["is_nsfw"]?.jsonPrimitive?.booleanOrNull ?: false, o["closed"]?.jsonPrimitive?.contentOrNull)
        }
        fun parseLogos(json: String): List<IptvLogo> = Json.parseToJsonElement(json).jsonArray.map {
            val o = it.jsonObject
            IptvLogo(o["channel"]!!.jsonPrimitive.content, o["url"]!!.jsonPrimitive.content, o["width"]?.jsonPrimitive?.intOrNull ?: 0, strs(o["tags"]), o["format"]?.jsonPrimitive?.contentOrNull)
        }
        fun parseFeeds(json: String): List<IptvFeed> = Json.parseToJsonElement(json).jsonArray.map {
            val o = it.jsonObject
            IptvFeed(o["channel"]!!.jsonPrimitive.content, o["is_main"]?.jsonPrimitive?.booleanOrNull ?: false, strs(o["languages"]), strs(o["timezones"]))
        }

        /** A missing, unreadable or empty block list throws: nothing is enriched without it. */
        fun build(channels: List<IptvChannel>, blocklistJson: String?, logos: List<IptvLogo> = emptyList(), feeds: List<IptvFeed> = emptyList()): IptvOrgIndex {
            val entries = try { Json.parseToJsonElement(blocklistJson ?: throw BlocklistUnavailable()).jsonArray.map { it.jsonObject["channel"]!!.jsonPrimitive.content } } catch (e: BlocklistUnavailable) { throw e } catch (e: Exception) { throw BlocklistUnavailable() }
            if (entries.isEmpty()) throw BlocklistUnavailable()
            val blocked = entries.toSet()
            val byId = LinkedHashMap<String, IptvChannel>(); val byName = HashMap<String, MutableList<String>>()
            for (c in channels) {
                if (c.id in blocked) continue
                byId[c.id] = c
                val seen = HashSet<String>()
                for (n in listOf(c.name) + c.altNames) { val k = ChannelNormalizer.name(n).key; if (k.isNotEmpty() && seen.add(k)) byName.getOrPut(k) { mutableListOf() }.add(c.id) }
            }
            return IptvOrgIndex(byId, blocked, byName, logos.filter { it.channel in byId }.groupBy { it.channel }, feeds.filter { it.channel in byId }.groupBy { it.channel })
        }
    }
}

object IptvOrgEnricher {
    fun match(name: String, tvgId: String?, country: String?, restricted: Boolean, index: IptvOrgIndex): IptvEnrichment? {
        if (restricted) return null
        fun usable(id: String): IptvChannel? { val c = index.channels[id] ?: return null; return if (id in index.blocked || c.nsfw || c.closed != null || "xxx" in c.categories) null else c }
        val tvg = tvgId?.trim()
        if (!tvg.isNullOrEmpty()) {
            val base = tvg.substringBefore('@')
            if (base in index.blocked) return null
            usable(base)?.let { return make(it, "id", 0.95, index) }
        }
        val key = ChannelNormalizer.name(name)
        if (key.isEmpty) return null
        val ids = index.idsForName(key.key)
        if (ids.isEmpty()) return null
        // Name only (owner policy): no country or language filter, the first usable record in database order wins; a record with a logo is preferred over one without.
        val cands = ids.mapNotNull(::usable)
        val first = cands.firstOrNull() ?: return null
        val pick = cands.firstOrNull { bestLogo(index.logosFor(it.id)) != null } ?: first
        return make(pick, "name", 0.65, index)
    }
    private fun make(c: IptvChannel, by: String, conf: Double, index: IptvOrgIndex): IptvEnrichment {
        val feeds = index.feedsFor(c.id); val main = feeds.firstOrNull { it.isMain } ?: feeds.firstOrNull()
        return IptvEnrichment(c.id, c.country, main?.languages.orEmpty(), c.categories, main?.timezones.orEmpty(), bestLogo(index.logosFor(c.id))?.url, by, conf)
    }
    fun bestLogo(logos: List<IptvLogo>): IptvLogo? {
        val ok = logos.filter { it.url.startsWith("https://") && "old" !in it.tags && it.width >= 128 }
        fun rank(l: IptvLogo) = when (l.format?.uppercase()) { "PNG", "WEBP" -> 0; "SVG" -> 2; else -> 1 }
        return ok.minWithOrNull(compareBy<IptvLogo>({ rank(it) }, { -it.width }))
    }
}
