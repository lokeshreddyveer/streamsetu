package app.streamsetu.core.data.repo

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * What Search remembers: recent searches and the words last typed. Everything is kept under who is searching (the active profile and library), so another profile, a kids profile or another
 * library never sees words typed by someone else. [contextOf] gives that "who" as one word, "profileId|libraryId"; [contextChanged] says it moved.
 */
class SearchHistory(private val prefs: SharedPreferences) {
    @Volatile var contextOf: () -> String = { "" }
    private fun ctx() = contextOf().ifEmpty { "-" }.replace('\n', ' ')
    private val _recent = MutableStateFlow(loadRecent())
    val recent: StateFlow<List<String>> = _recent
    private fun loadRecent() = prefs.getString("recent#" + ctx(), "").orEmpty().split('\n').filter { it.isNotBlank() }

    /** The profile or the library changed: what is shown as recent follows, and what was typed under the old one is forgotten. */
    fun contextChanged() { synchronized(lastTyped) { lastTyped.clear() }; _recent.value = loadRecent() }

    fun remember(query: String) {
        val q = query.trim(); if (q.length < 2) return
        val list = (listOf(q) + _recent.value.filter { !it.equals(q, true) }).take(10)
        prefs.edit().putString("recent#" + ctx(), list.joinToString("\n")).apply(); _recent.value = list
    }

    /** Recent searches kept apart for each screen they were made on and for each profile and library, newest first. */
    fun recentIn(scope: String): List<String> = prefs.getString("recent.${ctx()}#$scope", "").orEmpty().split('\n').filter { it.isNotBlank() }
    fun rememberIn(scope: String, query: String) {
        val q = query.trim(); if (q.length < 2) return
        val list = (listOf(q) + recentIn(scope).filter { !it.equals(q, true) }).take(8)
        prefs.edit().putString("recent.${ctx()}#$scope", list.joinToString("\n")).apply()
    }

    /** The text last typed on a screen's search, kept while the app runs so Back from a title returns to the same results. */
    private val lastTyped = HashMap<String, String>()
    fun lastIn(scope: String): String = synchronized(lastTyped) { lastTyped[ctx() + "#" + scope].orEmpty() }
    fun setLastIn(scope: String, query: String) { synchronized(lastTyped) { if (query.isEmpty()) lastTyped.remove(ctx() + "#" + scope) else lastTyped[ctx() + "#" + scope] = query } }
    fun clearIn(scope: String) { prefs.edit().remove("recent.${ctx()}#$scope").apply() }
    fun clearHistory() { prefs.edit().remove("recent#" + ctx()).apply(); _recent.value = emptyList() }

    /** A profile was removed: every search it made goes with it (its words under every library and screen). */
    fun forgetProfile(profileId: String) {
        val e = prefs.edit()
        for (k in prefs.all.keys) if (k.startsWith("recent#$profileId|") || k.startsWith("recent.$profileId|")) e.remove(k)
        e.apply(); synchronized(lastTyped) { lastTyped.keys.removeAll { it.startsWith("$profileId|") } }
    }
}
