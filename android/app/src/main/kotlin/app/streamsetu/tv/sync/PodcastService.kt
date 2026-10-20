package app.streamsetu.tv.sync

import android.content.Context
import app.streamsetu.core.net.Http
import app.streamsetu.core.podcast.PodcastFeed
import app.streamsetu.core.podcast.PodcastParser
import app.streamsetu.core.podcast.PodcastSearch
import app.streamsetu.core.podcast.PodcastSub
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/** The podcasts the person follows (kept on this device), and the ways of finding and reading them. */
class PodcastService(context: Context) {
    private val prefs = context.getSharedPreferences("podcasts", Context.MODE_PRIVATE)
    private val _subs = MutableStateFlow(load())
    val subscriptions: StateFlow<List<PodcastSub>> = _subs.asStateFlow()

    private fun load(): List<PodcastSub> = runCatching {
        val a = JSONArray(prefs.getString("subs", "[]"))
        (0 until a.length()).map { a.getJSONObject(it).let { o -> PodcastSub(o.getString("feed"), o.getString("title"), o.optString("author"), o.optString("art").takeIf { s -> s.isNotEmpty() }) } }
    }.getOrDefault(emptyList())

    private fun save(list: List<PodcastSub>) {
        _subs.value = list
        val a = JSONArray(); list.forEach { a.put(JSONObject().put("feed", it.feedUrl).put("title", it.title).put("author", it.author).put("art", it.artwork ?: "")) }
        prefs.edit().putString("subs", a.toString()).apply()
    }

    fun isFollowing(feedUrl: String) = _subs.value.any { it.feedUrl == feedUrl }

    private suspend fun get(url: String): ByteArray = withContext(Dispatchers.IO) {
        Http.client.newCall(Request.Builder().url(url).header("User-Agent", "StreamSetu").build()).execute().use { r ->
            if (!r.isSuccessful) error("The address answered ${r.code}.")
            r.body?.bytes() ?: error("Nothing was received.")
        }
    }

    suspend fun load(feedUrl: String): PodcastFeed = PodcastParser.parse(get(feedUrl)) ?: error("That address is not a podcast feed.")

    suspend fun follow(feedUrl: String): PodcastSub {
        val feed = load(feedUrl)
        val sub = PodcastSub(feedUrl, feed.title, feed.author, feed.artwork)
        save(_subs.value.filterNot { it.feedUrl == feedUrl } + sub)
        return sub
    }

    fun unfollow(feedUrl: String) = save(_subs.value.filterNot { it.feedUrl == feedUrl })

    /** Shows matching the words, from Apple's public podcast directory. */
    suspend fun search(term: String): List<PodcastSub> =
        PodcastSearch.parse(String(get("https://itunes.apple.com/search?media=podcast&limit=25&term=" + java.net.URLEncoder.encode(term, "UTF-8"))))
}
