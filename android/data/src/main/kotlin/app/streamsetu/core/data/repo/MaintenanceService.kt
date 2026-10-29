package app.streamsetu.core.data.repo

import android.content.Context
import android.os.Build
import androidx.room.withTransaction
import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore

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

    /**
     * Restores a backup in two steps. First the whole file is read and checked (every kind and scope is a known one, text and numbers are sane, nothing is absurdly large); a file with
     * anything wrong in it stops here with a message and changes nothing. Then everything is written in one database transaction, so a failure part-way leaves the device as it was.
     * The settings are written last, once the data has gone in. Restoring settings needs the app to start again for them to apply (the screens that call this do that).
     */
    suspend fun restoreBackup(text: String): RestoreResult = withContext(Dispatchers.IO) {
        val o = validateBackup(text)
        // Connections get new ids on a new device; entries are matched to this device's connections by name and rewritten.
        val old = o.optJSONArray("connections") ?: JSONArray()
        val current = sources.all().associateBy { it.name.lowercase() }
        val remap = HashMap<String, String>()
        for (i in 0 until old.length()) { val c = old.getJSONObject(i); current[c.getString("name").lowercase()]?.let { remap[c.getString("id")] = it.id } }
        var skipped = 0
        fun fix(id: String): String? { val head = id.substringBefore(':'); if (head in remap.values) return id; val to = remap[head] ?: return null.also { skipped++ }; return to + id.substring(head.length) }

        val kinds = ContentKind.entries.map { it.name }.toSet()
        fun rows(name: String): JSONArray { val a = o.optJSONArray(name) ?: return JSONArray(); if (a.length() > MAX_BACKUP_ROWS) error("The backup's $name list is too long to be a real one."); return a }
        fun obj(a: JSONArray, i: Int, list: String): JSONObject = a.optJSONObject(i) ?: error("The backup is damaged ($list entry ${i + 1} is not an entry).")
        fun str(e: JSONObject, k: String, list: String, max: Int = 600, allowEmpty: Boolean = false): String {
            val v = e.optString(k, "")
            if (e.has(k) && e.get(k) !is String) error("The backup is damaged ($list has a $k that is not text).")
            if ((!allowEmpty && v.isBlank()) || v.length > max) error("The backup is damaged ($list has a missing or oversized $k).")
            return v
        }
        fun kind(e: JSONObject, k: String, list: String): String = str(e, k, list, 20).also { if (it !in kinds) error("The backup has an unknown kind \"${it.take(20)}\" in $list.") }
        fun num(e: JSONObject, k: String, list: String, default: Long = 0): Long { val v = e.optLong(k, default); if (v < -1) error("The backup is damaged ($list has a negative $k)."); return v }

        val favourites = ArrayList<FavoriteEntity>(); val folders = ArrayList<FolderPrefEntity>(); val progress = ArrayList<ProgressEntity>(); val history = ArrayList<WatchLogEntity>()
        val collections = ArrayList<CollectionEntity>(); val collectionItems = ArrayList<CollectionItemEntity>()
        rows("favourites").let { a -> for (i in 0 until a.length()) { val e = obj(a, i, "favourites"); val id = fix(str(e, "itemId", "favourites")) ?: continue
            favourites += FavoriteEntity(id, kind(e, "kind", "favourites"), str(e, "listId", "favourites", 80), num(e, "addedAt", "favourites")) } }
        rows("folders").let { a -> for (i in 0 until a.length()) { val e = obj(a, i, "folders"); val id = fix(str(e, "folderId", "folders")) ?: continue
            folders += FolderPrefEntity(kind(e, "scope", "folders"), id, e.optBoolean("favorite"), e.optBoolean("pinned"), e.optBoolean("hidden"), e.optBoolean("locked"), if (e.isNull("alias")) null else str(e, "alias", "folders", 200), e.optInt("sortIndex", -1)) } }
        val u = db.user()
        rows("progress").let { a -> for (i in 0 until a.length()) { val e = obj(a, i, "progress"); val id = fix(str(e, "itemId", "progress")) ?: continue
            val updated = num(e, "updatedAt", "progress")
            progress += ProgressEntity(id, kind(e, "kind", "progress"), if (e.isNull("seriesId")) null else fix(str(e, "seriesId", "progress")), num(e, "positionMs", "progress"), num(e, "durationMs", "progress"), updated, e.optBoolean("completed")) } }
        rows("history").let { a -> for (i in 0 until a.length()) { val e = obj(a, i, "history"); val id = fix(str(e, "itemId", "history")) ?: continue
            history += WatchLogEntity(0, id, kind(e, "kind", "history"), str(e, "title", "history", 400, allowEmpty = true), num(e, "playedAt", "history")) } }
        rows("collections").let { a -> for (i in 0 until a.length()) { val e = obj(a, i, "collections")
            collections += CollectionEntity(str(e, "id", "collections", 80), str(e, "name", "collections", 200), kind(e, "scope", "collections").uppercase(), System.currentTimeMillis()) } }
        rows("collectionItems").let { a -> for (i in 0 until a.length()) { val e = obj(a, i, "collectionItems"); val id = fix(str(e, "itemId", "collectionItems")) ?: continue
            collectionItems += CollectionItemEntity(str(e, "collectionId", "collectionItems", 80), id, num(e, "addedAt", "collectionItems")) } }
        val prefOps = ArrayList<Pair<String, JSONObject>>()
        o.optJSONObject("preferences")?.let { p -> prefFiles.forEach { f -> p.optJSONObject(f)?.let { vals ->
            if (vals.length() > 500) error("The backup's $f settings are too many to be real ones.")
            vals.keys().forEach { k -> val v = vals.get(k); if (k.length > 120 || (v is String && v.length > 20_000) || !(v is Boolean || v is Int || v is Long || v is Double || v is String)) error("The backup's $f settings contain something that is not a setting.") }
            prefOps += f to vals } } }

        db.withTransaction {
            favourites.forEach { u.putFavorite(it) }
            folders.forEach { db.folders().put(it) }
            progress.forEach { e -> val existing = u.progress(e.itemId); if (existing == null || existing.updatedAt <= e.updatedAt) u.putProgress(e) }          // a newer position on this device wins
            if (history.isNotEmpty()) u.putLog(history)
            collections.forEach { db.extras().putCollection(it) }
            collectionItems.forEach { db.extras().putItem(it) }
        }
        prefOps.forEach { (f, vals) ->
            val ed = context.getSharedPreferences(f, Context.MODE_PRIVATE).edit()
            vals.keys().forEach { k -> when (val v = vals.get(k)) { is Boolean -> ed.putBoolean(k, v); is Int -> ed.putInt(k, v); is Long -> ed.putLong(k, v); is Double -> ed.putFloat(k, v.toFloat()); is String -> ed.putString(k, v) } }
            ed.commit()
        }
        RestoreResult(favourites.size, folders.size, progress.size, history.size, skipped)
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

    /**
     * Everything this app keeps on the device, as one inventory, so erasing and checking use the same list:
     *  - the database: every table, the ones Room knows and the ones made by hand (profiles and their saved rows, the Wi-Fi sync log, the search index);
     *  - every preferences file (settings, logins, integrations, recordings schedule, downloads list, PIN state, ...) and the Keystore keys that sealed the logins;
     *  - every file the app owns: its private files (crash reports), its folder on shared storage (recordings, saved titles, backups, reports, screenshots) and its caches.
     * The caller stops what is running first (playback, recordings, downloads, Wi-Fi sync); see AppContainer.eraseEverything.
     */
    suspend fun deleteAllLocalData() = withContext(Dispatchers.IO) {
        sources.all().forEach { sources.remove(it.id) }
        db.clearAllTables()
        val sdb = db.openHelper.writableDatabase
        val tables = sdb.query("SELECT name, sql FROM sqlite_master WHERE type = 'table'").use { c -> buildList { while (c.moveToNext()) add(c.getString(0) to (c.getString(1) ?: "")) } }
        val virtual = tables.filter { it.second.startsWith("CREATE VIRTUAL TABLE", true) }.map { it.first }
        for ((name, _) in tables) {
            if (name in setOf("android_metadata", "sqlite_sequence", "room_master_table") || name.startsWith("sqlite_")) continue
            if (virtual.any { name != it && name.startsWith(it + "_") }) continue          // the hidden tables of a search index go with their index
            runCatching { sdb.execSQL("DELETE FROM `$name`") }
        }
        Profiles.create(sdb); LanLog.create(sdb)          // the one profile every install has, and the sync switch the triggers read
        val prefsDir = File(context.applicationInfo.dataDir, "shared_prefs")
        prefsDir.listFiles()?.map { it.name.removeSuffix(".xml") }.orEmpty().forEach { name ->
            context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
            File(prefsDir, "$name.xml").delete()
        }
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.let { ks -> listOf("streamsetu.credentials", "streamsetu.credentials.rsa").forEach { if (ks.containsAlias(it)) ks.deleteEntry(it) } } }
        ownedFolders().forEach { dir -> dir.listFiles()?.forEach { it.deleteRecursively() } }
        clearImageCache(); library.close()
    }

    private fun ownedFolders(): List<File> = listOfNotNull(context.filesDir, context.cacheDir, context.getExternalFilesDir(null), context.externalCacheDir)

    /** What is still there after an erase. Empty means the device holds nothing of this app's (the defaults every install starts with are not counted). */
    suspend fun leftoversAfterErase(): List<String> = withContext(Dispatchers.IO) {
        val out = ArrayList<String>()
        val sdb = db.openHelper.writableDatabase
        val tables = sdb.query("SELECT name, sql FROM sqlite_master WHERE type = 'table'").use { c -> buildList { while (c.moveToNext()) add(c.getString(0) to (c.getString(1) ?: "")) } }
        val virtual = tables.filter { it.second.startsWith("CREATE VIRTUAL TABLE", true) }.map { it.first }
        for ((name, _) in tables) {
            if (name in setOf("android_metadata", "sqlite_sequence", "room_master_table", "lan_flag", "profile_state") || name.startsWith("sqlite_")) continue
            if (virtual.any { name != it && name.startsWith(it + "_") }) continue
            val n = sdb.query("SELECT COUNT(*) FROM `$name`").use { if (it.moveToFirst()) it.getInt(0) else 0 }
            val default = name == "profiles" && n == 1
            if (n > 0 && !default) out += "table $name ($n rows)"
        }
        File(context.applicationInfo.dataDir, "shared_prefs").listFiles()?.filter { it.name.endsWith(".xml") }?.forEach { f ->
            if (context.getSharedPreferences(f.name.removeSuffix(".xml"), Context.MODE_PRIVATE).all.isNotEmpty()) out += "settings file ${f.name}"
        }
        ownedFolders().forEach { dir -> dir.listFiles()?.forEach { out += "file ${dir.name}/${it.name}" } }
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.let { ks -> listOf("streamsetu.credentials", "streamsetu.credentials.rsa").filter { ks.containsAlias(it) }.forEach { out += "key $it" } } }
        out
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
        private const val MAX_BACKUP_ROWS = 500_000
        /** Takes web addresses and password-like values out of text before it is shown or exported. */
        fun redact(text: String): String = text.replace(Regex("""(?i)(https?|rtmp|rtsp)://\S+"""), "<address>").replace(Regex("""(?i)(password|pass|pwd|token|username|user)=[^&\s]+"""), "$1=<hidden>")
    }
}
