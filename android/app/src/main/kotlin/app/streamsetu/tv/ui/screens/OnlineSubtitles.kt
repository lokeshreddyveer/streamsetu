package app.streamsetu.tv.ui.screens

import android.content.Context
import app.streamsetu.core.net.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import app.streamsetu.core.subtitles.*
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

    private val base = "https://api.opensubtitles.com/api/v1"
    private val json = "application/json".toMediaType()
    private val metadata = SubtitleMetadataCache(File(context.applicationContext.cacheDir, "subtitle-meta"))
    private fun builder(path: String) = Request.Builder().url(base + path).header("Api-Key", apiKey).header("User-Agent", "StreamSetu v1").header("Accept", "application/json")

    /**
     * Subtitles for what is playing, ranked by how likely each is to belong to it (see SubtitleRanking), each with the reason it is shown. What the provider said is kept for six hours, so
     * opening the panel again, or asking for another preference, does not ask the provider again; the ranking is done every time, on this device.
     */
    suspend fun search(want: SubtitleWanted): List<RankedSubtitle> = withContext(Dispatchers.IO) {
        val found = metadata.get(want) ?: fetch(want).also { metadata.put(want, it) }
        SubtitleRanking.rank(found, want).take(15)
    }

    /** What is already known without any network: the last answer for this question, ranked, or null. The panel shows it at once and refreshes after. */
    fun cached(want: SubtitleWanted): List<RankedSubtitle>? = metadata.get(want)?.let { SubtitleRanking.rank(it, want).take(15) }

    private fun fetch(want: SubtitleWanted): List<SubtitleCandidate> {
        val q = java.net.URLEncoder.encode(want.title.replace(Regex("""\(.*?\)|\[.*?]"""), " ").replace(Regex("\\s+"), " ").trim(), "UTF-8")
        val url = "/subtitles?query=$q&languages=${want.language.ifBlank { "en" }}" + (want.year?.let { "&year=$it" } ?: "") +
            (if (want.season != null && want.episode != null) "&type=episode&season_number=${want.season}&episode_number=${want.episode}" else "&type=movie")
        Http.client.newCall(builder(url).build()).execute().use { r ->
            if (!r.isSuccessful) error(if (r.code == 401 || r.code == 403) "The API key was not accepted." else "OpenSubtitles answered ${r.code}.")
            val data = JSONObject(r.body?.string().orEmpty()).optJSONArray("data") ?: return emptyList()
            return (0 until data.length()).mapNotNull { i ->
                val a = data.getJSONObject(i).optJSONObject("attributes") ?: return@mapNotNull null
                val file = a.optJSONArray("files")?.optJSONObject(0) ?: return@mapNotNull null
                val fd = a.optJSONObject("feature_details")
                val episode = fd?.optString("parent_title").orEmpty().isNotBlank() || (fd?.has("season_number") == true && fd.optInt("season_number") > 0)
                SubtitleCandidate(
                    fileId = file.optLong("file_id"), fileName = file.optString("file_name"), release = a.optString("release"), language = a.optString("language"),
                    downloads = a.optInt("download_count"), rating = a.optDouble("ratings", 0.0), hearingImpaired = a.optBoolean("hearing_impaired"), hashMatch = a.optBoolean("moviehash_match"),
                    trusted = a.optBoolean("from_trusted"), aiTranslated = a.optBoolean("ai_translated"), machineTranslated = a.optBoolean("machine_translated"),
                    title = (if (episode) fd?.optString("parent_title") else listOfNotNull(fd?.optString("title"), fd?.optString("movie_name")).firstOrNull { it.isNotBlank() })?.takeIf { it.isNotBlank() },
                    year = fd?.optInt("year")?.takeIf { it > 0 }, season = fd?.optInt("season_number")?.takeIf { it > 0 }, episode = fd?.optInt("episode_number")?.takeIf { it > 0 },
                )
            }.filter { it.fileId > 0 }
        }
    }

    /** Downloads one subtitle and returns the local file's address, or throws a sentence saying what went wrong. */
    suspend fun download(pick: RankedSubtitle): String = withContext(Dispatchers.IO) {
        val login = Http.client.newCall(builder("/login").post(JSONObject().put("username", user).put("password", password).toString().toRequestBody(json)).build()).execute().use { r ->
            if (!r.isSuccessful) error("OpenSubtitles did not accept the account name and password.")
            JSONObject(r.body?.string().orEmpty()).optString("token")
        }
        val link = Http.client.newCall(builder("/download").header("Authorization", "Bearer $login").post(JSONObject().put("file_id", pick.candidate.fileId).toString().toRequestBody(json)).build()).execute().use { r ->
            if (!r.isSuccessful) error(if (r.code == 406) "The daily download limit of the free account is used up." else "OpenSubtitles answered ${r.code}.")
            JSONObject(r.body?.string().orEmpty()).optString("link").ifBlank { error("OpenSubtitles sent no file.") }
        }
        if (!link.startsWith("https://")) error("OpenSubtitles sent an address that is not secure.")
        val bytes = Http.client.newCall(Request.Builder().url(link).build()).execute().use { r ->
            if (!r.isSuccessful) error("The subtitle could not be downloaded (${r.code}).")
            SubtitleFiles.readLimited(r.body?.contentLength() ?: -1, r.body?.byteStream() ?: error("The subtitle file was empty."))
        }
        val checked = try { SubtitleFiles.check(bytes) } catch (e: SubtitleFiles.Rejected) { error(e.message ?: "That subtitle file cannot be used.") }
        val file = File(cache, SubtitleFiles.fileNameFor(checked))          // named by its content: the same file downloaded twice is one file, and a provider cannot choose the path
        if (!file.exists()) file.writeText(checked.text, Charsets.UTF_8) else file.setLastModified(System.currentTimeMillis())          // used again: it is the newest, so pruning cannot take it
        prune(keep = file)
        file.toURI().toString()
    }

    /** Keeps the folder of downloaded subtitles small: the newest 80 files. */
    private fun prune(keep: File) { cache.listFiles()?.filter { it != keep }?.sortedByDescending { it.lastModified() }?.drop(79)?.forEach { it.delete() } }
}
