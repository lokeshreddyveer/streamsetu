package app.streamsetu.core.data.repo

import android.content.Context
import app.streamsetu.core.addon.*
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.Source
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.model.SyncStatus
import app.streamsetu.core.net.Http
import app.streamsetu.core.security.CredentialStore
import app.streamsetu.core.sync.AddonSync
import app.streamsetu.core.sync.CatalogStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext

/** An add-on that is installed: its description, who vouches for it, and the connection it fills. */
data class InstalledAddon(val manifest: AddonManifest, val trust: AddonTrust, val source: Source) {
    val enabled get() = source.enabled
}

/**
 * The add-ons the person installed. Each one is a connection (type Add-on) whose catalog is read through [AddonClient], so it appears in Libraries like any other, is read in the
 * background, and a failing add-on only marks its own connection as failed: nothing already saved from any other connection is touched.
 * An add-on's sign-in is saved with the same credential store as a playlist's, under that connection's own reference, and is attached only to requests for the add-on's own servers.
 */
class AddonRegistry(context: Context, private val db: AppDatabase, private val sources: SourceRepository, private val credentials: CredentialStore, private val client: AddonClient = AddonClient(), private val listKey: String = OfficialAddons.PUBLIC_KEY, private val bundledSource: (() -> Pair<String, String>)? = null, storage: android.content.SharedPreferences? = null) {
    private val prefs = storage ?: context.applicationContext.getSharedPreferences("addons", Context.MODE_PRIVATE)

    companion object {
        fun sourceId(addonId: String) = "addon.$addonId"
        fun addonId(sourceId: String) = sourceId.removePrefix("addon.")
        /** The Authorization value for a sign-in, or null when the add-on needs none. */
        fun authorization(manifest: AddonManifest, username: String?, secret: String?): String? = when (manifest.auth) {
            AddonAuth.NONE -> null
            AddonAuth.USERNAME_PASSWORD -> if (!username.isNullOrBlank() && !secret.isNullOrEmpty()) Http.basic(username, secret) else null
            AddonAuth.TOKEN -> secret?.takeIf { it.isNotEmpty() }?.let { "Bearer $it" }
        }
    }

    /** Reads a description from an address the person typed. Nothing is saved. */
    suspend fun preview(url: String): Pair<String, ManifestResult> = withContext(Dispatchers.IO) { client.fetchManifest(url).let { it to AddonManifestParser.parse(it) } }

    /**
     * Installs a description that passed [AddonManifestParser]. A description from an address is [AddonTrust.COMMUNITY]; one the person pasted or opened from a file is
     * [AddonTrust.LOCAL]; [AddonTrust.OFFICIAL] is only ever given by the app's own signed list (not part of this version).
     */
    suspend fun install(text: String, trust: AddonTrust, username: String? = null, secret: String? = null): InstalledAddon {
        if (trust == AddonTrust.OFFICIAL) throw AddonException("Only the app's own list can mark an add-on official.")
        return installChecked(text, trust, username, secret)
    }

    /** The newest verified list the app already has (the last one checked, or the one that came with the app), with no network at all. Shown at once. */
    suspend fun localOfficial(): OfficialAddons.Resolved = withContext(Dispatchers.IO) { OfficialAddons.local(cachedList(), bundledList(), highestSequence()) }

    /**
     * Asks the list server and returns what to show now. The list and its signature are fetched side by side with a short time limit; a list that is newer than every list ever accepted
     * is kept (and its number remembered, so an older signed list can never be accepted again); anything else leaves the newest verified list the app has, with a note saying why.
     */
    suspend fun refreshOfficial(): OfficialAddons.Resolved = withContext(Dispatchers.IO) {
        var text: String? = null; var sig: String? = null; var problem: String? = null
        val remote = try {
            kotlinx.coroutines.coroutineScope {
                val t = async { client.fetchManifest(OfficialAddons.LIST_URL) }; val g = async { client.fetchManifest(OfficialAddons.SIGNATURE_URL).trim() }
                text = t.await(); sig = g.await()
            }
            OfficialAddons.verifiedList(text!!, sig!!, listKey)
        } catch (e: Exception) { problem = (e as? AddonException)?.message ?: "no answer"; null }
        val chosen = OfficialAddons.resolve(remote, problem, cachedList(), bundledList(), highestSequence())
        if (chosen.origin == OfficialAddons.Origin.REMOTE && text != null && sig != null) {
            // The list, its signature and its number are written together and to disk before the list is reported as accepted: if that fails, it was not accepted.
            if (!prefs.edit().putString("official.list", text).putString("official.sig", sig).putLong("official.seq", chosen.sequence).commit()) throw AddonException("The new list of official add-ons could not be saved, so it was not used.")
        }
        chosen
    }

    private fun cachedList() = runCatching { OfficialAddons.verifiedList(prefs.getString("official.list", null) ?: error("none"), prefs.getString("official.sig", null) ?: error("none"), listKey) }.getOrNull()          // checked again every time it is read: a damaged file is not used
    private fun bundledList() = runCatching { val (t, g) = bundledSource?.invoke() ?: (assetText("addons/registry.json") to assetText("addons/registry.json.sig")); OfficialAddons.verifiedList(t, g, listKey) }.getOrNull()
    /** The highest list number ever accepted, kept apart from the list itself so that losing the saved list does not allow an older one back. */
    private fun highestSequence() = prefs.getLong("official.seq", 0L)

    private val appContext = context.applicationContext
    private fun assetText(path: String) = appContext.assets.open(path).bufferedReader().use { it.readText() }

    /** The description of an approved add-on, for the person to read first. It is refused if it is not exactly the one the list approved. */
    suspend fun previewOfficial(entry: OfficialEntry): Pair<String, ManifestResult> = withContext(Dispatchers.IO) {
        val text = client.fetchManifest(entry.manifestUrl)
        if (OfficialAddons.sha256Hex(text) != entry.sha256.lowercase()) throw AddonException("${entry.name} has changed since it was approved, so it was not used.")
        val parsed = AddonManifestParser.parse(text)
        if (parsed is ManifestResult.Valid && parsed.manifest.id != entry.id) throw AddonException("${entry.name} does not match the approved list.")
        text to parsed
    }

    /** Installs an add-on of the list as [AddonTrust.OFFICIAL]: it is read again and checked against the list's fingerprint at this moment, not trusted from an earlier look. */
    suspend fun installOfficial(entry: OfficialEntry, username: String? = null, secret: String? = null): InstalledAddon {
        val (text, _) = previewOfficial(entry)
        return installChecked(text, AddonTrust.OFFICIAL, username, secret)
    }

    private suspend fun installChecked(text: String, trust: AddonTrust, username: String?, secret: String?): InstalledAddon {
        val m = when (val r = AddonManifestParser.parse(text)) { is ManifestResult.Valid -> r.manifest; is ManifestResult.Refused -> throw AddonException(r.reasons.first()) }
        if (sources.get(sourceId(m.id)) != null) throw AddonException("${m.name} is already installed.")
        // An add-on's guide address is never stored on the connection: the generic guide reader would fetch it outside the add-on's limits (size, time, hosts, public addresses only).
        val s = sources.add(Source(id = sourceId(m.id), name = m.name, type = SourceType.ADDON, address = m.id, username = username?.trim()?.takeIf { it.isNotEmpty() }, epgUrl = null), secret)
        prefs.edit().putString("m.${m.id}", text).putString("t.${m.id}", trust.name).apply()
        return InstalledAddon(m, trust, s)
    }

    suspend fun installed(): List<InstalledAddon> = sources.all().filter { it.type == SourceType.ADDON }.mapNotNull { s -> manifestOf(addonId(s.id))?.let { (m, t) -> InstalledAddon(m, t, s) } }

    private fun manifestOf(addonId: String): Pair<AddonManifest, AddonTrust>? {
        val text = prefs.getString("m.$addonId", null) ?: return null
        val m = (AddonManifestParser.parse(text) as? ManifestResult.Valid)?.manifest ?: return null          // checked again on every use: a stored description that no longer passes is not used
        return m to (runCatching { AddonTrust.valueOf(prefs.getString("t.$addonId", null).orEmpty()) }.getOrDefault(AddonTrust.LOCAL))
    }

    suspend fun setEnabled(addonId: String, on: Boolean) = sources.setEnabled(sourceId(addonId), on)

    /** Removes the add-on, everything read from it and its saved sign-in. */
    suspend fun remove(addonId: String) { sources.remove(sourceId(addonId)); prefs.edit().remove("m.$addonId").remove("t.$addonId").apply() }

    /** Forgets what was read from the add-on (it is read again at the next refresh); the add-on, its settings and its sign-in stay. */
    suspend fun clearCache(addonId: String) {
        CatalogStore(db).replace(sourceId(addonId), emptyList(), emptyList(), emptyList(), emptyList())          // takes the connection's own lock, so it waits for a refresh instead of running through it
        db.catalog().deleteOrphanEpisodes()          // the episodes of the series that were just removed
        sources.setCounts(sourceId(addonId), 0, 0, 0); sources.setStatus(sourceId(addonId), SyncStatus.NEVER, 0)
    }

    /** The add-on's catalog, read now. Runs off the main thread; a failure is an [AddonException] that says what went wrong, never a stack trace. */
    suspend fun catalog(sourceId: String): AddonCatalog = withContext(Dispatchers.IO) {
        val (m, _) = manifestOf(addonId(sourceId)) ?: throw AddonException("This add-on is no longer installed.")
        if (AddonCapability.CATALOG !in m.capabilitySet) throw AddonException("${m.name} does not provide a catalog.")
        val src = sources.get(sourceId)
        val text = client.get(m, AddonCapability.CATALOG, authorization = authorization(m, src?.username, sources.password(sourceId)))
        AddonCatalogParser.parse(text, m)
    }

    /** The play address of something the add-on listed without one ([ref] is what follows "addon:" in the stream reference), asked for when it is played. Null when the add-on has none to give. */
    suspend fun resolveStream(sourceId: String, ref: String): String? = withContext(Dispatchers.IO) {
        runCatching {
            val (m, _) = manifestOf(addonId(sourceId)) ?: return@runCatching null
            if (AddonCapability.STREAM !in m.capabilitySet) return@runCatching null
            val src = sources.get(sourceId)
            AddonCatalogParser.parseStream(client.get(m, AddonCapability.STREAM, AddonSync.lazyQuestion(ref) ?: return@runCatching null, authorization(m, src?.username, sources.password(sourceId))), m)
        }.getOrNull()
    }

}
