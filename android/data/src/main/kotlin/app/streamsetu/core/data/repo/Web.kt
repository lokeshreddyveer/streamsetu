package app.streamsetu.core.data.repo

import app.streamsetu.core.net.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** One web call, kept simple so the services that use it can be tested with a pretend server. */
class WebRequest(val method: String, val url: String, val headers: Map<String, String> = emptyMap(), val body: String? = null, val contentType: String = "application/json")
class WebResponse(val status: Int, val body: String)

fun interface Web { suspend fun call(r: WebRequest): WebResponse }

/** The real thing: the app's own HTTP client (with its proxy setting, and sign-in headers dropped when a redirect leaves the host). */
object LiveWeb : Web {
    override suspend fun call(r: WebRequest): WebResponse = withContext(Dispatchers.IO) {
        val b = Request.Builder().url(r.url)
        r.headers.forEach { (k, v) -> b.header(k, v) }
        if (r.method == "POST") b.post((r.body ?: "").toRequestBody(r.contentType.toMediaType())) else b.get()
        Http.client.newCall(b.build()).execute().use { WebResponse(it.code, it.body?.string().orEmpty()) }
    }
}

internal fun parseJson(s: String): JsonElement? = runCatching { Json.parseToJsonElement(s) }.getOrNull()
internal fun JsonElement?.obj(): JsonObject? = this as? JsonObject
internal fun JsonElement?.arr(): JsonArray? = this as? JsonArray
internal fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonElement?.num(): Double? = (this as? JsonPrimitive)?.doubleOrNull
internal fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.intOrNull
internal fun formEncode(form: Map<String, String>): String = form.entries.sortedBy { it.key }.joinToString("&") { java.net.URLEncoder.encode(it.key, "UTF-8").replace("%5B", "[").replace("%5D", "]") + "=" + java.net.URLEncoder.encode(it.value, "UTF-8").replace("+", "%20") }
