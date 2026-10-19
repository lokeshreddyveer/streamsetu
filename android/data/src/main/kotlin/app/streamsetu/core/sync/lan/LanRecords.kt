package app.streamsetu.core.sync.lan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * One thing that is kept in step between devices (see docs/WIFI-SYNC.md): [kind] is `fav`, `prog`, `col` or `colitem`, [key] says which one, [ts] is when it last changed (milliseconds),
 * and [deleted] says it was removed. [value] carries the rest, and is absent for a removal.
 */
data class LanRecord(val kind: String, val key: List<String>, val ts: Long, val deleted: Boolean = false, val value: JsonObject? = null) {
    val identity: String get() = kind + "\u0001" + key.joinToString("\u0001")

    fun toJson(): JsonObject = buildJsonObject {
        put("k", kind)
        put("key", JsonArray(key.map { JsonPrimitive(it) }))
        put("ts", ts)
        if (deleted) put("del", true)
        value?.let { put("v", it) }
    }

    companion object {
        fun fromJson(o: JsonObject): LanRecord? {
            val kind = o["k"]?.jsonPrimitive?.contentOrNull ?: return null
            val key = (o["key"] as? JsonArray)?.map { it.jsonPrimitive.contentOrNull ?: return null } ?: return null
            val ts = o["ts"]?.jsonPrimitive?.longOrNull ?: return null
            return LanRecord(kind, key, ts, o["del"]?.jsonPrimitive?.booleanOrNull == true, o["v"] as? JsonObject)
        }
    }
}

/** Whether a change that arrived should replace what is here: only a strictly newer change does, so the same state sent back and forth settles. */
fun shouldApply(localTs: Long?, remoteTs: Long): Boolean = localTs == null || remoteTs > localTs

/** The key that stands for a playlist on every device: the first 16 hex characters of SHA-256 of its address, lower-cased, without http(s):// and without trailing slashes. */
object SourceKey {
    fun of(address: String): String {
        var a = address.trim().lowercase()
        a = a.removePrefix("https://").removePrefix("http://").trimEnd('/')
        return LanCrypto.sha256(a.toByteArray()).take(8).joinToString("") { "%02x".format(it) }
    }
}

object LanJson {
    val json = Json { ignoreUnknownKeys = true }

    fun parse(bytes: ByteArray): JsonObject = json.parseToJsonElement(bytes.decodeToString()).jsonObject
    fun bytes(o: JsonObject): ByteArray = o.toString().toByteArray()

    fun message(type: String, build: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {}): JsonObject = buildJsonObject { put("t", type); build() }
    fun recordsOf(o: JsonObject): List<LanRecord> = (o["records"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let(LanRecord::fromJson) }
    fun withRecords(type: String, records: List<LanRecord>, more: Boolean): JsonObject = message(type) {
        put("records", buildJsonArray { records.forEach { add(it.toJson()) } })
        put("more", more)
    }
    fun type(o: JsonObject): String = o["t"]?.jsonPrimitive?.contentOrNull.orEmpty()
}
