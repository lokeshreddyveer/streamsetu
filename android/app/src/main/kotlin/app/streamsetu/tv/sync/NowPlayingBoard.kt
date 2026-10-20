package app.streamsetu.tv.sync

import app.streamsetu.core.sync.lan.LanRecord
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive

/** What the person's other devices are playing right now, learned over the Wi-Fi sync. Nothing is shown for a device that stopped, went private or has not been heard from lately. */
class NowPlayingBoard {
    data class Entry(val deviceId: String, val deviceName: String, val title: String, val positionSec: Double, val key: List<String>, val atMs: Long)

    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries.asStateFlow()

    /** Records that arrived from a paired device. */
    fun ingest(records: List<LanRecord>) {
        var list = _entries.value
        for (r in records) {
            if (r.kind != "now") continue
            val id = r.key.firstOrNull() ?: continue
            if (list.any { it.deviceId == id && it.atMs >= r.ts }) continue
            list = list.filterNot { it.deviceId == id }
            if (r.deleted) continue
            val v = r.value ?: continue
            fun s(k: String) = v[k]?.jsonPrimitive?.contentOrNull
            val title = s("title") ?: continue; val src = s("src") ?: continue; val kind = s("kind") ?: continue; val prov = s("prov") ?: continue
            list = list + Entry(id, s("dev") ?: "Another device", title, v["pos"]?.jsonPrimitive?.doubleOrNull ?: 0.0, listOf(src, kind, prov), r.ts)
        }
        _entries.value = list
    }

    /** What to show now, newest first. */
    fun current(nowMs: Long = System.currentTimeMillis()): List<Entry> = _entries.value.filter { nowMs - it.atMs < STALE_MS }.sortedByDescending { it.atMs }

    companion object { const val STALE_MS = 4 * 60_000L }
}
