package app.streamsetu.core.data.repo

import android.content.Context
import android.os.Build
import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** What a restore did, in plain numbers. */
data class RestoreResult(val favourites: Int, val folders: Int, val progress: Int, val history: Int, val skipped: Int)

/**
 * Housekeeping: storage numbers, cache clearing, search index rebuild, backups and restores, diagnostics, and the reset buttons.
 * Safe actions (clearing artwork, rebuilding the index) never touch favourites, connections or progress. Backups never contain logins, stream addresses or playlist links.
 */
class MaintenanceService(private val context: Context, private val db: AppDatabase, private val sources: SourceRepository, private val library: LibraryRepository, private val clearMemoryImages: () -> Unit = {}) {
    private val prefFiles = listOf("settings", "ui", "sort", "search")

    // ---- Storage ----
    private fun size(f: File): Long = if (f.isFile) f.length() else f.listFiles()?.sumOf { size(it) } ?: 0L
    fun databaseBytes(): Long = listOf("streamsetu.db", "streamsetu.db-wal", "streamsetu.db-shm").sumOf { context.getDatabasePath(it).let { f -> if (f.exists()) f.length() else 0L } }
    fun imageCacheBytes(): Long = size(File(context.cacheDir, "image_cache"))
    fun clearImageCache() { File(context.cacheDir, "image_cache").deleteRecursively(); runCatching { clearMemoryImages() } }

    /** Rebuilds the search index from the catalog tables. Nothing the person made is touched. */
    suspend fun rebuildSearchIndex(): Int = withContext(Dispatchers.IO) {
        val raw = db.openHelper.writableDatabase
        raw.beginTransaction()
        try { raw.execSQL("DELETE FROM ${SearchIndex.TABLE}"); SearchIndex.backfill(raw); raw.setTransactionSuccessful() } finally { raw.endTransaction() }
        indexRows()
    }
    suspend fun indexRows(): Int = withContext(Dispatchers.IO) { db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM ${SearchIndex.TABLE}").use { if (it.moveToFirst()) it.getInt(0) else 0 } }
    suspend fun catalogRows(): Int = withContext(Dispatchers.IO) { db.catalog().let { it.channelTotal() + it.movieTotal() + it.seriesTotal() } }

    /** Removes episodes of series that are gone, then compacts the database. */
    suspend fun cleanObsolete(): Int = withContext(Dispatchers.IO) {
        val n = db.catalog().deleteOrphanEpisodes()
        runCatching { db.openHelper.writableDatabase.execSQL("VACUUM") }
        n
    }

    // ---- Backup / restore ----
    suspend fun exportBackup(): String = withContext(Dispatchers.IO) {
        val root = JSONObject().put("format", "streamsetu-backup").put("version", 1).put("createdAt", System.currentTimeMillis())
        val conns = JSONArray(); sources.all().filter { !it.draft }.forEach { conns.put(JSONObject().put("id", it.id).put("name", it.name)) }
        root.put("connections", conns)
        root.put("favourites", JSONArray().also { a -> db.user().allFavorites().forEach { a.put(JSONObject().put("itemId", it.itemId).put("kind", it.kind).put("listId", it.listId).put("addedAt", it.addedAt)) } })
        root.put("folders", JSONArray().also { a -> db.folders().all().forEach { a.put(JSONObject().put("scope", it.scope).put("folderId", it.folderId).put("favorite", it.favorite).put("pinned", it.pinned).put("hidden", it.hidden).put("locked", it.locked).put("alias", it.alias ?: JSONObject.NULL).put("sortIndex", it.sortIndex)) } })
        root.put("progress", JSONArray().also { a -> db.user().allProgressNow().forEach { a.put(JSONObject().put("itemId", it.itemId).put("kind", it.kind).put("seriesId", it.seriesId ?: JSONObject.NULL).put("positionMs", it.positionMs).put("durationMs", it.durationMs).put("updatedAt", it.updatedAt).put("completed", it.completed)) } })
        root.put("history", JSONArray().also { a -> db.user().logNow().forEach { a.put(JSONObject().put("itemId", it.itemId).put("kind", it.kind).put("title", it.title).put("playedAt", it.playedAt)) } })
        root.put("collections", JSONArray().also { a -> db.extras().allCollections().forEach { a.put(JSONObject().put("id", it.id).put("name", it.name).put("scope", it.scope)) } })
        root.put("collectionItems", JSONArray().also { a -> db.extras().allCollectionItems().forEach { a.put(JSONObject().put("collectionId", it.collectionId).put("itemId", it.itemId).put("addedAt", it.addedAt)) } })
        val prefs = JSONObject()
        prefFiles.forEach { f -> val o = JSONObject(); context.getSharedPreferences(f, Context.MODE_PRIVATE).all.forEach { (k, v) -> if (v != null) o.put(k, v) }; prefs.put(f, o) }
        root.put("preferences", prefs)
        root.toString(2)
    }

    /** Checks the file before changing anything; throws a message the person can read. */
    fun validateBackup(text: String): JSONObject {
        val o = runCatching { JSONObject(text) }.getOrNull() ?: error("That file is not a StreamSetu backup.")
        if (o.optString("format") != "streamsetu-backup") error("That file is not a StreamSetu backup.")
        if (o.optInt("version", 0) !in 1..1) error("This backup was made by a newer version of StreamSetu.")
        return o
    }

    suspend fun restoreBackup(text: String): RestoreResult = withContext(Dispatchers.IO) {
        val o = validateBackup(text)
        // Connections get new ids on a new device; entries are matched to this device's connections by name and rewritten.
        val old = o.optJSONArray("connections") ?: JSONArray()
        val current = sources.all().associateBy { it.name.lowercase() }
        val remap = HashMap<String, String>()
        for (i in 0 until old.length()) { val c = old.getJSONObject(i); current[c.getString("name").lowercase()]?.let { remap[c.getString("id")] = it.id } }
        var skipped = 0
        fun fix(id: String): String? { val head = id.substringBefore(':'); if (head in remap.values) return id; val to = remap[head] ?: return null.also { skipped++ }; return to + id.substring(head.length) }
        var fav = 0; var fol = 0; var prog = 0; var hist = 0
        val u = db.user()
        o.optJSONArray("favourites")?.let { a -> for (i in 0 until a.length()) { val e = a.getJSONObject(i); val id = fix(e.getString("itemId")) ?: continue; u.putFavorite(FavoriteEntity(id, e.getString("kind"), e.getString("listId"), e.optLong("addedAt"))); fav++ } }
        o.optJSONArray("folders")?.let { a -> for (i in 0 until a.length()) { val e = a.getJSONObject(i); val id = fix(e.getString("folderId")) ?: continue
            db.folders().put(FolderPrefEntity(e.getString("scope"), id, e.optBoolean("favorite"), e.optBoolean("pinned"), e.optBoolean("hidden"), e.optBoolean("locked"), if (e.isNull("alias")) null else e.getString("alias"), e.optInt("sortIndex", -1))); fol++ } }
        o.optJSONArray("progress")?.let { a -> for (i in 0 until a.length()) { val e = a.getJSONObject(i); val id = fix(e.getString("itemId")) ?: continue
            val existing = u.progress(id); if (existing != null && existing.updatedAt > e.optLong("updatedAt")) continue          // a newer position on this device wins
            u.putProgress(ProgressEntity(id, e.getString("kind"), if (e.isNull("seriesId")) null else fix(e.getString("seriesId")), e.optLong("positionMs"), e.optLong("durationMs"), e.optLong("updatedAt"), e.optBoolean("completed"))); prog++ } }
        o.optJSONArray("history")?.let { a -> val rows = ArrayList<WatchLogEntity>(); for (i in 0 until a.length()) { val e = a.getJSONObject(i); val id = fix(e.getString("itemId")) ?: continue; rows += WatchLogEntity(0, id, e.getString("kind"), e.optString("title"), e.optLong("playedAt")) }; u.putLog(rows); hist = rows.size }
        o.optJSONArray("collections")?.let { a -> for (i in 0 until a.length()) { val e = a.getJSONObject(i); db.extras().putCollection(CollectionEntity(e.getString("id"), e.getString("name"), e.getString("scope"), System.currentTimeMillis())) } }
        o.optJSONArray("collectionItems")?.let { a -> for (i in 0 until a.length()) { val e = a.getJSONObject(i); val id = fix(e.getString("itemId")) ?: continue; db.extras().putItem(CollectionItemEntity(e.getString("collectionId"), id, e.optLong("addedAt"))) } }
        o.optJSONObject("preferences")?.let { p -> prefFiles.forEach { f -> p.optJSONObject(f)?.let { vals ->
            val ed = context.getSharedPreferences(f, Context.MODE_PRIVATE).edit()
            vals.keys().forEach { k -> when (val v = vals.get(k)) { is Boolean -> ed.putBoolean(k, v); is Int -> ed.putInt(k, v); is Long -> ed.putLong(k, v); is Double -> ed.putFloat(k, v.toFloat()); is String -> ed.putString(k, v) } }
            ed.apply() } } }
        RestoreResult(fav, fol, prog, hist, skipped)
    }

    /** What this connection delivered: guide data, catch-up channels, movies, series, live channels. */
    suspend fun capabilities(source: Source): SourceCapabilities = withContext(Dispatchers.IO) {
        val d = db.browse()
        SourceCapabilities(d.programmesFor(source.id) > 0, d.channelsWithGuideId(source.id), d.channelsWithCatchUp(source.id) > 0, d.channelsWithCatchUp(source.id), source.movieCount > 0, source.seriesCount > 0, source.channelCount > 0)
    }

    // ---- Resets ----
    /** Every setting back to its default. Connections, favourites, folders and progress stay. */
    fun resetSettings() { listOf("settings", "ui", "sort").forEach { context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().apply() } }

    /** Removes the person's marks on folders of one section (order, hidden, locked, labels). Provider content is untouched. */
    suspend fun resetFolderPrefs(kind: ContentKind) = db.folders().reset(kind.name)

    /** Everything stored here: connections, logins, catalogs, favourites, folders, progress and settings. */
    suspend fun deleteAllLocalData() = withContext(Dispatchers.IO) {
        sources.all().forEach { sources.remove(it.id) }
        db.clearAllTables()
        runCatching { db.openHelper.writableDatabase.execSQL("DELETE FROM ${SearchIndex.TABLE}") }
        listOf("settings", "ui", "sort", "search", "library", "parental", "account-formats").forEach { context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().apply() }
        clearImageCache(); library.close()
    }

    // ---- Diagnostics ----
    /** A report with no logins and no addresses. */
    suspend fun diagnosticsReport(playback: Map<String, String>, errors: List<String>, appVersion: String): String = withContext(Dispatchers.IO) {
        val sb = StringBuilder()
        sb.appendLine("StreamSetu diagnostics  ·  $appVersion")
        sb.appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL}  ·  Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        sb.appendLine("Hardware video decoders: " + hardwareDecoders().joinToString(", ").ifBlank { "none found" })
        sb.appendLine()
        sb.appendLine("Connections")
        sources.all().forEach { s -> sb.appendLine("  ${s.name}  ·  ${s.type}  ·  ${if (s.draft) "unfinished" else s.status}  ·  ${s.channelCount} live, ${s.movieCount} movies, ${s.seriesCount} series  ·  last read ${if (s.lastSyncAt > 0) java.util.Date(s.lastSyncAt) else "never"}" + (s.lastError?.let { "  ·  error: ${redact(it)}" } ?: "")) }
        sb.appendLine()
        sb.appendLine("Catalog rows ${catalogRows()}  ·  search index rows ${indexRows()}")
        sb.appendLine()
        sb.appendLine("Playback")
        playback.forEach { (k, v) -> sb.appendLine("  $k: $v") }
        sb.appendLine()
        File(context.filesDir, "crashes").listFiles()?.sortedByDescending { it.lastModified() }?.take(3)?.let { crashes -> sb.appendLine("Recent crashes"); if (crashes.isEmpty()) sb.appendLine("  none") else crashes.forEach { f -> sb.appendLine("  ${f.name}"); runCatching { f.readLines().take(8) }.getOrDefault(emptyList()).forEach { l -> sb.appendLine("    " + redact(l)) } }; sb.appendLine() }
        sb.appendLine("Recent player errors")
        if (errors.isEmpty()) sb.appendLine("  none") else errors.forEach { sb.appendLine("  " + redact(it)) }
        sb.toString()
    }

    fun hardwareDecoders(): List<String> = runCatching {
        val list = android.media.MediaCodecList(android.media.MediaCodecList.ALL_CODECS).codecInfos.filter { !it.isEncoder }
        listOf("video/avc" to "H.264", "video/hevc" to "H.265 (HEVC)", "video/x-vnd.on2.vp9" to "VP9", "video/av01" to "AV1", "video/dolby-vision" to "Dolby Vision").filter { (mime, _) ->
            list.any { c -> c.supportedTypes.any { it.equals(mime, true) } && (Build.VERSION.SDK_INT < 29 || c.isHardwareAccelerated) && !c.name.startsWith("OMX.google") && !c.name.startsWith("c2.android") }
        }.map { it.second }
    }.getOrDefault(emptyList())

    companion object {
        /** Takes web addresses and password-like values out of text before it is shown or exported. */
        fun redact(text: String): String = text.replace(Regex("""(?i)(https?|rtmp|rtsp)://\S+"""), "<address>").replace(Regex("""(?i)(password|pass|pwd|token|username|user)=[^&\s]+"""), "$1=<hidden>")
    }
}
