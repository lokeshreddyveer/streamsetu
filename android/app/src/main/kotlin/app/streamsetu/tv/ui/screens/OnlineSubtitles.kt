package app.streamsetu.tv.ui.screens

import android.content.Context
import app.streamsetu.core.net.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File

/**
 * Subtitles from OpenSubtitles. It needs the person's own free API key (and, to download, their free account name and password), kept on this device and sent only to
 * opensubtitles.com. Nothing is sent until the person asks for subtitles.
 */
class OnlineSubtitles(context: Context, private val store: app.streamsetu.core.security.CredentialStore) {
    private val cache = File(context.applicationContext.cacheDir, "subtitles").apply { mkdirs() }

    val apiKey: String get() = store.load("os.key").orEmpty()
    val user: String get() = store.load("os.user").orEmpty()
    val password: String get() = store.load("os.pass").orEmpty()
    val configured get() = apiKey.isNotBlank() && user.isNotBlank() && password.isNotBlank()

    data class Hit(val fileId: Long, val label: String)

    private val base = "https://api.opensubtitles.com/api/v1"
    private val json = "application/json".toMediaType()
    private fun builder(path: String) = Request.Builder().url(base + path).header("Api-Key", apiKey).header("User-Agent", "StreamSetu v1").header("Accept", "application/json")

    /** Subtitles for a title in a language ("en", "hi", "te"…), best matches first. */
    suspend fun search(title: String, year: Int?, language: String): List<Hit> = withContext(Dispatchers.IO) {
        val q = java.net.URLEncoder.encode(title.replace(Regex("""\(.*?\)|\[.*?]"""), " ").replace(Regex("\\s+"), " ").trim(), "UTF-8")
        val url = "/subtitles?query=$q&languages=${language.ifBlank { "en" }}" + (year?.let { "&year=$it" } ?: "") + "&order_by=download_count"
        Http.client.newCall(builder(url).build()).execute().use { r ->
            if (!r.isSuccessful) error(if (r.code == 401 || r.code == 403) "The API key was not accepted." else "OpenSubtitles answered ${r.code}.")
            val data = JSONObject(r.body?.string().orEmpty()).optJSONArray("data") ?: return@use emptyList()
            (0 until data.length()).mapNotNull { i ->
                val a = data.getJSONObject(i).optJSONObject("attributes") ?: return@mapNotNull null
                val file = a.optJSONArray("files")?.optJSONObject(0) ?: return@mapNotNull null
                Hit(file.optLong("file_id"), listOfNotNull(a.optString("release").takeIf { it.isNotBlank() } ?: file.optString("file_name"), a.optInt("download_count").takeIf { it > 0 }?.let { "$it downloads" }).joinToString("  ·  "))
            }.take(15)
        }
    }

    /** Downloads one subtitle and returns the local file's address, or throws a sentence saying what went wrong. */
    suspend fun download(hit: Hit): String = withContext(Dispatchers.IO) {
        val login = Http.client.newCall(builder("/login").post(JSONObject().put("username", user).put("password", password).toString().toRequestBody(json)).build()).execute().use { r ->
            if (!r.isSuccessful) error("OpenSubtitles did not accept the account name and password.")
            JSONObject(r.body?.string().orEmpty()).optString("token")
        }
        val link = Http.client.newCall(builder("/download").header("Authorization", "Bearer $login").post(JSONObject().put("file_id", hit.fileId).toString().toRequestBody(json)).build()).execute().use { r ->
            if (!r.isSuccessful) error(if (r.code == 406) "The daily download limit of the free account is used up." else "OpenSubtitles answered ${r.code}.")
            JSONObject(r.body?.string().orEmpty()).optString("link").ifBlank { error("OpenSubtitles sent no file.") }
        }
        val file = File(cache, "${hit.fileId}.srt")
        Http.client.newCall(Request.Builder().url(link).build()).execute().use { r -> file.writeBytes(r.body?.bytes() ?: error("The subtitle file was empty.")) }
        file.toURI().toString()
    }
}
