package app.streamsetu.core.security

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Where passwords live. Never the database, never a log. */
interface CredentialStore {
    fun save(ref: String, secret: String)
    fun load(ref: String): String?
    fun delete(ref: String)
}

/** Holds secrets in memory only; for tests. */
class InMemoryCredentialStore : CredentialStore {
    private val map = HashMap<String, String>()
    override fun save(ref: String, secret: String) { map[ref] = secret }
    override fun load(ref: String) = map[ref]
    override fun delete(ref: String) { map.remove(ref) }
}

/** AES-GCM with a key that never leaves the Android Keystore; the encrypted text is kept in private preferences. */
class KeystoreCredentialStore(context: Context) : CredentialStore {
    private val prefs: SharedPreferences = context.getSharedPreferences("credentials", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return gen.generateKey()
    }

    override fun save(ref: String, secret: String) {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val data = c.doFinal(secret.toByteArray())
        prefs.edit().putString(ref, Base64.encodeToString(c.iv + data, Base64.NO_WRAP)).apply()
    }

    override fun load(ref: String): String? {
        val raw = prefs.getString(ref, null) ?: return null
        return runCatching {
            val bytes = Base64.decode(raw, Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12)) }
            String(c.doFinal(bytes, 12, bytes.size - 12))
        }.getOrNull()
    }

    override fun delete(ref: String) { prefs.edit().remove(ref).apply() }

    private companion object { const val ALIAS = "streamsetu.credentials" }
}
