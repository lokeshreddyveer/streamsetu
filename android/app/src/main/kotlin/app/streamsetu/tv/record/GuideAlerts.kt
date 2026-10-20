package app.streamsetu.tv.record

import android.content.Context
import app.streamsetu.core.data.repo.KeywordAlerts
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.Reminders
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Words to watch for in the guide. A few times an hour the guide is searched for programmes with those words that have not started yet; each one found gets a reminder like
 * any other (a notification a minute before it starts), once. The words are kept on this device.
 */
class GuideAlerts(private val context: Context) {
    private val prefs = context.getSharedPreferences("guide-alerts", Context.MODE_PRIVATE)
    private val _words = MutableStateFlow(prefs.getString("words", "").orEmpty().split('\n').filter { it.isNotBlank() })
    private val _found = MutableStateFlow<List<String>>(emptyList())
    val words: StateFlow<List<String>> = _words.asStateFlow()
    val lastFound: StateFlow<List<String>> = _found.asStateFlow()

    private fun save(list: List<String>) { _words.value = list; prefs.edit().putString("words", list.joinToString("\n")).apply() }

    fun add(word: String): Boolean { val next = KeywordAlerts.add(_words.value, word); return (next != _words.value).also { if (it) save(next) } }
    fun remove(word: String) = save(_words.value - word)

    /** Looks for new matches now and sets a reminder for each. Returns how many were set. */
    suspend fun scan(c: AppContainer, now: Long = System.currentTimeMillis()): Int {
        if (_words.value.isEmpty()) return 0
        val done = prefs.getStringSet("done", emptySet()).orEmpty().toMutableSet()
        var set = 0
        val found = mutableListOf<String>()
        for (word in _words.value) {
            val hits = runCatching { c.db.epg().matching(word, now + KeywordAlerts.MIN_LEAD_MS, now + KeywordAlerts.HORIZON_MS) }.getOrDefault(emptyList())
            for (h in hits) {
                if (!KeywordAlerts.inWindow(h.startMs, now)) continue
                val key = KeywordAlerts.key("${h.channelEpgId}@${h.startMs}", word)
                if (key in done) continue
                val channel = c.db.catalog().channelForGuideId(h.channelEpgId)?.let { c.catalog.channel(it.id) } ?: continue
                if (Reminders.schedule(c, context, channel, EpgProgram(h.channelEpgId, h.startMs, h.endMs, h.title, h.description))) {
                    done += key; set++
                    found += "${h.title} · ${channel.name} · " + java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(h.startMs))
                }
            }
        }
        prefs.edit().putStringSet("done", if (done.size > 400) done.toList().takeLast(300).toSet() else done).apply()
        if (found.isNotEmpty()) _found.value = found
        return set
    }
}
