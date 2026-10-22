package app.streamsetu.core.data.repo

import app.streamsetu.core.security.CredentialStore
import kotlinx.coroutines.delay

/** A debrid service turns a link from a file host (or a magnet link) into a direct address that plays. The person brings their own account: the token is pasted in Settings and kept in encrypted storage. */
enum class DebridService(val title: String, val tokenHelp: String) {
    REAL_DEBRID("Real-Debrid", "real-debrid.com/apitoken"), ALL_DEBRID("AllDebrid", "alldebrid.com/apikeys"), PREMIUMIZE("Premiumize", "premiumize.me/account")
}

sealed interface DebridInput {
    data class Link(val url: String) : DebridInput
    data class Magnet(val magnet: String) : DebridInput
    data object Invalid : DebridInput

    companion object {
        fun parse(raw: String): DebridInput {
            val t = raw.trim(); val l = t.lowercase()
            if (l.startsWith("magnet:?") && (l.contains("xt=urn:btih:") || l.contains("xt=urn:btmh:"))) return Magnet(t)
            val u = runCatching { java.net.URI(t) }.getOrNull()
            if (u != null && (u.scheme?.lowercase() == "http" || u.scheme?.lowercase() == "https") && !u.host.isNullOrEmpty()) return Link(t)
            return Invalid
        }
    }
}

class DebridException(message: String) : Exception(message)
data class DebridResult(val name: String, val url: String)

class DebridClient(
    private val service: DebridService, private val token: String, private val web: Web = LiveWeb,
    private val allowMagnets: Boolean = true, private val magnetWaitMs: Long = 45_000, private val pollEveryMs: Long = 2_000,
) {
    companion object {
        val videoExtensions = setOf("mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg")
        fun isVideo(name: String) = name.substringAfterLast('.', "").lowercase() in videoExtensions
    }

    suspend fun resolve(raw: String): DebridResult {
        if (token.isBlank()) throw DebridException("Add your debrid token in Settings first.")
        return when (val input = DebridInput.parse(raw)) {
            DebridInput.Invalid -> throw DebridException("That is not a link or a magnet link.")
            is DebridInput.Link -> unlock(input.url)
            is DebridInput.Magnet -> {
                if (!allowMagnets) throw DebridException("Magnet links are not supported in this app.")
                when (service) { DebridService.REAL_DEBRID -> realDebridMagnet(input.magnet); DebridService.ALL_DEBRID -> allDebridMagnet(input.magnet); DebridService.PREMIUMIZE -> premiumize(input.magnet) }
            }
        }
    }

    private suspend fun unlock(link: String): DebridResult = when (service) {
        DebridService.REAL_DEBRID -> {
            val j = json(post("https://api.real-debrid.com/rest/1.0/unrestrict/link", mapOf("link" to link)))
            val dl = j.obj()?.get("download").str() ?: throw DebridException(message(j) ?: "Real-Debrid could not unlock that link.")
            DebridResult(j.obj()?.get("filename").str() ?: dl.substringAfterLast('/'), dl)
        }
        DebridService.ALL_DEBRID -> {
            val j = json(get("https://api.alldebrid.com/v4/link/unlock", mapOf("agent" to "StreamSetu", "link" to link)))
            val d = j.obj()?.get("data").obj()
            val dl = d?.get("link").str() ?: throw DebridException(message(j) ?: "AllDebrid could not unlock that link.")
            DebridResult(d?.get("filename").str() ?: dl.substringAfterLast('/'), dl)
        }
        DebridService.PREMIUMIZE -> premiumize(link)
    }

    private suspend fun premiumize(src: String): DebridResult {
        val j = json(post("https://www.premiumize.me/api/transfer/directdl", mapOf("src" to src)))
        if (j.obj()?.get("status").str() != "success") throw DebridException(message(j) ?: "Premiumize could not unlock that.")
        val best = j.obj()?.get("content").arr().orEmpty().mapNotNull { f ->
            val o = f.obj() ?: return@mapNotNull null
            val path = o["path"].str() ?: return@mapNotNull null
            if (!isVideo(path)) return@mapNotNull null
            val url = o["stream_link"].str()?.takeIf { it.isNotEmpty() } ?: o["link"].str() ?: return@mapNotNull null
            Triple(path.substringAfterLast('/'), url, o["size"].num() ?: 0.0)
        }.maxByOrNull { it.third } ?: throw DebridException("No video was found in it.")
        return DebridResult(best.first, best.second)
    }

    private suspend fun realDebridMagnet(magnet: String): DebridResult {
        val added = json(post("https://api.real-debrid.com/rest/1.0/torrents/addMagnet", mapOf("magnet" to magnet)))
        val id = added.obj()?.get("id").str() ?: throw DebridException(message(added) ?: "Real-Debrid did not accept that magnet link.")
        val end = System.currentTimeMillis() + magnetWaitMs
        var selected = false
        while (true) {
            val info = json(get("https://api.real-debrid.com/rest/1.0/torrents/info/$id")).obj()
            val status = info?.get("status").str().orEmpty()
            if (status == "waiting_files_selection" && !selected) {
                val best = info?.get("files").arr().orEmpty().mapNotNull { it.obj() }.filter { isVideo(it["path"].str().orEmpty()) }.maxByOrNull { it["bytes"].num() ?: 0.0 }
                val fid = best?.get("id")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } ?: throw DebridException("No video was found in it.")
                send(post("https://api.real-debrid.com/rest/1.0/torrents/selectFiles/$id", mapOf("files" to fid)))
                selected = true
            } else if (status == "downloaded") {
                val first = info?.get("links").arr()?.firstOrNull().str()
                if (first != null) return unlock(first)
            } else if (status in setOf("magnet_error", "error", "virus", "dead")) throw DebridException("Real-Debrid could not fetch that torrent ($status).")
            if (System.currentTimeMillis() >= end) throw DebridException("Real-Debrid is still fetching it (${status.ifEmpty { "queued" }}). Try again in a little while: it keeps going in your account.")
            delay(pollEveryMs)
        }
    }

    private suspend fun allDebridMagnet(magnet: String): DebridResult {
        val up = json(post("https://api.alldebrid.com/v4/magnet/upload", mapOf("agent" to "StreamSetu", "magnets[]" to magnet)))
        val id = up.obj()?.get("data").obj()?.get("magnets").arr()?.firstOrNull().obj()?.get("id")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
            ?: throw DebridException(message(up) ?: "AllDebrid did not accept that magnet link.")
        val end = System.currentTimeMillis() + magnetWaitMs
        while (true) {
            val m = json(get("https://api.alldebrid.com/v4/magnet/status", mapOf("agent" to "StreamSetu", "id" to id))).obj()?.get("data").obj()?.get("magnets").obj()
            val code = m?.get("statusCode").int() ?: -1
            if (code == 4) {
                val best = m?.get("links").arr().orEmpty().mapNotNull { it.obj() }.filter { isVideo(it["filename"].str().orEmpty()) }.maxByOrNull { it["size"].num() ?: 0.0 }
                return unlock(best?.get("link").str() ?: throw DebridException("No video was found in it."))
            }
            if (code >= 5) throw DebridException("AllDebrid could not fetch that torrent.")
            if (System.currentTimeMillis() >= end) throw DebridException("AllDebrid is still fetching it. Try again in a little while: it keeps going in your account.")
            delay(pollEveryMs)
        }
    }

    // ---- plumbing
    private fun auth() = mapOf("Authorization" to "Bearer $token", "User-Agent" to "StreamSetu")
    private fun get(base: String, query: Map<String, String> = emptyMap()) =
        WebRequest("GET", if (query.isEmpty()) base else base + "?" + formEncode(query), auth())
    private fun post(url: String, form: Map<String, String>) = WebRequest("POST", url, auth(), formEncode(form), "application/x-www-form-urlencoded")

    private suspend fun send(r: WebRequest): WebResponse = try { web.call(r) } catch (e: DebridException) { throw e } catch (e: Exception) { throw DebridException(e.message ?: "No answer from ${service.title}.") }

    private suspend fun json(r: WebRequest): kotlinx.serialization.json.JsonElement? {
        val res = send(r)
        val j = parseJson(res.body)
        when {
            res.status == 401 || res.status == 403 -> throw DebridException("${service.title} did not accept the token.")
            res.status == 429 -> throw DebridException("${service.title} says too many requests. Wait a minute.")
            res.status >= 500 -> throw DebridException("${service.title} is not answering (${res.status}).")
            res.status >= 400 -> throw DebridException(message(j) ?: "${service.title} answered ${res.status}.")
        }
        return j
    }

    private fun message(j: kotlinx.serialization.json.JsonElement?): String? = when (service) {
        DebridService.REAL_DEBRID -> j.obj()?.get("error").str()?.replace('_', ' ')
        DebridService.ALL_DEBRID -> j.obj()?.get("error").obj()?.get("message").str()
        DebridService.PREMIUMIZE -> j.obj()?.get("message").str()
    }
}

data class DebridAccount(val service: DebridService = DebridService.REAL_DEBRID, val token: String = "") { val isComplete get() = token.isNotBlank() }

class DebridStore(private val store: CredentialStore) {
    fun load(): DebridAccount = DebridAccount(store.load("debrid.service")?.let { runCatching { DebridService.valueOf(it) }.getOrNull() } ?: DebridService.REAL_DEBRID, store.load("debrid.token").orEmpty())
    fun save(a: DebridAccount) {
        if (!a.isComplete) { store.delete("debrid.token"); store.delete("debrid.service"); return }
        store.save("debrid.service", a.service.name); store.save("debrid.token", a.token.trim())
    }
}

/** Direct addresses the player is told about by id: a debrid result plays like a movie that belongs to no playlist. */
object DirectLinks {
    private val map = java.util.concurrent.ConcurrentHashMap<String, String>()
    private const val PREFIX = "direct:"
    fun register(url: String): String = (PREFIX + Integer.toHexString(url.hashCode())).also { map[it] = url }
    fun urlOf(id: String): String? = if (id.startsWith(PREFIX)) map[id] else null
}
