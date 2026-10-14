package app.streamsetu.core.net

import app.streamsetu.core.data.db.CategoryEntity
import app.streamsetu.core.data.db.EpisodeEntity
import app.streamsetu.core.data.db.MovieEntity
import app.streamsetu.core.data.db.SeriesEntity
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.Source
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.int
import app.streamsetu.core.parse.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder

/** What reading one movie or series library gave: rows ready for the catalog. */
data class MediaCatalog(val categories: List<CategoryEntity>, val movies: List<MovieEntity>, val series: List<SeriesEntity>)

private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
private fun JsonObject.arr(key: String): List<JsonObject> = (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()
private fun JsonObject.num(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
private fun String.firstContainer(): String = substringBefore(',').trim().lowercase().ifBlank { "mp4" }

/**
 * Jellyfin and Emby. The login is exchanged for an access token, which is kept in the credential store (never in the database) and renewed by signing in
 * again when the server stops accepting it. Movies and series come from the server's libraries; the server decides what each account may see.
 */
class MediaServerClient {
    /** The server's API root: Emby serves it under /emby, Jellyfin at the top. */
    fun base(source: Source): String {
        var a = source.address.trim().trimEnd('/')
        if ("://" !in a) a = "http://$a"
        return if (source.type == SourceType.EMBY && !a.endsWith("/emby")) "$a/emby" else a
    }

    fun deviceId(source: Source) = "streamsetu-${source.id.lowercase()}"
    private fun authHeader(source: Source, token: String? = null) =
        "MediaBrowser Client=\"StreamSetu\", Device=\"StreamSetu\", DeviceId=\"${deviceId(source)}\", Version=\"1.0\"" + (token?.let { ", Token=\"$it\"" } ?: "")

    /** Session = access token and user id, stored together as "token|userId". */
    data class Session(val token: String, val userId: String) { val encoded get() = "$token|$userId"
        companion object { fun decode(s: String?): Session? = s?.split('|', limit = 2)?.takeIf { it.size == 2 && it[0].isNotBlank() }?.let { Session(it[0], it[1]) } } }

    fun authenticate(source: Source, password: String): Session {
        val body = org.json.JSONObject().put("Username", source.username.orEmpty()).put("Pw", password).toString().toRequestBody("application/json".toMediaType())
        val req = Request.Builder().url(base(source) + "/Users/AuthenticateByName").post(body)
            .header("X-Emby-Authorization", authHeader(source)).header("Authorization", authHeader(source)).apply { source.userAgent?.let { header("User-Agent", it) } }.build()
        Http.client.newCall(req).execute().use { r ->
            if (r.code == 401 || r.code == 400) error("The server refused the login. Check the user name and password.")
            if (!r.isSuccessful) error("The server answered ${r.code}.")
            return parseSession(r.body?.string().orEmpty()) ?: error("The server did not give a session. Is this a ${if (source.type == SourceType.EMBY) "Emby" else "Jellyfin"} server?")
        }
    }

    fun parseSession(json: String): Session? {
        val o = Xtream.parseObject(json) ?: return null
        val token = o.str("AccessToken") ?: return null
        val uid = (o["User"] as? JsonObject)?.str("Id") ?: return null
        return Session(token, uid)
    }

    private fun get(source: Source, s: Session, path: String, query: Map<String, String>): JsonObject {
        val url = base(source) + path + "?" + query.entries.joinToString("&") { "${it.key}=${enc(it.value)}" }
        val req = Request.Builder().url(url).header("X-Emby-Token", s.token).header("X-Emby-Authorization", authHeader(source, s.token)).apply { source.userAgent?.let { header("User-Agent", it) } }.build()
        Http.client.newCall(req).execute().use { r ->
            if (r.code == 401) throw AuthExpired()
            if (!r.isSuccessful) error("The server answered ${r.code}.")
            return Xtream.parseObject(r.body?.string().orEmpty()) ?: error("Unexpected reply from the server.")
        }
    }

    class AuthExpired : RuntimeException("The server no longer accepts the saved session.")

    private fun items(source: Source, s: Session, type: String, fields: String): List<JsonObject> {
        val out = ArrayList<JsonObject>(); var start = 0
        while (true) {
            val page = get(source, s, "/Users/${s.userId}/Items", mapOf("IncludeItemTypes" to type, "Recursive" to "true", "Fields" to fields, "SortBy" to "SortName", "StartIndex" to "$start", "Limit" to "500"))
            val batch = page.arr("Items"); out += batch; start += batch.size
            val total = page.int("TotalRecordCount") ?: out.size
            if (batch.isEmpty() || start >= total) return out
        }
    }

    /** Reads every movie and series of the account. [session] is renewed by the caller when it throws [AuthExpired]. */
    fun catalog(source: Source, s: Session): MediaCatalog {
        val fields = "Overview,Genres,CommunityRating,ProductionYear,Container,DateCreated"
        return mapCatalog(source, base(source), items(source, s, "Movie", fields), items(source, s, "Series", fields))
    }

    fun mapCatalog(source: Source, base: String, movies: List<JsonObject>, series: List<JsonObject>): MediaCatalog {
        val cats = LinkedHashMap<String, CategoryEntity>()
        fun cat(item: JsonObject, kind: ContentKind): String {
            val g = (item["Genres"] as? JsonArray)?.firstOrNull()?.let { (it as? JsonPrimitive)?.contentOrNull }?.takeIf { it.isNotBlank() } ?: if (kind == ContentKind.MOVIE) "Movies" else "Series"
            val id = "${source.id}:${kind.name}:$g"
            cats.getOrPut(id) { CategoryEntity(id, source.id, kind.name, g, cats.size) }
            return id
        }
        fun image(item: JsonObject, kind: String) = item.str("Id")?.takeIf { (item["ImageTags"] as? JsonObject)?.containsKey(kind) == true }?.let { "$base/Items/$it/Images/$kind?maxWidth=400" }
        val m = movies.mapNotNull { o ->
            val id = o.str("Id") ?: return@mapNotNull null
            MovieEntity("${source.id}:mv:$id", source.id, cat(o, ContentKind.MOVIE), o.str("Name") ?: "Movie", image(o, "Primary"), o.int("ProductionYear"), o.num("CommunityRating")?.let { "%.1f".format(it) },
                o.str("Overview"), "jf:$id.${(o.str("Container") ?: "mp4").firstContainer()}", isoMillis(o.str("DateCreated")))
        }
        val s = series.mapNotNull { o ->
            val id = o.str("Id") ?: return@mapNotNull null
            SeriesEntity("${source.id}:sr:$id", source.id, cat(o, ContentKind.SERIES), o.str("Name") ?: "Series", image(o, "Primary"), id.let { image(o, "Backdrop") }, o.int("ProductionYear"),
                o.num("CommunityRating")?.let { "%.1f".format(it) }, o.str("Overview"), id, isoMillis(o.str("DateCreated")))
        }
        return MediaCatalog(cats.values.toList(), m, s)
    }

    /** The episodes of one series. */
    fun episodes(source: Source, s: Session, seriesProviderId: String, seriesId: String): List<EpisodeEntity> {
        val page = get(source, s, "/Shows/$seriesProviderId/Episodes", mapOf("UserId" to s.userId, "Fields" to "Overview,RunTimeTicks,Container"))
        return mapEpisodes(source, base(source), seriesId, page.arr("Items"))
    }

    fun mapEpisodes(source: Source, base: String, seriesId: String, items: List<JsonObject>): List<EpisodeEntity> = items.mapNotNull { e ->
        val id = e.str("Id") ?: return@mapNotNull null
        EpisodeEntity("${source.id}:ep:$id", seriesId, e.int("ParentIndexNumber") ?: 1, e.int("IndexNumber") ?: 0, e.str("Name") ?: "Episode", e.str("Overview"),
            if ((e["ImageTags"] as? JsonObject)?.containsKey("Primary") == true) "$base/Items/$id/Images/Primary?maxWidth=500" else null,
            e.num("RunTimeTicks")?.let { (it / 10_000_000).toInt() }, "jf:$id.${(e.str("Container") ?: "mp4").firstContainer()}")
    }

    /** The address to play: the file as it is stored, handed over by the server. */
    fun streamUrl(source: Source, s: Session, ref: String): String {
        val body = ref.removePrefix("jf:"); val id = body.substringBefore('.'); val ext = body.substringAfter('.', "mp4")
        return "${base(source)}/Videos/$id/stream.$ext?static=true&MediaSourceId=$id&DeviceId=${enc(deviceId(source))}&api_key=${enc(s.token)}"
    }

    private fun isoMillis(s: String?): Long = s?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() ?: runCatching { java.time.OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() } ?: 0L
}

/** Plex Media Server: movies and shows from its libraries, using the server's address and an access token (typed in the password field). */
class PlexClient {
    fun base(source: Source): String { var a = source.address.trim().trimEnd('/'); if ("://" !in a) a = "http://$a"; return a }

    private fun get(source: Source, token: String, path: String, query: Map<String, String> = emptyMap()): JsonObject {
        val url = base(source) + path + (if (query.isEmpty()) "" else "?" + query.entries.joinToString("&") { "${it.key}=${enc(it.value)}" })
        val req = Request.Builder().url(url).header("Accept", "application/json").header("X-Plex-Token", token).header("X-Plex-Product", "StreamSetu")
            .header("X-Plex-Client-Identifier", "streamsetu-${source.id.lowercase()}").apply { source.userAgent?.let { header("User-Agent", it) } }.build()
        Http.client.newCall(req).execute().use { r ->
            if (r.code == 401) error("Plex refused the token. Check it and try again.")
            if (!r.isSuccessful) error("Plex answered ${r.code}.")
            return (Xtream.parseObject(r.body?.string().orEmpty())?.get("MediaContainer") as? JsonObject) ?: error("Unexpected reply from Plex.")
        }
    }

    private fun items(source: Source, token: String, section: String, type: Int): List<JsonObject> {
        val out = ArrayList<JsonObject>(); var start = 0
        while (true) {
            val mc = get(source, token, "/library/sections/$section/all", mapOf("type" to "$type", "X-Plex-Container-Start" to "$start", "X-Plex-Container-Size" to "500"))
            val batch = mc.arr("Metadata"); out += batch; start += batch.size
            if (batch.isEmpty() || start >= (mc.int("totalSize") ?: out.size)) return out
        }
    }

    fun catalog(source: Source, token: String): MediaCatalog {
        val dirs = get(source, token, "/library/sections").arr("Directory")
        if (dirs.none { it.str("type") == "movie" || it.str("type") == "show" }) error("This Plex server has no movie or show libraries for this account.")
        val movies = dirs.filter { it.str("type") == "movie" }.mapNotNull { it.str("key") }.flatMap { items(source, token, it, 1) }
        val shows = dirs.filter { it.str("type") == "show" }.mapNotNull { it.str("key") }.flatMap { items(source, token, it, 2) }
        return mapCatalog(source, base(source), token, movies, shows)
    }

    fun mapCatalog(source: Source, base: String, token: String, movies: List<JsonObject>, shows: List<JsonObject>): MediaCatalog {
        val cats = LinkedHashMap<String, CategoryEntity>()
        fun cat(o: JsonObject, kind: ContentKind): String {
            val g = o.arr("Genre").firstOrNull()?.str("tag") ?: if (kind == ContentKind.MOVIE) "Movies" else "Series"
            val id = "${source.id}:${kind.name}:$g"
            cats.getOrPut(id) { CategoryEntity(id, source.id, kind.name, g, cats.size) }
            return id
        }
        fun art(path: String?) = path?.takeIf { it.startsWith("/") }?.let { "$base$it?X-Plex-Token=${enc(token)}" }
        val m = movies.mapNotNull { o ->
            val key = o.str("ratingKey") ?: return@mapNotNull null
            val part = o.arr("Media").firstOrNull()?.arr("Part")?.firstOrNull()?.str("key") ?: return@mapNotNull null
            MovieEntity("${source.id}:mv:$key", source.id, cat(o, ContentKind.MOVIE), o.str("title") ?: "Movie", art(o.str("thumb")), o.int("year"), o.num("rating")?.let { "%.1f".format(it) }, o.str("summary"), "plex:$part", (o.num("addedAt") ?: 0.0).toLong() * 1000)
        }
        val s = shows.mapNotNull { o ->
            val key = o.str("ratingKey") ?: return@mapNotNull null
            SeriesEntity("${source.id}:sr:$key", source.id, cat(o, ContentKind.SERIES), o.str("title") ?: "Series", art(o.str("thumb")), art(o.str("art")), o.int("year"), o.num("rating")?.let { "%.1f".format(it) }, o.str("summary"), key, (o.num("addedAt") ?: 0.0).toLong() * 1000)
        }
        return MediaCatalog(cats.values.toList(), m, s)
    }

    fun episodes(source: Source, token: String, seriesProviderId: String, seriesId: String): List<EpisodeEntity> {
        val out = ArrayList<EpisodeEntity>()
        val seasons = get(source, token, "/library/metadata/$seriesProviderId/children").arr("Metadata").filter { it.str("type") == "season" }
        for (season in seasons) {
            val key = season.str("ratingKey") ?: continue
            out += mapEpisodes(source, base(source), token, seriesId, season.int("index") ?: 1, get(source, token, "/library/metadata/$key/children").arr("Metadata"))
        }
        return out
    }

    fun mapEpisodes(source: Source, base: String, token: String, seriesId: String, season: Int, items: List<JsonObject>): List<EpisodeEntity> = items.mapNotNull { e ->
        val key = e.str("ratingKey") ?: return@mapNotNull null
        val part = e.arr("Media").firstOrNull()?.arr("Part")?.firstOrNull()?.str("key") ?: return@mapNotNull null
        EpisodeEntity("${source.id}:ep:$key", seriesId, season, e.int("index") ?: 0, e.str("title") ?: "Episode", e.str("summary"),
            e.str("thumb")?.takeIf { it.startsWith("/") }?.let { "$base$it?X-Plex-Token=${enc(token)}" }, e.num("duration")?.let { (it / 1000).toInt() }, "plex:$part")
    }

    /** The file's address with the token added. */
    fun streamUrl(source: Source, token: String, ref: String) = base(source) + ref.removePrefix("plex:") + (if ('?' in ref) "&" else "?") + "X-Plex-Token=" + enc(token)
}

/** Keeps the sign-in of a Jellyfin or Emby connection: the token is saved in the credential store and renewed when the server stops accepting it. */
class MediaSessions(private val credentials: app.streamsetu.core.security.CredentialStore, val client: MediaServerClient = MediaServerClient()) {
    private fun ref(source: Source) = "session.${source.id}"

    fun get(source: Source, renew: Boolean = false): MediaServerClient.Session {
        if (!renew) MediaServerClient.Session.decode(credentials.load(ref(source)))?.let { return it }
        val password = credentials.load(app.streamsetu.core.data.repo.SourceRepository.credentialRef(source.id)).orEmpty()
        return client.authenticate(source, password).also { credentials.save(ref(source), it.encoded) }
    }

    fun <T> with(source: Source, call: (MediaServerClient.Session) -> T): T =
        try { call(get(source)) } catch (e: MediaServerClient.AuthExpired) { call(get(source, renew = true)) }
}
