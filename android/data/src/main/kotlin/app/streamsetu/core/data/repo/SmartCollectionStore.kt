package app.streamsetu.core.data.repo

import android.content.Context
import app.streamsetu.core.model.CollectionRule
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.SmartCollection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * The person's smart collections. They are kept on this device as small JSON (a rule is a description, never code), read once and then held in memory: adding, renaming or deleting one
 * changes the list at once and writes it in one step. At most [MAX] are kept, so a damaged or hostile file can never grow without limit.
 */
class SmartCollectionStore(context: Context, private val file: String = "smartcollections") {
    private val prefs = context.applicationContext.getSharedPreferences(file, Context.MODE_PRIVATE)
    private val _all = MutableStateFlow(read())
    val all: StateFlow<List<SmartCollection>> = _all

    fun of(kind: ContentKind) = _all.value.filter { it.scope == kind }
    fun get(id: String) = _all.value.firstOrNull { it.id == id }

    /** Saves a new collection. Returns its id, or the reasons the rule or name cannot be saved. */
    fun add(name: String, scope: ContentKind, rule: CollectionRule): Result<String> {
        val why = checks(name, scope, rule); if (why.isNotEmpty()) return Result.failure(IllegalArgumentException(why.first()))
        if (_all.value.size >= MAX) return Result.failure(IllegalStateException("You have $MAX smart collections already. Delete one first."))
        val c = SmartCollection(UUID.randomUUID().toString(), name.trim(), scope, rule); write(_all.value + c); return Result.success(c.id)
    }

    fun update(id: String, name: String, rule: CollectionRule): Result<Unit> {
        val old = get(id) ?: return Result.failure(IllegalArgumentException("That collection no longer exists."))
        val why = checks(name, old.scope, rule); if (why.isNotEmpty()) return Result.failure(IllegalArgumentException(why.first()))
        write(_all.value.map { if (it.id == id) it.copy(name = name.trim(), rule = rule) else it }); return Result.success(Unit)
    }

    fun rename(id: String, name: String) = get(id)?.let { update(id, name, it.rule) } ?: Result.failure(IllegalArgumentException("That collection no longer exists."))
    fun delete(id: String) { write(_all.value.filter { it.id != id }) }

    private fun checks(name: String, scope: ContentKind, rule: CollectionRule): List<String> = buildList {
        if (name.isBlank()) add("Give the collection a name."); if (name.trim().length > 60) add("The name is too long.")
        if (scope == ContentKind.CHANNEL || scope == ContentKind.EPISODE) add("A smart collection holds movies or series.")
        addAll(rule.problems())
    }

    private fun write(list: List<SmartCollection>) { prefs.edit().putString("list", encode(list)).apply(); _all.value = list }
    private fun read(): List<SmartCollection> = decode(prefs.getString("list", null))

    companion object {
        const val MAX = 40
        /** The most saved text that is read at all: 40 collections of ordinary size are a few kilobytes, so anything beyond this is not a collection file and is ignored unread. */
        const val MAX_SAVED_CHARS = 128 * 1024

        fun encode(list: List<SmartCollection>): String = JSONArray().also { a -> list.forEach { c ->
            a.put(JSONObject().put("id", c.id).put("name", c.name).put("scope", c.scope.name).put("rule", JSONObject().apply {
                val r = c.rule
                r.sourceId?.let { put("sourceId", it) }; r.yearFrom?.let { put("yearFrom", it) }; r.yearTo?.let { put("yearTo", it) }; r.minRating?.let { put("minRating", it) }
                r.language?.let { put("language", it) }; if (r.unwatched) put("unwatched", true); if (r.favoritesOnly) put("favoritesOnly", true)
                r.addedWithinDays?.let { put("addedWithinDays", it) }; r.titleContains?.let { put("titleContains", it) }; r.folderContains?.let { put("folderContains", it) }
            }))
        } }.toString()

        /** Reads what was saved. Anything that is not a valid collection is skipped, never trusted: a rule that fails its own checks, an unknown kind, a duplicate id or more than [MAX]. */
        fun decode(text: String?): List<SmartCollection> {
            if (text.isNullOrBlank() || text.length > MAX_SAVED_CHARS) return emptyList()
            val a = runCatching { JSONArray(text) }.getOrNull() ?: return emptyList()
            val seen = HashSet<String>(); val out = ArrayList<SmartCollection>()
            for (i in 0 until minOf(a.length(), MAX)) {
                val o = a.optJSONObject(i) ?: continue
                val id = o.optString("id").takeIf { it.isNotBlank() && it.length <= 80 && seen.add(it) } ?: continue
                val scope = runCatching { ContentKind.valueOf(o.optString("scope")) }.getOrNull()?.takeIf { it == ContentKind.MOVIE || it == ContentKind.SERIES } ?: continue
                val name = o.optString("name").trim().takeIf { it.isNotBlank() && it.length <= 60 } ?: continue
                val r = o.optJSONObject("rule") ?: continue
                if (r.length() > 12) continue          // a rule has at most ten fields
                fun int(k: String) = if (r.has(k)) r.optInt(k) else null
                val rule = CollectionRule(
                    sourceId = r.optString("sourceId").takeIf { r.has("sourceId") && it.isNotBlank() }, yearFrom = int("yearFrom"), yearTo = int("yearTo"),
                    minRating = if (r.has("minRating")) r.optDouble("minRating") else null, language = r.optString("language").takeIf { r.has("language") && it.isNotBlank() },
                    unwatched = r.optBoolean("unwatched"), favoritesOnly = r.optBoolean("favoritesOnly"), addedWithinDays = int("addedWithinDays"),
                    titleContains = r.optString("titleContains").takeIf { r.has("titleContains") }, folderContains = r.optString("folderContains").takeIf { r.has("folderContains") },
                )
                if (rule.problems().isEmpty()) out += SmartCollection(id, name, scope, rule)
            }
            return out
        }
    }
}
