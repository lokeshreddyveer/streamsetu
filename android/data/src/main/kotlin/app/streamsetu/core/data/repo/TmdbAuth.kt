package app.streamsetu.core.data.repo

import app.streamsetu.core.net.Http
import app.streamsetu.core.net.HttpStatusException
import java.io.File
import java.io.IOException
import java.net.URLEncoder

/** One TMDB request: the address and, for a token, the Authorization header value. */
typealias TmdbCall = (url: String, bearer: String?) -> String

/** The ordinary way to ask TMDB: a bearer token travels in the Authorization header, never in the address. */
val tmdbHttp: TmdbCall = { url, bearer -> Http.text(url, headers = if (bearer != null) mapOf("Authorization" to "Bearer $bearer") else emptyMap()) }

/**
 * Which TMDB credential a request uses, in this order: the person's own key (a 32 character v3 key goes in the api_key parameter, a pasted v4 token that starts with "eyJ" goes in the
 * Authorization header), else the app's built-in read token (header), else nothing. A built-in token that TMDB refuses (401/403) is set aside: it is not used again for [PAUSE_DAYS]
 * days (and never for the rest of the session), so a revoked token is not hammered. The token itself is never logged, saved here or put in an address.
 */
class TmdbAuth(private val userKey: () -> String?, private val builtIn: () -> String? = { null }, private val dir: File? = null, private val now: () -> Long = System::currentTimeMillis) {
    enum class Source { OWN_KEY, OWN_TOKEN, BUILT_IN }
    class Credential internal constructor(val source: Source, private val value: String) {
        val bearer: String? get() = if (source == Source.OWN_KEY) null else value
        val apiKey: String? get() = if (source == Source.OWN_KEY) value else null
        override fun toString() = "TmdbCredential($source)"
    }

    companion object {
        const val BASE = "https://api.themoviedb.org/3"
        const val PAUSE_DAYS = 7
        /** The file that remembers a refused built-in token (kept when saved TMDB data is cleared). */
        const val OFF_FILE = "builtin-off"
        /** A v4 read token is a JWT: three dot-separated parts, starting "eyJ". */
        fun isToken(s: String) = s.startsWith("eyJ") && s.count { it == '.' } == 2 && s.none { it.isWhitespace() }
    }

    @Volatile private var sessionOff = false

    val builtInRefused: Boolean get() {
        if (sessionOff) return true
        val f = dir?.let { File(it, OFF_FILE) }?.takeIf { it.isFile } ?: return false
        val at = runCatching { f.readText().trim().toLong() }.getOrNull() ?: return false
        return if (now() - at < PAUSE_DAYS * TmdbFiles.DAY_MS) { sessionOff = true; true } else { f.delete(); false }
    }

    /** What a request would use right now, or null when there is no credential at all. */
    fun current(): Credential? {
        userKey()?.trim()?.takeIf { it.isNotEmpty() }?.let { return Credential(if (isToken(it)) Source.OWN_TOKEN else Source.OWN_KEY, it) }
        if (builtInRefused) return null
        return builtIn()?.takeIf { it.isNotEmpty() }?.let { Credential(Source.BUILT_IN, it) }
    }
    val source: Source? get() = current()?.source
    val available: Boolean get() = current() != null

    /** Runs one request with the credential in use. A refused built-in token is set aside; the error is passed on either way. */
    fun call(path: String, query: String = "", http: TmdbCall): String {
        val c = current() ?: throw IOException("TMDB is not available.")
        val parts = listOfNotNull(query.takeIf { it.isNotEmpty() }, c.apiKey?.let { "api_key=" + enc(it) }).joinToString("&")
        val url = "$BASE/$path" + (if (parts.isNotEmpty()) "?$parts" else "")
        return try { http(url, c.bearer) } catch (e: HttpStatusException) {
            if (c.source == Source.BUILT_IN && (e.code == 401 || e.code == 403)) refuseBuiltIn()
            throw e
        }
    }

    fun refuseBuiltIn() { sessionOff = true; runCatching { dir?.let { it.mkdirs(); File(it, OFF_FILE).writeText(now().toString()) } } }
}

internal fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
