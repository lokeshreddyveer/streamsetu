package app.streamsetu.core.data.repo

import app.streamsetu.core.security.CredentialStore
import kotlinx.serialization.json.*

/** Trakt keeps a record of what you have watched. The person brings their own Trakt app (a free Client ID and Secret), signs in with a short code, and what they finish is marked watched. Nothing is sent for a private watch or a kids profile. */
data class TraktTokens(val access: String, val refresh: String, val expiresMs: Long) {
    fun isExpiring(now: Long = System.currentTimeMillis()) = expiresMs - now < 24 * 3600_000L
}
data class TraktApp(val clientId: String = "", val secret: String = "") { val isComplete get() = clientId.isNotBlank() && secret.isNotBlank() }
data class TraktListed(val title: String, val year: Int?, val isShow: Boolean)
data class TraktDeviceCode(val deviceCode: String, val userCode: String, val url: String, val expiresIn: Int, val interval: Int)
class TraktException(message: String, val kind: Kind = Kind.OTHER) : Exception(message) { enum class Kind { NOT_SIGNED_IN, EXPIRED, DENIED, OTHER } }

sealed interface TraktItem {
    data class Movie(val title: String, val year: Int?) : TraktItem
    data class Episode(val show: String, val year: Int?, val season: Int, val number: Int) : TraktItem

    fun payload(progress: Double): JsonObject = buildJsonObject {
        when (this@TraktItem) {
            is Movie -> put("movie", buildJsonObject { put("title", title); year?.let { put("year", it) } })
            is Episode -> { put("show", buildJsonObject { put("title", show); year?.let { put("year", it) } }); put("episode", buildJsonObject { put("season", season); put("number", number) }) }
        }
        put("progress", progress.coerceIn(0.0, 100.0))
    }

    companion object {
        /** "John Wick (2014) 4K HEVC" -> "John Wick": the provider's decoration is taken off so Trakt can find the title. */
        fun cleanTitle(raw: String): String {
            var t = raw.replace(Regex("""[\(\[][^)\]]*[)\]]"""), " ")
            t = t.replace(Regex("""(?i)\b(2160p|1080p|720p|480p|4k|uhd|fhd|hd|sd|hevc|x26[45]|h26[45]|bluray|brrip|webrip|web-dl|hdrip|dvdrip|dubbed|multi|sub|subs)\b"""), " ")
            t = t.replace(Regex("""^\s*[A-Za-z]{2,3}\s*[:|\-]\s+"""), "")
            return t.trim().split(Regex("""\s+""")).filter { it.isNotEmpty() }.joinToString(" ")
        }
        fun normalize(s: String) = java.text.Normalizer.normalize(s, java.text.Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase().replace(Regex("[^a-z0-9]+"), " ").trim()
        /** A library title matches when its cleaned name is the same, and the years agree (within a year) when both are known. */
        fun matches(listed: TraktListed, title: String, year: Int?): Boolean {
            val a = normalize(cleanTitle(listed.title)); val b = normalize(cleanTitle(title))
            if (a.isEmpty() || a != b) return false
            val y1 = listed.year; return if (y1 != null && year != null) Math.abs(y1 - year) <= 1 else true
        }
    }
}

class TraktClient(private val app: TraktApp, private val web: Web = LiveWeb) {
    private fun headers(token: String? = null) = buildMap {
        put("trakt-api-version", "2"); put("trakt-api-key", app.clientId); put("User-Agent", "StreamSetu")
        if (token != null) put("Authorization", "Bearer $token")
    }
    private fun post(path: String, body: JsonObject, token: String? = null) = WebRequest("POST", "https://api.trakt.tv$path", headers(token), body.toString())
    private suspend fun send(r: WebRequest): WebResponse = try { web.call(r) } catch (e: TraktException) { throw e } catch (e: Exception) { throw TraktException(e.message ?: "No answer from Trakt.") }

    suspend fun startDeviceLogin(): TraktDeviceCode {
        if (!app.isComplete) throw TraktException("Add your Trakt Client ID and Secret first.")
        val res = send(post("/oauth/device/code", buildJsonObject { put("client_id", app.clientId) }))
        val j = parseJson(res.body).obj()
        val dc = j?.get("device_code").str(); val uc = j?.get("user_code").str()
        if (res.status != 200 || dc == null || uc == null) throw TraktException(if (res.status == 401 || res.status == 403) "Trakt did not accept the Client ID." else "Trakt answered ${res.status}.")
        return TraktDeviceCode(dc, uc, j?.get("verification_url").str() ?: "https://trakt.tv/activate", j?.get("expires_in").int() ?: 600, maxOf(1, j?.get("interval").int() ?: 5))
    }

    /** Asks once whether the code has been entered: tokens when it has, null while Trakt is still waiting. */
    suspend fun pollDeviceToken(code: TraktDeviceCode, now: Long = System.currentTimeMillis()): TraktTokens? {
        val res = send(post("/oauth/device/token", buildJsonObject { put("code", code.deviceCode); put("client_id", app.clientId); put("client_secret", app.secret) }))
        return when (res.status) {
            200 -> tokens(res.body, now)
            400, 429 -> null
            404, 409 -> throw TraktException("That code is not valid.")
            410 -> throw TraktException("The code ran out. Start again.", TraktException.Kind.EXPIRED)
            418 -> throw TraktException("Trakt sign-in was refused.", TraktException.Kind.DENIED)
            else -> throw TraktException("Trakt answered ${res.status}.")
        }
    }

    suspend fun refresh(t: TraktTokens, now: Long = System.currentTimeMillis()): TraktTokens {
        val res = send(post("/oauth/token", buildJsonObject {
            put("refresh_token", t.refresh); put("client_id", app.clientId); put("client_secret", app.secret); put("redirect_uri", "urn:ietf:wg:oauth:2.0:oob"); put("grant_type", "refresh_token")
        }))
        if (res.status != 200) throw TraktException("Sign in to Trakt first.", TraktException.Kind.NOT_SIGNED_IN)
        return tokens(res.body, now)
    }

    private fun tokens(body: String, now: Long): TraktTokens {
        val j = parseJson(body).obj()
        val a = j?.get("access_token").str(); val r = j?.get("refresh_token").str()
        if (a == null || r == null) throw TraktException("Trakt sent an unexpected answer.")
        val created = j?.get("created_at").num()?.let { (it * 1000).toLong() } ?: now
        val life = ((j?.get("expires_in").num() ?: 7_776_000.0) * 1000).toLong()
        return TraktTokens(a, r, created + life)
    }

    enum class Scrobble(val path: String) { START("start"), PAUSE("pause"), STOP("stop") }

    /** Tells Trakt what is playing. A stop at 80 or more is counted as watched. */
    suspend fun scrobble(action: Scrobble, item: TraktItem, progress: Double, tokens: TraktTokens) {
        val res = send(post("/scrobble/${action.path}", item.payload(progress), tokens.access))
        when (res.status) {
            200, 201, 409, 404 -> return          // 409: already scrobbled recently; 404: Trakt does not know the title
            401 -> throw TraktException("Sign in to Trakt first.", TraktException.Kind.NOT_SIGNED_IN)
            else -> throw TraktException("Trakt answered ${res.status}.")
        }
    }

    suspend fun watchlist(tokens: TraktTokens): List<TraktListed> {
        val out = ArrayList<TraktListed>()
        for ((kind, isShow) in listOf("movies" to false, "shows" to true)) {
            val res = send(WebRequest("GET", "https://api.trakt.tv/sync/watchlist/$kind", headers(tokens.access)))
            if (res.status == 401) throw TraktException("Sign in to Trakt first.", TraktException.Kind.NOT_SIGNED_IN)
            if (res.status != 200) continue
            parseJson(res.body).arr().orEmpty().forEach { row ->
                val node = row.obj()?.get(if (isShow) "show" else "movie").obj() ?: return@forEach
                val title = node["title"].str() ?: return@forEach
                out += TraktListed(title, node["year"].int(), isShow)
            }
        }
        return out
    }
}

/** The keys and tokens, kept in encrypted storage. */
class TraktStore(private val store: CredentialStore) {
    fun app() = TraktApp(store.load("trakt.id").orEmpty(), store.load("trakt.secret").orEmpty())
    fun saveApp(a: TraktApp) {
        if (a.isComplete) { store.save("trakt.id", a.clientId.trim()); store.save("trakt.secret", a.secret.trim()) } else { store.delete("trakt.id"); store.delete("trakt.secret") }
    }
    fun tokens(): TraktTokens? {
        val j = store.load("trakt.tokens")?.let { parseJson(it).obj() } ?: return null
        val a = j["a"].str() ?: return null; val r = j["r"].str() ?: return null
        return TraktTokens(a, r, j["e"].num()?.toLong() ?: 0)
    }
    fun saveTokens(t: TraktTokens?) {
        if (t == null) store.delete("trakt.tokens") else store.save("trakt.tokens", buildJsonObject { put("a", t.access); put("r", t.refresh); put("e", t.expiresMs) }.toString())
    }
}
