package app.streamsetu.core.data.hub

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Payload parsers and request builders for the extra services (the same shapes as the Apple app; fixtures in artwork/fixtures). Network calls go through the app's Http; a key travels only
// in a header or a JSON body, never in an address, and is never logged.

data class HubEpisode(val season: Int, val number: Int, val name: String?, val summary: String?, val airdate: String?, val airstamp: String?, val runtime: Int?, val imageUrl: String?, val rating: Double?)
data class HubSeason(val number: Int, val episodeCount: Int?, val premiere: String?, val end: String?)
data class HubEpisodes(val source: HubSource, val status: String? = null, val seasons: List<HubSeason> = emptyList(), val episodes: List<HubEpisode> = emptyList(),
                       val next: HubEpisode? = null, val rating: Double? = null, val ids: HubIdentity = HubIdentity(), val updated: Long? = null)
data class ScheduleEntry(val tvmazeId: Int, val show: String, val tvdb: Int?, val imdb: String?, val season: Int?, val number: Int?, val airstamp: String?)

private fun parse(text: String): JsonElement? = runCatching { Json.parseToJsonElement(text) }.getOrNull()
private fun JsonElement?.obj(): JsonObject? = this as? JsonObject
private fun JsonElement?.arr(): JsonArray? = this as? JsonArray
private fun JsonElement?.prim(): JsonPrimitive? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }
private fun JsonElement?.int(): Int? = prim()?.content?.let { it.toIntOrNull() ?: it.toDoubleOrNull()?.toInt() }
private fun JsonElement?.long(): Long? = prim()?.content?.toLongOrNull()
private fun JsonElement?.dbl(): Double? = prim()?.content?.toDoubleOrNull()
private fun JsonElement?.str(): String? = prim()?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() }
private fun https(s: String) = if (s.startsWith("http://")) "https://" + s.removePrefix("http://") else s

/** What a fanart.tv request carries: the project key always, and the person's personal key in addition (it also skips the 7-day delay on new images). */
data class FanartKeys(val projectKey: String, val clientKey: String?) { override fun toString() = "FanartKeys(redacted)" }

/** The request a service call is: address and headers (keys only in headers). */
data class HubRequest(val url: String, val headers: Map<String, String> = emptyMap(), val method: String = "GET", val body: String? = null) { override fun toString() = "HubRequest($method $url)" }

object FanartProvider {
    const val HOST = "webservice.fanart.tv"
    fun request(kind: HubTitleKind, id: String, keys: FanartKeys): HubRequest =
        HubRequest("https://$HOST/v3.2/" + (if (kind == HubTitleKind.MOVIE) "movies/" else "tv/") + id,
            buildMap { put("api-key", keys.projectKey); keys.clientKey?.let { put("client-key", it) }; put("Accept", "application/json") })

    private data class Slot(val key: String, val kind: ArtKind, val w: Int, val h: Int, val tv: Boolean)
    private val slots = listOf(
        Slot("hdmovielogo", ArtKind.LOGO, 800, 310, false), Slot("movielogo", ArtKind.LOGO, 400, 155, false), Slot("moviebackground", ArtKind.BACKDROP, 1920, 1080, false),
        Slot("movieposter", ArtKind.POSTER, 1000, 1426, false), Slot("moviebanner", ArtKind.BANNER, 1000, 185, false), Slot("moviethumb", ArtKind.THUMB, 1000, 562, false),
        Slot("hdtvlogo", ArtKind.LOGO, 800, 310, true), Slot("clearlogo", ArtKind.LOGO, 400, 155, true), Slot("showbackground", ArtKind.BACKDROP, 1920, 1080, true),
        Slot("tvposter", ArtKind.POSTER, 1000, 1426, true), Slot("tvbanner", ArtKind.BANNER, 1000, 185, true), Slot("tvthumb", ArtKind.THUMB, 1000, 562, true),
        Slot("seasonposter", ArtKind.SEASON_POSTER, 1000, 1426, true))

    fun parse(text: String, kind: HubTitleKind): List<ArtCandidate> {
        val root = parse(text).obj() ?: return emptyList()
        val out = mutableListOf<ArtCandidate>()
        for (s in slots) {
            if (s.tv != (kind == HubTitleKind.SERIES)) continue
            for (e in root[s.key].arr().orEmpty()) {
                val o = e.obj() ?: continue
                val url = o["url"].str() ?: continue
                var lang = o["lang"].str(); if (lang == "00") lang = ""
                var season: Int? = null
                if (s.kind == ArtKind.SEASON_POSTER) { val sn = o["season"].str(); if (sn == "all") continue; season = sn?.toIntOrNull() }
                out += ArtCandidate(s.kind, https(url), HubSource.FANART, lang, s.w, s.h, o["likes"].int() ?: 0, season)
            }
        }
        return out
    }
}

object TVDBProvider {
    const val BASE = "https://api4.thetvdb.com/v4"
    const val TOKEN_LIFE_MS = 30L * 86_400_000
    /** The login: the key goes in the JSON body, never in the address. */
    fun loginRequest(apiKey: String, pin: String?): HubRequest = HubRequest("$BASE/login", mapOf("Content-Type" to "application/json", "Accept" to "application/json"), "POST",
        buildJsonObject { put("apikey", apiKey); if (!pin.isNullOrEmpty()) put("pin", pin) }.toString())
    fun authorized(path: String, token: String) = HubRequest("$BASE$path", mapOf("Authorization" to "Bearer $token", "Accept" to "application/json"))
    fun parseToken(text: String): String? = parse(text).obj()?.get("data").obj()?.get("token").str()
    fun encodeToken(token: String, at: Long) = "$at:$token"
    fun decodeToken(s: String): Pair<String, Long>? { val i = s.indexOf(':'); val at = s.substring(0, if (i < 0) 0 else i).toLongOrNull() ?: return null; return s.substring(i + 1) to at }

    private val langs = mapOf("eng" to "en", "hin" to "hi", "tel" to "te", "tam" to "ta", "mal" to "ml", "kan" to "kn", "ben" to "bn", "mar" to "mr", "pan" to "pa", "guj" to "gu", "urd" to "ur",
        "spa" to "es", "fra" to "fr", "fre" to "fr", "deu" to "de", "ger" to "de", "jpn" to "ja", "kor" to "ko", "zho" to "zh", "ita" to "it", "por" to "pt", "rus" to "ru", "tur" to "tr", "ara" to "ar")
    fun lang(three: String?): String { val t = three?.lowercase().orEmpty(); return if (t.isEmpty()) "" else langs[t] ?: t.take(2) }

    /** Artwork type ids: series 1 banner, 2 poster, 3 background, 7 season poster, 23 clearlogo; movies 14 poster, 15 background, 16 banner, 25 clearlogo. */
    fun parseArtworks(text: String, kind: HubTitleKind): List<ArtCandidate> {
        val list = parse(text).obj()?.get("data").obj()?.get("artworks").arr().orEmpty()
        val map = if (kind == HubTitleKind.SERIES) mapOf(1 to ArtKind.BANNER, 2 to ArtKind.POSTER, 3 to ArtKind.BACKDROP, 7 to ArtKind.SEASON_POSTER, 23 to ArtKind.LOGO)
                  else mapOf(14 to ArtKind.POSTER, 15 to ArtKind.BACKDROP, 16 to ArtKind.BANNER, 25 to ArtKind.LOGO)
        return list.mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            val k = map[o["type"].int()] ?: return@mapNotNull null
            val u = o["image"].str() ?: return@mapNotNull null
            ArtCandidate(k, https(u), HubSource.TVDB, lang(o["language"].str()), o["width"].int() ?: 0, o["height"].int() ?: 0, o["score"].int() ?: 0)
        }
    }
}

object TVmazeProvider {
    const val BASE = "https://api.tvmaze.com"
    fun showRequest(id: HubIdentity): HubRequest? = when {
        id.tvmaze != null -> HubRequest("$BASE/shows/${id.tvmaze}?embed[]=nextepisode&embed[]=seasons&embed[]=episodes")
        id.tvdb != null -> HubRequest("$BASE/lookup/shows?thetvdb=${id.tvdb}")
        id.imdb != null -> HubRequest("$BASE/lookup/shows?imdb=${id.imdb}")
        else -> null
    }

    fun parseShow(text: String): HubEpisodes? {
        val s = parse(text).obj() ?: return null
        val sid = s["id"].int() ?: return null
        val emb = s["_embedded"].obj()
        fun ep(e: JsonObject): HubEpisode? {
            val sn = e["season"].int() ?: return null; val n = e["number"].int() ?: return null        // specials without a number are skipped
            val img = e["image"].obj()?.let { it["original"].str() ?: it["medium"].str() }
            return HubEpisode(sn, n, e["name"].str(), e["summary"].str()?.let(EpisodeTextArbiter::stripHtml), e["airdate"].str(), e["airstamp"].str(), e["runtime"].int(), img?.let(::https), e["rating"].obj()?.get("average").dbl())
        }
        val eps = emb?.get("episodes").arr().orEmpty().mapNotNull { it.obj()?.let(::ep) }
        val seasons = emb?.get("seasons").arr().orEmpty().mapNotNull { x -> val o = x.obj() ?: return@mapNotNull null; HubSeason(o["number"].int() ?: return@mapNotNull null, o["episodeOrder"].int(), o["premiereDate"].str(), o["endDate"].str()) }
        val ne = emb?.get("nextepisode"); val next = ne.obj()?.let(::ep) ?: ne.arr()?.firstOrNull()?.obj()?.let(::ep)
        val ext = s["externals"].obj()
        return HubEpisodes(HubSource.TVMAZE, s["status"].str(), seasons, eps, next, s["rating"].obj()?.get("average").dbl(),
            HubIdentity(tvdb = ext?.get("thetvdb").int(), imdb = HubIdentity.imdbId(ext?.get("imdb").str()), tvmaze = sid, kind = HubTitleKind.SERIES), s["updated"].long())
    }
    fun parseSchedule(text: String): List<ScheduleEntry> = parse(text).arr().orEmpty().mapNotNull { e ->
        val o = e.obj() ?: return@mapNotNull null
        val show = o["show"].obj() ?: o["_embedded"].obj()?.get("show").obj() ?: return@mapNotNull null
        val ext = show["externals"].obj()
        ScheduleEntry(show["id"].int() ?: return@mapNotNull null, show["name"].str() ?: return@mapNotNull null, ext?.get("thetvdb").int(), HubIdentity.imdbId(ext?.get("imdb").str()), o["season"].int(), o["number"].int(), o["airstamp"].str())
    }
}

object TMDBProvider {
    /** A TMDB /images reply as candidates; [base] is the image base address. */
    fun parseImages(text: String, base: String = "https://image.tmdb.org/t/p/original"): List<ArtCandidate> {
        val r = parse(text).obj() ?: return emptyList()
        val out = mutableListOf<ArtCandidate>()
        for ((key, kind) in listOf("posters" to ArtKind.POSTER, "backdrops" to ArtKind.BACKDROP, "logos" to ArtKind.LOGO))
            for (e in r[key].arr().orEmpty()) {
                val o = e.obj() ?: continue
                val p = o["file_path"].str() ?: continue
                out += ArtCandidate(kind, base + p, HubSource.TMDB, o["iso_639_1"].str(), o["width"].int() ?: 0, o["height"].int() ?: 0, o["vote_count"].int() ?: 0)
            }
        return out
    }
}

/** What the details reply carries beyond the page's own fields: the other services' ids (external_ids) and the Hindi/Telugu title and overview (translations). */
object TMDBExtras {
    /** The /external_ids reply of a series or film ({"id", "imdb_id", "tvdb_id", ...}) as the crosswalk ids; null when it is not readable. */
    fun parseExternalIds(text: String, tmdbId: Int, isSeries: Boolean): HubIdentity? {
        val j = parse(text).obj() ?: return null
        return HubIdentity(tmdbId, if (isSeries) j["tvdb_id"].int() else null, HubIdentity.imdbId(j["imdb_id"].str()), null, if (isSeries) HubTitleKind.SERIES else HubTitleKind.MOVIE)
    }

    data class Parsed(val ids: HubIdentity, val translations: Map<String, String>)
    fun parse(text: String, isSeries: Boolean): Parsed? {
        val j = parse(text).obj() ?: return null
        val id = j["id"].int() ?: return null
        val ext = j["external_ids"].obj()
        val imdb = HubIdentity.imdbId(ext?.get("imdb_id").str() ?: j["imdb_id"].str())
        val ids = HubIdentity(id, if (isSeries) ext?.get("tvdb_id").int() else null, imdb, null, if (isSeries) HubTitleKind.SERIES else HubTitleKind.MOVIE)
        val tr = linkedMapOf<String, String>()
        for (t in j["translations"].obj()?.get("translations").arr().orEmpty()) {
            val o = t.obj() ?: continue
            val lang = o["iso_639_1"].str() ?: continue
            if (lang != "hi" && lang != "te") continue
            val d = o["data"].obj() ?: continue
            (d["title"].str() ?: d["name"].str())?.let { tr["title:$lang"] = it }
            d["overview"].str()?.let { tr["overview:$lang"] = it }
        }
        return Parsed(ids, tr)
    }
}

/** Where the person's own keys are kept (EncryptedSharedPreferences on device; memory in tests) and the small flags (toggle, pause). */
interface HubSecretStore { fun get(account: String): String?; fun set(account: String, value: String?) }
interface HubFlags { fun getLong(key: String): Long?; fun setLong(key: String, v: Long?); fun getBool(key: String): Boolean?; fun setBool(key: String, v: Boolean) }
class MemoryHubStore : HubSecretStore, HubFlags {
    private val m = HashMap<String, String>(); private val l = HashMap<String, Long>(); private val b = HashMap<String, Boolean>()
    override fun get(account: String) = m[account]
    override fun set(account: String, value: String?) { if (value == null) m.remove(account) else m[account] = value }
    override fun getLong(key: String) = l[key]
    override fun setLong(key: String, v: Long?) { if (v == null) l.remove(key) else l[key] = v }
    override fun getBool(key: String) = b[key]
    override fun setBool(key: String, v: Boolean) { b[key] = v }
}

/** Which credential a service uses, with its toggle and its 7-day pause after the built-in key is refused (401/403). Order: the person's own key, then the built-in one, else off. */
class HubAccess(val source: HubSource, private val secrets: HubSecretStore, private val flags: HubFlags, private val builtIn: () -> String?, private val now: () -> Long = System::currentTimeMillis) {
    enum class Origin { OWN, BUILT_IN, NONE }
    companion object {
        const val PAUSE_MS = 7L * 86_400_000
        fun keyAccount(s: HubSource) = "hub.${s.key}.own"
        const val TVDB_PIN_ACCOUNT = "hub.tvdb.pin"
        const val TVDB_TOKEN_ACCOUNT = "hub.tvdb.token"
    }
    private val rejectedKey get() = "hub.${source.key}.builtIn.rejectedAt"
    private val enabledKey get() = "hub.${source.key}.enabled"
    var enabled: Boolean
        get() = flags.getBool(enabledKey) ?: when (source) { HubSource.FANART -> HubDefaults.FANART_BUILT_IN_DEFAULT_ON; HubSource.TVDB -> HubDefaults.TVDB_BUILT_IN_DEFAULT_ON; HubSource.TVMAZE -> HubDefaults.TVMAZE_DEFAULT_ON; else -> true }
        set(v) = flags.setBool(enabledKey, v)
    val ownKey: String? get() = secrets.get(keyAccount(source))?.trim()?.takeIf { it.isNotEmpty() }
    val pin: String? get() = secrets.get(TVDB_PIN_ACCOUNT)?.takeIf { it.isNotEmpty() }
    fun setOwnKey(k: String?) { secrets.set(keyAccount(source), k?.trim()?.takeIf { it.isNotEmpty() }); clearRejection() }
    val builtInRejected: Boolean get() { val at = flags.getLong(rejectedKey) ?: return false; return at > 0 && now() - at < PAUSE_MS }
    fun markBuiltInRejected() = flags.setLong(rejectedKey, now())
    fun clearRejection() = flags.setLong(rejectedKey, null)
    val builtInUsable: Boolean get() = !builtInRejected && builtIn() != null
    val origin: Origin get() = when {
        !enabled -> Origin.NONE
        source == HubSource.TVMAZE -> Origin.BUILT_IN
        ownKey != null -> Origin.OWN
        builtInUsable -> Origin.BUILT_IN
        else -> Origin.NONE
    }
    /** The plain status line shown in Settings (the only place a service is named). */
    val statusLine: String get() = when {
        !enabled -> "Off"
        source == HubSource.TVMAZE -> "Working"
        ownKey != null -> "Using your key"
        builtInRejected -> "Paused for 7 days: the built-in key was refused"
        builtIn() != null -> "Using the built-in key"
        source == HubSource.TVDB -> "Off until you add your own key"
        else -> "No key available"
    }
    fun fanartKeys(): FanartKeys? {
        if (!enabled) return null
        val own = ownKey
        if (builtInUsable) return FanartKeys(builtIn()!!, own)
        return own?.let { FanartKeys(it, null) }
    }
    fun builtInKey(): String? = builtIn()
}
