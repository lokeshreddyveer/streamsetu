package app.streamsetu.tv.hub

import android.content.Context
import app.streamsetu.core.data.hub.HubAccess
import app.streamsetu.core.data.hub.HubFlags
import app.streamsetu.core.data.hub.HubSecretStore
import app.streamsetu.core.data.hub.HubSource
import app.streamsetu.core.security.CredentialStore
import app.streamsetu.tv.BuiltInFanart
import app.streamsetu.tv.BuiltInTvdb

/** The person's own keys (and the saved TheTVDB token) in the Keystore-backed credential store; nothing secret in plain preferences. */
class CredentialHubSecrets(private val store: CredentialStore) : HubSecretStore {
    override fun get(account: String): String? = store.load(account)
    override fun set(account: String, value: String?) { if (value.isNullOrEmpty()) store.delete(account) else store.save(account, value) }
}

/** Toggles and the 7-day pause marker: plain preferences (not secret). */
class PrefsHubFlags(context: Context) : HubFlags {
    private val p = context.applicationContext.getSharedPreferences("hub_flags", Context.MODE_PRIVATE)
    override fun getLong(key: String): Long? = if (p.contains(key)) p.getLong(key, 0) else null
    override fun setLong(key: String, v: Long?) { p.edit().apply { if (v == null) remove(key) else putLong(key, v) }.apply() }
    override fun getBool(key: String): Boolean? = if (p.contains(key)) p.getBoolean(key, false) else null
    override fun setBool(key: String, v: Boolean) { p.edit().putBoolean(key, v).apply() }
}

/** The access of each extra service as the app uses it: own key first, then the key built into this build (if any), else off. */
object HubRuntime {
    fun secrets(c: app.streamsetu.tv.AppContainer): HubSecretStore = CredentialHubSecrets(c.credentials)
    fun access(c: app.streamsetu.tv.AppContainer, context: Context, source: HubSource): HubAccess =
        HubAccess(source, secrets(c), PrefsHubFlags(context), { when (source) { HubSource.FANART -> BuiltInFanart.token(); HubSource.TVDB -> BuiltInTvdb.token(); else -> null } })
}
