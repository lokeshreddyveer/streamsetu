package app.streamsetu.core.security

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
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

/**
 * AES-GCM; the encrypted text is kept in private preferences.
 *  - Android 6 and later: the AES key is made by, and never leaves, the Android Keystore.
 *  - Android 5.x (the Keystore cannot make AES keys there): a random AES key is made by the app and kept in the same preferences wrapped (RSA) by a key pair that does live in the
 *    Keystore. The wrapped key is no use without the Keystore on this device, but the AES key itself does pass through app memory while it is in use, which is why this is the weaker path.
 */
class KeystoreCredentialStore(private val context: Context) : CredentialStore {
    private val prefs: SharedPreferences = context.getSharedPreferences("credentials", Context.MODE_PRIVATE)
    private val random = java.security.SecureRandom()

    private fun key(): SecretKey = if (Build.VERSION.SDK_INT >= 23) keystoreKey() else wrappedKey()

    @android.annotation.TargetApi(23)          // only called on Android 6 and later (see key())
    private fun keystoreKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(android.security.keystore.KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return gen.generateKey()
    }

    @Suppress("DEPRECATION")
    private fun wrappedKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(RSA_ALIAS)) {
            val from = java.util.Calendar.getInstance(); val to = java.util.Calendar.getInstance().apply { add(java.util.Calendar.YEAR, 30) }
            val spec = android.security.KeyPairGeneratorSpec.Builder(context).setAlias(RSA_ALIAS).setSubject(javax.security.auth.x500.X500Principal("CN=StreamSetu"))
                .setSerialNumber(java.math.BigInteger.ONE).setStartDate(from.time).setEndDate(to.time).build()
            java.security.KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
        }
        val entry = ks.getEntry(RSA_ALIAS, null) as java.security.KeyStore.PrivateKeyEntry
        val saved = prefs.getString(WRAPPED, null)
        if (saved != null) {
            val unwrap = Cipher.getInstance("RSA/ECB/PKCS1Padding").apply { init(Cipher.DECRYPT_MODE, entry.privateKey) }
            return javax.crypto.spec.SecretKeySpec(unwrap.doFinal(Base64.decode(saved, Base64.NO_WRAP)), "AES")
        }
        val raw = ByteArray(32).also { random.nextBytes(it) }
        val wrap = Cipher.getInstance("RSA/ECB/PKCS1Padding").apply { init(Cipher.ENCRYPT_MODE, entry.certificate.publicKey) }
        prefs.edit().putString(WRAPPED, Base64.encodeToString(wrap.doFinal(raw), Base64.NO_WRAP)).commit()
        return javax.crypto.spec.SecretKeySpec(raw, "AES")
    }

    override fun save(ref: String, secret: String) {
        // A Keystore key chooses its own IV and refuses one handed to it (Android 6 and later); the older software key on Android 5 needs one from here.
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply {
            if (Build.VERSION.SDK_INT >= 23) init(Cipher.ENCRYPT_MODE, key())
            else init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(128, ByteArray(12).also { random.nextBytes(it) }))
        }
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

    private companion object { const val ALIAS = "streamsetu.credentials"; const val RSA_ALIAS = "streamsetu.credentials.rsa"; const val WRAPPED = "__wrapped_key" }
}
