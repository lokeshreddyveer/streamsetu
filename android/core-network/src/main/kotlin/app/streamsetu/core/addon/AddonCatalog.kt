package app.streamsetu.core.addon

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** One folder an add-on lists. */
@Serializable data class AddonCategory(val id: String, val name: String, val kind: String = "movie")

/** One title or channel an add-on lists. [url] is the address to play; without it the add-on's stream endpoint is asked when the person presses play. */
@Serializable data class AddonItem(
    val id: String, val title: String, val category: String? = null, val image: String? = null, val year: Int? = null,
    val rating: String? = null, val plot: String? = null, val url: String? = null, val number: Int? = null,
)

/** One episode of a series. [url] is the address to play; without it the add-on's stream endpoint is asked when the person presses play. */
@Serializable data class AddonEpisode(val id: String, val season: Int = 1, val number: Int, val title: String = "", val plot: String? = null, val image: String? = null, val url: String? = null, val minutes: Int? = null)

/** A series with its episodes listed in the catalog. */
@Serializable data class AddonSeries(
    val id: String, val title: String, val category: String? = null, val image: String? = null, val year: Int? = null, val rating: String? = null, val plot: String? = null,
    val episodes: List<AddonEpisode> = emptyList(),
)

/** What an add-on's catalog endpoint answers. Unknown fields are ignored so a newer add-on still works; everything that is used is checked below. */
@Serializable data class AddonCatalogResponse(val categories: List<AddonCategory> = emptyList(), val channels: List<AddonItem> = emptyList(), val movies: List<AddonItem> = emptyList(), val series: List<AddonSeries> = emptyList())

/** An add-on's catalog after checking: only what this version can show, with every address on one of the add-on's own servers. */
data class AddonCatalog(val categories: List<AddonCategory>, val channels: List<AddonItem>, val movies: List<AddonItem>, val dropped: Int, val series: List<AddonSeries> = emptyList())

object AddonCatalogParser {
    const val MAX_ITEMS = 100_000
    const val MAX_EPISODES = 200_000
    const val MAX_EPISODES_PER_SERIES = 3_000
    private val lenient = Json { ignoreUnknownKeys = true; isLenient = false }

    fun parse(text: String, manifest: AddonManifest): AddonCatalog {
        val raw = try { lenient.decodeFromString(AddonCatalogResponse.serializer(), text) } catch (e: Exception) { throw AddonException("${manifest.name} sent a catalog this version cannot read.") }
        val hosts = manifest.allowedHosts.map { it.trim().lowercase() }.toSet()
        var dropped = 0
        fun ok(u: String?) = u == null || AddonManifestParser.hostOf(u)?.let { it in hosts } == true          // a picture or a stream on a server the add-on did not name is not used
        fun clean(i: AddonItem): AddonItem? {
            if (i.id.isBlank() || i.id.length > 200 || i.title.isBlank() || !ok(i.image) || !ok(i.url)) { dropped++; return null }
            return i.copy(title = i.title.take(200), plot = i.plot?.take(2000), rating = i.rating?.take(12), category = i.category?.take(200), year = i.year?.takeIf { it in 1870..2200 })
        }
        val categories = raw.categories.filter { it.id.isNotBlank() && it.id.length <= 200 && it.name.isNotBlank() }.map { it.copy(name = it.name.take(120)) }.distinctBy { it.id }.take(5_000)
        val channels = raw.channels.mapNotNull(::clean).distinctBy { it.id }
        val movies = raw.movies.mapNotNull(::clean).distinctBy { it.id }
        val series = raw.series.mapNotNull { s ->
            if (s.id.isBlank() || s.id.length > 200 || s.title.isBlank() || !ok(s.image)) { dropped++; return@mapNotNull null }
            val episodes = s.episodes.take(MAX_EPISODES_PER_SERIES).filter { e -> (e.id.isNotBlank() && e.id.length <= 200 && e.number >= 0 && e.season in 0..500 && ok(e.image) && ok(e.url)).also { good -> if (!good) dropped++ } }
                .distinctBy { it.id }.map { it.copy(title = it.title.take(200), plot = it.plot?.take(2000), minutes = it.minutes?.takeIf { m -> m in 1..1000 }) }
            s.copy(title = s.title.take(200), plot = s.plot?.take(2000), rating = s.rating?.take(12), category = s.category?.take(200), year = s.year?.takeIf { it in 1870..2200 }, episodes = episodes)
        }.distinctBy { it.id }
        if (channels.size + movies.size + series.size > MAX_ITEMS) throw AddonException("${manifest.name} listed more than $MAX_ITEMS titles. Nothing was added.")
        if (series.sumOf { it.episodes.size } > MAX_EPISODES) throw AddonException("${manifest.name} listed more than $MAX_EPISODES episodes. Nothing was added.")
        return AddonCatalog(categories, channels, movies, dropped, series)
    }

    /** The question for one title's play address: `{"url": "https://..."}`. Null when the answer is not an address on the add-on's own servers. */
    fun parseStream(text: String, manifest: AddonManifest): String? {
        val url = runCatching { lenient.parseToJsonElement(text) }.getOrNull()?.let { e -> (e as? kotlinx.serialization.json.JsonObject)?.get("url") as? kotlinx.serialization.json.JsonPrimitive }?.content ?: return null
        val host = AddonManifestParser.hostOf(url) ?: return null
        return url.takeIf { host in manifest.allowedHosts.map { it.trim().lowercase() } }
    }
}
